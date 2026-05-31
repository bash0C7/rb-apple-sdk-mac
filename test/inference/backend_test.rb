# frozen_string_literal: true

require "test_helper"

class InferenceBackendTest < Test::Unit::TestCase
  def test_abstract_generate_glue_raises
    backend = AppleSDKMac::Inference::Backend.new
    assert_raise(NotImplementedError) do
      backend.generate_glue(framework: "Foo", symbol: {}, glue_id: "x", exported: "y")
    end
  end

  def test_abstract_name_raises
    assert_raise(NotImplementedError) { AppleSDKMac::Inference::Backend.new.name }
  end

  def test_generate_glue_accepts_seed_kwarg
    backend = AppleSDKMac::Inference::Backend.new
    assert_raise(NotImplementedError) do
      backend.generate_glue(framework: "Foo", symbol: {}, glue_id: "x", exported: "y",
                            seed: { rule_scaffold: "// scaffold", failure_detail: nil })
    end
  end
end
