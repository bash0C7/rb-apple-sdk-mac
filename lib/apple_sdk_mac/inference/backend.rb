# frozen_string_literal: true

module AppleSDKMac
  module Inference
    # backend 生成結果。swift_source は glue 本体、driver_inputs は round-trip 検証
    # 駆動入力 (call_expr / invoke_args / value_kind / setter 系)。driver_inputs が
    # nil のときは C fallback (RoundTrip::GlueAnalyzer) に委ねる。
    BackendResult = Struct.new(:swift_source, :driver_inputs, keyword_init: true)

    # 推論 backend の抽象 interface。実装は Knowledge Base の symbol メタから Swift glue
    # source を生成し BackendResult で返す。生成できなければ nil を返し、compile 側は
    # OutOfCoverageError に確定する。生成物は backend 信用ではなく、呼び出し側で
    # ValidationGates + swiftc + round-trip + cache に通して初めて採用される。
    class Backend
      # @param seed [Hash, nil] optional seed context (各 key とも nil 可):
      #   :rule_scaffold   — template が生成した足場 Swift source
      #   :failure_detail  — 直前 attempt の失敗詳細文字列
      #   :last_glue       — 直前に reject された Swift source
      #   :context         — ユーザが retry_with(context:) で渡したヒント
      # @return [String, nil] Swift glue source、生成不能なら nil
      def generate_glue(framework:, symbol:, glue_id:, exported:, seed: nil)
        raise NotImplementedError, "#{self.class}#generate_glue"
      end

      # @return [String] telemetry 用 backend 識別子
      def name
        raise NotImplementedError, "#{self.class}#name"
      end
    end
  end
end
