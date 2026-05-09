# frozen_string_literal: true
require "open3"

module AppleSDKKnowledge
  class Error < StandardError; end

  module SDK
    module_function

    def version
      @version ||= xcrun("--show-sdk-version")
    end

    def path
      @path ||= xcrun("--show-sdk-path")
    end

    def xcrun(*args)
      out, err, status = Open3.capture3("xcrun", *args)
      raise Error, "xcrun #{args.join(' ')} failed: #{err.strip}" unless status.success?
      out.strip
    end
  end
end
