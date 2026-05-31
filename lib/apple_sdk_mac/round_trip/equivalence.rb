# lib/apple_sdk_mac/round_trip/equivalence.rb
# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    # 戻り値の性質で段階縮退する等価述語。
    # :value  -> 値の等価
    # :opaque -> 型 tag 一致 + 両者 non-null (毎回別アドレス/別オブジェクトなので値は問わない)
    # :setter -> set した値と getter 読み戻しが一致 (set/readback ペア)
    module Equivalence
      module_function

      def equivalent?(kind:, swift:, ruby:)
        case kind
        when :value
          swift == ruby
        when :opaque
          shape_ok?(swift) && shape_ok?(ruby) && swift["type"] == ruby["type"]
        when :setter
          readback_ok?(swift) && readback_ok?(ruby)
        else
          raise ArgumentError, "unknown equivalence kind: #{kind.inspect}"
        end
      end

      def shape_ok?(obj)
        obj.is_a?(Hash) && obj["null"] == false && !obj["type"].to_s.empty?
      end

      def readback_ok?(obj)
        obj.is_a?(Hash) && obj.key?("set") && obj["set"] == obj["readback"]
      end
    end
  end
end
