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
        safe_record_attempt(
          framework: framework.to_s,
          symbol: symbol.to_s,
          generator: "knowledge_lookup",
          error_stage: "symbol_missing",
          error_detail: "no entry in Knowledge Base"
        )
        raise SymbolMissingError, "unknown symbol #{framework}::#{symbol}"
      end

      canonical = sym_meta[:name]
      cache_hit = @cache.lookup(framework: framework, symbol: canonical)
      if cache_hit.nil?
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
          safe_record_attempt(
            framework: framework.to_s,
            symbol: symbol.to_s,
            generator: "template",
            error_stage: "unsupported_pattern",
            error_detail: detail
          )
          raise
        rescue OutOfCoverageError => e
          Telemetry.append_event(
            stage: "out_of_coverage",
            framework: framework.to_s,
            symbol: symbol.to_s,
            detail: e.reason
          )
          safe_record_attempt(
            framework: framework.to_s,
            symbol: symbol.to_s,
            generator: "coverage_boundary",
            error_stage: "out_of_coverage",
            error_detail: e.reason
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
          safe_record_attempt(
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

    private

    def safe_record_attempt(**kwargs)
      @cache.record_attempt(**kwargs)
    rescue StandardError => record_err
      Telemetry.append_event(
        stage: "record_attempt_failed",
        framework: kwargs[:framework],
        symbol: kwargs[:symbol],
        detail: "#{record_err.class}: #{record_err.message}"
      )
    end
  end
end
