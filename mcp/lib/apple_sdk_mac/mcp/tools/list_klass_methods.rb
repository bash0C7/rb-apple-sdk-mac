# frozen_string_literal: true
require "json"

module AppleSDKMac
  module MCP
    module Tools
      class ListKlassMethods
        def self.tool_class(kb:)
          tool_obj = new(kb: kb)
          ::MCP::Tool.define(
            name: "apple_sdk_mac_list_klass_methods",
            description: "Knowledge Base からクラス / 構造体の子 (instance method / class method / property / init / enum_case 等) を列挙する。",
            input_schema: {
              type: "object",
              properties: {
                framework: { type: "string", description: "framework 名" },
                klass:     { type: "string", description: "クラス / 構造体 / actor / protocol 名" }
              },
              required: ["framework", "klass"]
            }
          ) do |framework:, klass:, server_context: nil, **_|
            AppleSDKMac::MCP::Server.wrap_with_log(tool_name: "apple_sdk_mac_list_klass_methods") do
              text = tool_obj.call(framework: framework, klass: klass)
              ::MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          end
        end

        def initialize(kb:)
          @kb = kb
        end

        def call(framework:, klass:)
          rows = @kb.list_klass_methods(framework: framework, klass: klass)
          JSON.generate(rows)
        end
      end
    end
  end
end
