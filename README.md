# rb-apple-sdk-mac

Runtime dynamic Ruby ↔ Apple SDK bridge for macOS. Call any public Apple framework API from Ruby with no pre-declarations.

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
bundle exec rake apple:knowledge:rebuild   # see rb-apple-sdk-knowledge
```

## Usage

```ruby
require "apple_sdk_mac"

# Just call it. KB-known symbols compile transparently on first call.
client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

Subsequent calls hit the compiled-glue cache and dispatch directly. First-call
latency is the swiftc compile (~1–3 s); cache hits are sub-millisecond.

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

If `ENV["APPLE_SDK_DOC_LANG"]` is set to a non-English BCP-47 tag
(e.g. `ja-JP`, `fr-FR`) and the
[`rb-translation-mac`](https://github.com/bash0C7/rb-translation-mac)
gem (specifically the `translation_mac-locale` sub-gem) is
available, the doc text is translated by Apple Intelligence on the
fly via a `doc_transform` lambda hook on `DocResolver`.
`APPLE_SDK_DOC_LANG` is the documented primary input and expects
**BCP-47 only** (no charset suffix). When it is unset, `ENV["LANG"]`
is consulted as fallback and POSIX-style values like
`ja_JP.UTF-8` are accepted there too. English /
`C` / `POSIX` / unset locales pass through unchanged. The
translation gem is an optional runtime dep — sub-gem degrades
silently if absent. Per-input cache keeps the popup snappy across
re-hovers.

```
$ APPLE_SDK_DOC_LANG=ja-JP irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
> Apple::CoreFoundation::CFArrayAppendValue<TAB-hover>
  ┌─ candidates ─┐ ┌─ doc (ja-JP) ─────────────────────────┐
  │ ...          │ │ 配列に値を追加し、新しい最大インデック   │
  │              │ │ スを付与します。 値を追加する配列。      │
  └──────────────┘ └────────────────────────────────────────┘

# Or, fall back to LANG (POSIX style accepted here):
$ LANG=ja_JP.UTF-8 irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
```

Design notes and decision log: `docs/superpowers/specs/2026-05-08-irb-subgem-and-doc-discover-design.md`.

Note that the knowledge base ingests Swift framework interfaces (`*.swiftinterface`),
so types appear under their Swift import names (`URL` rather than `NSURL`,
`Data` rather than `NSData`). ObjC-only types whose selectors aren't in the
KB (e.g. private framework methods) still need explicit `Apple.discover`
with `klass:` and `selector:`/`class_method:`; KB-known selectors compile
transparently on first call like everything else.

## Architecture

See `docs/superpowers/specs/2026-05-04-rb-apple-sdk-mac-design.md` in the swift_gem repo.

The bridge is composed of:

- **Glue Runtime** (`ext/apple_sdk_mac_runtime/`): static Swift dylib with 9 pillars (Ref Table, Marshal, Callback, ARC, Error, Async, Threading, RunLoop, Conformance) bridged to CRuby via SE-0495 `@c`.
- **Ruby cache layer**: Config (XDG/ENV/YAML), CompiledGlueCache (SQLite + dylib FS), KnowledgeCache (consume rb-apple-sdk-knowledge).
- **Glue Compiler pipeline**: TemplateGenerator (deterministic shape catalog) → LLMGenerator fallback (rb-foundation-model-mac via Ollama) → ValidationGates (allowed imports / banned APIs / glue shape) → SwiftcInvoker.
- **Ruby runtime**: GlueLoader (dlopen + pointer cache), Dispatcher (cache miss → inline compile + invoke; transparent for KB symbols), SecurityCop (in-Box monkey patches with allow-list bypass), NamespaceBuilder (eager `Apple::<Framework>` shell definition at bootstrap), `Apple` Ruby::Box bootstrap.

## License

MIT
