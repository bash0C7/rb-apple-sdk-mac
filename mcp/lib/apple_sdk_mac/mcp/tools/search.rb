# frozen_string_literal: true
require "json"

# Knowledge Base の semantic + lexical 検索。
#
# input_schema:
#   query        (string, required)  — 検索したい機能の自然言語表現
#   framework?   (string)            — 特定 framework に限定
#   kinds?       (array of string)   — function/class/swift_func/objc_method_instance 等で絞り込み
#   limit?       (integer, default 10)
#
# 親 gem の KnowledgeCache#search は framework: 必須なので、 framework 未指定時は
# list_frameworks を回して各 framework から拾い、 統合してから limit する。

module AppleSDKMac
  module MCP
    module Tools
      class Search
        DEFAULT_LIMIT = 10
        PER_FRAMEWORK_FETCH = 5
        # 親 gem の Store#fts_search が FTS5 を multi-token AND default で叩くため、
        # 自然言語 phrase (例 "read EXIF metadata from image") では 0 件返る。
        # MCP 経由は AI が自然言語投げてくる前提なので、 ここで token 化 + OR 結合に
        # 正規化する。 1 token / 空文字 / FTS5 syntax 文字を含む advanced query は
        # そのまま透過。
        # 2 文字 token (of, is, it, to, at, in, on, by 等) は Apple SDK 名前空間で
        # ノイズが大きい。 3 文字以上に絞ると URL / EXIF / from / with / image 等の
        # signal は残る。
        MIN_TOKEN_LENGTH = 3

        def self.tool_class(kb:)
          tool_obj = new(kb: kb)
          ::MCP::Tool.define(
            name: "apple_sdk_mac_search",
            description: "rb-apple-sdk-mac の Knowledge Base から Apple SDK symbol を検索する。 自然言語 phrase は 3 文字以上の token に分解され OR 結合で投げられる (例 'read EXIF metadata from image' → 'read OR EXIF OR metadata OR from OR image')。 1 token / OR・AND・NOT を含む advanced query はそのまま透過。 framework / kinds での絞り込み optional。 結果は JSON 配列のテキスト。",
            input_schema: {
              type: "object",
              properties: {
                query:     { type: "string",  description: "検索したい機能の自然言語表現" },
                framework: { type: "string",  description: "(optional) 特定 framework に限定" },
                kinds:     { type: "array", items: { type: "string" },
                             description: "(optional) function / class / swift_func / objc_method_instance 等で絞り込み" },
                limit:     { type: "integer", description: "(optional) 上限件数 (default 10)" }
              },
              required: ["query"]
            }
          ) do |query:, framework: nil, kinds: nil, limit: DEFAULT_LIMIT, server_context: nil, **_|
            AppleSDKMac::MCP::Server.wrap_with_log(tool_name: "apple_sdk_mac_search") do
              text = tool_obj.call(query: query, framework: framework, kinds: kinds, limit: limit)
              ::MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          end
        end

        def initialize(kb:)
          @kb = kb
        end

        def call(query:, framework: nil, kinds: nil, limit: DEFAULT_LIMIT)
          normalized = normalize_query(query)
          rows = if framework
                   fetch_one_framework(framework: framework, query: normalized, limit: limit)
                 else
                   fetch_cross_framework(query: normalized, limit: limit)
                 end
          rows = filter_kinds(rows, kinds)
          JSON.generate(rows.first(limit))
        end

        # token 化 + OR 結合。 短すぎる token (a / of 等) は filter。
        # 1 token / 空 / 既に OR/AND 含む advanced query はそのまま透過。
        def normalize_query(query)
          return query if query.nil? || query.empty?
          return query if query.match?(/\b(?:OR|AND|NOT)\b/)
          tokens = query.scan(/[A-Za-z0-9_]+/).select { |t| t.length >= MIN_TOKEN_LENGTH }
          return query if tokens.size <= 1
          tokens.join(" OR ")
        end

        private

        def fetch_one_framework(framework:, query:, limit:)
          @kb.search(framework: framework, query: query, limit: limit).map do |r|
            r.merge(framework: framework)
          end
        end

        def fetch_cross_framework(query:, limit:)
          @kb.search_all_frameworks(query: query, per_fw: PER_FRAMEWORK_FETCH, total: limit)
        end

        def filter_kinds(rows, kinds)
          return rows if kinds.nil? || kinds.empty?
          allowed = kinds.map(&:to_s)
          rows.select { |r| allowed.include?(r[:kind].to_s) }
        end
      end
    end
  end
end
