# lib/apple_sdk_mac/round_trip/glue_analyzer.rb
# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    # C フォールバック: LLM が json ブロック (driver_inputs) を返さなかったとき、
    # 生成済み glue source を静的解析して round-trip 駆動入力を best-effort 合成する。
    #
    # 安全契約: 確信が持てない形は必ず nil 縮退する。誤った call_expr / invoke_args を
    # 作ると round-trip が false RED / false GREEN になり検証の意味が壊れるので、
    # 「正しく取れるか nil か」の二択に倒す。対応するのは
    #   - zero-arg glue (引数を取らない = invoke_args [] が安全) で
    #   - return が自己完結 native call 式 (out-param 経由で local を返す形は対象外)
    #   - 戻り型が value / opaque (Void/setter は A path 必須)
    # の組み合わせのみ。
    module GlueAnalyzer
      module_function

      # 数値系戻り型 (Optional 付き含む) → :value。
      VALUE_RETURN = /\A(Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Double|Float|CGFloat|Bool)\??\z/

      # @return [Hash, nil] {call_expr:, invoke_args:, value_kind:} or nil
      def extract_driver_inputs(swift_source)
        return nil if swift_source.nil?
        sig = swift_source.match(
          /public\s+func\s+glue_[A-Za-z0-9_]+\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_<>?.\s]+?)\s*)?\{/m
        )
        return nil unless sig
        return nil unless sig[1].strip.empty?       # zero-arg glue のみ
        ret = sig[2].to_s.strip
        kind = value_kind_for(ret)
        return nil unless kind                       # Void / 未対応戻り型は nil
        call = extract_return_call(swift_source)
        return nil unless call
        { call_expr: call, invoke_args: [], value_kind: kind }
      end

      # 戻り型 → value_kind。value 判定を先に行う (Int32? を opaque と誤判定しない)。
      def value_kind_for(ret)
        return nil if ret.empty?
        return :value  if ret.match?(VALUE_RETURN)
        return :opaque if ret == "AnyObject" || ret.end_with?("?")
        nil
      end

      # 最初の `return <expr>` を取り、それが call 式 (`Ident(...)`) なら call_expr。
      # bare な local var (`return size`) は自己完結 call ではないので nil。
      def extract_return_call(src)
        m = src.match(/\breturn\s+([^\n]+)/)
        return nil unless m
        expr = m[1].strip.sub(/;\z/, "").strip
        expr.match?(/\A[\w.]+\s*\(.*\)\z/) ? expr : nil
      end
    end
  end
end
