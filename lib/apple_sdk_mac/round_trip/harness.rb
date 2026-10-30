# frozen_string_literal: true
require "json"
require_relative "equivalence"
require_relative "driver_generator"

module AppleSDKMac
  module RoundTrip
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
      rescue JSON::ParserError
        nil
      end

      def unwrap(value_kind, obj)
        case value_kind
        when :value  then obj["v"]
        when :opaque then obj
        when :setter then obj
        else raise ArgumentError, "unknown value_kind: #{value_kind.inspect}"
        end
      end
    end
  end
end
