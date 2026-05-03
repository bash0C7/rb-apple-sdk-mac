# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    class Embedder
      DIM = 768

      def initialize
        @backend = detect_backend
      end

      def available?
        !@backend.nil?
      end

      def backend_name
        @backend && @backend[:name]
      end

      def embed(text)
        return zero_vector if @backend.nil?
        @backend[:fn].call(text)
      end

      private

      def detect_backend
        if defined?(::AppleFoundationModel)
          { name: :foundation_models, fn: ->(t) { foundation_models_embed(t) } }
        elsif informers_available?
          require "informers"
          model = Informers.pipeline("feature-extraction", "mochiya98/ruri-v3-310m-onnx")
          { name: :informers, fn: ->(t) { model.(t).flatten } }
        else
          nil
        end
      rescue LoadError
        nil
      end

      def informers_available?
        require "informers"
        true
      rescue LoadError
        false
      end

      def foundation_models_embed(_text)
        # Plan-A v1 does not yet expose embeddings. Fallback to zero vector.
        zero_vector
      end

      def zero_vector
        Array.new(DIM, 0.0)
      end
    end
  end
end
