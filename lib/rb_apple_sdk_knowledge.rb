# frozen_string_literal: true
require_relative "rb_apple_sdk_knowledge/version"
require_relative "rb_apple_sdk_knowledge/sdk"
require_relative "rb_apple_sdk_knowledge/store"
require_relative "rb_apple_sdk_knowledge/search"
require_relative "rb_apple_sdk_knowledge/importer"

module AppleSDKKnowledge
  def self.knowledge_path(sdk_version: nil)
    sdk_version ||= SDK.version
    File.expand_path("../data/sdk_knowledge_#{sdk_version}.sqlite", __dir__)
  end

  def self.open(sdk_version: nil)
    path = knowledge_path(sdk_version: sdk_version)
    raise Error, "knowledge base missing at #{path}; run `rake apple:knowledge:rebuild`" unless File.exist?(path)
    Store.open(path)
  end
end
