# frozen_string_literal: true
require "sqlite3"

module EmitterDev
  module Sources
    class CompileHistory
      class CacheNotFoundError < StandardError; end

      def initialize(sqlite_path)
        @sqlite_path = sqlite_path
      end

      def aggregate
        unless File.exist?(@sqlite_path)
          raise CacheNotFoundError,
            "compile_history db not found: #{@sqlite_path}\n" \
            "run `bundle exec rake apple:knowledge:rebuild` first."
        end
        db = SQLite3::Database.new(@sqlite_path)
        db.results_as_hash = true
        rows = db.execute(<<~SQL)
          SELECT framework, symbol,
                 SUM(CASE WHEN generator = 'llm'      THEN 1 ELSE 0 END) AS llm_count,
                 SUM(CASE WHEN generator = 'template' THEN 1 ELSE 0 END) AS tpl_count,
                 AVG(CASE WHEN generator = 'llm' THEN retry_count END)   AS avg_retry,
                 group_concat(DISTINCT error_stage)                       AS error_stages
          FROM compile_history
          GROUP BY framework, symbol
          HAVING llm_count > 0
          ORDER BY llm_count DESC, avg_retry DESC
        SQL
        rows.map do |r|
          {
            "framework"    => r["framework"],
            "symbol"       => r["symbol"],
            "llm_count"    => r["llm_count"].to_i,
            "tpl_count"    => r["tpl_count"].to_i,
            "avg_retry"    => (r["avg_retry"] || 0.0).to_f,
            "error_stages" => (r["error_stages"] || "").split(",").map(&:strip).reject(&:empty?).uniq,
          }
        end
      ensure
        db&.close
      end
    end
  end
end
