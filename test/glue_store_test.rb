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

  def test_safe_name_is_injective_no_collision
    # "NSString.foo" and literal "NSString_foo" must NOT collapse to the same
    # path. With a lossy gsub(/[^A-Za-z0-9_]/, "_") both became "NSString_foo"
    # and the second store silently overwrote the first (1 entry). The injective
    # encoding keeps them distinct (2 entries), each looking up its own content.
    @store.store(framework: "Foundation", symbol_name: "NSString.foo",
                 swift_source: "// dotted")
    @store.store(framework: "Foundation", symbol_name: "NSString_foo",
                 swift_source: "// underscored")
    assert_equal 2, @store.all_entries.size
    assert_equal "// dotted", @store.lookup(framework: "Foundation", symbol_name: "NSString.foo")
    assert_equal "// underscored", @store.lookup(framework: "Foundation", symbol_name: "NSString_foo")
  end

  def test_safe_name_injective_objc_selector
    # ObjC selector "foo:bar:" must not collide with literal "foo_bar_".
    @store.store(framework: "Foundation", symbol_name: "foo:bar:", swift_source: "// selector")
    @store.store(framework: "Foundation", symbol_name: "foo_bar_", swift_source: "// literal")
    assert_equal 2, @store.all_entries.size
    assert_equal "// selector", @store.lookup(framework: "Foundation", symbol_name: "foo:bar:")
    assert_equal "// literal", @store.lookup(framework: "Foundation", symbol_name: "foo_bar_")
  end

  def test_store_creates_round_trip_test_when_provided
    @store.store(framework: "CoreAudio", symbol_name: "AudioSym",
                 swift_source: "// glue", round_trip_test: "# ruby test content")
    test_path = @store.round_trip_test_path(framework: "CoreAudio", symbol_name: "AudioSym")
    assert File.exist?(test_path), "round_trip_test file should be created"
    assert_equal "# ruby test content", File.read(test_path)
  end

  def test_store_writes_provenance_sidecar_when_provenance_given
    swift = "@c public func glue_x_Sym() {}"
    @store.store(framework: "CoreAudio", symbol_name: "AudioObjectGetPropertyDataSize",
                 swift_source: swift,
                 kind: "function",
                 rule_failure_reason: "uncovered shape: out-param struct",
                 rule_scaffold: "// template output",
                 context_used: "Use UInt32 size param")
    entries = @store.provenance_entries
    assert_equal 1, entries.size, "one provenance sidecar should be present"
    e = entries.first
    assert_equal "CoreAudio", e["framework"]
    assert_equal "AudioObjectGetPropertyDataSize", e["symbol"]
    assert_equal "26.5", e["sdk_version"]
    assert_equal "function", e["kind"]
    assert_equal "uncovered shape: out-param struct", e["rule_failure_reason"]
    assert_equal "// template output", e["rule_scaffold"]
    assert_equal "Use UInt32 size param", e["context_used"]
    assert_equal swift, e["inferred_glue"], "inferred_glue must match sibling .swift content"
  end

  def test_provenance_entries_empty_when_no_provenance
    @store.store(framework: "CoreAudio", symbol_name: "AudioSym", swift_source: "// glue only")
    assert_equal [], @store.provenance_entries,
                 "no sidecar should be emitted when no provenance fields are given"
  end
end
