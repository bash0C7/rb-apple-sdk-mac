# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
require "apple_sdk_mac/compiled_glue_cache"

class TestCompiledGlueCache < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @cache = AppleSDKMac::CompiledGlueCache.open(@tmpdir, sdk_version: "26.0")
  end

  def teardown
    @cache.close
    FileUtils.rm_rf(@tmpdir)
  end

  def test_lookup_returns_nil_for_unknown
    assert_nil @cache.lookup(framework: "CoreMIDI", symbol: "Foo")
  end

  def test_insert_and_lookup_round_trip
    @cache.insert(
      glue_id: "abc123",
      framework: "CoreMIDI",
      symbol: "MIDIClientCreate",
      swift_source: "@c public func glue_abc123_MIDIClientCreate(...)",
      dylib_path: File.join(@tmpdir, "lib", "abc123.dylib"),
      exported_symbol: "glue_abc123_MIDIClientCreate",
      generator: "template"
    )
    rec = @cache.lookup(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    assert_equal "abc123", rec[:glue_id]
    assert_equal "template", rec[:generator]
  end

  # schema_version mismatch evicts rows. When the mac gem bumps
  # CACHE_SCHEMA_VERSION (template HEADER, marshaller emit, etc. change in
  # ways that invalidate stored Swift sources), reopening the cache must
  # evict the stale dylibs so the next discover recompiles instead of
  # dlopen'ing a pre-bump dylib that may no longer link.
  def test_schema_version_mismatch_evicts_compiled_glue_rows
    @cache.insert(
      glue_id: "old1", framework: "F", symbol: "Sym",
      swift_source: "old", dylib_path: File.join(@tmpdir, "old.dylib"),
      exported_symbol: "glue_old1_Sym", generator: "template"
    )
    assert_not_nil @cache.lookup(framework: "F", symbol: "Sym")
    @cache.close

    cache2 = AppleSDKMac::CompiledGlueCache.open(
      @tmpdir, sdk_version: "26.0", schema_version: "future-bump"
    )
    assert_nil cache2.lookup(framework: "F", symbol: "Sym"),
      "schema_version bump must evict pre-bump rows"
    cache2.close
  end

  def test_schema_version_match_preserves_rows
    @cache.insert(
      glue_id: "keep", framework: "F", symbol: "Sym",
      swift_source: "keep", dylib_path: File.join(@tmpdir, "keep.dylib"),
      exported_symbol: "glue_keep_Sym", generator: "template"
    )
    @cache.close

    cache2 = AppleSDKMac::CompiledGlueCache.open(@tmpdir, sdk_version: "26.0")
    assert_not_nil cache2.lookup(framework: "F", symbol: "Sym"),
      "same schema_version must preserve cache rows across reopens"
    cache2.close
  end
end
