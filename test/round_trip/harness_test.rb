# test/round_trip/harness_test.rb
# frozen_string_literal: true
require "test/unit"
require "json"
require_relative "../../lib/apple_sdk_mac/round_trip/harness"

class HarnessTest < Test::Unit::TestCase
  H = AppleSDKMac::RoundTrip::Harness

  # value: Swift 直走 stdout の RTRESULT 行を parse し、ruby 値と値比較
  def test_value_match
    swift = ->(_src) { "noise\nRTRESULT:{\"v\":3}\nmore" }
    ruby  = ->() { 3 }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "CoreAudio",
                symbol: { name: "audio_device_count", call_expr: "audioDeviceCount()" },
                value_kind: :value)
    assert_true r.green?
  end

  def test_value_mismatch_red
    swift = ->(_src) { "RTRESULT:{\"v\":3}" }
    ruby  = ->() { 4 }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "CoreAudio",
                symbol: { name: "audio_device_count", call_expr: "audioDeviceCount()" },
                value_kind: :value)
    assert_false r.green?
    assert_match(/swift=3/, r.detail)
    assert_match(/ruby=4/, r.detail)
  end

  def test_missing_rtresult_line_is_red_with_detail
    swift = ->(_src) { "compile produced no output" }
    ruby  = ->() { 3 }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "CoreAudio",
                symbol: { name: "audio_device_count", call_expr: "audioDeviceCount()" },
                value_kind: :value)
    assert_false r.green?
    assert_match(/no RTRESULT/, r.detail)
  end

  def test_opaque_match
    swift = ->(_src) { "RTRESULT:{\"type\":\"OpaquePointer\",\"null\":false}" }
    ruby  = ->() { { "type" => "OpaquePointer", "null" => false } }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "Foundation",
                symbol: { name: "make_obj", call_expr: "MyType()" },
                value_kind: :opaque)
    assert_true r.green?
  end
end
