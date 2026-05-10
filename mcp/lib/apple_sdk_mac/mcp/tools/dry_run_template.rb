# frozen_string_literal: true
require "json"
require "securerandom"

# TemplateGenerator#generate だけ呼んで Swift glue source 文字列を返す
# (swiftc は走らせない)。 親 gem 強依存ポイント:
# AppleSDKMac::GlueCompiler::TemplateGenerator を直接呼ぶ。
#
# trust-but-verify ループ: AI が「ユーザが Apple.discover 走らせたら↓の Swift が
# cache される」を実行前に確認できる。

module AppleSDKMac
  module MCP
    module Tools
      class DryRunTemplate
        def self.tool_class(kb:)
          tool_obj = new(kb: kb)
          ::MCP::Tool.define(
            name: "apple_sdk_mac_dry_run_template",
            description: "TemplateGenerator のみ呼び出して、 Apple.discover が走った場合に生成される Swift glue source を返す。 swiftc は走らせない。 LLM fallback path の場合は declined を返す。",
            input_schema: {
              type: "object",
              properties: {
                framework: { type: "string", description: "framework 名" },
                symbol:    { type: "string", description: "symbol canonical name" }
              },
              required: ["framework", "symbol"]
            }
          ) do |framework:, symbol:, server_context: nil, **_|
            AppleSDKMac::MCP::Server.wrap_with_log(tool_name: "apple_sdk_mac_dry_run_template") do
              text = tool_obj.call(framework: framework, symbol: symbol)
              ::MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          end
        end

        def initialize(kb:, template: nil)
          @kb = kb
          @template = template || lazy_template
        end

        def call(framework:, symbol:)
          record = @kb.lookup_symbol(framework: framework, symbol: symbol)
          if record.nil?
            return JSON.generate(
              error: "symbol not found in KB",
              framework: framework,
              symbol: symbol
            )
          end

          glue_id = "dryrun_#{SecureRandom.hex(8)}"
          swift_source = @template.generate(framework: framework, symbol: record, glue_id: glue_id)

          if swift_source.nil?
            JSON.generate(
              generator: "template",
              result: "declined",
              message: "TemplateGenerator declined this symbol — at real Apple.discover time the LLM fallback path would handle it",
              framework: framework,
              symbol: symbol
            )
          else
            JSON.generate(
              generator: "template",
              result: "success",
              framework: framework,
              symbol: symbol,
              glue_id: glue_id,
              swift_source: swift_source
            )
          end
        end

        private

        def lazy_template
          @lazy_template ||= ::AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: @kb)
        end
      end
    end
  end
end
