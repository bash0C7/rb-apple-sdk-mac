# lib/apple_sdk_mac/round_trip/harness.rb
# frozen_string_literal: true
require "json"
require_relative "equivalence"
require_relative "driver_generator"

module AppleSDKMac
  module RoundTrip
    # 直走値(Swift driver) と wrapper 値(Ruby-via-glue) を突き合わせ green/red を返す。
    # swift_runner: lambda(swift_source) -> stdout 文字列 (compile+実走の実体は注入)
    # ruby_runner:  lambda() -> Ruby wrapper の戻り値
    class Harness
      Outcome = Struct.new(:green?, :detail, :swift, :ruby, keyword_init: true)

      def initialize(swift_runner:, ruby_runner:)
        @swift_runner = swift_runner
        @ruby_runner = ruby_runner
      end

      def check(framework:, symbol:, value_kind:)
        src = DriverGenerator.generate(framework: framework, symbol: symbol, value_kind: value_kind)
        stdout = @swift_runner.call(src)
        swift_obj = parse_rtresult(stdout)
        if swift_obj.nil?
          return Outcome.new(green?: false,
                             detail: "no RTRESULT line in swift driver output: #{stdout.to_s[0, 200]}")
        end
        swift_val = unwrap(value_kind, swift_obj)
        ruby_val = @ruby_runner.call
        green = Equivalence.equivalent?(kind: value_kind, swift: swift_val, ruby: ruby_val)
        Outcome.new(green?: green, swift: swift_val, ruby: ruby_val,
                    detail: green ? "equivalent" : "mismatch: swift=#{swift_val.inspect} ruby=#{ruby_val.inspect}")
      end

      private

      def parse_rtresult(stdout)
        line = stdout.to_s.each_line.find { |l| l.start_with?("RTRESULT:") }
        return nil unless line
        JSON.parse(line.sub("RTRESULT:", "").strip)
      rescue JSON::ParserError => e
        nil # parse 不能は RTRESULT 無し扱い (detail は呼び出し側で表面化)
      end

      # value_kind ごとに driver JSON から比較対象を取り出す。
      def unwrap(value_kind, obj)
        case value_kind
        when :value  then obj["v"]
        when :opaque then obj            # {"type","null"} を Equivalence にそのまま渡す
        when :setter then obj            # {"set","readback"}
        else raise ArgumentError, "unknown value_kind: #{value_kind.inspect}"
        end
      end
    end
  end
end
