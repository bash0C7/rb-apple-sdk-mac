# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb"

class TestSubgemSkeleton < Test::Unit::TestCase
  def test_module_loads
    assert defined?(AppleSDKMac::IRB),
      "AppleSDKMac::IRB should be defined after `require apple_sdk_mac/irb`"
  end
end
