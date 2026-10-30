# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    class PocLoop
      LoudFail = Class.new(StandardError)
      Outcome = Struct.new(:green?, :glue, :attempts, keyword_init: true)

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
