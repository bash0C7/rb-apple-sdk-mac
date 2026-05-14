# frozen_string_literal: true

module AppleSDKMac
  # Public exception hierarchy. All Apple framework dispatch paths surface
  # failures through these classes; raw swiftc / clang errors are wrapped
  # (CompileError) rather than escaping to user rescue blocks.
  #
  # Implementation note: the implementations are defined under AppleSDKMac
  # (not Apple) because Apple is a Ruby::Box that gets reset late in the
  # gem load sequence — class objects defined under Apple before the Box
  # bootstrap would lose their Apple::* lookup path. AppleSDKMac is a plain
  # module that survives Box bootstrap, so it owns the canonical hierarchy.
  # Apple::Error etc. are aliased into the Apple Box after bootstrap so
  # `rescue Apple::Error` keeps working.

  # Knowledge Base SQLite schema version (Phase 2 で導入)。
  # bump 時は importer の rebuild と cache invalidation を伴う。
  # Telemetry や error message が独立して参照するため module top-level に置く。
  KNOWLEDGE_BASE_SCHEMA = 9

  class Error < StandardError; end

  # Raised when Apple.discover(...) cannot resolve a symbol or shape:
  # - keyword combination not recognized
  # - symbol absent from Knowledge Base (after LLM-fallback exhaust)
  # - generic `type_args:` resolution failure
  class DiscoveryError < Error; end

  # Raised when the Glue Compiler pipeline (TemplateGenerator → ValidationGates
  # → SwiftcInvoker) fails to produce a working dylib.
  # Carries the failing stage in the message; raw swiftc stderr is captured
  # in `Apple.diagnostics` for issue reproduction.
  class CompileError < Error; end

  # Raised when a requested framework is not present in the Knowledge Base.
  class FrameworkMissingError < Error; end

  # Raised when a requested symbol is absent from the Knowledge Base.
  class SymbolMissingError < Error; end

  # Raised when the requested API pattern (e.g. swift_macro, async throws)
  # is not yet supported by the glue generator pipeline. Carries structured
  # metadata (pattern / framework / symbol) for diagnostic surfacing.
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

  # Alias: GlueCompileError is the same class as CompileError.
  # Callers in the glue pipeline may rescue either name.
  GlueCompileError = CompileError

  # Raised when an Objective-C runtime error crosses the bridge
  # (NSError, OSStatus, kIOReturn*, etc.).
  class ObjcError < Error; end

  # Raised when a Swift-side error crosses the bridge
  # (thrown Swift Error values, URLError, etc.).
  class SwiftError < Error; end
end
