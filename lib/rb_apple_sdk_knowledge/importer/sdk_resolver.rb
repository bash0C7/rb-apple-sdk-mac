# frozen_string_literal: true
require "open3"

module AppleSDKKnowledge
  module Importer
    class SDKResolver
      Framework = Struct.new(:name, :path, keyword_init: true)

      def sdk_version
        @sdk_version ||= xcrun("--show-sdk-version").strip
      end

      def sdk_path
        @sdk_path ||= xcrun("--show-sdk-path").strip
      end

      def frameworks
        return @frameworks if @frameworks
        root = File.join(sdk_path, "System", "Library", "Frameworks")
        @frameworks = Dir.children(root)
          .select { |entry| entry.end_with?(".framework") }
          .map do |entry|
            Framework.new(
              name: entry.delete_suffix(".framework"),
              path: File.join(root, entry)
            )
          end
          .sort_by(&:name)
      end

      private

      def xcrun(*args)
        out, status = Open3.capture2("xcrun", *args)
        raise "xcrun failed: xcrun #{args.join(' ')}" unless status.success?
        out
      end
    end
  end
end
