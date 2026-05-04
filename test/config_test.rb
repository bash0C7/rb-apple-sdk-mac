# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/config"
require "tmpdir"

class TestConfig < Test::Unit::TestCase
  def test_default_cache_dir_under_xdg
    ENV.delete("RB_APPLE_SDK_MAC_CACHE_DIR")
    config = AppleSDKMac::Config.new
    expected = File.join(ENV["XDG_CACHE_HOME"] || File.expand_path("~/.cache"), "rb-apple-sdk-mac")
    assert config.cache_dir.start_with?(expected)
  end

  def test_env_override_takes_precedence
    Dir.mktmpdir do |dir|
      ENV["RB_APPLE_SDK_MAC_CACHE_DIR"] = dir
      config = AppleSDKMac::Config.new
      assert_equal dir, config.cache_dir
      ENV.delete("RB_APPLE_SDK_MAC_CACHE_DIR")
    end
  end

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
