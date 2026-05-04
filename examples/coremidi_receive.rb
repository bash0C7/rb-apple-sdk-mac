#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "apple_sdk_mac"

[:MIDIClientCreate, :MIDIInputPortCreate, :MIDIGetSource,
 :MIDIPortConnectSource].each do |sym|
  Apple.discover(framework: :CoreMIDI, symbol: sym)
end

client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac demo", nil, nil)
in_port = Apple::CoreMIDI.MIDIInputPortCreate(client, "input", nil, nil) do |packets, _|
  packets.each { |pkt| puts pkt.inspect }
end
src = Apple::CoreMIDI.MIDIGetSource(0)
Apple::CoreMIDI.MIDIPortConnectSource(in_port, src, nil)

Apple.event_loop { |ctx| ctx.stop if ctx.elapsed > 30 }
