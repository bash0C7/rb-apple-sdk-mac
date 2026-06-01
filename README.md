# rb-apple-sdk-mac

> **This gem is experimental.** Ruby 4 Box namespace isolation
> (`RUBY_BOX=1`) は実験 flag、 production runtime は決定論 template で動く。
> Knowledge Base 未知 / coverage 外 symbol の Swift glue は生成保守時に
> `claude -p` ヘッドレス推論で合成され (この合成は確率的)、 round-trip 等価
> 検証を通った GREEN なものだけ採用・永続化される (production default には
> 未配線、 end user は検証済みの決定論 glue を replay)。 public API shape は
> v1.x の間に変わりうる。 production 投入は自己責任で。

Runtime dynamic Ruby ↔ Apple SDK bridge for macOS. Call any public Apple framework API from Ruby with no pre-declarations.

> Swift overlay framework (AVFoundation / AppKit / Vision / SwiftUI 系) の API も
> `bootstrap!` だけで動く。 ObjC selector → Swift imported name は Knowledge
> Base に `swift_imported_name` column として取り込まれ、 ObjC↔Swift bridge
> 名前解決は Knowledge Base lookup → 内蔵 heuristic の順 (runtime は決定論)。
> Knowledge Base 未知 symbol の glue は生成保守時の `claude -p` 推論 +
> round-trip 等価検証で起こす (runtime safety net ではない)。
> `examples/avspeech_synth.rb` / `examples/vision_ocr.rb` が end-to-end の
> release-quality 検収例。 `Apple.discover` は escape hatch 専用 (private
> framework / 第三者 framework / 自前 ObjC selector / Knowledge Base 分類の
> 上書きにのみ使う)、 `examples/discover_escape.rb` を参照。

## Requirements

- macOS 26+
- Ruby 4.x master with `RUBY_BOX=1` (required for namespace isolation)
- Xcode + Swift 6.3+
- Runtime gem dependencies: `rb-apple-sdk-knowledge` (Knowledge Base) + `sqlite3`。 主 gem はこれ以外に依存しない (IRB / Reline / foundation_model_mac 系依存は `irb/` sub-gem 側にのみ存在)
- Generation/maintenance-time のみ: `claude` CLI を PATH に (coverage 外 symbol の `claude -p` glue 推論 + round-trip rebuild 用)。 end-user runtime には不要
- Internal sub-gems (same repo, separate gemspecs): `knowledge/` (Apple SDK Knowledge Base ingester), `irb/` (IRB autocomplete + doc preview), `mcp/` (MCP server)

## Installation

```ruby
gem "rb-apple-sdk-mac"
```

After install:

```bash
bundle exec rake apple:knowledge:rebuild   # 50+ 分 / forground; CI / 単体実行向き
# あるいは長時間 detached で走らせる:
bundle exec rake apple:knowledge:rebuild_async   # screen -dmS で背景化、 tmp/longrun/<NAME>.log を tail
```

`rebuild` は ObjC framework + Swift overlay framework 両方の
`*.swiftinterface` を ingest し、 `<project>/.rb-apple-sdk-mac/knowledge/`
に SQLite を生成する。 完了後 `Apple::<Framework>::<Type>.<method>` が
全て呼び出し可能になる。

## Usage

Pick one of two startup styles, then just call the APIs.

### Recommended: bootstrap once, call freely

```ruby
require "apple_sdk_mac"
AppleSDKMac.bootstrap!   # ~1 s — eager-defines Apple::<Framework> shells from the Knowledge Base

client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

After `bootstrap!`, every Knowledge-Base-known symbol has a Ruby method
shell ready to go. The dispatcher compiles the Swift glue dylib inline on
the first invocation per symbol (~1–3 s swiftc latency); subsequent calls
hit the compiled-glue cache and dispatch in sub-millisecond time.

### Lightweight: per-symbol on-demand

If you don't want the bootstrap startup cost — e.g. a script that touches
a handful of symbols — use `Apple.discover` to set up the namespace for
just those symbols:

```ruby
require "apple_sdk_mac"
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

`Apple.discover` builds the namespace shell **and** compiles glue for the
single symbol it's given. This is the right shape for one-off scripts and
is also required for the cases the transparent path can't resolve (next
section).

### When you still need `Apple.discover`

`Apple.discover` is the manual escape hatch for cases the transparent path
cannot resolve on its own:

1. **You want to override the Knowledge Base classification.** The Knowledge
   Base sometimes labels a C parameter as `:string` when your call site needs
   `:opaque_ref`, tags a return as `:bool` when it's an `Int`, etc. Force the
   shape with explicit `params:` / `return_kind:`:

   ```ruby
   Apple.discover(
     framework: :CoreFoundation, symbol: :CFStringCreateWithCString,
     params: [:opaque_ref, :cstring, :uint32], return_kind: :opaque_ref
   )
   ```

2. **The symbol isn't in the Knowledge Base at all.** Private framework
   methods, custom ObjC selectors, anything outside the indexed
   `*.swiftinterface` set — the eager method shell never gets installed
   because nothing told the namespace builder it exists. Declare the shape so
   the dispatcher knows how to compile it:

   ```ruby
   Apple.discover(
     framework: :Foundation, klass: :NSString,
     class_method: :stringWithUTF8String
   )
   ```

3. **Pre-warm.** Even for Knowledge-Base-known symbols, calling
   `Apple.discover` at boot avoids paying the swiftc latency on the first
   user-facing invocation.

For everything else, just call the API directly. See `examples/` for more.

## IRB autocomplete

IRB / autocomplete / LLM doc preview / auto-discover prefetch features
live in the **logical sub-gem `apple_sdk_mac-irb`** under `irb/` (same
repo, separate gemspec). The main gem stays free of IRB / Reline /
foundation_model_mac dependencies.

