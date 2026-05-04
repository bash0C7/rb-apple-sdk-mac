# frozen_string_literal: true

require "test_helper"

class AppleSdkMacSampleTest < Test::Unit::TestCase
  test "perform echoes input from skeleton implementation" do
    assert_equal("hello", AppleSdkMac.perform("hello"))
    # TODO: Replace with a meaningful assertion once you implement perform.
  end
end
