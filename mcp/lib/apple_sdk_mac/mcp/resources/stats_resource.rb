# frozen_string_literal: true

# spec §5.2 — KB metadata (frameworks 数 / symbols 数 / kind 内訳) を markdown で返す。

module AppleSDKMac
  module MCP
    module Resources
      class StatsResource
        def initialize(kb:)
          @kb = kb
        end

        def call
          fw_count = @kb.list_frameworks.size
          symbol_count = total_symbol_count
          kind_breakdown = compute_kind_breakdown

          lines = []
          lines << "# rb-apple-sdk-mac KB Stats"
          lines << ""
          lines << "- frameworks: #{fw_count}"
          lines << "- symbols: #{symbol_count}"
          lines << ""
          unless kind_breakdown.empty?
            lines << "## kind 内訳"
            lines << ""
            lines << "| kind | count |"
            lines << "|---|---|"
            kind_breakdown.each { |kind, count| lines << "| #{kind} | #{count} |" }
          end
          lines.join("\n")
        end

        private

        def total_symbol_count
          row = @kb.db.execute("SELECT COUNT(*) FROM symbols").first
          row.is_a?(Array) ? row.first : row
        rescue StandardError
          "?"
        end

        def compute_kind_breakdown
          rows = @kb.db.execute(
            "SELECT kind, COUNT(*) FROM symbols GROUP BY kind ORDER BY COUNT(*) DESC"
          )
          rows.map { |row| [row[0], row[1]] }
        rescue StandardError
          []
        end
      end
    end
  end
end
