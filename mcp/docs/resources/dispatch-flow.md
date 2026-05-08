# Apple.discover → メソッド呼び出しの全フロー

## discover 時 (初回のみ)

```
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
    │
    ▼
_synthesize_symbol_record (keyword shape → kind / canonical_name 化)
    │
    ▼
KB lookup or transient register
    │
    ▼
GlueCompiler#compile
    │
    ├─ glue_id = SHA256("CoreMIDI|MIDIClientCreate|<sig>|<params_json>")[0,16]
    ├─ TemplateGenerator.generate (kind dispatcher で emit_<kind>)
    │     ↓ 失敗 (nil 返却)
    │   LLMGenerator (Foundation Models on-device、 max 6 retry)
    ├─ ValidationGates.validate (9 GATE で構文・安全性チェック)
    ├─ SwiftcInvoker.compile → ~/.cache/.../<glue_id>.dylib
    └─ CompiledGlueCache.insert
    │
    ▼
NamespaceBuilder.install_one
    │
    ├─ Apple::CoreMIDI モジュール ensure
    └─ define_singleton_method(:MIDIClientCreate) { |*args|
         dispatcher.call(framework: "CoreMIDI", symbol: "MIDIClientCreate", args: args)
       }
```

## メソッド呼び出し時 (毎回)

```
Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
    │
    ▼ NamespaceBuilder で定義された Ruby singleton method
    │
    ▼ unwrap_proxy_args (Apple proxy instance を __opaque_ref Integer に再帰展開)
    │
    ▼
Dispatcher#dispatch
    │
    ├─ KnowledgeCache.lookup_symbol (transient overlay → DB)
    ├─ CompiledGlueCache.lookup (glue_id → dylib_path)
    │
    ▼
GlueLoader#load
    │
    ├─ AppleSDKMacRuntime.dlopen_glue (dylib_handles cache hit でスキップ)
    └─ AppleSDKMacRuntime.dlsym_glue (symbol_pointers cache hit でスキップ)
    │
    ▼
AppleSDKMacRuntime.invoke_glue (C ext で fn(VALUE*, int) を直叩き)
    │
    ▼
glue dylib 内
    │
    ├─ rb_num2ll, rb_string_value_cstr 等で VALUE → Swift 値
    ├─ Apple SDK 関数を呼ぶ (例: MIDIClientCreate)
    └─ rb_ll2inum, rb_str_new_cstr 等で 戻り値を VALUE 化
    │
    ▼
Ruby VALUE 返却
    │
    ▼ opaque_ref / cftype_ref 戻り値なら proxy class.from_ref で auto-wrap
    │
    ▼
ユーザコードに値が返る
```

## 9 Pillar が支える Swift runtime

per-symbol glue dylib は 1 個の `libAppleSDKMacRuntime.dylib` を共有しとる。 中身は 9 個の柱:

- **RefTable** — Apple object を u32 ハンドルで持つ retain table
- **Marshal** — C string ↔ Swift String、 Int64 ↔ Ruby Integer 等
- **Callback** — Apple thread から Ruby Proc を呼び戻す経路
- **ARC** — CFTypeRef の box/unbox
- **Error** — OSStatus / NSError を Ruby Exception に持ち上げ
- **Async** — try await を DispatchSemaphore で同期化
- **Threading** — Apple thread → Ruby main thread queue
- **RunLoop** — CFRunLoop pump
- **Conformance** — Ruby Hash を Swift protocol shim 化

## 2 回目以降の呼び出し性能

- Swift 生成・コンパイル: 初回のみ (glue_id content-addressed)
- dlopen / dlsym: 初回のみ (process 内 Hash cache)
- 呼び出し本体: 毎回 (関数ポインタ直叩き)

つまり「初回 discover 時に 1 回のみ swiftc が走り、 以降は dylib 関数ポインタを直接呼ぶだけ」。
