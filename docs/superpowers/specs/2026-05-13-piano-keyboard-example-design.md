# piano_keyboard example design

## Goal

`examples/piano_keyboard.rb` を 1 file 追加し、 README L3 「any public Apple framework API」 の dogfood を 3 領域跨ぎで実演する:

- CoreAudio HAL の audio output device 列挙 (`AudioObjectGetPropertyDataSize` / `AudioObjectGetPropertyData`) を escape-hatch + `Fiddle::Pointer.malloc` のハイブリッドで完走
- AVFAudio (`AVAudioEngine` / `AVAudioPlayerNode` / `AVAudioFile` / `AVAudioFormat`) で wav file 経路の音再生
- 選択 output device への routing (`AudioUnitSetProperty` で `kAudioOutputUnitProperty_CurrentDevice`)

Ruby は orchestration と key input (io/console getch) に専念、 device 列挙・音生成・device routing は全部 Apple SDK 経由。

## Architecture

```
examples/piano_keyboard.rb
  ├─ Constants         KEY_MAP / 周波数表 / FourCC selectors
  ├─ DeviceLister      CoreAudio で output 可能 device の id + name + uid 列挙
  ├─ WavBaker          freq → Float32 square wave bytes + RIFF header、 13 note 分 tmp dir に書き出し
  ├─ AudioPipeline     AVAudioEngine + PlayerNode + AVAudioFile load、
  │                    AudioUnitSetProperty で選択 device へ route、 engine.start + player.play
  └─ KeyLoop           io/console#getch ループ → KEY_MAP → playerNode.scheduleFile
                       q / Ctrl-C で engine.stop → exit 0
```

## なぜこの path

- AVFAudio class 群 (AVAudioEngine / AVAudioPlayerNode / AVAudioFile / AVAudioFormat) は Knowledge Base 未登録 (`AVSpeechSynthesizer` は登録あり、 `AVAudio*` sub-framework は別)。 `Apple.discover` で shape 明示すれば static template path で通る期待値、 落ちれば LLM safety-net で吸収。
- `AVAudioPCMBuffer.floatChannelData` の `UnsafeMutablePointer<UnsafeMutablePointer<Float>>?` return shape は marshaller registry に対応 kind が無く、 PCMBuffer 直叩き path は LLM 必須。 wav file 経路は throws init 2 個 (`AVAudioFile.init(forReading:)` / `AVAudioEngine.startAndReturnError:`) だけが LLM risk。
- `AudioObjectGetPropertyData` は Knowledge Base で `kind:unsupported` だが、 `params:` で `void_ptr_nilable` override + Ruby 側 `Fiddle::Pointer.malloc` で raw buffer 渡しすれば static emit path で完走 (LLM 不要)。

## 起動シーケンス

1. `AppleSDKMac.bootstrap!`
2. 17 個の `Apple.discover` を register (初回は swiftc が 17 回 compile、 30–60 秒。 二回目以降は `CompiledGlueCache` hit で即起動)
3. `DeviceLister.list_output_devices()` で `{id:, name:, uid:}` の配列取得
4. `PIANO_LIST_ONLY=1` env → 一覧印字 → exit 0
5. それ以外 → 番号入力受付 → 対応 device id 確定
6. `WavBaker` で 13 note の wav file を tmp dir に書き出し
7. `AVAudioFile.init(forReading:)` で 13 個読み込み
8. `AVAudioEngine` + `AVAudioPlayerNode` を attach / connect / mainMixerNode 経由
9. `engine.outputNode.audioUnit` から AudioUnit pointer (Integer) を取得
10. `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device_id, 4)` で device 切替
11. `engine.startAndReturnError:` (戻り false なら stderr + exit 1)
12. `player.play` → getch loop

## Key map (C4 起点)

| Key | Note | Freq (Hz) |
|---|---|---|
| z | C4  | 261.63 |
| s | C#4 | 277.18 |
| x | D4  | 293.66 |
| d | D#4 | 311.13 |
| c | E4  | 329.63 |
| v | F4  | 349.23 |
| g | F#4 | 369.99 |
| b | G4  | 392.00 |
| h | G#4 | 415.30 |
| n | A4  | 440.00 |
| j | A#4 | 466.16 |
| m | B4  | 493.88 |
| , | C5  | 523.25 |

## WavBaker

- sample rate 44100 Hz, mono, 32-bit Float PCM
- duration 300 ms per note
- amplitude 0.3 (耳保護のため低め)
- 5 ms linear attack/release envelope (click 防止)
- `samples.pack("e*")` で Float32 little-endian
- RIFF header (PCM Float = format code 3)
- `Dir.mktmpdir("piano_keyboard")` + `at_exit { FileUtils.remove_entry(...) }`

## Property selectors (FourCC)

```
kAudioHardwarePropertyDevices            = 0x64657623  # 'dev#'
kAudioObjectPropertyName                 = 0x6c6e616d  # 'lnam'
kAudioDevicePropertyDeviceUID            = 0x75696420  # 'uid '
kAudioDevicePropertyStreamConfiguration  = 0x736c6179  # 'slay'
kAudioObjectPropertyScopeGlobal          = 0x676c6f62  # 'glob'
kAudioObjectPropertyScopeOutput          = 0x6f757470  # 'outp'
kAudioObjectPropertyElementMain          = 0
kAudioObjectSystemObject                 = 1
kAudioOutputUnitProperty_CurrentDevice   = 2000
kAudioUnitScope_Global                   = 0
```

