# frozen_string_literal: true
require "json"

# Intent → Apple.discover kwargs 生成。
#
# フロー:
#   1. Knowledge Base search で候補取得
#   2a. 0 件 → action: "no_match"
#   2b. 1 件 → 即決、 action: "accept" + kwargs
#   2c. 2 件以上 + server_context あり → create_form_elicitation で user に選ばせる
#       accept / decline / cancel の 3 分岐
#   2d. 2 件以上 + server_context なし → action: "candidates" でリスト返却 (host が
#       elicitation 非対応の場合の fallback)

module AppleSDKMac
  module MCP
    module Tools
      class SuggestDiscoverCall
        SEARCH_LIMIT = 5

        def self.tool_class(kb:)
          tool_obj = new(kb: kb)
          ::MCP::Tool.define(
            name: "apple_sdk_mac_suggest_discover_call",
            description: "intent から Apple.discover の正しい kwargs を生成する。 候補が複数あれば elicitation で user に選ばせる。 accept/decline/cancel/no_match/candidates の 5 action を返す。",
            input_schema: {
              type: "object",
              properties: {
                intent:    { type: "string", description: "やりたいことの自然言語表現" },
                framework: { type: "string", description: "(optional) 検索対象 framework" }
              },
              required: ["intent"]
            }
          ) do |intent:, framework: nil, server_context: nil, **_|
            AppleSDKMac::MCP::Server.wrap_with_log(tool_name: "apple_sdk_mac_suggest_discover_call") do
              text = tool_obj.call(intent: intent, framework: framework, server_context: server_context)
              ::MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          end
        end

        def initialize(kb:)
          @kb = kb
        end

        def call(intent:, framework: nil, server_context: nil)
          candidates = fetch_candidates(intent: intent, framework: framework)

          return JSON.generate(action: "no_match", message: "no candidates for intent: #{intent}") if candidates.empty?

          if candidates.size == 1
            return accept_response(candidates.first)
          end

          if server_context.nil? || !server_context.respond_to?(:create_form_elicitation)
            return candidates_response(candidates, "host has no server_context / elicitation method")
          end

          begin
            handle_elicitation(intent: intent, candidates: candidates, server_context: server_context)
          rescue StandardError => e
            # capability 未 declare、 transport 切断、 elicitation reject 等の例外を
            # candidates fallback に降ろす。 caller (AI agent) が手元で選べるように。
            candidates_response(candidates, "elicitation failed: #{e.message[0..200]}")
          end
        end

        def candidates_response(candidates, reason)
          JSON.generate(
            action: "candidates",
            message: reason,
            candidates: candidates
          )
        end

        private

        def fetch_candidates(intent:, framework:)
          if framework
            @kb.search(framework: framework, query: intent, limit: SEARCH_LIMIT).map { |r| r.merge(framework: framework) }
          else
            @kb.list_frameworks.flat_map { |fw|
              begin
                @kb.search(framework: fw, query: intent, limit: 3).map { |r| r.merge(framework: fw) }
              rescue StandardError
                []
              end
            }.first(SEARCH_LIMIT)
          end
        end

        def handle_elicitation(intent:, candidates:, server_context:)
          choices = candidates.map { |c| candidate_label(c) }
          schema = {
            type: "object",
            properties: {
              choice: {
                type: "string",
                enum: choices,
                description: "使う Apple SDK symbol を選択"
              }
            },
            required: ["choice"]
          }
          response = server_context.create_form_elicitation(
            message: "「#{intent}」 の候補が複数あります。 どれを使いますか?",
            requested_schema: schema
          )

          action = response[:action] || response["action"]
          case action
          when "accept"
            content = response[:content] || response["content"] || {}
            chosen_label = content[:choice] || content["choice"]
            chosen = candidates.find { |c| candidate_label(c) == chosen_label } || candidates.first
            accept_response(chosen)
          when "decline"
            JSON.generate(action: "decline", message: "user declined disambiguation")
          when "cancel"
            JSON.generate(action: "cancel", message: "user cancelled")
          else
            JSON.generate(action: action.to_s, message: "unexpected elicitation action")
          end
        end

        def accept_response(record)
          enriched = enrich_record(record)
          JSON.generate(
            action: "accept",
            kwargs: build_kwargs(enriched),
            record: enriched
          )
        end

        # search row は薄い (framework/name/kind/signature 程度)。 AI agent が
        # params: / return_kind: の override を判断するには documentation /
        # parameters_json / return_kind 等の richer field が要る。 lookup_symbol
        # で fetch しなおして上書き。 KB が lookup_symbol を持たん / nil 返すと
        # search row に fallback。
        def enrich_record(record)
          return record unless @kb.respond_to?(:lookup_symbol)
          fw   = record[:framework] || record["framework"]
          name = record[:name]      || record["name"]
          return record if fw.nil? || name.nil?
          fuller = begin
            @kb.lookup_symbol(framework: fw, name: name)
          rescue StandardError
            nil
          end
          fuller || record
        end

        def candidate_label(record)
          fw = record[:framework] || record["framework"]
          name = record[:name] || record["name"]
          kind = record[:kind] || record["kind"]
          sig = (record[:signature] || record["signature"]).to_s
          # signature の先頭 80 文字を suffix にして duplicate label を避ける
          # (Foundation の同名 instance_method overload 等)。
          suffix = sig.empty? ? "" : " — #{sig[0, 80]}"
          "#{fw}::#{name} (#{kind})#{suffix}"
        end

        def build_kwargs(record)
          fw   = record[:framework] || record["framework"]
          name = record[:name]      || record["name"]
          kind = (record[:kind]     || record["kind"]).to_s
          base = { framework: fw }

          case kind
          when "function", "global_constant"
            base.merge(symbol: name)
          when "struct", "class", "enum", "enum_module", "protocol", "actor"
            base.merge(klass: name)
          when "swift_func"
            klass, method = split_klass_method(name)
            klass ? base.merge(klass: klass, swift_func: method) : base.merge(swift_func: name)
          when "swift_init"
            klass, method = split_klass_method(name)
            base.merge(klass: klass, swift_initializer: method)
          when "swift_property"
            klass, method = split_klass_method(name)
            base.merge(klass: klass, swift_property: method, instance: true)
          when "instance_method", "objc_method_instance"
            klass, method = split_klass_method(name)
            base.merge(klass: klass, selector: method)
          when "class_method", "objc_method_class"
            klass, method = split_klass_method(name)
            base.merge(klass: klass, class_method: method)
          else
            base.merge(symbol: name)
          end
        end

        def split_klass_method(name)
          return [nil, name] unless name.include?(".")
          klass, _, method = name.partition(".")
          [klass, method]
        end
      end
    end
  end
end
