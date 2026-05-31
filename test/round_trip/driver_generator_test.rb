# test/round_trip/driver_generator_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/driver_generator"

class DriverGeneratorTest < Test::Unit::TestCase
  G = AppleSDKMac::RoundTrip::DriverGenerator

  def setup
    @symbol = { name: "audio_device_count", kind: "function", signature: "() -> Int",
                call_expr: "audioDeviceCount()" }
  end

  def test_imports_target_framework
    src = G.generate(framework: "CoreAudio", symbol: @symbol, value_kind: :value)
    assert_match(/import CoreAudio/, src)
    assert_match(/import Foundation/, src)
  end

  def test_value_kind_prints_rtresult_line
    src = G.generate(framework: "CoreAudio", symbol: @symbol, value_kind: :value)
    assert_match(/RTRESULT:/, src)
    assert_match(/audioDeviceCount\(\)/, src)
  end

  def test_opaque_kind_emits_type_and_null_fields
    sym = { name: "make_obj", kind: "swift_init", call_expr: "MyType()" }
    src = G.generate(framework: "Foundation", symbol: sym, value_kind: :opaque)
    assert_match(/"type"/, src)
    assert_match(/"null"/, src)
  end

  def test_setter_kind_emits_set_and_readback_fields
    sym = { name: "set_x", kind: "swift_property_setter",
            set_expr: "obj.x = 5", read_expr: "obj.x", set_value: "5" }
    src = G.generate(framework: "Foundation", symbol: sym, value_kind: :setter)
    assert_match(/"set"/, src)
    assert_match(/"readback"/, src)
  end

  def test_unknown_value_kind_raises
    assert_raise(ArgumentError) do
      G.generate(framework: "CoreAudio", symbol: @symbol, value_kind: :bogus)
    end
  end
end
