require "test/unit"
require "json"
require "apple_sdk_mac/glue_compiler/template_generator"

class TemplateGeneratorSafetyTest < Test::Unit::TestCase
  def test_returns_nil_when_int_out_param_lacks_out_handling
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
    assert_nil gen.generate(framework: "Fake", symbol: sym, glue_id: "deadbeef")
  end
end
