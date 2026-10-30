# frozen_string_literal: true
require "apple_sdk_mac/irb"

module AppleSDKMac
  module IRB
    class Prefetcher
      def initialize(discoverer:)
        @discoverer = discoverer
        @started = {}
        @mutex = Mutex.new
      end

      def prefetch(matched)
        ctx = AppleSDKMac::IRB::Context.parse(matched)
        return nil if ctx.nil? || ctx.receiver_kind != :class
        key = [ctx.framework, ctx.klass, ctx.prefix]
        @mutex.synchronize do
          return nil if @started.key?(key)
          thread = Thread.new do
            begin
              @discoverer.run(ctx, ctx.prefix)
            rescue => e
              warn "[apple-sdk-mac prefetch] #{e.class}: #{e.message}" if ENV["APPLE_IRB_DEBUG"]
            end
          end
          @started[key] = thread
          thread
        end
      end

      def started?(framework:, klass:, name:)
        key = [framework, klass, name]
        @mutex.synchronize { @started.key?(key) }
      end
    end
  end
end
