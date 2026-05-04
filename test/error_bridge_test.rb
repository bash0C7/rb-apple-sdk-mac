# frozen_string_literal: true
require "test_helper"

class TestErrorBridge < Test::Unit::TestCase
  def test_runtime_error_raises_runtime_error
    assert_raise(RuntimeError) do
      AppleSDKMacRuntime::Test.raise_runtime_error("boom")
    end
  end

  def test_argument_error_raises_argument_error
    assert_raise(ArgumentError) do
      AppleSDKMacRuntime::Test.raise_argument_error("nope")
    end
  end
end
