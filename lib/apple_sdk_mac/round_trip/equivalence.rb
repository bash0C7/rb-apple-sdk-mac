# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
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
