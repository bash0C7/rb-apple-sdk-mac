# frozen_string_literal: true
require_relative "rb_apple_sdk_knowledge/version"
require_relative "rb_apple_sdk_knowledge/sdk"
require_relative "rb_apple_sdk_knowledge/store"
require_relative "rb_apple_sdk_knowledge/importer/kind"

module AppleSDKKnowledge
  def self.knowledge_path(sdk_version: nil, base_dir: nil)
    sdk_version ||= SDK.version
    if base_dir
      File.join(base_dir, sdk_version, "sdk_knowledge.sqlite")
    else
      File.expand_path("../data/sdk_knowledge_#{sdk_version}.sqlite", __dir__)
    end
  end

  def self.open(sdk_version: nil, base_dir: nil)
    path = knowledge_path(sdk_version: sdk_version, base_dir: base_dir)
    raise Error, "knowledge base missing at #{path}; run `rake apple:knowledge:rebuild`" unless File.exist?(path)
    Store.open(path)
  end
end
