# frozen_string_literal: true
require "test_helper"
require "json"
require "tmpdir"
require "fileutils"
require "apple_sdk_mac/compiled_glue_cache"
require "apple_sdk_mac/diagnostics"

# Apple.diagnostics JSON dump. Spec §9 acceptance:
# "JSON: cache stats / recent LLM attempts (last 16) / last 16 validation
# failures / pillar runtime stats. Sufficient for issue reproduction."
#
# Tests build a cache from scratch with synthetic rows so we don't
# depend on the live KB/cache state.
class TestDiagnostics < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @cache = AppleSDKMac::CompiledGlueCache.open(@tmpdir, sdk_version: "26.0")
    seed_synthetic_data
  end

  def teardown
    @cache.close
    FileUtils.rm_rf(@tmpdir)
  end

  def seed_synthetic_data
    3.times do |i|
      @cache.insert(
        glue_id: "glue-#{i}", framework: "F", symbol: "Sym#{i}",
        swift_source: "x" * 16, dylib_path: "/tmp/glue-#{i}.dylib",
        exported_symbol: "ex-#{i}", generator: i.even? ? "template" : "llm"
      )
    end
    20.times do |i|
      @cache.record_attempt(
        framework: "F", symbol: "Try#{i}", generator: "llm",
        llm_response: nil,
        error_stage: i.odd? ? "validation" : nil,
        error_detail: i.odd? ? "shape mismatch" : nil
      )
    end
  end

  def test_diagnostics_module_present
    assert AppleSDKMac::Diagnostics.respond_to?(:dump),
      "AppleSDKMac::Diagnostics.dump must exist"
  end

  def test_diagnostics_dump_returns_json_serializable_hash
    h = AppleSDKMac::Diagnostics.dump(cache: @cache)
    assert_kind_of Hash, h
    json = JSON.dump(h)
    parsed = JSON.parse(json)
    assert_equal h.keys.map(&:to_s).sort, parsed.keys.sort
  end

  def test_diagnostics_includes_cache_stats
    h = AppleSDKMac::Diagnostics.dump(cache: @cache)
    assert h.key?(:cache), "diagnostics must include :cache key"
    assert_equal 3, h[:cache][:compiled_glue_count]
    assert_equal AppleSDKMac::CompiledGlueCache::CACHE_SCHEMA_VERSION,
                 h[:cache][:schema_version],
                 "schema_version は CompiledGlueCache::CACHE_SCHEMA_VERSION と一致"
    assert_equal "26.0", h[:cache][:sdk_version]
  end

  def test_diagnostics_recent_llm_attempts_capped_at_16
    h = AppleSDKMac::Diagnostics.dump(cache: @cache)
    assert h.key?(:llm_attempts_recent)
    assert_operator h[:llm_attempts_recent].size, :<=, 16,
      "must cap at 16; got #{h[:llm_attempts_recent].size}"
    # Most recent first ordering — record_attempt seeds 20 in ascending
    # order so the highest-numbered attempt should be at the head.
    head_symbol = h[:llm_attempts_recent].first[:symbol]
    assert_match(/^Try1\d$/, head_symbol,
      "expected Try1x at head (most recent), got #{head_symbol}")
  end

  def test_diagnostics_recent_validation_failures_capped_at_16
    h = AppleSDKMac::Diagnostics.dump(cache: @cache)
    assert h.key?(:validation_failures_recent)
    assert h[:validation_failures_recent].all? { |a| a[:error_stage] == "validation" }
    assert_operator h[:validation_failures_recent].size, :<=, 16
  end

  def test_diagnostics_includes_pillar_runtime_stats_keys
    h = AppleSDKMac::Diagnostics.dump(cache: @cache)
    assert h.key?(:pillar_runtime), "diagnostics must include :pillar_runtime"
    pr = h[:pillar_runtime]
    assert pr.key?(:refs_alive),           "pillar_runtime needs :refs_alive"
    assert pr.key?(:threading_queue_depth),"pillar_runtime needs :threading_queue_depth"
  end

  # Public surface — Apple.diagnostics module method routes to the
  # collector. Argument-less form must work (uses live caches).
  def test_apple_module_method_exists
    assert ::Apple.respond_to?(:diagnostics),
      "Apple.diagnostics must be public"
  end
end
