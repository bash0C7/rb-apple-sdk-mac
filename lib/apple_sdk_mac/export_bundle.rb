# frozen_string_literal: true
require "json"

module AppleSDKMac
  module ExportBundle
    InferenceRecord = Struct.new(
      :framework, :symbol, :sdk_version, :kind,
      :rule_failure_reason, :rule_scaffold, :inferred_glue, :context_used,
      :round_trip_outcome,
      keyword_init: true
    )

    module_function

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
