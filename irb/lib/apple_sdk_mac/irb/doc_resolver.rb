# frozen_string_literal: true
require "apple_sdk_mac/irb"

module AppleSDKMac
  module IRB
    # Resolves a Reline-popup candidate string into Apple SDK
    # documentation text via KnowledgeCache. Returns nil for non-Apple
    # input, framework-level matches (no symbol), and symbols whose KB
    # row has no doc-comment populated.
    class DocResolver
      def initialize(knowledge_cache:)
        @cache = knowledge_cache
      end

      def resolve(matched)
        ctx = AppleSDKMac::IRB::Context.parse(matched)
        return nil if ctx.nil?
        case ctx.receiver_kind
        when :class
          @cache.lookup_documentation(
            framework: ctx.framework, klass: ctx.klass, name: ctx.prefix
          )
        when :module
          # `Apple::Foundation::URL` — the type itself is a top-level
          # symbol within its framework; lookup with no klass.
          @cache.lookup_documentation(framework: ctx.framework, name: ctx.prefix)
        else
          # :apple_root → framework name only, no symbol to look up.
          nil
        end
      end
    end
  end
end
