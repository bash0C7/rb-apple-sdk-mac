# frozen_string_literal: true
require "json"

# spec §4.2 — symbol full record (parameters_json 込み)。
# 親 gem の KnowledgeCache#lookup_symbol を呼び、 transient overlay → DB の
# 優先順で record (Hash) または nil を返す。 nil は JSON 'null' として返却。

module AppleSDKMac
  module MCP
    module Tools
      class GetSymbolInfo
        def self.tool_class(kb:)
          tool_obj = new(kb: kb)
          ::MCP::Tool.define(
            name: "apple_sdk_mac_get_symbol_info",
            description: "Knowledge Base から symbol の完全な record (kind / signature / parameters_json / parent_id 等) を返す。",
            input_schema: {
              type: "object",
              properties: {
                framework: { type: "string", description: "framework 名 (例 Foundation)" },
                symbol:    { type: "string", description: "symbol canonical name (例 URL or URL.appendingPathComponent(_:))" }
              },
              required: ["framework", "symbol"]
            }
          ) do |framework:, symbol:, server_context: nil, **_|
            AppleSDKMac::MCP::Server.wrap_with_log(tool_name: "apple_sdk_mac_get_symbol_info") do
              text = tool_obj.call(framework: framework, symbol: symbol)
              ::MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          end
        end

        def initialize(kb:)
          @kb = kb
        end

        def call(framework:, symbol:)
          record = @kb.lookup_symbol(framework: framework, symbol: symbol)
          JSON.generate(record)
        end
      end
    end
  end
end
