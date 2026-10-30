# frozen_string_literal: true
require "apple_sdk_mac/irb"

module AppleSDKMac
  module IRB
    class DocResolver
      def initialize(knowledge_cache:)
        @cache = knowledge_cache
      end

      def resolve(matched)
        ctx = AppleSDKMac::IRB::Context.parse(matched)
        return nil if ctx.nil?
        lookup_raw(ctx)
      end

      private

      def lookup_raw(ctx)
        case ctx.receiver_kind
        when :class
          @cache.lookup_documentation(
            framework: ctx.framework, klass: ctx.klass, name: ctx.prefix
          )
        when :module
          @cache.lookup_documentation(framework: ctx.framework, name: ctx.prefix)
        when :apple_root
          if @cache.respond_to?(:lookup_framework_documentation)
            @cache.lookup_framework_documentation(name: ctx.prefix)
          end
        end
      end
    end
  end
end
