# frozen_string_literal: true
require "apple_sdk_mac"

text = "The quick brown fox jumped over the lazy dog."

Apple.discover(framework: :AVFoundation, klass: :AVSpeechSynthesizer,
               swift_initializer: "init()",
               params: [], return_kind: :opaque_ref)

Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
               swift_initializer: "init(string:)",
               params: [:string],
               return_kind: :opaque_ref)

Apple.discover(framework: :AVFoundation, klass: :AVSpeechSynthesizer,
               selector: "speak:",
               params: [{kind: :opaque_ref, type: "AVSpeechUtterance"}],
               return_kind: :void)

Apple.discover(framework: :AVFoundation, klass: :AVSpeechSynthesizer,
               swift_property: :isSpeaking, instance: true,
               return_kind: :bool)

synthesizer = Apple::AVFoundation::AVSpeechSynthesizer.init
utterance   = Apple::AVFoundation::AVSpeechUtterance.init_string(text)

synthesizer.speak(utterance)
puts "speak issued: #{text}"

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
