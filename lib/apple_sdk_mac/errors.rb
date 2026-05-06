# frozen_string_literal: true

module Apple
  # Phase 7 / v1.0 — public exception hierarchy. All Apple framework dispatch
  # paths surface failures through these classes; raw swiftc / clang errors
  # are wrapped (CompileError) rather than escaping to user rescue blocks.
  class Error < StandardError; end

  # Raised when Apple.discover(...) cannot resolve a symbol or shape:
  # - keyword combination not recognized (e.g. neither `symbol:` nor
  #   `selector:` nor `swift_func:` etc. supplied)
  # - symbol absent from KnowledgeCache (after LLM-fallback exhaust)
  # - generic `type_args:` resolution failure
  class DiscoveryError < Error; end

  # Raised when the Glue Compiler pipeline (TemplateGenerator → LLMGenerator
  # → ValidationGates → SwiftcInvoker) fails to produce a working dylib.
  # Carries the failing stage in the message; raw swiftc stderr is captured
  # in `Apple.diagnostics` for issue reproduction without leaking tooling
  # internals to user rescue blocks.
  class CompileError < Error; end

  # Raised when the Apple framework itself signals a runtime failure:
  # OSStatus != 0, NSError thrown across the bridge, kIOReturn* failures.
  class CallError < Error; end
end

module AppleSDKMac
  # Bridge aliases — historical AppleSDKMac::Error is preserved so existing
  # `rescue AppleSDKMac::Error => e` blocks keep working under v1.0. New code
  # should rescue Apple::Error or one of its subclasses directly. The aliases
  # use `unless defined?` so legacy modules that already declared their own
  # AppleSDKMac::Error don't trip a constant-redefinition warning.
  Error          = ::Apple::Error          unless defined?(Error)
  DiscoveryError = ::Apple::DiscoveryError unless defined?(DiscoveryError)
  CompileError   = ::Apple::CompileError   unless defined?(CompileError)
  CallError      = ::Apple::CallError      unless defined?(CallError)
end
