# frozen_string_literal: true
require "test_helper"
require "json"
require "rb_apple_sdk_knowledge/reclassifier"

class TestReclassifierRecompute < Test::Unit::TestCase
  R = AppleSDKKnowledge::Reclassifier

  def test_recompute_fills_kind_and_is_out_param_from_type_only
    raw = JSON.generate([
      { name: "name",      type: "const char *" },
      { name: "outClient", type: "MIDIClientRef *" }
    ])
    out = R.recompute_parameters(raw)
    parsed = JSON.parse(out, symbolize_names: true)

    assert_equal "string",     parsed[0][:kind]
    assert_equal false,        parsed[0][:is_out_param]
    assert_equal "unspecified", parsed[0][:nullability]

    assert_equal "opaque_ref", parsed[1][:kind]
    assert_equal true,         parsed[1][:is_out_param]
  end

  def test_recompute_marks_void_pointer_unsupported
    raw = JSON.generate([{ name: "userData", type: "void *" }])
    parsed = JSON.parse(R.recompute_parameters(raw), symbolize_names: true)
    assert_equal "unsupported", parsed[0][:kind]
  end

  def test_recompute_is_idempotent
    raw = JSON.generate([{ name: "x", type: "int" }])
    once  = R.recompute_parameters(raw)
    twice = R.recompute_parameters(once)
    assert_equal once, twice
  end

  def test_recompute_handles_nil_or_empty_input
    assert_nil R.recompute_parameters(nil)
    assert_nil R.recompute_parameters("")
  end
end
