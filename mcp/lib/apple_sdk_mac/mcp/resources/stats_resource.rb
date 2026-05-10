# frozen_string_literal: true

# Knowledge Base metadata (frameworks 数 / symbols 数 / kind 内訳) を markdown で返す。

module AppleSDKMac
  module MCP
    module Resources
      class StatsResource
        def initialize(kb:)
          @kb = kb
        end

        def call
          s = @kb.stats
          lines = []
          lines << "# rb-apple-sdk-mac KB Stats"
          lines << ""
          lines << "- frameworks: #{s[:framework_count]}"
          lines << "- symbols: #{s[:symbol_count]}"
          lines << ""
          unless s[:kind_breakdown].empty?
            lines << "## kind 内訳"
            lines << ""
            lines << "| kind | count |"
            lines << "|---|---|"
            s[:kind_breakdown].each { |kind, count| lines << "| #{kind} | #{count} |" }
          end
          lines.join("\n")
        end
      end
    end
  end
end