```ruby
require "apple_sdk_mac"
require "apple_sdk_mac/irb"
AppleSDKMac::IRB.install!
```

After `install!`, a Reline completion hook lists Apple SDK frameworks,
types, and methods inside any IRB session:

```
$ irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
> Apple::<TAB>
  → ARKit, AVFAudio, AVFoundation, AVKit, AVRouting, ... (100 frameworks)
> Apple::Foundation::U<TAB>
  → URL, URLComponents, URLError, URLQueryItem, URLRequest, ... (8 types)
> Apple::Foundation::URL.<TAB>
  → appendingPathComponent, appendingPathExtension, fragment, ... (15 methods)
```

### Doc preview, prefetch, and on-the-fly translation

When the Reline autocomplete popup opens, hovering an Apple SDK
candidate fills the right-side `:show_doc` dialog with documentation
sourced from the Apple SDK Knowledge Base (clang FullComment AST
ingested by the `knowledge/` sub-gem):

- ObjC / C frameworks (CoreFoundation, Security, AudioToolbox, ARKit,
  CoreMedia, etc.) ship with rich Apple-official doc strings.
- Swift-overlay frameworks (Foundation, AppKit, SwiftUI) currently
  ship empty — Apple's compiler strips `///` from `*.swiftinterface`.
- `Apple::<Framework>` (no symbol) shows a synthesized description
  with Swift module + (when present) category / macOS minimum / doc URL.
- Non-Apple candidates fall back to IRB's standard RDoc-driven
  `:show_doc`. Errors there are caught silently so a broken `~/.ri`
  store does not leak into the prompt.

While the popup renders, the same hover triggers a **background
prefetch**: the symbol's `Apple.discover` runs in a separate Thread
so the first real call has its glue dylib already compiled.
Idempotent per `(framework, klass, name)`.

Design notes and decision log: `docs/superpowers/specs/2026-05-08-irb-subgem-and-doc-discover-design.md`.

Note that the Knowledge Base ingests Swift framework interfaces (`*.swiftinterface`),
so types appear under their Swift import names (`URL` rather than `NSURL`,
`Data` rather than `NSData`). ObjC-only types whose selectors aren't in the
Knowledge Base (e.g. private framework methods) still need explicit
`Apple.discover` with `klass:` and `selector:`/`class_method:`;
Knowledge-Base-known selectors compile transparently on first call like
everything else.

## Architecture

See `docs/superpowers/specs/2026-05-04-rb-apple-sdk-mac-design.md` in the
swift_gem repo for the original design, and
`docs/superpowers/specs/2026-05-09-v1.2-bootstrap-principle-design.md` for
the bootstrap-principle thesis.

The bridge is composed of:

- **Glue Runtime** (`ext/apple_sdk_mac_runtime/`): static Swift dylib with 9 pillars (Ref Table, Marshal, Callback, ARC, Error, Async, Threading, RunLoop, Conformance) bridged to CRuby via SE-0495 `@c`.
- **Ruby cache layer**: Config (XDG/ENV/YAML), CompiledGlueCache (SQLite + dylib FS), KnowledgeCache (reads the `knowledge/` sub-gem's SQLite output).
- **Discovery / shape resolution**: SelectorBridge (canonical method-name + acronym normalization, single source for `public_api` and `template_generator`), DiscoveryShape (`synthesize_symbol_record` + `KIND_SYM_TO_TYPE` + C-symbol param overrides).
- **Glue Compiler pipeline** (production runtime, deterministic): TemplateGenerator (deterministic shape catalog) → ObjcMarshalling (ObjC `in_load` + `return_lines` emit) → SwiftBridgeName (Knowledge Base lookup; falls through to in-template heuristic) → ValidationGates (allowed imports / banned APIs / glue shape) → SwiftcInvoker. Symbols outside the template coverage are handled at generation/maintenance time (below), not at runtime.
- **Inference + round-trip** (`inference/`, `round_trip/` — generation/maintenance-time, **not wired into the production default**): ClaudePBackend (`claude -p` headless synthesizes Swift glue from Knowledge Base symbol metadata) → ProductionRunner round-trip equivalence (generated glue vs native call must behave identically) → only GREEN glue is adopted and persisted. End users replay the persisted, round-trip-verified deterministic glue; the cloud inference path is never on the gem's public runtime path.
- **Ruby runtime**: GlueLoader (dlopen + pointer cache), Dispatcher (cache miss → inline compile + invoke; transparent for Knowledge-Base-known symbols), SecurityCop (in-Box monkey patches with allow-list bypass), NamespaceBuilder (eager `Apple::<Framework>` shell definition at bootstrap), `Apple` Ruby::Box bootstrap.
- **Knowledge Base** (`knowledge/` sub-gem): `*.swiftinterface` ingester for both ObjC frameworks and Swift overlay frameworks; ObjC selector → Swift imported name correspondence is stored in `symbols.swift_imported_name`.

## Maintainer tools (`tooling/`)

長期改善 (新 emitter 追加 / 冗長 marshaller 統合) を 2-gate HITL workflow
で回す `tooling/` サブツリー。 `bundle exec rake apple:emitter:candidates`
で compile_history + RedundancyScanner から候補を ranking、 `git worktree`
で隔離 → implementer subagent → fact bundle gate → 非 fast-forward merge と
進む。 詳細は `tooling/README.md` および
`docs/superpowers/specs/2026-05-09-hitl-emitter-improvement-design.md`。

Slash command 経由起動: `/rb-apple-sdk-mac-improve-emitter [--mode=add|trim|all] [--top=N]`

## License

MIT
