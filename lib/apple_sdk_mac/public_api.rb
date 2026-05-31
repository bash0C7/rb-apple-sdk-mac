# frozen_string_literal: true
require "json"
require_relative "config"
require_relative "cache_dir"
require_relative "knowledge_cache"
require_relative "compiled_glue_cache"
require_relative "glue_loader"
require_relative "glue_compiler"
require_relative "glue_store"
require_relative "dispatcher"
require_relative "namespace_builder"
require_relative "opaque_ref"
require_relative "selector_bridge"
require_relative "discovery_shape"

module AppleSDKMac
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

    # Polymorphic single entry. Seven keyword shapes:
    #   symbol:           — C function (the README canonical form)
    #   selector:         — ObjC instance method (requires klass:)
    #   class_method:     — ObjC class method (requires klass:)
    #   swift_func:       — Swift function (top-level or static)
    #   swift_initializer:— Swift initializer (requires klass:)
    #   swift_property:   — Swift property (requires klass:)
    #   type_args:        — Swift generic resolution (combined with swift_func:)
    #
    # Synthesizes a symbol record with the proper kind, registers it into
    # the Knowledge Base transient lookup tier, then runs the compile
    # pipeline. C-symbol path uses the stored record when available so the
    # README canonical snippet's behavior matches the bootstrap path.
    def discover(framework:, **opts)
      sym_meta = DiscoveryShape.synthesize_symbol_record(framework: framework, **opts)
      canonical = sym_meta[:name]

      # For C symbols where the DB has the record, use the DB version —
      # it carries parameters_json + abi + signature that the synthesized
      # record can't guess. Synthesized record is the fallback only.
      if opts.key?(:symbol)
        db_meta = knowledge_cache.lookup_symbol(
          framework: framework.to_s, symbol: canonical
        )
        sym_meta = db_meta if db_meta
        # Knowledge Base 分類迂回 `params:` / `return_kind:` override。
        # User が明示的に渡した kind 配列 / return_kind で parameters_json と
        # signature を上書きする (CFStringRef を string とした、 buffer を
        # is_out_param=true とした、 Boolean を unrecognised return とした等の
        # 分類を回避)。
        if opts[:params] || opts[:return_kind]
          sym_meta = DiscoveryShape.override_c_symbol_params(
            sym_meta, params: opts[:params], return_kind: opts[:return_kind]
          )
        end
      else
        # Non-C shapes: register synthesized record into transient tier so
        # downstream lookups (Dispatcher, NamespaceBuilder) see it. Key MUST
        # be sym_meta[:name] (canonical).
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

    # Apple.discover の install path を install_one 経由に。
    # build! 全走査の毎回コストが消え、 transient synth record (DB に未収載の
    # objc/swift kinds) も install できる。
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
