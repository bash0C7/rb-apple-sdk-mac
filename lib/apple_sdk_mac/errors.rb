# frozen_string_literal: true

module AppleSDKMac
  KNOWLEDGE_BASE_SCHEMA = 9

  class Error < StandardError; end

  class DiscoveryError < Error; end

  class CompileError < Error; end

  class FrameworkMissingError < Error; end

  class SymbolMissingError < Error; end

  class UnsupportedPatternError < Error
    attr_reader :pattern, :framework, :symbol, :hint

    def initialize(pattern:, framework:, symbol:, hint: nil)
      @pattern = pattern
      @framework = framework
      @symbol = symbol
      @hint = hint
      super(format_message)
    end

    private

    def format_message
      require_relative "version" unless defined?(AppleSdkMac::VERSION)
      sdk_version = ENV["APPLE_SDK_MAC_SDK_VERSION"] || "(macOS SDK detection requires KnowledgeCache.sdk_version)"
      gem_version = defined?(AppleSdkMac::VERSION) ? AppleSdkMac::VERSION : "unknown"
      workaround = @hint ||
        "See https://github.com/bash0C7/rb-apple-sdk-mac for guidance on writing a Swift / C wrapper."
      <<~MSG.chomp
        AppleSDKMac::UnsupportedPatternError:
          Symbol '#{@framework}::#{@symbol}' uses pattern that cannot be bridged.

          Pattern: #{@pattern}
          Framework: #{@framework}
          Symbol: #{@symbol}
          macOS SDK: #{sdk_version}
          gem version: #{gem_version}
          Knowledge Base schema: #{KNOWLEDGE_BASE_SCHEMA}

          Workaround:
            #{workaround}

          Report at https://github.com/bash0C7/rb-apple-sdk-mac/issues if you
          believe this pattern should be supported.
      MSG
    end
  end

  GlueCompileError = CompileError

  class ObjcError < Error; end

  class SwiftError < Error; end

  class OutOfCoverageError < Error
    RetryUnavailableError = Class.new(Error)

    attr_reader :framework, :symbol, :pattern, :reason, :last_failure_detail

    def initialize(framework:, symbol:, pattern:, reason:,
                   retry_proc: nil, last_failure_detail: nil)
      @framework = framework
      @symbol = symbol
      @pattern = pattern
      @reason = reason
      @retry_proc = retry_proc
      @last_failure_detail = last_failure_detail
      super("#{framework}::#{symbol} is outside rule-based coverage " \
            "(pattern=#{pattern}): #{reason}")
    end

    def retry_with(context:)
      unless @retry_proc
        raise RetryUnavailableError,
          "retry_with is only available when an inference backend is configured. " \
          "Initialize Apple SDK with an inference backend to enable this."
      end
      @retry_proc.call(context: context)
    end
  end
end
