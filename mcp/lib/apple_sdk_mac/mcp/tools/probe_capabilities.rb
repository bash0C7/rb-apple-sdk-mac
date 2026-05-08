# frozen_string_literal: true

# spec §4.7 — MCP host が elicitation / sampling capability を宣言しとるかを
# 実地で確認するツール。引数なし。 server_context.client_capabilities を覗いて
# 文字列で報告する。 Claude Code 接続デバッグ用、 elicitation 動作前の事前確認。

module AppleSDKMac
  module MCP
    module Tools
      module ProbeCapabilities
        def self.tool_class
          @tool_class ||= ::MCP::Tool.define(
            name: "apple_sdk_mac_probe_capabilities",
            description: "MCP host が elicitation / sampling capability を宣言しとるか実地で確認する実証ツール。引数なし。",
            input_schema: { type: "object", properties: {} }
          ) do |server_context: nil, **_|
            text = AppleSDKMac::MCP::Tools::ProbeCapabilities.report(server_context)
            ::MCP::Tool::Response.new([{ type: "text", text: text }])
          end
        end

        def self.report(server_context)
          return "no server_context available — capabilities unknown" if server_context.nil?
          caps = server_context.respond_to?(:client_capabilities) ? server_context.client_capabilities : nil
          caps ||= {}
          elicitation = capability_status(caps, "elicitation")
          sampling    = capability_status(caps, "sampling")
          <<~REPORT.strip
            MCP host capabilities:
              elicitation: #{elicitation}
              sampling: #{sampling}
          REPORT
        end

        def self.capability_status(caps, name)
          present = caps[name] || caps[name.to_sym]
          present ? "supported" : "not supported"
        end
      end
    end
  end
end
