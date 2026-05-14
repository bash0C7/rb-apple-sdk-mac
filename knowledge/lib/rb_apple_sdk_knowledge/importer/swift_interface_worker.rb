# frozen_string_literal: true
require_relative "swift_interface_parser"

module AppleSDKKnowledge
  module Importer
    class SwiftInterfaceWorker
      def initialize
        @parser = SwiftInterfaceParser.new
      end

      def call(framework:, path:)
        _ = framework
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        symbols = @parser.parse_file(path)
        {
          result: symbols,
          error: nil,
          elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
        }
      rescue => e
        {
          result: nil,
          error: "#{e.class}: #{e.message}",
          elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
        }
      end
    end
  end
end
