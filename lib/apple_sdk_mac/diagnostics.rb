# frozen_string_literal: true
require "json"

module AppleSDKMac
  module Diagnostics
    HISTORY_CAP = 16

    def self.dump(cache: nil)
      cache ||= AppleSDKMac.glue_cache
      {
        cache:                       cache_stats(cache),
        llm_attempts_recent:         recent_attempts(cache),
        validation_failures_recent:  recent_validation_failures(cache),
        pillar_runtime:              pillar_runtime_stats
      }
    end

    def self.cache_stats(cache)
      db = cache.db
      count = db.execute("SELECT COUNT(*) FROM compiled_glue").first[0]
      {
        compiled_glue_count: count,
        schema_version:      cache.schema_version,
        sdk_version:         cache.sdk_version,
        base_dir:            cache.base_dir
      }
    end

    def self.recent_attempts(cache)
      cache.db.execute(<<~SQL, [HISTORY_CAP]).map { |r| attempt_row(r) }
        SELECT framework, symbol, attempt_at, generator, error_stage, error_detail, glue_id
        FROM compile_history
        ORDER BY id DESC
        LIMIT ?
      SQL
    end

    def self.recent_validation_failures(cache)
      cache.db.execute(<<~SQL, [HISTORY_CAP]).map { |r| attempt_row(r) }
        SELECT framework, symbol, attempt_at, generator, error_stage, error_detail, glue_id
        FROM compile_history
        WHERE error_stage = 'validation'
        ORDER BY id DESC
        LIMIT ?
      SQL
    end

    def self.attempt_row(r)
      { framework: r[0], symbol: r[1], attempt_at: r[2], generator: r[3],
        error_stage: r[4], error_detail: r[5], glue_id: r[6] }
    end

    def self.pillar_runtime_stats
      refs = safe_call { ::AppleSDKMacRuntime.respond_to?(:ref_table_count) && ::AppleSDKMacRuntime.ref_table_count } || 0
      qd   = safe_call { ::AppleSDKMacRuntime.respond_to?(:threading_queue_depth) && ::AppleSDKMacRuntime.threading_queue_depth } || 0
      { refs_alive: refs, threading_queue_depth: qd }
    end

    def self.safe_call
      yield
    rescue StandardError => e
      warn "diagnostics: safe_call swallowed #{e.class}: #{e.message}" if ENV["APPLE_DEBUG"]
      nil
    end
  end
end
