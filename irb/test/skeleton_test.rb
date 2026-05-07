# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb"

# Step 1.1 sanity test — gemspec + entry-point load works.
# Real coverage gets added in Step 1.3 (existing irb_completion tests migrate).
class TestSubgemSkeleton < Test::Unit::TestCase
  def test_module_loads
    assert defined?(AppleSDKMac::IRB),
      "AppleSDKMac::IRB should be defined after `require apple_sdk_mac/irb`"
  end
end
