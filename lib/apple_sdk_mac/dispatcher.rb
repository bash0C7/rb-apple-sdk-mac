# frozen_string_literal: true

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
      raise Error, "unknown symbol #{framework}::#{symbol}" unless sym_meta

      # cache.lookup keys rows by canonical_name (sym_meta[:name]), not the
      # user-facing symbol arg which may arrive as an alias or single-segment shorthand.
      canonical = sym_meta[:name]
      cache_hit = @cache.lookup(framework: framework, symbol: canonical)
      if cache_hit.nil?
        # Transparent auto-compile: trigger compile inline so callers don't need
        # an upfront `Apple.discover` for symbols the Knowledge Base already knows.
        # Apple.discover stays available for shapes that need explicit kwargs.
        @compiler.compile(framework: framework, symbol: sym_meta)
        cache_hit = @cache.lookup(framework: framework, symbol: canonical)
        raise Error, "compile failed for #{framework}::#{canonical}" if cache_hit.nil?
      end

      fn_ptr = @loader.load(
        dylib_path: cache_hit[:dylib_path],
        exported_symbol: cache_hit[:exported_symbol]
      )
      @loader.invoke(fn_ptr, args)
    end
  end
end
