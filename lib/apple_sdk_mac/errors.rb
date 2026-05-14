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
  class Error < StandardError; end

  # Raised when Apple.discover(...) cannot resolve a symbol or shape:
  # - keyword combination not recognized
  # - symbol absent from Knowledge Base (after LLM-fallback exhaust)
  # - generic `type_args:` resolution failure
  class DiscoveryError < Error; end

  # Raised when the Glue Compiler pipeline (TemplateGenerator → LLMGenerator
  # → ValidationGates → SwiftcInvoker) fails to produce a working dylib.
  # Carries the failing stage in the message; raw swiftc stderr is captured
  # in `Apple.diagnostics` for issue reproduction.
  class CompileError < Error; end

  # Raised when the Apple framework itself signals a runtime failure:
  # OSStatus != 0, NSError thrown across the bridge, kIOReturn* failures.
  class CallError < Error; end

  # Raised when a requested framework is not present in the Knowledge Base.
  class FrameworkMissingError < Error; end

  # Raised when a requested symbol is absent from the Knowledge Base.
  class SymbolMissingError < Error; end

  # Raised when the requested API pattern (e.g. swift_macro, async throws)
  # is not yet supported by the glue generator pipeline. Carries structured
  # metadata (pattern / framework / symbol) for diagnostic surfacing.
  class UnsupportedPatternError < Error
    attr_reader :pattern, :framework, :symbol

    def initialize(pattern:, framework:, symbol:, hint: nil)
      @pattern = pattern
      @framework = framework
      @symbol = symbol
      @hint = hint
      super(format_message)
    end

    private

    def format_message
      parts = ["pattern=#{@pattern}", "framework=#{@framework}", "symbol=#{@symbol}"]
      parts << "hint=#{@hint}" if @hint
      "AppleSDKMac::UnsupportedPatternError #{parts.join(' ')}"
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
