# rb-apple-sdk-mac

Runtime dynamic Ruby ↔ Apple SDK bridge for macOS. Call public Apple framework APIs from Ruby with no pre-declarations.

> **This gem is experimental.** Ruby 4 Box namespace isolation (`RUBY_BOX=1`) is an experimental Ruby feature. The production runtime emits Swift glue from a deterministic template catalog. Glue for symbols outside that catalog is synthesized at generation/maintenance time with headless `claude -p` inference, and only glue that passes a round-trip equivalence check is adopted and persisted; that inference path is not wired into the runtime default. The public API shape may change during v1.x.

Swift overlay frameworks (AVFoundation, AppKit, Vision, SwiftUI, ...) work through `bootstrap!` as well. The Knowledge Base stores the ObjC selector → Swift imported name mapping in its `swift_imported_name` column; name resolution looks up the Knowledge Base first and falls back to a built-in heuristic. `examples/avspeech_synth.rb` and `examples/vision_ocr.rb` are end-to-end acceptance examples. `Apple.discover` is an escape hatch for private frameworks, third-party frameworks, custom ObjC selectors, and overriding the Knowledge Base classification; see `examples/discover_escape.rb`.

## Requirements

- macOS 27+, Apple Silicon
- Xcode 27 (builds run `xcrun swift`; glue compiles run `xcrun swiftc`)
- Ruby 4.0+ with `RUBY_BOX=1` for namespace isolation, Bundler 4.x
- `claude` CLI on `PATH` only for generation/maintenance-time glue inference
- Runtime gem dependencies: `rb-apple-sdk-knowledge` (the `knowledge/` sub-gem) and `sqlite3`

The repository also holds these sub-gems, each with its own gemspec:

- `knowledge/` — `rb-apple-sdk-knowledge`, the Apple SDK Knowledge Base importer
- `irb/` — `apple_sdk_mac-irb`, IRB autocomplete and documentation preview
- `mcp/` — `rb-apple-sdk-mac-mcp`, an MCP server over the Knowledge Base

## Installation

Install from source:

```bash
git clone https://github.com/bash0C7/rb-apple-sdk-mac.git
cd rb-apple-sdk-mac
bundle install
bundle exec rake compile
bundle exec rake apple:knowledge:rebuild
```

`rake compile` builds the Swift runtime (`xcrun swift build -c release --package-path ext/apple_sdk_mac_runtime`) and the C extension into `lib/apple_sdk_mac/apple_sdk_mac_runtime.bundle`.

`rake apple:knowledge:rebuild` ingests the ObjC/C headers and the Swift overlay `*.swiftinterface` files of the active SDK and writes `.rb-apple-sdk-mac/knowledge/<sdk_version>/sdk_knowledge.sqlite` under the project root (the directory of the Bundler `Gemfile`). `rake apple:knowledge:rebuild_async` runs the same rebuild in a detached `screen` session and logs to `tmp/longrun/<NAME>.log`.

## Usage

Pick one of two startup styles, then call the APIs.

### Bootstrap once, call freely

```ruby
require "apple_sdk_mac"
AppleSDKMac.bootstrap!

client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

`bootstrap!` defines a Ruby method shell for every Knowledge-Base-known symbol. The first call of each symbol compiles its Swift glue dylib with `swiftc`; later calls hit the compiled-glue cache.

### Per-symbol on demand

```ruby
require "apple_sdk_mac"
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

`Apple.discover` builds the namespace shell and compiles glue for the one symbol it is given.

### When you need `Apple.discover`

1. **Override the Knowledge Base classification.** Force the shape with explicit `params:` / `return_kind:`:

   ```ruby
   Apple.discover(
     framework: :CoreFoundation, symbol: :CFStringCreateWithCString,
     params: [:opaque_ref, :cstring, :uint32], return_kind: :opaque_ref
   )
   ```

2. **The symbol is not in the Knowledge Base.** Private framework methods and custom ObjC selectors get no method shell from `bootstrap!`. Declare the shape:

   ```ruby
   Apple.discover(
     framework: :Foundation, klass: :NSString,
     class_method: :stringWithUTF8String
   )
   ```

