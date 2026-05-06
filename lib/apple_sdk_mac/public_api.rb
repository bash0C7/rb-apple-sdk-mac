# frozen_string_literal: true
require_relative "config"
require_relative "knowledge_cache"
require_relative "compiled_glue_cache"
require_relative "glue_loader"
require_relative "glue_compiler"
require_relative "glue_compiler/llm_generator"
require_relative "dispatcher"
require_relative "namespace_builder"
require_relative "opaque_ref"
require_relative "did_you_mean"

module AppleSDKMac
  @config = nil
  @knowledge_cache = nil
  @glue_cache = nil
  @loader = nil
  @compiler = nil
  @dispatcher = nil
  @box_modules = {}

  class << self
    def configure
      yield(config) if block_given?
      config
    end

    def config
      @config ||= Config.new
    end

    def knowledge_cache
      @knowledge_cache ||= KnowledgeCache.open
    end

    def glue_cache
      @glue_cache ||= CompiledGlueCache.open(config.cache_dir, sdk_version: AppleSDKKnowledge::SDK.version)
    end

    def loader
      @loader ||= GlueLoader.new
    end

    def compiler
      @compiler ||= GlueCompiler.new(
        cache: glue_cache,
        runtime_dylib_path: runtime_dylib_path,
        runtime_modules_paths: runtime_modules_paths,
        llm_generator: GlueCompiler::LLMGenerator.new
      )
    end

    def dispatcher
      @dispatcher ||= Dispatcher.new(
        knowledge_cache: knowledge_cache,
        glue_cache: glue_cache,
        loader: loader,
        compiler: compiler
      )
    end

    def discover(framework:, symbol:)
      sym_meta = knowledge_cache.lookup_symbol(framework: framework.to_s, symbol: symbol.to_s)
      raise Error, "symbol not in knowledge base: #{framework}::#{symbol}" unless sym_meta

      result = compiler.compile(framework: framework.to_s, symbol: sym_meta)
      unless result.success?
        raise CompileError,
              "discover failed at #{result.error_stage}: #{result.error_detail}"
      end
      install_into_box(framework, symbol, sym_meta)
      true
    end

    # Eagerly populate Apple::<Framework> modules and their type constants from
    # the knowledge base without compiling glue. Function methods are still
    # defined (proxied through the dispatcher) but no symbol is dlopen'd until
    # called. Idempotent.
    def bootstrap!
      builder = NamespaceBuilder.new(
        knowledge_cache: knowledge_cache, target: ::Apple,
        dispatcher: ->(framework:, symbol:, args:) {
          dispatcher.dispatch(framework: framework, symbol: symbol, args: args)
        }
      )
      builder.build!
      true
    end

    def event_loop
      ctx = EventLoopContext.new
      until ctx.stopped?
        AppleSDKMacRuntime.runloop_pump(0.01)
        AppleSDKMacRuntime.threading_poll(0.01)
        Fiber.scheduler&.yield
        yield(ctx) if block_given?
      end
    end

    def box_module?(mod)
      @box_modules.value?(mod)
    end

    def register_framework_module(name, mod)
      @box_modules[name] = mod
    end

    private

    def runtime_dylib_path
      # Linker expects MH_DYLIB. The Ruby C extension `.bundle` (MH_BUNDLE) is
      # loaded by Ruby via require but is not a valid linkage target. Prefer the
      # Swift package's libAppleSDKMacRuntime.dylib when present (development
      # checkout); fall back to nil so SwiftcInvoker omits the -Xlinker arg
      # entirely (glue uses @_silgen_name + -undefined dynamic_lookup, so the
      # runtime is not strictly required at link time for kinds that don't
      # reference AppleSDKMacRuntime Swift symbols).
      gem_root = File.expand_path("../../..", __FILE__)
      dylib = File.join(gem_root, "ext/apple_sdk_mac_runtime/.build/arm64-apple-macosx/release/libAppleSDKMacRuntime.dylib")
      File.exist?(dylib) ? dylib : nil
    end

    def runtime_modules_paths
      gem_root = File.expand_path("../../..", __FILE__)
      [File.join(gem_root, "ext/apple_sdk_mac_runtime/.build/arm64-apple-macosx/release/Modules")].select { |p| File.directory?(p) }
    end

    def install_into_box(framework, symbol, sym_meta)
      builder = NamespaceBuilder.new(
        knowledge_cache: knowledge_cache, target: ::Apple,
        dispatcher: ->(framework:, symbol:, args:) {
          dispatcher.dispatch(framework: framework, symbol: symbol, args: args)
        }
      )
      builder.build!
    end
  end

  class EventLoopContext
    attr_reader :start_time
    def initialize; @start_time = Time.now; @stopped = false; end
    def stop; @stopped = true; end
    def stopped?; @stopped; end
    def elapsed; Time.now - @start_time; end
  end
end
