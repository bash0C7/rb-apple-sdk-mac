# rb-apple-sdk-mac

Runtime dynamic Ruby ↔ Apple SDK bridge for macOS. Call any public Apple framework API from Ruby with no pre-declarations.

> **v1.2 status.** Swift overlay framework (AVFoundation / AppKit / Vision /
> SwiftUI 系) の API も `bootstrap!` だけで動く。 ObjC selector → Swift
> imported name は Knowledge Base に取り込まれ (`swift_imported_name`
> column)、 ObjC↔Swift bridge 名前解決は `SwiftBridgeName` の 3 段
> resolution (Knowledge Base → 手動 override → heuristic → LLM 安全網)
> に統一された。 `examples/avspeech_synth.rb` / `examples/vision_ocr.rb`
> が end-to-end の release-quality 検収例。

## Requirements

- macOS 26+
- Ruby 4.x master with `RUBY_BOX=1` (required for namespace isolation)
- Xcode + Swift 6.3+
- Sibling gems: `rb-foundation-model-mac`, `rb-apple-sdk-knowledge`, `swift_gem`

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
AppleSDKMac.bootstrap!   # ~1 s — eager-defines Apple::<Framework> shells from the KB

client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

After `bootstrap!`, every KB-known symbol has a Ruby method shell ready to
go. The dispatcher compiles the Swift glue dylib inline on the first
invocation per symbol (~1–3 s swiftc latency); subsequent calls hit the
compiled-glue cache and dispatch in sub-millisecond time.

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

1. **The KB classification is wrong for your use case.** The knowledge base
   sometimes labels a C parameter as `:string` when you need `:opaque_ref`,
   tags a return as `:bool` when it's an `Int`, etc. Override the shape with
   explicit `params:` / `return_kind:`:

   ```ruby
   Apple.discover(
     framework: :CoreFoundation, symbol: :CFStringCreateWithCString,
     params: [:opaque_ref, :cstring, :uint32], return_kind: :opaque_ref
   )
   ```

2. **The symbol isn't in the KB at all.** Private framework methods, custom
   ObjC selectors, anything outside the indexed `*.swiftinterface` set —
   the eager method shell never gets installed because nothing told the
   namespace builder it exists. Declare the shape so the dispatcher knows
   how to compile it:

   ```ruby
   Apple.discover(
     framework: :Foundation, klass: :NSString,
     class_method: :stringWithUTF8String
   )
   ```

3. **Pre-warm.** Even for KB-known symbols, calling `Apple.discover` at boot
   avoids paying the swiftc latency on the first user-facing invocation.

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
sourced from the Apple SDK knowledge base (clang FullComment AST
ingested by `rb-apple-sdk-knowledge`):

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

Note that the knowledge base ingests Swift framework interfaces (`*.swiftinterface`),
so types appear under their Swift import names (`URL` rather than `NSURL`,
`Data` rather than `NSData`). ObjC-only types whose selectors aren't in the
KB (e.g. private framework methods) still need explicit `Apple.discover`
with `klass:` and `selector:`/`class_method:`; KB-known selectors compile
transparently on first call like everything else.

## Architecture

See `docs/superpowers/specs/2026-05-04-rb-apple-sdk-mac-design.md` in the swift_gem repo + v1.2 spec `docs/superpowers/specs/2026-05-09-v1.2-bootstrap-principle-design.md`.

The bridge is composed of:

- **Glue Runtime** (`ext/apple_sdk_mac_runtime/`): static Swift dylib with 9 pillars (Ref Table, Marshal, Callback, ARC, Error, Async, Threading, RunLoop, Conformance) bridged to CRuby via SE-0495 `@c`.
- **Ruby cache layer**: Config (XDG/ENV/YAML), CompiledGlueCache (SQLite + dylib FS), KnowledgeCache (consume rb-apple-sdk-knowledge).
- **Glue Compiler pipeline**: TemplateGenerator (deterministic shape catalog) → SwiftBridgeName (Knowledge Base + override 2 段 resolver, v1.2 で追加) → LLMGenerator fallback (rb-foundation-model-mac via Ollama) → ValidationGates (allowed imports / banned APIs / glue shape) → SwiftcInvoker.
- **Ruby runtime**: GlueLoader (dlopen + pointer cache), Dispatcher (cache miss → inline compile + invoke; transparent for KB symbols), SecurityCop (in-Box monkey patches with allow-list bypass), NamespaceBuilder (eager `Apple::<Framework>` shell definition at bootstrap), `Apple` Ruby::Box bootstrap.
- **Knowledge Base** (`knowledge/` sub-gem): `*.swiftinterface` ingester + Swift overlay ingester (v1.2 Phase 4a で追加)、 ObjC selector → Swift imported name の対応を `symbols.swift_imported_name` に保存。

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
