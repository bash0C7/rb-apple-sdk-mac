# frozen_string_literal: true

module AppleSDKMac
  module Inference
    BackendResult = Struct.new(:swift_source, :driver_inputs, keyword_init: true)

    class Backend
      def generate_glue(framework:, symbol:, glue_id:, exported:, seed: nil)
        raise NotImplementedError, "#{self.class}#generate_glue"
      end

      def name
        raise NotImplementedError, "#{self.class}#name"
      end
    end
  end
end
