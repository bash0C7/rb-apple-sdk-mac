# frozen_string_literal: true
require_relative "rb_apple_sdk_knowledge/version"
require_relative "rb_apple_sdk_knowledge/store"
require_relative "rb_apple_sdk_knowledge/search"
require_relative "rb_apple_sdk_knowledge/importer"

module AppleSDKKnowledge
  class Error < StandardError; end

  def self.knowledge_path(sdk_version: nil)
    sdk_version ||= detect_sdk_version
    File.expand_path("../data/sdk_knowledge_#{sdk_version}.sqlite", __dir__)
  end

  def self.open(sdk_version: nil)
    path = knowledge_path(sdk_version: sdk_version)
    raise Error, "knowledge base missing at #{path}; run `rake apple:knowledge:rebuild`" unless File.exist?(path)
    Store.open(path)
  end

  def self.detect_sdk_version
    require "open3"
    out, status = Open3.capture2("xcrun", "--show-sdk-version")
    raise Error, "xcrun unavailable" unless status.success?
    out.strip
  end
end
