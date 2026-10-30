# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    module DriverGenerator
      module_function

      def generate(framework:, symbol:, value_kind:)
        body =
          case value_kind
          when :value  then value_body(symbol)
          when :opaque then opaque_body(symbol)
          when :setter then setter_body(symbol)
          else raise ArgumentError, "unknown value_kind: #{value_kind.inspect}"
          end
        <<~SWIFT
          import #{framework}
          import Foundation

          func emit(_ json: String) { print("RTRESULT:" + json) }

          #{body}
        SWIFT
      end

      def value_body(symbol)
        <<~SWIFT
          let __v = #{symbol[:call_expr]}
          emit("{\\"v\\":\\(__v)}")
        SWIFT
      end

      def opaque_body(symbol)
        <<~SWIFT
          let __o: AnyObject? = #{symbol[:call_expr]} as AnyObject?
          let __null = (__o == nil)
          let __t = __null ? "nil" : String(describing: type(of: __o!))
          emit(#"{"type":"\\#(__t)","null":\\#(__null)}"#)
        SWIFT
      end

      def setter_body(symbol)
        set_value = symbol[:set_value].to_s
        if set_value.include?('"')
          raise ArgumentError,
            "setter_body set_value must not contain a double-quote (got: #{set_value.inspect}). " \
            "Use a numeric Swift literal."
        end
        <<~SWIFT
          #{symbol[:set_expr]}
          let __rb = #{symbol[:read_expr]}
          emit(#"{"set":#{set_value},"readback":\\#(__rb)}"#)
        SWIFT
      end
    end
  end
end
