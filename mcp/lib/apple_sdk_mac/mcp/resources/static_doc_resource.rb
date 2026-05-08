# frozen_string_literal: true

# spec §5.1 — 静的 markdown を mcp/docs/resources/ から読み出す薄い handler。
# Resource handler は #call で markdown 文字列を返す約束。

module AppleSDKMac
  module MCP
    module Resources
      class StaticDocResource
        DOCS_DIR = File.expand_path("../../../../docs/resources", __dir__)

        def initialize(filename:)
          @path = File.join(DOCS_DIR, filename)
        end

        def call
          File.read(@path)
        rescue Errno::ENOENT
          "(documentation file not found: #{@path})"
        end
      end
    end
  end
end
