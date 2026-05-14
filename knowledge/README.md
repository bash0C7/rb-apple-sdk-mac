# rb-apple-sdk-knowledge

A SQLite knowledge base of every public Apple framework on the local Xcode SDK.
Built at install time on the user's machine. Read-only after that.

## Use cases

- Lexical and semantic search over Apple SDK symbols
- IDE/editor autocomplete data source
- RBS generation for Apple frameworks
- Knowledge backend for `rb-apple-sdk-mac` (the dynamic Ruby↔Apple bridge)

## Requirements

- macOS with Xcode installed (provides `xcrun`, headers, `.swiftinterface` files, optional DocC archives)
- Ruby 3.2+
- swift-syntax-compatible Swift 6.3+ toolchain (only required at SDK parse time)

## Installation

```ruby
gem "rb-apple-sdk-knowledge"
```

After install, build the knowledge base for your local SDK:

```bash
bundle exec rake apple:knowledge:rebuild
```

Skip embeddings (much faster, FTS5 search still works):

```bash
RB_APPLE_SDK_KNOWLEDGE_FAST=1 bundle exec rake apple:knowledge:rebuild
```

## CLI

```bash
apple-sdk-knowledge rebuild
apple-sdk-knowledge info
apple-sdk-knowledge search CoreMIDI MIDIClient
```

## Library API

```ruby
require "rb_apple_sdk_knowledge"

store = AppleSDKKnowledge.open
search = AppleSDKKnowledge::Search.new(store)
search.lexical(framework: "CoreMIDI", query: "MIDIClient").each do |r|
  puts "#{r[:name]} (#{r[:kind]})"
end
store.close
```

## Environment variables

| ENV var | Default | 用途 |
|---------|---------|------|
| `APPLE_SDK_MAC_KB_WORKERS` | `2` | rebuild 時の worker pool 並列度。 macOS の CPU core 数まで上げると 1/3 まで縮む見込み (Phase 2 target) |
| `APPLE_SDK_MAC_KB_BATCH_SIZE` | `1000` | StoreWriter の transaction batch size |
| `APPLE_SDK_MAC_KB_BASE_DIR` | (なし) | Knowledge Base SQLite の base dir。 親 gem の rake task 経由で設定される |
| `APPLE_SDK_MAC_KB_INTEGRATION` | (なし) | `1` で `rake integration` が bit-identical test を実行 (heavy、 default skip) |

## License

MIT
