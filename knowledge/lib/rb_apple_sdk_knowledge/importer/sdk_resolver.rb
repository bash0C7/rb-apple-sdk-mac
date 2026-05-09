# frozen_string_literal: true
require_relative "../sdk"

module AppleSDKKnowledge
  module Importer
    class SDKResolver
      Framework = Struct.new(:name, :path, keyword_init: true)

      def sdk_version
        SDK.version
      end

      def sdk_path
        SDK.path
      end

      def frameworks
        @frameworks ||= begin
          root = File.join(sdk_path, "System", "Library", "Frameworks")
          Dir.children(root)
            .select { |entry| entry.end_with?(".framework") }
            .map { |entry| Framework.new(name: entry.delete_suffix(".framework"), path: File.join(root, entry)) }
            .sort_by(&:name)
        end
      end
    end
  end
end
