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
        # 参照/新規確保: Optional を意識し、実 nil チェックで null フィールドを出す。
        # call_expr が nil を返しうる Optional 型でも "null":false ハードコードしない。
        <<~SWIFT
          let __o: AnyObject? = #{symbol[:call_expr]} as AnyObject?
          let __null = (__o == nil)
          let __t = __null ? "nil" : String(describing: type(of: __o!))
          emit(#"{"type":"\\#(__t)","null":\\#(__null)}"#)
        SWIFT
      end

      def setter_body(symbol)
        # set → getter 読み戻し。set 値と readback を一緒に吐く。
        # set_value はそのまま Swift リテラルとして埋め込むので、JSON を壊す
        # unescaped double-quote を含む値は拒否する (numeric か single-quoted literal を使う)。
        set_value = symbol[:set_value].to_s
        if set_value.include?('"')
          raise ArgumentError,
            "setter_body set_value must not contain unescaped double-quote (got: #{set_value.inspect}). " \
            "Use a numeric or single-quoted Swift literal."
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
