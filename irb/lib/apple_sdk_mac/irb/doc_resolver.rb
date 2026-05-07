# frozen_string_literal: true
require "apple_sdk_mac/irb"

module AppleSDKMac
  module IRB
    # Resolves a Reline-popup candidate string into Apple SDK
    # documentation text via KnowledgeCache. Returns nil for non-Apple
    # input, framework-level matches (no symbol), and symbols whose KB
    # row has no doc-comment populated.
    class DocResolver
      IDENTITY_TRANSFORM = ->(doc, _ctx) { doc }

      def initialize(knowledge_cache:, doc_transform: IDENTITY_TRANSFORM)
        @cache = knowledge_cache
        @doc_transform = doc_transform
      end

      def resolve(matched)
        ctx = AppleSDKMac::IRB::Context.parse(matched)
        return nil if ctx.nil?
        raw = lookup_raw(ctx)
        return nil if raw.nil?
        @doc_transform.call(raw, ctx)
      end

      private

      def lookup_raw(ctx)
        case ctx.receiver_kind
        when :class
          @cache.lookup_documentation(
            framework: ctx.framework, klass: ctx.klass, name: ctx.prefix
          )
        when :module
          # `Apple::Foundation::URL` — the type itself is a top-level
          # symbol within its framework; lookup with no klass.
          @cache.lookup_documentation(framework: ctx.framework, name: ctx.prefix)
        when :apple_root
          # `Apple::ARKit` — popup is hovering a framework name.
          # Synthesize a description from frameworks + symbol-count.
          if @cache.respond_to?(:lookup_framework_documentation)
            @cache.lookup_framework_documentation(name: ctx.prefix)
          end
        end
      end
    end
  end
end
