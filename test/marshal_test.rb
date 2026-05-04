# frozen_string_literal: true
require "test_helper"

class TestMarshal < Test::Unit::TestCase
  def test_string_round_trip
    out = AppleSDKMacRuntime.marshal_string_round_trip("hello")
    assert_equal "hello", out
  end

  def test_int_round_trip
    out = AppleSDKMacRuntime.marshal_int_round_trip(42)
    assert_equal 42, out
  end

  def test_array_round_trip
    out = AppleSDKMacRuntime.marshal_array_to_swift_count(["a", "b", "c"])
    assert_equal 3, out
  end
end
