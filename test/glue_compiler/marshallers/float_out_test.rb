require "test/unit"
require "apple_sdk_mac/glue_compiler/marshallers"

class FloatOutMarshallerTest < Test::Unit::TestCase
  def make(type:, name: "outVal")
    AppleSDKMac::GlueCompiler::Marshaller::REGISTRY["float"].new(
      { name: name, kind: "float", type: type, is_out_param: true, nullability: "nonnull" },
      0, {}
    )
  end

  def test_float_pointer_out_handling
    h = make(type: "float *").out_handling
    assert_equal "var outVal: Float = 0", h[:init]
    assert_equal "&outVal", h[:addr]
    assert_equal "rb_float_new(Double(outVal))", h[:to_ruby]
  end

  def test_double_pointer_out_handling
    h = make(type: "double *").out_handling
    assert_equal "var outVal: Double = 0", h[:init]
    assert_equal "rb_float_new(outVal)", h[:to_ruby]
  end

  def test_cgfloat_pointer_out_handling
    h = make(type: "CGFloat *").out_handling
    assert_equal "var outVal: CGFloat = 0", h[:init]
    assert_equal "rb_float_new(Double(outVal))", h[:to_ruby]
  end

  def test_cftimeinterval_pointer_out_handling
    h = make(type: "CFTimeInterval *").out_handling
    assert_equal "var outVal: CFTimeInterval = 0", h[:init]
    assert_equal "rb_float_new(Double(outVal))", h[:to_ruby]
  end

  def test_default_double_when_type_unknown
    h = make(type: "void *").out_handling
    assert_equal "var outVal: Double = 0", h[:init]
    assert_equal "rb_float_new(outVal)", h[:to_ruby]
  end

  def test_in_load_returns_nil_when_out_param
    m = make(type: "double *")
    assert_nil m.in_load
  end

  def test_call_arg_returns_addr_when_out_param
    m = make(type: "double *")
    assert_equal "&outVal", m.call_arg
  end
end
