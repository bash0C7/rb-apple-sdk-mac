# frozen_string_literal: true

module AppleSDKMac
  # Phase 7 / v1.0 — public exception hierarchy. All Apple framework dispatch
  # paths surface failures through these classes; raw swiftc / clang errors
  # are wrapped (CompileError) rather than escaping to user rescue blocks.
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
  # - symbol absent from KnowledgeCache (after LLM-fallback exhaust)
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
end
