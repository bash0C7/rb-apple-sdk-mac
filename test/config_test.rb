# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/config"
require "tmpdir"

class TestConfig < Test::Unit::TestCase
  def test_yaml_config_loaded_when_present
    Dir.mktmpdir do |dir|
      yaml = File.join(dir, "config.yml")
      File.write(yaml, "trust_mode: review_first\n")
      config = AppleSDKMac::Config.new(config_file: yaml)
      assert_equal "review_first", config.trust_mode
    end
  end

  def test_programmatic_override
    config = AppleSDKMac::Config.new
    config.trust_mode = :auto
    assert_equal :auto, config.trust_mode
  end
end

class ConfigInferenceBackendTest < Test::Unit::TestCase
  def test_defaults_to_none
    cfg = AppleSDKMac::Config.new(config_file: "/nonexistent.yml")
    assert_equal :none, cfg.inference_backend
  end

  def test_env_override_to_claude_p
    ENV["RB_APPLE_SDK_MAC_INFERENCE_BACKEND"] = "claude_p"
    cfg = AppleSDKMac::Config.new(config_file: "/nonexistent.yml")
    assert_equal :claude_p, cfg.inference_backend
  ensure
    ENV.delete("RB_APPLE_SDK_MAC_INFERENCE_BACKEND")
  end
end
