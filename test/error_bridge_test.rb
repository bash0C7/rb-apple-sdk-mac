# frozen_string_literal: true
require "test_helper"

class TestErrorBridge < Test::Unit::TestCase
  def test_runtime_error_raises_runtime_error
    assert_raise(RuntimeError) do
      AppleSDKMacRuntime.raise_runtime_error_test("boom")
    end
  end

  def test_argument_error_raises_argument_error
    assert_raise(ArgumentError) do
      AppleSDKMacRuntime.raise_argument_error_test("nope")
    end
  end
end
