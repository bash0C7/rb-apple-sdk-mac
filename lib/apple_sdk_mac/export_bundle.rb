# frozen_string_literal: true
require "json"

module AppleSDKMac
  # Tier 3 還流: 推論成功 symbol の export bundle 形式。
  # bundle は upstream の rb-apple-sdk-mac-improve-emitter HITL workflow に
  # 手動 PR で提出する。自動 PR 投稿は行わない (1-way door)。
  #
  # round-trip green 証跡は production inference path の round-trip 検証で得られ、
  # round_trip_outcome フィールド ("green: ..." or nil=未検証) として bundle に含む。
  module ExportBundle
    InferenceRecord = Struct.new(
      :framework, :symbol, :sdk_version, :kind,
      :rule_failure_reason, :rule_scaffold, :inferred_glue, :context_used,
      :round_trip_outcome,
      keyword_init: true
    )

    module_function

    # 失敗理由の先頭 word でクラスタリング。
    # "uncovered shape: out-param struct" → cluster key "uncovered shape"
    def cluster_by_failure_reason(records)
      records.group_by do |r|
        r.rule_failure_reason.to_s.split(":").first.to_s.strip
      end
    end

    def cluster_summary(records)
      cluster_by_failure_reason(records).transform_values(&:size)
    end

    def to_json(records)
      JSON.pretty_generate(records.map { |r|
        r.to_h.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v }
      })
    end

    # GlueStore の provenance sidecar から InferenceRecord を復元。
    # 成功 inference は store 時に金脈フィールド (kind / rule_failure_reason /
    # rule_scaffold / context_used) を sidecar 永続化しており、ここから組み立てる。
    def from_glue_store(store)
      store.provenance_entries.map do |h|
        InferenceRecord.new(
          framework: h["framework"], symbol: h["symbol"],
          sdk_version: h["sdk_version"], kind: h["kind"],
          rule_failure_reason: h["rule_failure_reason"],
          rule_scaffold: h["rule_scaffold"],
          inferred_glue: h["inferred_glue"],
          context_used: h["context_used"],
          round_trip_outcome: h["round_trip_outcome"]
        )
      end
    end
  end
end
