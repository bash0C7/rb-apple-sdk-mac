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

  # 同 (framework, symbol) で別 glue_id (= parameters_json 差) の row が並存すると、
  # lookup は LIMIT 1 / no ORDER BY で旧 row を返す可能性がある。 これは Apple.discover が
  # `params:` / `return_kind:` override を渡したときに発生する cache pollution の真因
  # (postmortem 2026-05-14 #1)。 insert は同 (framework, symbol) の旧 row を invalidate して
  # 「(framework, symbol) は最新 1 row のみ」 の invariant を保つ。
  def test_insert_invalidates_prior_row_with_same_framework_and_symbol
    @cache.insert(
      glue_id: "old_id", framework: "AVFAudio",
      symbol: "AVAudioEngine.startAndReturnError",
      swift_source: "old_src",
      dylib_path: File.join(@tmpdir, "lib", "old_id.dylib"),
      exported_symbol: "glue_old_id_start", generator: "template"
    )
    @cache.insert(
      glue_id: "new_id", framework: "AVFAudio",
      symbol: "AVAudioEngine.startAndReturnError",
      swift_source: "new_src",
      dylib_path: File.join(@tmpdir, "lib", "new_id.dylib"),
      exported_symbol: "glue_new_id_start", generator: "template"
    )

    rec = @cache.lookup(framework: "AVFAudio",
                        symbol: "AVAudioEngine.startAndReturnError")
    assert_equal "new_id", rec[:glue_id],
      "lookup must return the newly inserted row, not the stale one"

    count = @cache.db.execute(
      "SELECT COUNT(*) FROM compiled_glue WHERE framework_name=? AND symbol_name=?",
      ["AVFAudio", "AVAudioEngine.startAndReturnError"]
    ).first[0]
    assert_equal 1, count,
      "stale row with different glue_id must be invalidated"
  end

  # 同 glue_id の再 insert は既存 INSERT OR REPLACE 経路に乗って idempotent。
  # 新 invariant 導入で他 (framework, symbol) row が誤って消えないことも保証。
  def test_insert_does_not_disturb_unrelated_rows
    @cache.insert(
      glue_id: "id_a", framework: "F1", symbol: "S1",
      swift_source: "a", dylib_path: File.join(@tmpdir, "a.dylib"),
      exported_symbol: "glue_a", generator: "template"
    )
    @cache.insert(
      glue_id: "id_b", framework: "F2", symbol: "S2",
      swift_source: "b", dylib_path: File.join(@tmpdir, "b.dylib"),
      exported_symbol: "glue_b", generator: "template"
    )

    assert_equal "id_a", @cache.lookup(framework: "F1", symbol: "S1")[:glue_id]
    assert_equal "id_b", @cache.lookup(framework: "F2", symbol: "S2")[:glue_id]
  end
end
