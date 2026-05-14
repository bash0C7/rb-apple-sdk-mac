# frozen_string_literal: true
require_relative "header_parser"

module AppleSDKKnowledge
  module Importer
    class ObjCHeaderWorker
      def initialize(sdk_path:)
        @parser = HeaderParser.new(sdk_path: sdk_path)
      end

      # framework: は WorkerPool dispatch シグネチャと揃えるために受け取るが、
      # HeaderParser#parse_file は path 単独で動くため現状未使用。
      def call(framework:, header:)
        _ = framework
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        symbols = @parser.parse_file(header)
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
