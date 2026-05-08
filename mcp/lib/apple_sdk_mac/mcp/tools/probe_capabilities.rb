# frozen_string_literal: true
require "json"

# spec §4.7 — MCP host が elicitation / sampling capability を実装しとるかを
# 実地で確認するツール。 chiebukuro-mcp の ProbeTool と同方式: 実際に
# server_context.create_form_elicitation / create_sampling_message を呼んで、
# 例外で判定する。 mcp gem の client_capabilities hash は host 側 transport の
# 実装で必ずしも populate されないため、 hash 覗きより実呼びの方が信頼できる。
#
# 出力は JSON。 elicitation/sampling 各々 status (supported/unsupported) と
# 補助情報 (action / model) もしくは error message を含む。

module AppleSDKMac
  module MCP
    module Tools
      module ProbeCapabilities
        ELICITATION_PROBE_MESSAGE = "rb-apple-sdk-mac-mcp probe: please decline to confirm elicitation works."
        ELICITATION_PROBE_SCHEMA  = {
          type: "object",
          properties: {
            ack: { type: "boolean", description: "Acknowledge that elicitation works" }
          },
          required: ["ack"]
        }.freeze

        SAMPLING_PROBE_MESSAGES = [
          { role: "user", content: { type: "text", text: "Reply with the single word 'pong'." } }
        ].freeze
        SAMPLING_PROBE_SYSTEM_PROMPT = "You are a probe responder. Reply tersely."

        def self.tool_class
          @tool_class ||= ::MCP::Tool.define(
            name: "apple_sdk_mac_probe_capabilities",
            description: "MCP host が elicitation / sampling capability を実装しとるか実地で確認する実証ツール。 create_form_elicitation / create_sampling_message を実呼びし例外で判定。 引数なし、 JSON で結果を返す。",
            input_schema: { type: "object", properties: {} }
          ) do |server_context: nil, **_|
            text = AppleSDKMac::MCP::Tools::ProbeCapabilities.report(server_context)
            ::MCP::Tool::Response.new([{ type: "text", text: text }])
          end
        end

        def self.report(server_context)
          if server_context.nil?
            return JSON.generate(status: "error", error: "no server_context available — capabilities cannot be probed")
          end
          JSON.generate(
            elicitation: probe_elicitation(server_context),
            sampling:    probe_sampling(server_context)
          )
        end

        def self.probe_elicitation(ctx)
          response = ctx.create_form_elicitation(
            message: ELICITATION_PROBE_MESSAGE,
            requested_schema: ELICITATION_PROBE_SCHEMA
          )
          {
            status: "supported",
            action: response[:action] || response["action"]
          }
        rescue StandardError => e
          { status: "unsupported", error: e.message }
        end

        def self.probe_sampling(ctx)
          response = ctx.create_sampling_message(
            messages:      SAMPLING_PROBE_MESSAGES,
            max_tokens:    10,
            system_prompt: SAMPLING_PROBE_SYSTEM_PROMPT
          )
          {
            status: "supported",
            model:  response[:model] || response["model"]
          }
        rescue StandardError => e
          { status: "unsupported", error: e.message }
        end
      end
    end
  end
end
