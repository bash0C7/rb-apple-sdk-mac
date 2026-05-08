# callback / async / threading パターン

Apple SDK の callback / async / 別 thread 経路を Ruby 側に橋渡しするための仕組み。 9 Pillar のうち Callback / Threading / Async / RunLoop の 4 本が関与します。

## block_persistent (escaping closure)

URLSession の completionHandler のように、 関数呼び出し後も保持される closure。 Ruby Proc を `runtime_callback_register_block_persistent` で登録 → スロット ID で参照。

`Apple.discover` での宣言:

```ruby
Apple.discover(
  framework: :Foundation,
  klass: :NSURLSession,
  selector: :"dataTaskWithURL:completionHandler:",
  params: [
    { kind: :cftype_ref, type: "NSURL" },
    { kind: :block_persistent, arity: 3 }   # (Data?, URLResponse?, Error?) → Void
  ]
)
```

呼び出し:

```ruby
session.dataTaskWithURL_completionHandler(url) do |data, response, error|
  # data / response / error は Ruby 側 Proc に届く
end
```

## CallbackPillar (C function pointer slot)

`MIDIClientCreate(name, MIDINotifyProc, refCon, &outClient)` のように C function pointer を渡す API。 Swift closure は C function pointer に渡せないので、 静的に slot 化された関数を使います。

`callback_signatures.yml` でシグネチャ宣言 → `callback_pillar_codegen.rb` が pool_size 個の slot 関数を生成 → `runtime_callback_pillar_register_<token>` で空きスロットに proc を bind。

```yaml
- token: midiNotifyProc
  pool_size: 4
  swift_type: MIDINotifyProc
  swift_params: "_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?"
  arg_marshaller: "Int64(message.pointee.messageID.rawValue)"
  frameworks: [CoreMIDI]
```

YAML 編集 → `rake runtime:codegen_callback_pillar` で `CallbackPillarGenerated.swift` を再生成。 これを commit。

## Threading bridge (Apple thread → Ruby main thread)

Apple thread から Ruby を直接触ると GVL がない世界で走るため即 SEGV。 `runtime_threading_enqueue` で main thread queue に積み、 Ruby 側 `Apple.event_loop` が `threading_poll` で吸い上げ → proc 起動。

```ruby
Apple.event_loop do |ctx|
  # main thread queue が pump され、 callback 系の proc が起動
  ctx.stop if some_done_condition
end
```

内部で 10ms 単位で `runloop_pump` + `threading_poll` が回ります。

## Async (try await を同期化)

Swift の `try await Foo.bar()` を Ruby から同期に見せるため、 `DispatchSemaphore(value: 0)` + `Task { try await ...; sema.signal() }` + `sema.wait()` で同期化。

```ruby
Apple.discover(
  framework: :Foundation,
  klass: :URLSession,
  swift_func: :"data(from:)",
  async: true
)
data, response = session.data_from(url)   # await が完了するまで block
```

ValidationGates の GATE 6 が、 `await` を含む glue に DispatchSemaphore + Task + try/catch + sema.signal/wait の 6 要素全部を要求します。

## CFRunLoop pump

CoreMIDI 等の CFRunLoop ベース API は `Apple.event_loop` で 10ms 単位で pump されます。 これがないと callback が積まれただけで Ruby に届きません。

```ruby
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
client = Apple::CoreMIDI.MIDIClientCreate("MyClient", proc { |msg|
  puts "MIDI notification: #{msg}"
}, nil)

Apple.event_loop do |ctx|
  ctx.stop if Time.now > start + 30
end
```

## どれを使うか判断

- API が `MIDINotifyProc` 等の C function pointer を取る → CallbackPillar (`callback_signatures.yml` に追加 + KB の kind を `block_persistent` ではなく専用 token に)
- API が Swift closure (`@escaping`) を取る → block_persistent
- API が `try await` 形式 → async: true
- callback が来るのを待つだけ → `Apple.event_loop`

新しい signature 追加が要るときは `callback_signatures.yml` に追記して codegen 再実行 → 親 gem の dylib 再ビルド。
