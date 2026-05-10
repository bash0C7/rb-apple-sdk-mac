# frozen_string_literal: true
require "json"

# Ruby コード片の Apple.discover / Apple::FW.method 呼び出しを Knowledge Base
# に対して検証する。 swiftc は走らせない (重い)。 regex で抽出 →
# lookup_symbol で存在確認、 不存在シンボルを issues として返す。

module AppleSDKMac
  module MCP
    module Tools
      class ValidateCall
        # `Apple.discover(framework: :Foo, symbol: :Bar)` 形を抽出。 ネスト無し前提
        # (引数に :"foo(bar)" のような quote 内 paren が来る稀ケースは後続改修で対応)。
        DISCOVER_BLOCK_RE = /Apple\.discover\(([^)]*?)\)/.freeze
        FRAMEWORK_RE = /framework:\s*[:"']?([A-Z][A-Za-z0-9_]*)["']?/.freeze
        SYMBOL_KEYWORDS = %w[symbol selector class_method swift_func swift_initializer swift_property].freeze
        # symbol value forms: :"..." | :'...' | "..." | '...' | :bare
        def self.symbol_value_re(kw)
          /#{kw}:\s*(?::"([^"]+)"|:'([^']+)'|"([^"]+)"|'([^']+)'|:([A-Za-z_][A-Za-z0-9_]*))/
        end

        # Apple.discover 後の動的メソッドの直接呼び出し:
        #   Apple::Foundation::URL.appendingPathComponent("...")  # FW::Klass.method
        #   Apple::CoreMIDI.MIDIClientCreate(...)                 # FW.func
        # group1 = framework, group2 = klass (optional, nil は FW.func 形),
        # group3 = method。 Klass の有無で symbol を "Klass.method" or "method"
        # に組み立てて KB lookup。
        # lookbehind: 文字列頭 / literal "\n" 2 chars / non-word のいずれか。
        # `\b` だと literal `\n` (backslash + n) の n→A 間で boundary が立たず
        # 抽出に失敗するため、 zero-width lookbehind で 3 case を網羅する。
        DIRECT_CALL_RE = /(?<=\A|\\n|[^A-Za-z0-9_])Apple::([A-Z][A-Za-z0-9_]*)(?:::([A-Z][A-Za-z0-9_]*))?\.([A-Za-z_][A-Za-z0-9_?!]*)/.freeze

        def self.tool_class(kb:)
          tool_obj = new(kb: kb)
          ::MCP::Tool.define(
            name: "apple_sdk_mac_validate_call",
            description: "Ruby コード片の中の Apple.discover 呼び出しを抽出し、 KB に存在しない symbol を warning として返す。 swiftc 起動なし。",
            input_schema: {
              type: "object",
              properties: {
                ruby_code: { type: "string", description: "検証する Ruby コード片" }
              },
              required: ["ruby_code"]
            }
          ) do |ruby_code:, server_context: nil, **_|
            AppleSDKMac::MCP::Server.wrap_with_log(tool_name: "apple_sdk_mac_validate_call") do
              text = tool_obj.call(ruby_code: ruby_code)
              ::MCP::Tool::Response.new([{ type: "text", text: text }])
            end
          end
        end

        def initialize(kb:)
          @kb = kb
        end

        def call(ruby_code:)
          issues = []
          total  = 0

          extract_discoveries(ruby_code).each do |framework, symbol|
            total += 1
            record = @kb.lookup_symbol(framework: framework, symbol: symbol)
            issues << build_issue(framework, symbol) if record.nil?
          end

          # klass あり時は parent_id JOIN で検証する KnowledgeCache#lookup_klass_method
          # 経由。 Knowledge Base の symbols table は klass を parent_id で持つので
          # flat name lookup_symbol("Klass.method") では hit しない。
          extract_direct_calls(ruby_code).each do |framework, klass, method|
            total += 1
            record = if klass
                       @kb.lookup_klass_method(framework: framework, klass: klass, method: method)
                     else
                       @kb.lookup_symbol(framework: framework, symbol: method)
                     end
            if record.nil?
              symbol = klass ? "#{klass}.#{method}" : method
              issues << build_issue(framework, symbol)
            end
          end

          JSON.generate(
            valid: issues.empty?,
            checked_count: total,
            issues: issues
          )
        end

        private

        def build_issue(framework, symbol)
          {
            kind: "unknown_symbol",
            message: "symbol '#{symbol}' not found in framework '#{framework}'",
            framework: framework,
            symbol: symbol
          }
        end

        def extract_discoveries(code)
          results = []
          code.scan(DISCOVER_BLOCK_RE) do |(args_str)|
            framework = args_str[FRAMEWORK_RE, 1]
            next unless framework
            symbol = extract_symbol_value(args_str)
            results << [framework, symbol] if symbol
          end
          results
        end

        def extract_direct_calls(code)
          results = []
          code.scan(DIRECT_CALL_RE) do |framework, klass, method|
            results << [framework, klass, method]
          end
          results
        end

        def extract_symbol_value(args_str)
          SYMBOL_KEYWORDS.each do |kw|
            re = self.class.symbol_value_re(kw)
            if (m = args_str.match(re))
              return m.captures.compact.first
            end
          end
          nil
        end
      end
    end
  end
end
