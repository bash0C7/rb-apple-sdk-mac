# frozen_string_literal: true
require "json"
require_relative "config"
require_relative "cache_dir"
require_relative "knowledge_cache"
require_relative "compiled_glue_cache"
require_relative "glue_loader"
require_relative "glue_compiler"
require_relative "glue_store"
require_relative "round_trip/production_runner"
require_relative "dispatcher"
require_relative "namespace_builder"
require_relative "opaque_ref"
require_relative "selector_bridge"
require_relative "discovery_shape"

module AppleSDKMac
  RUNTIME_BUILD_DIR = File.expand_path("../../ext/apple_sdk_mac_runtime/.build/release", __dir__)

  @config = nil
  @knowledge_cache = nil
  @glue_cache = nil
  @loader = nil
  @compiler = nil
  @dispatcher = nil

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
      @glue_cache ||= CompiledGlueCache.open(AppleSDKMac.cache_dir, sdk_version: AppleSDKKnowledge::SDK.version)
    end

    def loader
      @loader ||= GlueLoader.new
    end

    def compiler
      @compiler ||= GlueCompiler.new(
        cache: glue_cache,
        runtime_dylib_path: runtime_dylib_path,
        runtime_modules_paths: runtime_modules_paths,
        knowledge_cache: knowledge_cache,
        glue_store: GlueStore.new(
          project_dir: AppleSDKMac.cache_dir,
          sdk_version: AppleSDKKnowledge::SDK.version
        ),
        round_trip_runner: RoundTrip::ProductionRunner.new(
          sdk_path: AppleSDKKnowledge::SDK.path
        )
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

    def discover(framework:, **opts)
      sym_meta = DiscoveryShape.synthesize_symbol_record(framework: framework, **opts)
      canonical = sym_meta[:name]

      if opts.key?(:symbol)
        db_meta = knowledge_cache.lookup_symbol(
          framework: framework.to_s, symbol: canonical
        )
        sym_meta = db_meta if db_meta
        if opts[:params] || opts[:return_kind]
          sym_meta = DiscoveryShape.override_c_symbol_params(
            sym_meta, params: opts[:params], return_kind: opts[:return_kind]
          )
        end
      else
        knowledge_cache.register_transient(
          framework: framework.to_s, symbol: canonical, record: sym_meta
        )
      end

      result = compiler.compile(framework: framework.to_s, symbol: sym_meta)
      unless result.success?
        raise AppleSDKMac::CompileError,
              "discover failed at #{result.error_stage}: #{result.error_detail}"
      end
      install_into_box(framework, canonical, sym_meta)
      true
    end

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

    private

    def runtime_dylib_path
      File.join(RUNTIME_BUILD_DIR, "libAppleSDKMacRuntime.dylib")
    end

    def runtime_modules_paths
      [RUNTIME_BUILD_DIR]
    end

    def install_into_box(framework, _canonical_name, sym_meta)
      builder = NamespaceBuilder.new(
        knowledge_cache: knowledge_cache, target: ::Apple,
        dispatcher: ->(framework:, symbol:, args:) {
          dispatcher.dispatch(framework: framework, symbol: symbol, args: args)
        }
      )
      builder.install_one(framework.to_s, sym_meta)
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
