# frozen_string_literal: true
require "json"

# spec §4.6 — Ruby コード片の Apple.discover / Apple::FW.method 呼び出しを
# KB に対して検証。 swiftc は走らせない (重い)。 regex で抽出 → KB lookup_symbol
# で存在確認、 不存在シンボルを issues として返す。

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
        DIRECT_CALL_RE = /\bApple::([A-Z][A-Za-z0-9_]*)(?:::([A-Z][A-Za-z0-9_]*))?\.([A-Za-z_][A-Za-z0-9_?!]*)/.freeze

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
            text = tool_obj.call(ruby_code: ruby_code)
            ::MCP::Tool::Response.new([{ type: "text", text: text }])
          end
        end

        def initialize(kb:)
          @kb = kb
        end

        def call(ruby_code:)
          all = extract_discoveries(ruby_code) + extract_direct_calls(ruby_code)
          issues = []

          all.each do |framework, symbol|
            record = @kb.lookup_symbol(framework: framework, symbol: symbol)
            if record.nil?
              issues << {
                kind: "unknown_symbol",
                message: "symbol '#{symbol}' not found in framework '#{framework}'",
                framework: framework,
                symbol: symbol
              }
            end
          end

          JSON.generate(
            valid: issues.empty?,
            checked_count: all.size,
            issues: issues
          )
        end

        private

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
            symbol = klass ? "#{klass}.#{method}" : method
            results << [framework, symbol]
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
