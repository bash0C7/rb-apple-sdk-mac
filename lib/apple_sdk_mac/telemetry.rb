# frozen_string_literal: true
require "json"
require "fileutils"
require "time"
require_relative "errors"

module AppleSDKMac
  # Section 6.3 internal telemetry: append failure events to a daily jsonl
  # for gem self-improvement. Default-on; disable via env
  # APPLE_SDK_MAC_NO_DIAGNOSTICS=1. Write failures are named-rescued
  # (SystemCallError, IOError) and logged only when APPLE_DEBUG is set,
  # so the gem's primary error-reporting path is never disturbed.
  module Telemetry
    DEFAULT_DIR = File.expand_path("~/.cache/rb-apple-sdk-mac/diagnostics")

    def self.append_event(stage:, framework:, symbol:, detail:)
      return if disabled?
      dir = ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] || DEFAULT_DIR
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl")
      row = {
        at: Time.now.utc.iso8601,
        stage: stage,
        framework: framework,
        symbol: symbol,
        detail: detail,
        gem_version: AppleSdkMac::VERSION,
        kb_schema: AppleSDKMac::KNOWLEDGE_BASE_SCHEMA
      }
      File.open(path, "a") { |f| f.write(JSON.generate(row) + "\n") }
    rescue SystemCallError, IOError => e
      warn "[apple_sdk_mac] telemetry skipped: #{e.class}: #{e.message}" if ENV["APPLE_DEBUG"]
    end

    def self.disabled?
      ENV["APPLE_SDK_MAC_NO_DIAGNOSTICS"] == "1"
    end
  end
end
