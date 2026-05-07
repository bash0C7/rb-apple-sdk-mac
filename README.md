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

# First-time: declare you want to call this API
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

# Use it
client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

See `examples/` for more.

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

LLM-backed doc preview (popup right side, sourced from the Apple SDK
KB) and silent background prefetch on hover are tracked in
`docs/superpowers/specs/2026-05-08-irb-subgem-and-doc-discover-design.md`.

Note that the knowledge base ingests Swift framework interfaces (`*.swiftinterface`),
so types appear under their Swift import names (`URL` rather than `NSURL`,
`Data` rather than `NSData`). ObjC-only types still need explicit `Apple.discover`
with `klass:` and `selector:`/`class_method:`.

## Architecture

See `docs/superpowers/specs/2026-05-04-rb-apple-sdk-mac-design.md` in the swift_gem repo.

The bridge is composed of:

- **Glue Runtime** (`ext/apple_sdk_mac_runtime/`): static Swift dylib with 9 pillars (Ref Table, Marshal, Callback, ARC, Error, Async, Threading, RunLoop, Conformance) bridged to CRuby via SE-0495 `@c`.
- **Ruby cache layer**: Config (XDG/ENV/YAML), CompiledGlueCache (SQLite + dylib FS), KnowledgeCache (consume rb-apple-sdk-knowledge).
- **Glue Compiler pipeline**: TemplateGenerator (deterministic shape catalog) → LLMGenerator fallback (rb-foundation-model-mac via Ollama) → ValidationGates (allowed imports / banned APIs / glue shape) → SwiftcInvoker.
- **Ruby runtime**: GlueLoader (dlopen + pointer cache), Dispatcher, SecurityCop (in-Box monkey patches with allow-list bypass), NamespaceBuilder (eager `Apple::<Framework>` definition), `Apple` Ruby::Box bootstrap.

## License

MIT
