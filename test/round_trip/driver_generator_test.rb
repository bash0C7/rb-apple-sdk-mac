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

  def test_opaque_body_emits_null_true_for_optional_aware_nil
    # call_expr が nil を返す可能性がある Optional 型の symbol で
    # "null":false ハードコードではなく nil チェックを入れることを確認。
    sym = { call_expr: "Optional<NSObject>(nil) as AnyObject?" }
    src = AppleSDKMac::RoundTrip::DriverGenerator.generate(
      framework: "Foundation", symbol: sym, value_kind: :opaque
    )
    assert_match(/let __null/, src, "opaque_body must emit a nil-check binding, not hardcode false")
  end

  def test_setter_body_raises_when_set_value_contains_unescaped_double_quote
    sym = { set_expr: "obj.x = 1", read_expr: "obj.x",
            set_value: '"broken"' } # double-quote in set_value breaks JSON
    assert_raise(ArgumentError) do
      AppleSDKMac::RoundTrip::DriverGenerator.generate(
        framework: "F", symbol: sym, value_kind: :setter
      )
    end
  end

  def test_setter_body_accepts_numeric_set_value
    sym = { set_expr: "obj.x = 42", read_expr: "obj.x", set_value: "42" }
    src = AppleSDKMac::RoundTrip::DriverGenerator.generate(
      framework: "F", symbol: sym, value_kind: :setter
    )
    assert_match(/"set":42/, src)
  end
end
