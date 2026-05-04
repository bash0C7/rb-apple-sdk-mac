# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/opaque_ref"

class TestARCBridge < Test::Unit::TestCase
  def test_opaque_ref_release_called_on_gc
    counter_handle = AppleSDKMacRuntime::Test.arc_release_counter_init
    assert_equal 0, AppleSDKMacRuntime::Test.arc_release_counter_value(counter_handle)
    100.times { _ = AppleSDKMac::OpaqueRef.new(counter_handle) }
    GC.start
    GC.start
    sleep 0.05
    assert AppleSDKMacRuntime::Test.arc_release_counter_value(counter_handle) > 0
  end
end
