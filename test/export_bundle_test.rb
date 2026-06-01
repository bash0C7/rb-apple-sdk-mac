# frozen_string_literal: true
require "test/unit"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/apple_sdk_mac/export_bundle"
require_relative "../lib/apple_sdk_mac/glue_store"

class ExportBundleTest < Test::Unit::TestCase
  SAMPLE_RECORDS = [
    AppleSDKMac::ExportBundle::InferenceRecord.new(
      framework: "CoreAudio",
      symbol: "AudioObjectGetPropertyDataSize",
      sdk_version: "26.5",
      kind: "function",
      rule_failure_reason: "uncovered shape: out-param struct",
      rule_scaffold: "// template output",
      inferred_glue: "@c public func glue_x_AudioObjectGetPropertyDataSize() {}",
      context_used: nil
    ),
    AppleSDKMac::ExportBundle::InferenceRecord.new(
      framework: "CoreAudio",
      symbol: "AudioObjectSetPropertyData",
      sdk_version: "26.5",
      kind: "function",
      rule_failure_reason: "uncovered shape: out-param struct",
      rule_scaffold: nil,
      inferred_glue: "@c public func glue_y_AudioObjectSetPropertyData() {}",
      context_used: "Use UInt32 size param"
    ),
    AppleSDKMac::ExportBundle::InferenceRecord.new(
      framework: "Foundation",
      symbol: "NSString.init",
      sdk_version: "26.5",
      kind: "swift_initializer",
      rule_failure_reason: "uncovered shape: swift initializer",
      rule_scaffold: nil,
      inferred_glue: "@c public func glue_z_NSString_init() {}",
      context_used: nil
    )
  ].freeze

  def test_cluster_groups_by_failure_reason_prefix
    clusters = AppleSDKMac::ExportBundle.cluster_by_failure_reason(SAMPLE_RECORDS)
    assert clusters.key?("uncovered shape"), "should have cluster for 'uncovered shape'"
    # spec §5: cluster key は失敗理由の先頭 word (":" の前)。
    # "uncovered shape: out-param struct" → "uncovered shape"
    # "uncovered shape: swift initializer" → "uncovered shape"
    # よって 3 record すべてが同一 cluster "uncovered shape" に入る。
    assert_equal 3, clusters["uncovered shape"].size,
                 "all three records share the 'uncovered shape' prefix cluster"
  end

  def test_to_json_produces_valid_json
    json_str = AppleSDKMac::ExportBundle.to_json(SAMPLE_RECORDS)
    parsed = JSON.parse(json_str)
    assert_equal 3, parsed.size
    assert_equal "CoreAudio", parsed.first["framework"]
    assert_equal "AudioObjectGetPropertyDataSize", parsed.first["symbol"]
  end

  def test_to_json_includes_all_required_fields
    json_str = AppleSDKMac::ExportBundle.to_json(SAMPLE_RECORDS)
    parsed = JSON.parse(json_str)
    record = parsed.first
    %w[framework symbol sdk_version kind rule_failure_reason inferred_glue].each do |field|
      assert record.key?(field), "export bundle record must include '#{field}'"
    end
  end

  def test_cluster_summary_returns_counts
    summary = AppleSDKMac::ExportBundle.cluster_summary(SAMPLE_RECORDS)
    assert summary.is_a?(Hash)
    assert summary.values.all? { |v| v.is_a?(Integer) }
  end

  def test_from_glue_store_builds_records
    Dir.mktmpdir do |tmpdir|
      store = AppleSDKMac::GlueStore.new(project_dir: tmpdir, sdk_version: "26.5")
      store.store(framework: "CoreAudio", symbol_name: "AudioObjectGetPropertyDataSize",
                  swift_source: "@c public func glue_a() {}",
                  kind: "function",
                  rule_failure_reason: "uncovered shape: out-param struct",
                  rule_scaffold: "// scaffold a",
                  context_used: nil)
      store.store(framework: "Foundation", symbol_name: "NSString.init",
                  swift_source: "@c public func glue_b() {}",
                  kind: "swift_initializer",
                  rule_failure_reason: "uncovered shape: swift initializer",
                  rule_scaffold: "// scaffold b",
                  context_used: "hint")

      records = AppleSDKMac::ExportBundle.from_glue_store(store)
      assert_equal 2, records.size
      assert records.all? { |r| r.is_a?(AppleSDKMac::ExportBundle::InferenceRecord) }

      by_symbol = records.group_by(&:symbol)
      audio = by_symbol["AudioObjectGetPropertyDataSize"].first
      assert_equal "CoreAudio", audio.framework
      assert_equal "26.5", audio.sdk_version
      assert_equal "function", audio.kind
      assert_equal "uncovered shape: out-param struct", audio.rule_failure_reason
      assert_equal "// scaffold a", audio.rule_scaffold
      assert_equal "@c public func glue_a() {}", audio.inferred_glue
      assert_nil audio.context_used

      ns = by_symbol["NSString.init"].first
      assert_equal "hint", ns.context_used

      # records flow through cluster/to_json correctly
      summary = AppleSDKMac::ExportBundle.cluster_summary(records)
      assert_equal 2, summary["uncovered shape"]
      parsed = JSON.parse(AppleSDKMac::ExportBundle.to_json(records))
      assert_equal 2, parsed.size
    end
  end

  # round-trip green 証跡が GlueStore → InferenceRecord → Tier 3 export まで流れる。
  def test_from_glue_store_maps_round_trip_outcome
    Dir.mktmpdir do |tmpdir|
      store = AppleSDKMac::GlueStore.new(project_dir: tmpdir, sdk_version: "26.5")
      store.store(framework: "CoreAudio", symbol_name: "AudioObjectGetPropertyDataSize",
                  swift_source: "@c public func glue_a() {}",
                  kind: "function", rule_failure_reason: "uncovered shape",
                  round_trip_outcome: "green: equivalent")
      rec = AppleSDKMac::ExportBundle.from_glue_store(store).first
      assert_equal "green: equivalent", rec.round_trip_outcome
      parsed = JSON.parse(AppleSDKMac::ExportBundle.to_json([rec])).first
      assert_equal "green: equivalent", parsed["round_trip_outcome"]
    end
  end
end
