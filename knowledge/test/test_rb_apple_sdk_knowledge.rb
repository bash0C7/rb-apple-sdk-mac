# frozen_string_literal: true

require "test_helper"

class TestRbAppleSdkKnowledge < Test::Unit::TestCase
  test "VERSION is defined" do
    assert AppleSDKKnowledge.const_defined?(:VERSION)
  end
end
