# frozen_string_literal: true
require "yaml"

module AppleSDKMac
  class Config
    DEFAULTS = {
      trust_mode: :auto,
      raise_on_error: true,
      llm_model: "foundation-models/default"
    }.freeze

    attr_accessor :trust_mode, :raise_on_error, :llm_model
    attr_reader :cache_dir

    def initialize(config_file: nil)
      @trust_mode = DEFAULTS[:trust_mode]
      @raise_on_error = DEFAULTS[:raise_on_error]
      @llm_model = DEFAULTS[:llm_model]
      @cache_dir = compute_cache_dir
      load_yaml(config_file || default_yaml_path)
      apply_env
    end

    def cache_dir=(path)
      @cache_dir = File.expand_path(path)
    end

    private

    def compute_cache_dir
      base = ENV["XDG_CACHE_HOME"] || File.expand_path("~/.cache")
      File.join(base, "rb-apple-sdk-mac")
    end

    def default_yaml_path
      base = ENV["XDG_CONFIG_HOME"] || File.expand_path("~/.config")
      File.join(base, "rb-apple-sdk-mac", "config.yml")
    end

    def load_yaml(path)
      return unless path && File.exist?(path)
      data = YAML.safe_load_file(path, permitted_classes: [Symbol])
      return unless data.is_a?(Hash)
      @trust_mode = data["trust_mode"] if data.key?("trust_mode") && !data["trust_mode"].to_s.empty?
      @raise_on_error = data["raise_on_error"] if data.key?("raise_on_error")
      @llm_model = data["llm_model"] || @llm_model
      @cache_dir = data["cache_dir"] if data["cache_dir"]
    end

    def apply_env
      @cache_dir = ENV["RB_APPLE_SDK_MAC_CACHE_DIR"] if ENV["RB_APPLE_SDK_MAC_CACHE_DIR"]
      @llm_model = ENV["RB_APPLE_SDK_MAC_LLM_MODEL"] if ENV["RB_APPLE_SDK_MAC_LLM_MODEL"]
    end
  end
end
