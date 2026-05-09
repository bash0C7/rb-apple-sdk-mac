require "test/unit"
require "apple_sdk_mac/glue_compiler/marshallers"

class OutHandlingBaseTest < Test::Unit::TestCase
  def test_base_marshaller_returns_nil_for_out_handling
    param = { name: "x", kind: "string", type: "char *", is_out_param: true }
    m = AppleSDKMac::GlueCompiler::Marshaller::REGISTRY["string"].new(param, 0, {})
    assert_nil m.out_handling
  end

  def test_int_in_param_returns_nil_for_out_handling
    param = { name: "x", kind: "int", type: "Int64", is_out_param: false }
    m = AppleSDKMac::GlueCompiler::Marshaller::REGISTRY["int"].new(param, 0, {})
    assert_nil m.out_handling
  end
end
