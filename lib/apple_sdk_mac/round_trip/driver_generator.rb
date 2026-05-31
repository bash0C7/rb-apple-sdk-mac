# lib/apple_sdk_mac/round_trip/driver_generator.rb
# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    # symbol を native に呼び結果を `RTRESULT:<json>` 1 行で stdout に吐く Swift ドライバを生成。
    # value_kind ごとに吐く JSON 形が変わる:
    #   :value  -> {"v": <serialized>}            (Harness 側で v を取り出し値比較)
    #   :opaque -> {"type": "...", "null": <bool>}
    #   :setter -> {"set": <v>, "readback": <v>}
    # call_expr / set_expr / read_expr / set_value は symbol メタ (KB or 手書き) が供給する。
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
        # 新規確保/参照: 非 nil なら null=false。type は Swift の動的型名。
        <<~SWIFT
          let __o = #{symbol[:call_expr]}
          let __t = String(describing: type(of: __o))
          emit(#"{"type":"\\#(__t)","null":false}"#)
        SWIFT
      end

      def setter_body(symbol)
        # set → getter 読み戻し。set 値と readback を一緒に吐く。
        <<~SWIFT
          #{symbol[:set_expr]}
          let __rb = #{symbol[:read_expr]}
          emit(#"{"set":#{symbol[:set_value]},"readback":\\#(__rb)}"#)
        SWIFT
      end
    end
  end
end
