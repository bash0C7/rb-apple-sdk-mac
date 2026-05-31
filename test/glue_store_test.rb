# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "fileutils"
require_relative "../lib/apple_sdk_mac/glue_store"

class GlueStoreTest < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @store = AppleSDKMac::GlueStore.new(project_dir: @tmpdir, sdk_version: "26.5")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_store_and_lookup_roundtrip
    src = "@c public func glue_x_Sym() {}"
    @store.store(framework: "CoreAudio", symbol_name: "AudioObjectGetPropertyDataSize",
                 swift_source: src)
    result = @store.lookup(framework: "CoreAudio", symbol_name: "AudioObjectGetPropertyDataSize")
    assert_equal src, result
  end

  def test_lookup_returns_nil_for_unknown_symbol
    result = @store.lookup(framework: "CoreAudio", symbol_name: "NonExistent")
    assert_nil result
  end

  def test_store_sanitizes_symbol_name_with_dots
    src = "@c public func glue_x_NSString_str() {}"
    @store.store(framework: "Foundation", symbol_name: "NSString.stringWithUTF8String",
                 swift_source: src)
    result = @store.lookup(framework: "Foundation", symbol_name: "NSString.stringWithUTF8String")
    assert_equal src, result
  end

  def test_all_entries_lists_stored_glues
    @store.store(framework: "CoreAudio", symbol_name: "AudioObjectGetPropertyDataSize",
                 swift_source: "// glue A")
    @store.store(framework: "Foundation", symbol_name: "NSString", swift_source: "// glue B")
    entries = @store.all_entries
    assert_equal 2, entries.size
    frameworks = entries.map { |e| e[:framework] }.sort
    assert_equal %w[CoreAudio Foundation], frameworks
  end

  def test_store_creates_round_trip_test_when_provided
    @store.store(framework: "CoreAudio", symbol_name: "AudioSym",
                 swift_source: "// glue", round_trip_test: "# ruby test content")
    test_path = @store.round_trip_test_path(framework: "CoreAudio", symbol_name: "AudioSym")
    assert File.exist?(test_path), "round_trip_test file should be created"
    assert_equal "# ruby test content", File.read(test_path)
  end
end
