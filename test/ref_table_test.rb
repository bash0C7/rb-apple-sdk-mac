# frozen_string_literal: true
require "test_helper"

class TestRefTable < Test::Unit::TestCase
  def test_retain_returns_handle_and_lookup_recovers_object
    handle = AppleSDKMacRuntime.ref_retain_test_object(0xCAFE)
    assert handle > 0
    recovered_id = AppleSDKMacRuntime.ref_lookup_test_object_id(handle)
    assert_equal 0xCAFE, recovered_id
  end

  def test_release_invalidates_handle
    handle = AppleSDKMacRuntime.ref_retain_test_object(42)
    AppleSDKMacRuntime.ref_release(handle)
    assert_equal 0, AppleSDKMacRuntime.ref_lookup_test_object_id(handle)
  end
end
