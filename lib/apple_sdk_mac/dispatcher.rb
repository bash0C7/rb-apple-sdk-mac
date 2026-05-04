# frozen_string_literal: true

module AppleSDKMac
  class Error < StandardError; end
  class CompileError < Error; end

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

      cache_hit = @cache.lookup(framework: framework, symbol: symbol)
      if cache_hit.nil?
        raise Error, "no glue cached for #{framework}::#{symbol}; call Apple.discover first"
      end

      fn_ptr = @loader.load(
        dylib_path: cache_hit[:dylib_path],
        exported_symbol: cache_hit[:exported_symbol]
      )
      @loader.invoke(fn_ptr, args)
    end
  end
end
