require "test/unit"
require "apple_sdk_mac/glue_compiler/marshallers"

class IntOutMarshallerTest < Test::Unit::TestCase
  def make(type:, name: "outVal")
    AppleSDKMac::GlueCompiler::Marshaller::REGISTRY["int"].new(
      { name: name, kind: "int", type: type, is_out_param: true, nullability: "nonnull" },
      0, {}
    )
  end

  def test_uint32_out_handling
    h = make(type: "UInt32 *").out_handling
    assert_equal "var outVal: UInt32 = 0", h[:init]
    assert_equal "&outVal", h[:addr]
    assert_equal "rb_ull2inum(UInt64(outVal))", h[:to_ruby]
  end

  def test_int32_out_handling
    h = make(type: "Int32 *").out_handling
    assert_equal "var outVal: Int32 = 0", h[:init]
    assert_equal "rb_ll2inum(Int64(outVal))", h[:to_ruby]
  end

  def test_int64_default_when_type_unknown
    h = make(type: "void *").out_handling
    assert_equal "var outVal: Int64 = 0", h[:init]
  end

  def test_in_load_returns_nil_when_out_param
    m = make(type: "UInt32 *")
    assert_nil m.in_load
  end

  def test_call_arg_returns_addr_when_out_param
    m = make(type: "UInt32 *")
    assert_equal "&outVal", m.call_arg
  end
end
