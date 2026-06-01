# test/round_trip/glue_analyzer_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/glue_analyzer"

# C フォールバック: LLM が json ブロックを返さなかったとき、生成 glue source を
# 静的解析して round-trip 駆動入力を best-effort 合成する。確信が持てない形は
# 必ず nil 縮退する (誤った driver_inputs を作らない) のが安全契約。
class GlueAnalyzerTest < Test::Unit::TestCase
  A = AppleSDKMac::RoundTrip::GlueAnalyzer

  # zero-arg glue で return が自己完結 native call → value 駆動入力。
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

  # UInt32 等の数値型も :value。
  def test_uint32_return_is_value
    src = "@c public func glue_x_Bar() -> UInt32 {\n  return Count()\n}"
    assert_equal :value, A.extract_driver_inputs(src)[:value_kind]
  end

  # Optional 参照型 (AnyObject?) は :opaque。
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

  # 数値 Optional (Int32?) は opaque ではなく value。
  def test_numeric_optional_is_value_not_opaque
    src = "@c public func glue_x_N() -> Int32? {\n  return Maybe()\n}"
    assert_equal :value, A.extract_driver_inputs(src)[:value_kind]
  end

  # out-param 経由で local var を return する形 (AudioObjectGetPropertyDataSize
  # 相当) は自己完結 call ではないので nil (A path 必須)。
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

  # Void 戻り (setter 等) は C fallback 対象外 → nil。
  def test_void_return_yields_nil
    src = "@c public func glue_x_Set() {\n  doThing()\n}"
    assert_nil A.extract_driver_inputs(src)
  end

  # 引数を取る glue は zero-arg invoke できないので nil (誤った invoke_args を作らない)。
  def test_glue_with_params_yields_nil
    src = <<~SWIFT
      @c public func glue_x_P(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> Int32 {
          return Native()
      }
    SWIFT
    assert_nil A.extract_driver_inputs(src)
  end

  # exported glue func が見つからない → nil。
  def test_no_exported_func_yields_nil
    assert_nil A.extract_driver_inputs("import Foundation\n// nothing here")
  end

  def test_nil_source_yields_nil
    assert_nil A.extract_driver_inputs(nil)
  end
end
