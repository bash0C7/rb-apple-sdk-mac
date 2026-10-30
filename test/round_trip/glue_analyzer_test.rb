# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/glue_analyzer"

class GlueAnalyzerTest < Test::Unit::TestCase
  A = AppleSDKMac::RoundTrip::GlueAnalyzer

  def test_value_self_contained_call
    src = <<~SWIFT
      @c public func glue_abc123_Foo() -> Int32 {
          return SomeNativeCall(42, 7)
      }
    SWIFT
    di = A.extract_driver_inputs(src)
    assert_equal "SomeNativeCall(42, 7)", di[:call_expr]
    assert_equal [], di[:invoke_args]
    assert_equal :value, di[:value_kind]
  end

  def test_uint32_return_is_value
    src = "@c public func glue_x_Bar() -> UInt32 {\n  return Count()\n}"
    assert_equal :value, A.extract_driver_inputs(src)[:value_kind]
  end

  def test_optional_reference_is_opaque
    src = <<~SWIFT
      @c public func glue_x_Obj() -> AnyObject? {
          return MakeObject()
      }
    SWIFT
    di = A.extract_driver_inputs(src)
    assert_equal :opaque, di[:value_kind]
    assert_equal "MakeObject()", di[:call_expr]
  end

  def test_numeric_optional_is_value_not_opaque
    src = "@c public func glue_x_N() -> Int32? {\n  return Maybe()\n}"
    assert_equal :value, A.extract_driver_inputs(src)[:value_kind]
  end

  def test_out_param_local_var_return_yields_nil
    src = <<~SWIFT
      @c public func glue_x_Size() -> UInt32 {
          var size: UInt32 = 0
          _ = AudioObjectGetPropertyDataSize(AudioObjectID(1), &addr, 0, nil, &size)
          return size
      }
    SWIFT
    assert_nil A.extract_driver_inputs(src)
  end

  def test_void_return_yields_nil
    src = "@c public func glue_x_Set() {\n  doThing()\n}"
    assert_nil A.extract_driver_inputs(src)
  end

  def test_glue_with_params_yields_nil
    src = <<~SWIFT
      @c public func glue_x_P(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> Int32 {
          return Native()
      }
    SWIFT
    assert_nil A.extract_driver_inputs(src)
  end

  def test_no_exported_func_yields_nil
    assert_nil A.extract_driver_inputs("import Foundation\n// nothing here")
  end

  def test_nil_source_yields_nil
    assert_nil A.extract_driver_inputs(nil)
  end
end
