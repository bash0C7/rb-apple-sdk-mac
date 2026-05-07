# frozen_string_literal: true
require "apple_sdk_mac/irb"

module AppleSDKMac
  module IRB
    # Fires AutoDiscoverer.run in a background Thread when the popup
    # surfaces a class-method candidate, so glue compilation is in
    # flight (and frequently finished) by the time the user actually
    # calls the method. Idempotent per (framework, klass, name) for
    # the lifetime of the process — popup hover repeats are common
    # and we never want to re-run the same discover.
    class Prefetcher
      def initialize(discoverer:)
        @discoverer = discoverer
        @started = {}
        @mutex = Mutex.new
      end

      # Returns the spawned Thread when prefetch was kicked off, or nil
      # when the matched candidate was not eligible (non-Apple input,
      # framework or module level, or already started).
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
              # Background prefetch must never crash IRB. Surface the
              # error only when explicitly debugging.
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
