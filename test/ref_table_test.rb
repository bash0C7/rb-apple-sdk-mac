# frozen_string_literal: true
require "test_helper"

class TestRefTable < Test::Unit::TestCase
  def test_retain_returns_handle_and_lookup_recovers_object
    handle = AppleSDKMacRuntime::Test.ref_retain_object(0xCAFE)
    assert handle > 0
    recovered_id = AppleSDKMacRuntime::Test.ref_lookup_object_id(handle)
    assert_equal 0xCAFE, recovered_id
  end

  def test_release_invalidates_handle
    handle = AppleSDKMacRuntime::Test.ref_retain_object(42)
    AppleSDKMacRuntime.ref_release(handle)
    assert_equal 0, AppleSDKMacRuntime::Test.ref_lookup_object_id(handle)
  end
end
