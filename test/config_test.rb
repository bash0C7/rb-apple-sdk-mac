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
