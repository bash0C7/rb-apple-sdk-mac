# frozen_string_literal: true
require "apple_sdk_mac/irb"
require "apple_sdk_mac/irb/doc_resolver"

module AppleSDKMac
  module IRB
    # Generates documentation on the fly via an injected llm_proc when
    # the KB has no doc populated. Used as the secondary in DocDialog
    # (after the KB-driven DocResolver returns nil) so:
    # - Swift-overlay Apple symbols (Foundation::URL.appendingPathComponent)
    #   that the swiftinterface stripped of `///` get a synthesized doc
    # - Ruby stdlib expressions (String.to_s) that fall outside the KB
    #   scope still surface a useful description
    class LLMResolver
      def initialize(llm_proc:, knowledge_cache: nil)
        @llm_proc = llm_proc
        @cache_kb = knowledge_cache
        @result_cache = {}
        @mutex = Mutex.new
      end

      def resolve(matched)
        return nil if matched.nil?
        key = matched.to_s
        return nil if key.strip.empty?
        @mutex.synchronize do
          return @result_cache[key] if @result_cache.key?(key)
        end
        ctx = AppleSDKMac::IRB::Context.parse(key)
        prompt = build_prompt(ctx, key)
        raw = prompt && invoke_llm(prompt)
        if raw.nil? || raw.to_s.strip.empty?
          memoize(key, nil)
          return nil
        end
        memoize(key, raw)
      end

      private

      def memoize(key, value)
        @mutex.synchronize { @result_cache[key] = value }
        value
      end

      def build_prompt(ctx, matched)
        return build_ruby_prompt(matched) if ctx.nil?
        build_apple_prompt(ctx)
      end

      def build_apple_prompt(ctx)
        kind_label = case ctx.receiver_kind
                     when :class then "method or property"
                     when :module then "type"
                     when :apple_root then "framework"
                     else "API element"
                     end
        parts = ["Write 1-3 short sentences of API-style documentation for the following Apple framework #{kind_label}. Plain prose, no code blocks, no preamble, do not repeat the identifier."]
        parts << "Framework: #{ctx.framework}" if ctx.framework
        parts << "Type: #{ctx.klass}" if ctx.klass
        parts << "Name: #{ctx.prefix}" if ctx.prefix && !ctx.prefix.empty?
        sig = lookup_signature(ctx)
        parts << "Signature: #{sig}" if sig
        parts.join("\n")
      end

      def build_ruby_prompt(matched)
        "Write 1-3 short sentences of Ruby API documentation for `#{matched}` (a Ruby core or standard library method or class). Plain prose, no code blocks, no preamble, do not repeat the identifier."
      end

      def lookup_signature(ctx)
        return nil unless @cache_kb && @cache_kb.respond_to?(:lookup_signature)
        @cache_kb.lookup_signature(
          framework: ctx.framework, klass: ctx.klass, name: ctx.prefix
        )
      rescue StandardError => e
        warn "llm_resolver: lookup_signature failed: #{e.class}: #{e.message}" if ENV["APPLE_IRB_DEBUG"]
        nil
      end

      def invoke_llm(prompt)
        @llm_proc.call(prompt)
      rescue => e
        warn "[apple-sdk-mac irb llm] #{e.class}: #{e.message}" if ENV["APPLE_IRB_DEBUG"]
        nil
      end
    end
  end
end
