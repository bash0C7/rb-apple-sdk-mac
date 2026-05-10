require "test/unit"
require "json"
require "apple_sdk_mac/glue_compiler/template_generator"

class TemplateGeneratorSafetyTest < Test::Unit::TestCase
  # Task 3.2 GREEN — IntMarshaller now has out_handling, so the template path
  # generates Swift (not nil) for a UInt32 * out param.
  def test_generates_swift_when_int_out_param_has_out_handling
    sym = {
      name: "FakeFunctionWithIntOut",
      kind: "function",
      abi: "c",
      signature: "OSStatus FakeFunctionWithIntOut(UInt32 *outSize)",
      parameters_json: JSON.dump([
        { "name" => "outSize", "type" => "UInt32 *", "kind" => "int", "is_out_param" => true, "nullability" => "nonnull" }
      ])
    }
    gen = AppleSDKMac::GlueCompiler::TemplateGenerator.new
    result = gen.generate(framework: "Fake", symbol: sym, glue_id: "deadbeef")
    assert_not_nil result
    assert result.include?("var outSize: UInt32 = 0"), "expected UInt32 var decl, got: #{result}"
    assert result.include?("rb_ull2inum(UInt64(outSize))"), "expected unsigned to_ruby, got: #{result}"
    assert result.include?("FakeFunctionWithIntOut(&outSize)"), "expected call with addr, got: #{result}"
  end
end
