# frozen_string_literal: true

module AppleSDKMac
  module Inference
    # 推論 backend の抽象 interface。実装は Knowledge Base の symbol メタから Swift glue
    # source 文字列を返す。生成できなければ nil を返し、compile 側は
    # OutOfCoverageError に確定する。生成物は backend 信用ではなく、呼び出し側で
    # ValidationGates + swiftc + cache に通して初めて採用される。
    class Backend
      # @return [String, nil] Swift glue source、生成不能なら nil
      def generate_glue(framework:, symbol:, glue_id:, exported:)
        raise NotImplementedError, "#{self.class}#generate_glue"
      end

      # @return [String] telemetry 用 backend 識別子
      def name
        raise NotImplementedError, "#{self.class}#name"
      end
    end
  end
end
