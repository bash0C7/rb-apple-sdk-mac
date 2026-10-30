# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/equivalence"

class EquivalenceTest < Test::Unit::TestCase
  E = AppleSDKMac::RoundTrip::Equivalence

  def test_value_equal
    assert_true E.equivalent?(kind: :value, swift: 3, ruby: 3)
  end

  def test_value_unequal
    assert_false E.equivalent?(kind: :value, swift: 3, ruby: 4)
  end

  def test_opaque_same_shape_non_null
    a = { "type" => "OpaquePointer", "null" => false }
    b = { "type" => "OpaquePointer", "null" => false }
    assert_true E.equivalent?(kind: :opaque, swift: a, ruby: b)
  end

  def test_opaque_null_fails
    a = { "type" => "OpaquePointer", "null" => false }
    b = { "type" => "OpaquePointer", "null" => true }
    assert_false E.equivalent?(kind: :opaque, swift: a, ruby: b)
  end

  def test_opaque_type_mismatch_fails
    a = { "type" => "OpaquePointer", "null" => false }
    b = { "type" => "CGRect", "null" => false }
    assert_false E.equivalent?(kind: :opaque, swift: a, ruby: b)
  end

  def test_setter_readback_matches
    assert_true E.equivalent?(kind: :setter, swift: { "set" => 5, "readback" => 5 },
                                            ruby: { "set" => 5, "readback" => 5 })
  end

  def test_setter_readback_mismatch_fails
    assert_false E.equivalent?(kind: :setter, swift: { "set" => 5, "readback" => 9 },
                                             ruby: { "set" => 5, "readback" => 9 })
  end

  def test_unknown_kind_raises
    assert_raise(ArgumentError) { E.equivalent?(kind: :bogus, swift: 1, ruby: 1) }
  end
end
