# frozen_string_literal: true
# AVFoundation Speech Synthesis example.
# https://developer.apple.com/documentation/avfoundation/speech-synthesis
#
# 「事前宣言ゼロで Apple framework を Ruby から呼ぶ」 README L3 を
# AVSpeechSynthesizer で実演。 AVSpeechUtterance を作り、 共有
# AVSpeechSynthesizer に speak(_:) を投げ、 isSpeaking が false に戻るまで
# threading_poll で待機する。
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/avspeech_synth.rb
require "apple_sdk_mac"

text = "The quick brown fox jumped over the lazy dog."

# --- AVFoundation: AVSpeechSynthesizer.init() ---
Apple.discover(framework: :AVFoundation, klass: :AVSpeechSynthesizer,
               swift_initializer: "init()",
               params: [], return_kind: :opaque_ref)

# --- AVFoundation: AVSpeechUtterance.init(string:) ---
Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
               swift_initializer: "init(string:)",
               params: [:string],
               return_kind: :opaque_ref)

# --- AVFoundation: AVSpeechSynthesizer.speak(_:) ---
# Swift 6 で `speakUtterance:` は obsoleted、 importer rename で `speak(_:)`。
# selector を `speak:` に統一して Swift 6 imported name 経路で emit させる。
Apple.discover(framework: :AVFoundation, klass: :AVSpeechSynthesizer,
               selector: "speak:",
               params: [{kind: :opaque_ref, type: "AVSpeechUtterance"}],
               return_kind: :void)

# --- AVFoundation: AVSpeechSynthesizer.isSpeaking (instance Bool property) ---
Apple.discover(framework: :AVFoundation, klass: :AVSpeechSynthesizer,
               swift_property: :isSpeaking, instance: true,
               return_kind: :bool)

# --- Pipeline ---
synthesizer = Apple::AVFoundation::AVSpeechSynthesizer.init
utterance   = Apple::AVFoundation::AVSpeechUtterance.init_string(text)

synthesizer.speak(utterance)
puts "speak issued: #{text}"

# Wait for completion: speaking が一旦 true → false になる遷移を観測。
# 一切 speaking=true に到達しない場合 (mute / no voice) でも timeout で抜ける。
deadline       = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30.0
saw_speaking   = false
loop do
  speaking = synthesizer.isSpeaking
  saw_speaking = true if speaking
  break if saw_speaking && !speaking
  if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "AVSpeechSynthesizer: timeout 30s (saw_speaking=#{saw_speaking})"
  end
  AppleSDKMacRuntime.threading_poll(0.05)
end

raise "AVSpeechSynthesizer: speaking never observed" unless saw_speaking
puts "speak completed OK"
