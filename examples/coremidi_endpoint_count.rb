# frozen_string_literal: true
# CoreMIDI endpoint counts (input sources / output destinations).
# https://developer.apple.com/documentation/coremidi/midigetnumberofsources
# https://developer.apple.com/documentation/coremidi/midigetnumberofdestinations
#
# Mac に接続されている MIDI 機器 (synth / controller / audio interface など)
# の入力 endpoint 数 / 出力 endpoint 数を表示する。
#
# Apple.discover を 1 行も書いていない点に注目。 AppleSDKMac.bootstrap! が
# Knowledge Base から Apple::CoreMIDI module と method shell を eager-define
# し、 各 method の初回呼び出しで Dispatcher が inline で Swift glue dylib を
# コンパイルする。 Ruby の interpreter から見ると Apple framework の関数が
# 動的 dispatch されているように見える。
#
# Usage:
#   . ~/.swiftly/env.sh
#   RUBY_BOX=1 bundle exec ruby examples/coremidi_endpoint_count.rb
require "apple_sdk_mac"

AppleSDKMac.bootstrap!

ins  = Apple::CoreMIDI.MIDIGetNumberOfSources
outs = Apple::CoreMIDI.MIDIGetNumberOfDestinations

puts "MIDI input endpoints  (sources):      #{ins}"
puts "MIDI output endpoints (destinations): #{outs}"
