# frozen_string_literal: true
require "apple_sdk_mac"

AppleSDKMac.bootstrap!

ins  = Apple::CoreMIDI.MIDIGetNumberOfSources
outs = Apple::CoreMIDI.MIDIGetNumberOfDestinations

puts "MIDI input endpoints  (sources):      #{ins}"
puts "MIDI output endpoints (destinations): #{outs}"
