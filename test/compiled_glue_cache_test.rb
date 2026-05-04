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
end
