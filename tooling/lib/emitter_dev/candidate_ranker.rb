# frozen_string_literal: true
require "time"

# Stateless candidate ranker for the HITL emitter-improvement workflow.
#
# Two modes share a single envelope:
#
#   add  — given pre-aggregated compile_history rows, produce candidates
#          for adding new static emitters. See spec section 5.1 / 5.6.
#   trim — given RedundancyScanner findings, produce candidates for
#          consolidating redundant marshallers. See spec section 5.4.
#   all  — emit add and trim merged, sorted by score together.
#
# `rank_add` row shape (Hash with string keys):
#   framework, symbol, llm_count, tpl_count, avg_retry (nil-safe), error_stages
#
# `rank_trim` finding shape (Hash with symbol keys, produced by
# `EmitterDev::RedundancyScanner#scan`):
#   :heuristic, :classes, :methods | :common_methods, :score
#
# Source aggregation (SQLite read for add, AST scan for trim) lives in the
# rake task layer; this module stays stateless so it unit-tests against
# synthetic input arrays.
module EmitterDev
  module CandidateRanker
    TEMPLATE_NIL_BONUS = 5
    LLM_COUNT_WEIGHT   = 10
    AVG_RETRY_WEIGHT   = 3
    TPL_COUNT_PENALTY  = 1

    module_function

    def rank(rows: [], findings: [], mode:, top:)
      candidates = []
      candidates.concat(rank_add(rows))      if %w[add all].include?(mode)
      candidates.concat(rank_trim(findings)) if %w[trim all].include?(mode)
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

    def rank_trim(findings)
      findings.map do |f|
        {
          "mode"               => "trim",
          "score"              => f.fetch(:score).to_f,
          "summary"            => trim_summary(f),
          "evidence"           => { "redundancy_scanner" => stringify_finding(f) },
          "recommended_action" => trim_action(f),
        }
      end
    end

    def trim_summary(f)
      case f[:heuristic]
      when :twin_private_helper
        "#{f[:classes].join(' / ')} の双子 helper #{f[:methods].join(' / ')} を共通化"
      when :class_pair_method_overlap
        "Marshaller pair #{f[:classes].join(' / ')} の重複 method " \
          "#{f[:common_methods].join(',')} を整理"
      else
        "redundancy: #{f[:heuristic]}"
      end
    end

    def trim_action(f)
      case f[:heuristic]
      when :twin_private_helper
        "#{f[:methods].join(' と ')} を Marshaller base の単一 helper にまとめて両 class から呼ぶ"
      when :class_pair_method_overlap
        "#{f[:classes].join(' と ')} の overlap (#{f[:common_methods].join(',')}) を片方に統合 + 残る側を delegator に"
      else
        "redundancy 解消"
      end
    end

    # JSON encoders fail on Symbol-keyed hashes downstream (FactBundler reads
    # candidates back out as JSON), so flatten finding keys to strings before
    # emitting the candidate envelope.
    def stringify_finding(f)
      f.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.is_a?(Symbol) ? v.to_s : v }
    end
  end
end
