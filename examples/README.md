# examples/

Runnable demos of `rb-apple-sdk-mac` against real Apple SDK frameworks. Every Ruby file here exercises a different pillar (auto-ARC, ObjC class methods, async/await, callback persistent slots, OCR, networking, IRB completion, ...) and prints its own one-line OK marker on success.

These exist to dogfood the README's central proposition — "call any public Apple framework API from Ruby with no pre-declarations" — under conditions a user actually faces, not a unit test suite.

## Prerequisites

- Ruby 4.x with `RUBY_BOX=1` set on every invocation (Apple namespace lives in a Box; without this, Apple SDK loading has no isolation and refuses to bootstrap)
- Xcode + Swift 6.3+ on PATH (the runtime invokes `swiftc` for inline glue compilation)
- Sibling repos checked out per the parent `Gemfile` paths (currently `knowledge/` in-repo, `../rb-foundation-model-mac` sibling, `swift_gem` git source)
- `bundle install` ran in repo root once

The Knowledge Base does **not** need to be pre-built. The runtime builds the Knowledge Base on first `Apple.discover` / `AppleSDKMac.bootstrap!` / `AppleSDKMac::IRB.install!` call (transparent bootstrap principle). First call is several seconds; later calls hit the cache.

## Run

```sh
RUBY_BOX=1 bundle exec ruby examples/<name>.rb
```

A few examples take optional positional args (download URL, OCR fixture path, MIDI source filter); see the file's leading comment block for usage.

## Inventory

| File | Framework / pillar | Status (2026-05-13, main) |
|---|---|---|
| `async_taskgroup.rb` | NSOperationQueue + NSBlockOperation true parallelism | ✅ exits 0 with `OperationQueue OK` |
| `audio_device_count.rb` | CoreAudio `AudioObjectGetPropertyDataSize` (int out-param) | ✅ exits 0 — reports the CoreAudio system device count |
| `avspeech_synth.rb` | AVFoundation Speech Synthesis (`AVSpeechSynthesizer.speak`) | ✅ runs — produces audible speech, run with sound off if you do not want that |
| `cf_string_create.rb` | CoreFoundation `CFStringCreateWithCString` round-trip via auto-ARC `BoxedCFType` | ✅ exits 0 with `auto-ARC OK — runtime BoxedCFType owns release` |
| `coremidi_endpoint_count.rb` | CoreMIDI `MIDIGetNumberOfSources` / `MIDIGetNumberOfDestinations` | ✅ exits 0 — output reflects the actual MIDI hardware state (`0` if nothing connected) |
| `coremidi_receive.rb` | CoreMIDI client + input port + 2-second receive loop (CallbackPillar persistent slot) | ✅ exits 0 with `done` |
| `discover_escape.rb` | Apple.discover escape-hatch demo: (1) CF function direct via [:opaque_ref, :cstring, :uint32] -> :opaque_ref shape, (2) ObjC class method via `Apple.discover(class_method:)` (`+[NSString stringWithUTF8String:]` → Swift 6 init-bridge) | ✅ exits 0, both `box=` and `ptr=` lines printed |
| `irb_completion_demo.rb` | Headless smoke of the `apple_sdk_mac/irb` Completor (no TTY required) | ✅ exits 0 with `irb_completion_demo OK` |
| `piano_keyboard.rb` | CoreAudio HAL device enum + AudioUnitSetProperty + AVFAudio (AVAudioEngine / PlayerNode / AVAudioFile) ソフトピアノ CLI。 4 framework 跨ぎ。 引数なし: device list を出して exit / 引数 = device 番号: interactive piano 起動 | ✅ 引数なしで exits 0 — interactive 起動は output audio device 必要 |
| `urlsession_download.rb` | NSURLSession real HTTP `dataTaskWithURL:completionHandler:` (BlockPersistentMarshaller) | ✅ exits 0 — needs network |
| `vision_ocr.rb` | Vision `VNRecognizeTextRequest` against `fixtures/ocr_hello.png` | ✅ exits 0 — needs the fixture |

## Fixtures

`fixtures/ocr_hello.png` is the input image for `vision_ocr.rb`. Add new fixtures here when you write an example that needs deterministic input (e.g. an audio file for AVF, a PDF for PDFKit). Keep them small.

## Adding a new example

1. Lead with a frozen-string-literal pragma + a comment block stating: which framework / API surface, why this case is interesting (which pillar / Worked Example / spec section it touches), and the `Usage:` line.
2. End the script with a single-line `OK` marker on success — the smoke pass in [`docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md`](../docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md) and the per-PR sweep both grep for it.
3. If the example needs a fixture, drop it under `examples/fixtures/` and reference by `__dir__`.
4. Add a row to the inventory table above. Note any prerequisites (network, hardware, fixture, audio output).
