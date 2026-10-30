require "test_helper"

class CoverageContractTest < Test::Unit::TestCase
  def setup
    @contract = AppleSDKMac::CoverageContract.new
  end

  def test_audio_property_data_size_shape_is_covered
    sym = {
      kind: "function", abi: "c",
      parameters_json: JSON.generate([
        { "name" => "objectID", "type" => "AudioObjectID", "kind" => "int", "is_out_param" => false },
        { "name" => "addr", "type" => "AudioObjectPropertyAddress * _Nonnull", "kind" => "struct_in", "is_out_param" => false },
        { "name" => "qualifierSize", "type" => "UInt32", "kind" => "int", "is_out_param" => false },
        { "name" => "size", "type" => "UInt32 * _Nonnull", "kind" => "int", "is_out_param" => true }
      ])
    }
    assert_true @contract.covered?(sym)
  end

  def test_unknown_kind_is_not_covered
    sym = { kind: "swift_macro", abi: "swift", parameters_json: "[]" }
    assert_false @contract.covered?(sym)
  end

  def test_known_kind_with_unsupported_param_is_not_covered
    sym = {
      kind: "function", abi: "c",
      parameters_json: JSON.generate([
        { "name" => "v", "type" => "std::vector<NSObject *>", "kind" => "unsupported", "is_out_param" => false }
      ])
    }
    assert_false @contract.covered?(sym)
  end

  def test_reason_for_uncovered_is_descriptive
    sym = { kind: "swift_macro", abi: "swift", parameters_json: "[]" }
    reason = @contract.uncovered_reason(sym)
    assert_match(/kind/, reason)
    assert_match(/swift_macro/, reason)
  end
end
