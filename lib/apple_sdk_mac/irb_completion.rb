# frozen_string_literal: true

module AppleSDKMac
  module IRBCompletion
    Context = Struct.new(:framework, :klass, :receiver_kind, :prefix) do
      # Parse Reline input line into framework/klass/prefix.
      # Returns nil for non-Apple paths.
      def self.parse(input)
        return nil unless input.is_a?(String)
        return nil unless input.start_with?("Apple::")
        rest = input[7..]

        if rest.empty? || rest.match?(/\A[A-Z][A-Za-z0-9_]*\z/)
          return new(nil, nil, :apple_root, rest)
        end

        if (m = rest.match(/\A([A-Z][A-Za-z0-9_]*)::([A-Za-z0-9_]*)\z/))
          return new(m[1], nil, :module, m[2])
        end

        if (m = rest.match(/\A([A-Z][A-Za-z0-9_]*)::([A-Z][A-Za-z0-9_]*)\.([A-Za-z0-9_]*)\z/))
          return new(m[1], m[2], :class, m[3])
        end

        nil
      end
    end
  end
end
