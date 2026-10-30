# rb-apple-sdk-knowledge

A SQLite knowledge base of every public Apple framework on the local Xcode SDK. It ingests Objective-C and C headers through clang's JSON AST and Swift overlays through `*.swiftinterface`, and is the knowledge backend of `rb-apple-sdk-mac`.

## Requirements

- macOS 27+, Apple Silicon
- Xcode 27 (the importer runs `xcrun clang` and reads the SDK from `xcrun --show-sdk-path`)
- Ruby 4.0+, Bundler 4.x

## Installation

Install from source:

```bash
git clone https://github.com/bash0C7/rb-apple-sdk-mac.git
cd rb-apple-sdk-mac/knowledge
bundle install
```

Build the knowledge base for the active SDK:

```bash
bundle exec rake apple:knowledge:rebuild
```

The SQLite file is written to `data/sdk_knowledge_<sdk_version>.sqlite`, or to `<APPLE_SDK_MAC_KB_BASE_DIR>/<sdk_version>/sdk_knowledge.sqlite` when `APPLE_SDK_MAC_KB_BASE_DIR` is set.

## CLI

```bash
bundle exec exe/apple-sdk-knowledge rebuild
bundle exec exe/apple-sdk-knowledge info
bundle exec exe/apple-sdk-knowledge search CoreMIDI MIDIClient
```

## Library API

```ruby
require "rb_apple_sdk_knowledge"

store = AppleSDKKnowledge.open
store.fts_search("CoreMIDI", "MIDIClient").each do |r|
  puts "#{r[:name]} (#{r[:kind]})"
end
store.close
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `APPLE_SDK_MAC_KB_WORKERS` | `Etc.nprocessors` | Header-parsing worker processes per framework |
| `APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM` | `4` | Frameworks processed in parallel |
| `APPLE_SDK_MAC_KB_BATCH_SIZE` | `1000` | Rows per write transaction |
| `APPLE_SDK_MAC_KB_BASE_DIR` | none | Base directory of the SQLite file; the parent gem's rake task sets it |
| `APPLE_SDK_MAC_KB_INTEGRATION` | none | `1` makes `rake integration` run the parallel-import determinism test against the real SDK |

## Development

```bash
bundle install
bundle exec rake test
```

`rake test` validates `sig/rb_apple_sdk_knowledge.rbs`, then runs the tests.

## License

MIT
