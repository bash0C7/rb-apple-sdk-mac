require "test_helper"
require "open3"

class RuntimeTestModuleGatingTest < Test::Unit::TestCase
  def test_test_submodule_absent_when_env_unset
    bundle = File.expand_path("../lib/apple_sdk_mac/apple_sdk_mac_runtime", __dir__)
    out, status = Open3.capture2(
      { "RB_APPLE_SDK_MAC_RUNTIME_TEST" => nil },
      RbConfig.ruby, "-e", "require ARGV[0]; print defined?(AppleSDKMacRuntime::Test).inspect", bundle
    )
    assert status.success?
    assert_equal "nil", out, "AppleSDKMacRuntime::Test must be env-gated, not unconditional"
  end

  def test_test_submodule_present_when_env_set
    assert_equal "1", ENV["RB_APPLE_SDK_MAC_RUNTIME_TEST"],
      "test_helper.rb must export RB_APPLE_SDK_MAC_RUNTIME_TEST=1 before requiring runtime"
    assert defined?(AppleSDKMacRuntime::Test),
      "Test submodule must be present in test harness"
  end
end
