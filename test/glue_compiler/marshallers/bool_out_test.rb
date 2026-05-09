require "test/unit"
require "apple_sdk_mac/glue_compiler/marshallers"

class BoolOutMarshallerTest < Test::Unit::TestCase
  def make(type:, name: "outFlag")
    AppleSDKMac::GlueCompiler::Marshaller::REGISTRY["bool"].new(
      { name: name, kind: "bool", type: type, is_out_param: true, nullability: "nonnull" },
      0, {}
    )
  end

  def test_bool_pointer_out_handling
    h = make(type: "bool *").out_handling
    assert_equal "var outFlag: Bool = false", h[:init]
    assert_equal "&outFlag", h[:addr]
    assert_equal "outFlag ? Qtrue : Qfalse", h[:to_ruby]
  end

  def test_objc_bool_pointer_out_handling
    # CoreFoundation Boolean is typedef'd to unsigned char; treat as ObjCBool
    h = make(type: "Boolean *").out_handling
    assert h[:init].start_with?("var outFlag: ")
    assert_equal "&outFlag", h[:addr]
    assert_equal "outFlag ? Qtrue : Qfalse", h[:to_ruby]
  end

  def test_in_load_returns_nil_when_out_param
    m = make(type: "bool *")
    assert_nil m.in_load
  end

  def test_call_arg_returns_addr_when_out_param
    m = make(type: "bool *")
    assert_equal "&outFlag", m.call_arg
  end

  def test_in_load_unchanged_for_in_param
    m = AppleSDKMac::GlueCompiler::Marshaller::REGISTRY["bool"].new(
      { name: "flag", kind: "bool", type: "bool", is_out_param: false, nullability: "nonnull" },
      0, {}
    )
    refute_nil m.in_load
    assert_includes m.in_load, "Bool"
  end
end
