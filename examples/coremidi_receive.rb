#!/usr/bin/env ruby
# frozen_string_literal: true
# Phase 7 example: CoreMIDI client + input port creation, optional
# source-connect, and a short event loop drain. Demonstrates the
# canonical README path (MIDIClientCreate) plus callback (MIDIReadProc)
# routing through the CallbackPillar persistent slot table.
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/coremidi_receive.rb
#
# Set EVENT_LOOP_SECONDS=N to keep the loop alive longer; default is 2s
# so the example exits 0 in CI when no MIDI source is connected.
require "apple_sdk_mac"

[:MIDIClientCreate, :MIDIInputPortCreate, :MIDIGetSource,
 :MIDIPortConnectSource].each do |sym|
  Apple.discover(framework: :CoreMIDI, symbol: sym)
end

client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac demo", nil, nil)
puts "client=#{client}"
raise "MIDIClientCreate returned 0" if client.nil? || client.zero?

in_port = Apple::CoreMIDI.MIDIInputPortCreate(client, "input", nil, nil) do |packets, _|
  packets.each { |pkt| puts pkt.inspect }
end
puts "in_port=#{in_port}"

src = Apple::CoreMIDI.MIDIGetSource(0)
puts "src=#{src}"
unless src.nil? || src.zero?
  Apple::CoreMIDI.MIDIPortConnectSource(in_port, src, nil)
end

elapsed = Float(ENV["EVENT_LOOP_SECONDS"] || 2.0)
Apple.event_loop { |ctx| ctx.stop if ctx.elapsed > elapsed }
puts "done"
