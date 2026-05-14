# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/sdk_resolver"

class TestSDKResolver < Test::Unit::TestCase
  def test_detects_local_sdk_version_string
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new
    version = resolver.sdk_version
    assert_match(/\A\d+\.\d+/, version, "expected version like '26.1', got: #{version.inspect}")
  end

  def test_detects_local_sdk_path
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new
    path = resolver.sdk_path
    assert File.directory?(path), "expected SDK path to exist, got: #{path}"
    assert path.end_with?(".sdk"), "expected path to end with .sdk, got: #{path}"
  end

  def test_lists_top_level_frameworks
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new
    frameworks = resolver.frameworks
    assert frameworks.length > 50, "expected >50 frameworks, got #{frameworks.length}"
    assert_includes frameworks.map(&:name), "Foundation"
    assert_includes frameworks.map(&:name), "CoreMIDI"
  end
end

class TestSDKResolverFilter < Test::Unit::TestCase
  def test_filter_returns_only_listed_frameworks
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: ["Foundation"])
    names = resolver.frameworks.map(&:name)
    assert_equal ["Foundation"], names
  end

  def test_filter_nil_returns_all_frameworks
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: nil)
    assert_operator resolver.frameworks.size, :>=, 50
  end
end
