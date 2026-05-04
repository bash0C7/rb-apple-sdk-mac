# frozen_string_literal: true
require "did_you_mean"

module AppleSDKMac
  module DidYouMeanIntegration
    class AppleSDKChecker
      def initialize(no_method_error)
        @receiver = no_method_error.receiver
        @method = no_method_error.name
      end

      def corrections
        return [] unless apple_module?(@receiver)
        framework = framework_name(@receiver)
        return [] unless framework
        knowledge = AppleSDKMac.knowledge_cache
        results = knowledge.search(framework: framework, query: @method.to_s, limit: 5)
        results.map { |r| r[:name] }
      end

      def formatter(corrections)
        if corrections.empty?
          "\nIf this is a real Apple SDK API not yet known to the bridge, run:\n" \
          "  Apple.discover(framework: :#{framework_name(@receiver)}, " \
          "symbol: :#{@method})\n"
        else
          msg = "\nDid you mean? #{corrections.join(', ')}\n"
          msg + "\nIf you want a brand-new API, run Apple.discover(...).\n"
        end
      end

      private

      def apple_module?(receiver)
        receiver.is_a?(Module) && AppleSDKMac.box_module?(receiver)
      end

      def framework_name(receiver)
        receiver.name && receiver.name.split("::").last
      end
    end
  end
end

DidYouMean.correct_error(NoMethodError, AppleSDKMac::DidYouMeanIntegration::AppleSDKChecker)
