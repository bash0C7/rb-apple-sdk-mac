# frozen_string_literal: true
require_relative "../sdk"

module AppleSDKKnowledge
  module Importer
    class SDKResolver
      Framework = Struct.new(:name, :path, keyword_init: true)

      def initialize(filter: nil)
        @filter = filter
      end

      def sdk_version
        SDK.version
      end

      def sdk_path
        SDK.path
      end

      def frameworks
        @frameworks ||= begin
          all = enumerate_frameworks
          @filter ? all.select { |fw| @filter.include?(fw.name) } : all
        end
      end

      private

      def enumerate_frameworks
        root = File.join(sdk_path, "System", "Library", "Frameworks")
        Dir.children(root)
          .select { |entry| entry.end_with?(".framework") }
          .map { |entry| Framework.new(name: entry.delete_suffix(".framework"), path: File.join(root, entry)) }
          .sort_by(&:name)
      end
    end
  end
end
