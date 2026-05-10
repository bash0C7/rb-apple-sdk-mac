require "test_helper"

class RuntimeTestModuleGatingTest < Test::Unit::TestCase
  # Verify that AppleSDKMacRuntime::Test is gated by env.
  # Production users (no env) must not see the test helpers.
  def test_test_submodule_absent_when_env_unset
    omit "harness sets env in test_helper" if ENV["RB_APPLE_SDK_MAC_RUNTIME_TEST"]
    refute defined?(AppleSDKMacRuntime::Test),
      "AppleSDKMacRuntime::Test must be env-gated, not unconditional"
  end

  # Sanity check the gate IS open in the test harness (test_helper sets env)
  def test_test_submodule_present_when_env_set
    assert_equal "1", ENV["RB_APPLE_SDK_MAC_RUNTIME_TEST"],
      "test_helper.rb must export RB_APPLE_SDK_MAC_RUNTIME_TEST=1 before requiring runtime"
    assert defined?(AppleSDKMacRuntime::Test),
      "Test submodule must be present in test harness"
  end
end
