require "test_helper"

class CoverageContractTest < Test::Unit::TestCase
  def setup
    @contract = AppleSDKMac::CoverageContract.new
  end

  # audio_device_count が依存する shape: C function + (uint32, struct-in,
  # uint32, int-out-pointer)。これは「カバー済みと表明する」範囲 = true。
  def test_audio_property_data_size_shape_is_covered
    sym = {
      kind: "function", abi: "c",
      parameters_json: JSON.generate([
        { "type" => "AudioObjectID" },             # uint32
        { "type" => "AudioObjectPropertyAddress*", "is_struct_in" => true },
        { "type" => "UInt32" },
        { "type" => "UInt32*", "is_out_param" => true }
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
      parameters_json: JSON.generate([{ "type" => "std::vector<NSObject*>" }])
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
