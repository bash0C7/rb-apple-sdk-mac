# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    class Embedder
      DIM = 768

      def available?
        defined?(::AppleFoundationModel) ? true : false
      end

      def backend_name
        available? ? :foundation_models : nil
      end

      def embed(_text)
        Array.new(DIM, 0.0)
      end
    end
  end
end
