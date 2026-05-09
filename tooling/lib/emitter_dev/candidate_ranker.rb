# frozen_string_literal: true
require "time"

# Stateless candidate ranker for the HITL emitter-improvement workflow.
#
# Add mode only — given pre-aggregated compile_history rows, produce a
# sorted top-N candidate envelope per design spec section 5.1 / 5.6.
#
# Each input row is expected to be a Hash with string keys:
#   framework    : String
#   symbol       : String
#   llm_count    : Integer
#   tpl_count    : Integer
#   avg_retry    : Numeric (may be nil if no llm runs — those rows are dropped)
#   error_stages : String or nil (group_concat of distinct error_stage values)
#
# Source aggregation (SQLite read) is the rake task's job (Task 1.6); this
# module is intentionally stateless so it can be unit-tested with synthetic
# input arrays.
module EmitterDev
  module CandidateRanker
    TEMPLATE_NIL_BONUS = 5
    LLM_COUNT_WEIGHT   = 10
    AVG_RETRY_WEIGHT   = 3
    TPL_COUNT_PENALTY  = 1

    module_function

    def rank(rows:, mode:, top:)
      candidates = []
      candidates += rank_add(rows) if %w[add all].include?(mode)
      candidates.sort_by! { |c| -c["score"] }
      candidates = candidates.first(top)
      candidates.each_with_index { |c, i| c["id"] = i + 1 }
      {
        "generated_at" => Time.now.utc.iso8601,
        "mode"         => mode,
        "top"          => top,
        "candidates"   => candidates,
      }
    end

    def rank_add(rows)
      rows.each_with_object([]) do |row, acc|
        llm_count = row.fetch("llm_count").to_i
        next if llm_count <= 0   # mirror SQL `HAVING llm_count > 0`

        tpl_count    = row.fetch("tpl_count").to_i
        avg_retry    = (row["avg_retry"] || 0).to_f
        error_stages = row["error_stages"].to_s

        score = (llm_count * LLM_COUNT_WEIGHT) +
                (avg_retry * AVG_RETRY_WEIGHT) +
                (error_stages.split(",").include?("template_nil") ? TEMPLATE_NIL_BONUS : 0) -
                (tpl_count * TPL_COUNT_PENALTY)

        acc << {
          "mode"               => "add",
          "score"              => score.round(1),
          "summary"            => "#{row['framework']} / #{row['symbol']} の static emitter 追加",
          "evidence"           => { "compile_history" => row },
          "recommended_action" =>
            "compile_history で LLM 経路に流れとる #{row['symbol']} を template path に乗せる",
        }
      end
    end
  end
end