## Apple.discover register 一覧

**CoreAudio (escape-hatch + Fiddle ハイブリッド)**

```ruby
Apple.discover(framework: :CoreAudio, symbol: :AudioObjectGetPropertyDataSize)
Apple.discover(framework: :CoreAudio, symbol: :AudioObjectGetPropertyData,
  params: [:opaque_ref, :struct_in_pointer, :int, :void_ptr_nilable, :int, :void_ptr_nilable],
  return_kind: :int)
Apple.discover(framework: :CoreAudio, symbol: :AudioUnitSetProperty,
  params: [:opaque_ref, :int, :int, :int, :void_ptr_nilable, :int],
  return_kind: :int)
```

**CoreFoundation (CFString → Ruby String)**

```ruby
Apple.discover(framework: :CoreFoundation, symbol: :CFStringGetCString)
Apple.discover(framework: :CoreFoundation, symbol: :CFStringGetLength)
```

**Foundation**

```ruby
Apple.discover(framework: :Foundation, klass: :NSURL,
  class_method: "fileURLWithPath:",
  params: [:string], return_kind: :opaque_ref)
```

**AVFAudio**

```ruby
Apple.discover(framework: :AVFAudio, klass: :AVAudioFormat,
  swift_initializer: "init(standardFormatWithSampleRate:channels:)",
  params: [:float, :int], return_kind: :opaque_ref)

Apple.discover(framework: :AVFAudio, klass: :AVAudioEngine,
  swift_initializer: "init()", params: [], return_kind: :opaque_ref)

Apple.discover(framework: :AVFAudio, klass: :AVAudioPlayerNode,
  swift_initializer: "init()", params: [], return_kind: :opaque_ref)

Apple.discover(framework: :AVFAudio, klass: :AVAudioFile,
  swift_initializer: "init(forReading:)",
  params: [:opaque_ref], return_kind: :opaque_ref)

Apple.discover(framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "attachNode:",
  params: [{kind: :opaque_ref, type: "AVAudioNode"}], return_kind: :void)

Apple.discover(framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "connect:to:format:",
  params: [{kind: :opaque_ref, type: "AVAudioNode"},
           {kind: :opaque_ref, type: "AVAudioNode"},
           {kind: :opaque_ref, type: "AVAudioFormat"}],
  return_kind: :void)

Apple.discover(framework: :AVFAudio, klass: :AVAudioEngine,
  swift_property: :mainMixerNode, instance: true, return_kind: :opaque_ref)

Apple.discover(framework: :AVFAudio, klass: :AVAudioEngine,
  swift_property: :outputNode, instance: true, return_kind: :opaque_ref)

Apple.discover(framework: :AVFAudio, klass: :AVAudioIONode,
  swift_property: :audioUnit, instance: true, return_kind: :opaque_ref)

Apple.discover(framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "startAndReturnError:",
  params: [:opaque_ref], return_kind: :bool)

Apple.discover(framework: :AVFAudio, klass: :AVAudioEngine,
  selector: "stop", params: [], return_kind: :void)

Apple.discover(framework: :AVFAudio, klass: :AVAudioPlayerNode,
  selector: "scheduleFile:atTime:completionHandler:",
  params: [{kind: :opaque_ref, type: "AVAudioFile"}, :opaque_ref, :block_nilable],
  return_kind: :void)

Apple.discover(framework: :AVFAudio, klass: :AVAudioPlayerNode,
  selector: "play", params: [], return_kind: :void)
```

合計 **17 個** の `Apple.discover` 宣言。

## Non-interactive smoke (PIANO_LIST_ONLY=1)

env 検出時:

1. device 列挙
2. `Output devices:` ヘッダ + numbered list 印字
3. exit 0

NSAudioEngine setup を走らせない → swiftc 17 個動かず smoke は数秒で終わる。 `test/integration/examples_smoke_test.rb` がこの path を assert する。

## Failure handling

- 出力可能 device 0 個 → stderr `no output audio devices found` + exit 1
- `engine.startAndReturnError:` が false → stderr `engine start failed` + exit 1
- `AVAudioFile.init(forReading:)` 失敗 → 当該 note を skip + warn (他の note は動かす)
- `AudioUnitSetProperty` failure → warn + default device に fallback
- 範囲外キー → silent ignore
- q / Ctrl-C → engine.stop + cleanup + exit 0

## Testing

- 対話 CLI なので自動 e2e は `PIANO_LIST_ONLY=1` の 1 path のみ
- `test/integration/examples_smoke_test.rb` に `test_piano_keyboard_list_only_exits_zero` を追加
- `examples/README.md` inventory に 1 行追加

## Risk (実装中に解決)

1. Swift `throws` init/method の glue marshaller 経路 (`AVAudioFile.init(forReading:)` / `AVAudioEngine.startAndReturnError:`)。 動かなければ ObjC `initWithURL:error:` 形式に切替
2. `engine.outputNode.audioUnit` getter の return marshalling (`swift_property:` + `return_kind: :opaque_ref` で AudioUnit pointer を Integer で取れる期待値)
3. AVFAudio class 群が Knowledge Base 未登録のまま `Apple.discover(klass:, swift_initializer:)` で static emit できるか — 落ちれば LLM safety-net で吸収

3 つ全部 LLM safety-net で吸収できる前提で進める。
