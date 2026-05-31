# lib/apple_sdk_mac/round_trip/poc_loop.rb
# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    # Phase 0 PoC のオーケストレータ。ルール足場 seed → backend 生成 → round-trip 判定 →
    # RED なら失敗 detail+直前 glue を seed に足して budget まで retry → green / loud fail。
    # production try_inference は触らない。
    class PocLoop
      LoudFail = Class.new(StandardError)
      Outcome = Struct.new(:green?, :glue, :attempts, keyword_init: true)

      # backend: generate_glue(framework:, symbol:, seed:) -> glue 文字列
      # harness_check: lambda(glue) -> true(green)/false(red)
      def initialize(backend:, harness_check:, budget: 3)
        @backend = backend
        @harness_check = harness_check
        @budget = budget
      end

      def run(framework:, symbol:, rule_scaffold:)
        failure_detail = nil
        last_glue = nil
        attempt = 0
        while attempt < @budget
          seed = { rule_scaffold: rule_scaffold, failure_detail: failure_detail, last_glue: last_glue }
          glue = @backend.generate_glue(framework: framework, symbol: symbol, seed: seed)
          attempt += 1
          if @harness_check.call(glue)
            return Outcome.new(green?: true, glue: glue, attempts: attempt)
          end
          failure_detail = "round-trip RED on attempt #{attempt}"
          last_glue = glue
        end
        raise LoudFail, "#{framework}.#{symbol[:name]}: no green round-trip glue within budget=#{@budget}"
      end
    end
  end
end
