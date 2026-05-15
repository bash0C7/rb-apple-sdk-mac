# frozen_string_literal: true
require_relative "telemetry"

module AppleSDKMac
  class Dispatcher
    def initialize(knowledge_cache:, glue_cache:, loader:, compiler:)
      @knowledge = knowledge_cache
      @cache = glue_cache
      @loader = loader
      @compiler = compiler
    end

    def dispatch(framework:, symbol:, args: [])
      sym_meta = @knowledge.lookup_symbol(framework: framework, symbol: symbol)
      unless sym_meta
        Telemetry.append_event(
          stage: "symbol_missing",
          framework: framework.to_s,
          symbol: symbol.to_s,
          detail: "no entry in Knowledge Base"
        )
        @cache.record_attempt(
          framework: framework.to_s,
          symbol: symbol.to_s,
          generator: "knowledge_lookup",
          error_stage: "symbol_missing",
          error_detail: "no entry in Knowledge Base"
        )
        raise SymbolMissingError, "unknown symbol #{framework}::#{symbol}"
      end

      # cache.lookup keys rows by canonical_name (sym_meta[:name]), not the
      # user-facing symbol arg which may arrive as an alias or single-segment shorthand.
      canonical = sym_meta[:name]
      cache_hit = @cache.lookup(framework: framework, symbol: canonical)
      if cache_hit.nil?
        # Transparent auto-compile: trigger compile inline so callers don't need
        # an upfront `Apple.discover` for symbols the Knowledge Base already knows.
        # Apple.discover stays available for shapes that need explicit kwargs.
        begin
          @compiler.compile(framework: framework, symbol: sym_meta)
        rescue UnsupportedPatternError => e
          detail = e.respond_to?(:pattern) ? e.pattern.to_s : "unknown"
          Telemetry.append_event(
            stage: "unsupported_pattern",
            framework: framework.to_s,
            symbol: symbol.to_s,
            detail: detail
          )
          @cache.record_attempt(
            framework: framework.to_s,
            symbol: symbol.to_s,
            generator: "template",
            error_stage: "unsupported_pattern",
            error_detail: detail
          )
          raise
        end
        cache_hit = @cache.lookup(framework: framework, symbol: canonical)
        if cache_hit.nil?
          Telemetry.append_event(
            stage: "compile_failed",
            framework: framework.to_s,
            symbol: symbol.to_s,
            detail: "compile produced no cache row"
          )
          @cache.record_attempt(
            framework: framework.to_s,
            symbol: symbol.to_s,
            generator: "template",
            error_stage: "compile_failed",
            error_detail: "compile produced no cache row"
          )
          raise GlueCompileError, "compile failed for #{framework}::#{canonical}"
        end
      end

      fn_ptr = @loader.load(
        dylib_path: cache_hit[:dylib_path],
        exported_symbol: cache_hit[:exported_symbol]
      )
      @loader.invoke(fn_ptr, args)
    end
  end
end
