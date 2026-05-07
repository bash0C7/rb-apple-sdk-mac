# frozen_string_literal: true
require "apple_sdk_mac/irb"

module AppleSDKMac
  module IRB
    # Wraps a translation provider (designed for rb-translation-mac's
    # `TranslationMac.translate(text, from:, to:)` Result API) so the
    # DocResolver doc_transform can localize Apple SDK doc on the fly.
    # Caches per-input, degrades silently to the original text on any
    # failure (popup hover must never crash IRB).
    class Translator
      DEFAULT_SOURCE_LANG = "en-US"

      # LANG env (e.g. "ja_JP.UTF-8") → BCP-47 ("ja-JP"). Returns nil
      # for English locales (no translation needed) and for C / POSIX /
      # blank values, so callers can branch on truthiness alone.
      def self.detect_target_lang(env_lang)
        return nil if env_lang.nil?
        s = env_lang.to_s
        return nil if s.empty?
        return nil if %w[C POSIX].include?(s.upcase)
        base = s.split(".").first.to_s
        bcp47 = base.tr("_", "-")
        return nil if bcp47.empty?
        return nil if bcp47.downcase.start_with?("en-", "en") && (bcp47.size == 2 || bcp47.size > 2 && bcp47[2] == "-")
        bcp47
      end

      def initialize(target_lang:, translate_proc:, source_lang: DEFAULT_SOURCE_LANG)
        @target_lang = target_lang
        @source_lang = source_lang
        @translate_proc = translate_proc
        @cache = {}
        @mutex = Mutex.new
      end

      def active?
        !@target_lang.nil? && !@target_lang.empty?
      end

      def translate(text)
        return text if text.nil? || text.empty?
        return text unless active?
        cached = @mutex.synchronize { @cache[text] }
        return cached if cached
        translated = invoke_provider(text) || text
        @mutex.synchronize { @cache[text] = translated }
        translated
      end

      private

      def invoke_provider(text)
        result =
          begin
            @translate_proc.call(text, from: @source_lang, to: @target_lang)
          rescue => e
            warn "[apple-sdk-mac irb translator] #{e.class}: #{e.message}" if ENV["APPLE_IRB_DEBUG"]
            return nil
          end
        extract_text(result)
      end

      def extract_text(result)
        return result if result.is_a?(String) && !result.empty?
        return nil unless result.respond_to?(:success)
        return nil unless result.success
        return nil unless result.respond_to?(:text)
        result.text
      end
    end
  end
end
