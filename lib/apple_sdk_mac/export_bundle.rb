# frozen_string_literal: true
require "json"

module AppleSDKMac
  # Tier 3 還流: 推論成功 symbol の export bundle 形式。
  # bundle は upstream の rb-apple-sdk-mac-improve-emitter HITL workflow に
  # 手動 PR で提出する。自動 PR 投稿は行わない (1-way door)。
  module ExportBundle
    InferenceRecord = Struct.new(
      :framework, :symbol, :sdk_version, :kind,
      :rule_failure_reason, :rule_scaffold, :inferred_glue, :context_used,
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

    # CompiledGlueCache の compile_history から InferenceRecord を復元。
    # generator が 'inference:' で始まる successful row を対象とする。
    def from_cache(cache)
      rows = cache.db.execute(<<~SQL)
        SELECT cg.framework_name, cg.symbol_name, cg.swift_source,
               ch.error_detail, ch.llm_response
        FROM compiled_glue cg
        JOIN compile_history ch
          ON ch.framework = cg.framework_name AND ch.symbol = cg.symbol_name
        WHERE cg.generator LIKE 'inference:%'
        ORDER BY cg.generated_at
      SQL
      rows.map do |row|
        InferenceRecord.new(
          framework: row[0], symbol: row[1], sdk_version: cache.sdk_version,
          kind: nil, rule_failure_reason: row[3], rule_scaffold: nil,
          inferred_glue: row[2], context_used: nil
        )
      end
    end
  end
end
