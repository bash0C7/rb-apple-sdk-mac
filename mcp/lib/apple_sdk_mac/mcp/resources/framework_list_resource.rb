# frozen_string_literal: true

# Knowledge Base から framework 一覧 + symbol 数を markdown 表で返す。

module AppleSDKMac
  module MCP
    module Resources
      class FrameworkListResource
        def initialize(kb:)
          @kb = kb
        end

        def call
          frameworks = @kb.list_frameworks.sort
          lines = []
          lines << "# Apple SDK Frameworks (KB に存在するもの)"
          lines << ""
          lines << "総数: #{frameworks.size} framework"
          lines << ""
          lines << "| framework |"
          lines << "|---|"
          frameworks.each { |fw| lines << "| #{fw} |" }
          lines.join("\n")
        end
      end
    end
  end
end