3. **Pre-warm.** Calling `Apple.discover` at boot compiles the glue before the first user-facing call.

See `examples/` for more.

### Errors

- A non-zero `OSStatus` raises `RuntimeError`.
- A thrown `NSError` raises `AppleSDKMac::ObjcError`; a thrown Swift error raises `AppleSDKMac::SwiftError`.
- `AppleSDKMac::CompileError` (also `Apple::CompileError`) is raised when glue fails to compile.

## IRB autocomplete

IRB autocomplete, documentation preview, and discover prefetch live in the `irb/` sub-gem. The main gem has no IRB or Reline dependency.

```
$ RUBY_BOX=1 bundle exec irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
> Apple::<TAB>
> Apple::Foundation::U<TAB>
> Apple::Foundation::URL.<TAB>
```

Hovering an Apple SDK candidate fills the `:show_doc` dialog with documentation from the Knowledge Base and starts a background `Apple.discover` for that symbol. See `irb/README.md`.

The Knowledge Base ingests Swift interfaces, so types appear under their Swift import names (`URL` rather than `NSURL`, `Data` rather than `NSData`).

## Architecture

- **Glue runtime** (`ext/apple_sdk_mac_runtime/`): a Swift dynamic library with the Ref Table, Marshal, Callback, ARC, Error, Async, Threading, RunLoop, and Conformance pillars, exported to the CRuby extension with SE-0495 `@c`.
- **Ruby cache layer**: `Config` (XDG / ENV / YAML), `CompiledGlueCache` (SQLite + dylibs under `.rb-apple-sdk-mac/<sdk_version>/`), `KnowledgeCache` (reads the `knowledge/` sub-gem's SQLite).
- **Discovery / shape resolution**: `SelectorBridge` (canonical method names and acronym normalization), `DiscoveryShape` (symbol record synthesis and C-symbol parameter overrides).
- **Glue compiler pipeline**: `TemplateGenerator` → `ObjcMarshalling` → `SwiftBridgeName` → `ValidationGates` (allowed imports, banned APIs, glue shape) → `SwiftcInvoker`.
- **Inference and round-trip** (`inference/`, `round_trip/`, generation/maintenance time): `ClaudePBackend` synthesizes Swift glue from Knowledge Base metadata, `ProductionRunner` checks that the glue and a native call behave identically, and only matching glue is persisted.
- **Ruby runtime**: `GlueLoader` (dlopen + pointer cache), `Dispatcher` (cache miss → compile + invoke), `SecurityCop` (in-Box monkey patches with an allow-list), `NamespaceBuilder` (`Apple::<Framework>` shells), and the `Apple` `Ruby::Box`.

## Maintainer tools

`tooling/` holds the human-in-the-loop emitter improvement workflow (`bundle exec rake apple:emitter:candidates` and the related tasks). See `tooling/README.md`. The workflow is also started with the `/rb-apple-sdk-mac-improve-emitter [--mode=add|trim|all] [--top=N]` Claude Code skill.

## Development

```bash
bundle install
bundle exec rake test
```

`rake test` validates `sig/apple_sdk_mac.rbs`, regenerates `CallbackPillarGenerated.swift` from `callback_signatures.yml`, builds the Swift runtime and the C extension, then runs `test/` (except `test/integration/`) and the top-level `knowledge/test/` files. Several tests read the Knowledge Base, so run `rake apple:knowledge:rebuild` first.

`rake test:release_quality` runs `rake test`, the README, examples, Knowledge Base, coverage, memory-leak, and concurrency suites under `test/integration/`, and `benchmark/dispatch_overhead.rb`. Run any other file under `test/integration/` with `bundle exec ruby -Ilib -Itest <file>`; `coverage_matrix_test.rb` and `examples_coreaudio_e2e_test.rb` run only with `APPLE_SDK_MAC_RUN_E2E=1`.

```bash
bundle exec rake console
```

opens IRB with the gem loaded.

## License

MIT
