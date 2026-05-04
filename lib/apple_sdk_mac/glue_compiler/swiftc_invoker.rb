# frozen_string_literal: true
require "open3"

module AppleSDKMac
  class GlueCompiler
    class SwiftcInvoker
      def initialize(swiftc: nil, sdk_path: nil)
        @swiftc = swiftc || ENV["RB_APPLE_SDK_MAC_SWIFTC"] || "swiftc"
        @sdk_path = sdk_path
      end

      def compile(source_path:, dylib_path:, runtime_dylib_path: nil, link_libs: [])
        sdk = @sdk_path || `xcrun --show-sdk-path`.strip
        args = [
          "-emit-library",
          "-target", "arm64-apple-macos26.0",
          "-sdk", sdk,
          "-O",
          "-parse-as-library",
          "-enable-library-evolution",
          "-o", dylib_path
        ]
        link_libs.each do |lib|
          args << "-l#{lib}"
        end
        if runtime_dylib_path
          args << "-Xlinker"
          args << runtime_dylib_path
        end
        args << source_path

        out, err, status = Open3.capture3(@swiftc, *args)
        if status.success?
          [true, out]
        else
          [false, err]
        end
      end
    end
  end
end
