# examples/

Runnable demos of `rb-apple-sdk-mac` against real Apple SDK frameworks. Each script exercises a different part of the bridge and prints an `OK` marker or its result on success.

## Prerequisites

- The setup in the parent `README.md`: `bundle install`, `bundle exec rake compile`, and `bundle exec rake apple:knowledge:rebuild` in the repository root
- `RUBY_BOX=1` on every invocation

## Run

```sh
RUBY_BOX=1 bundle exec ruby examples/<name>.rb
```

## Inventory

| File | Framework / pillar | Input | Success output |
|---|---|---|---|
| `async_taskgroup.rb` | `NSOperationQueue` + `NSBlockOperation` parallel execution | `TASKGROUP_INPUTS` (default `10,20,30`) | `OperationQueue OK` |
| `audio_device_count.rb` | CoreAudio `AudioObjectGetPropertyDataSize` (int out-param) | none | `audio devices: N` |
| `avspeech_synth.rb` | AVFoundation `AVSpeechSynthesizer.speak` | none; plays audible speech | `speak completed OK` |
| `cf_string_create.rb` | CoreFoundation `CFStringCreateWithCString` with auto-ARC `BoxedCFType` | none | `auto-ARC OK — runtime BoxedCFType owns release` |
| `coremidi_endpoint_count.rb` | CoreMIDI `MIDIGetNumberOfSources` / `MIDIGetNumberOfDestinations` | none | source and destination counts |
| `coremidi_receive.rb` | CoreMIDI client + input port + receive loop (CallbackPillar slot) | `EVENT_LOOP_SECONDS` (default `2`) | `done` |
| `discover_escape.rb` | `Apple.discover` escape hatch: a CF function with explicit `params:` / `return_kind:`, and `+[NSString stringWithUTF8String:]` via `class_method:` | `OBJC_INPUT` (default `rb-apple-sdk-mac`) | `box=` and `ptr=` lines |
| `irb_completion_demo.rb` | Headless `apple_sdk_mac/irb` completor | none | `irb_completion_demo OK` |
| `piano_keyboard.rb` | CoreAudio device enumeration + `AudioUnitSetProperty` + AVFAudio (`AVAudioEngine` / `AVAudioPlayerNode` / `AVAudioFile`) | none: lists output devices and exits; a device number: starts an interactive piano (q or Ctrl-C to quit) | device list |
| `urlsession_download.rb` | `NSURLSession` `dataTaskWithURL:completionHandler:` (escaping block) | `T53_FIXTURE_URL` (default: a public URL; needs network) | `urlsession download OK` |
| `vision_ocr.rb` | Vision `VNRecognizeTextRequest` on `fixtures/ocr_hello.png` | none | `vision_ocr OK` |

## Fixtures

`fixtures/ocr_hello.png` is the input image of `vision_ocr.rb`. `xcrun swift script/regen_t54_fixture.swift` regenerates it.
