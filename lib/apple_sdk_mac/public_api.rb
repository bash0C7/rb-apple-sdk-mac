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

    # Phase 7 T5 — polymorphic single entry. Seven keyword shapes:
    #   symbol:           — C function (the README canonical form)
    #   selector:         — ObjC instance method (requires klass:)
    #   class_method:     — ObjC class method (requires klass:)
    #   swift_func:       — Swift function (top-level or static)
    #   swift_initializer:— Swift initializer (requires klass:)
    #   swift_property:   — Swift property (requires klass:)
    #   type_args:        — Swift generic resolution (combined with swift_func:)
    #
    # The dispatch synthesizes a symbol record with the proper kind,
    # registers it into the KnowledgeCache transient lookup tier, then
    # runs the existing compile pipeline. C-symbol path keeps using the
    # KB-stored record when available so the README canonical snippet's
    # behavior is unchanged.
    def discover(framework:, **opts)
      sym_meta = _synthesize_symbol_record(framework: framework, **opts)
      canonical = sym_meta[:name]

      # For C symbols where the DB has the record, use the DB version —
      # it carries parameters_json + abi + signature that the synthesized
      # record can't guess. Synthesized record is the fallback only.
      if opts.key?(:symbol)
        db_meta = knowledge_cache.lookup_symbol(
          framework: framework.to_s, symbol: canonical
        )
        sym_meta = db_meta if db_meta
      else
        # Non-C shapes: register synthesized record into transient tier so
        # downstream lookups (Dispatcher, NamespaceBuilder) see it. Key MUST
        # be sym_meta[:name] (canonical) per spec §3.2 Name 体系.
        knowledge_cache.register_transient(
          framework: framework.to_s, symbol: canonical, record: sym_meta
        )
      end

      raise AppleSDKMac::DiscoveryError, "symbol not in knowledge base: #{framework}::#{canonical}" unless sym_meta

      result = compiler.compile(framework: framework.to_s, symbol: sym_meta)
      unless result.success?
        raise AppleSDKMac::CompileError,
              "discover failed at #{result.error_stage}: #{result.error_detail}"
      end
      install_into_box(framework, canonical, sym_meta)
      true
    end

    # Build a symbol record (Hash) for the requested shape without
    # touching the KB. Public for testability — Apple.discover wraps this
    # plus transient register + compile.
    def _synthesize_symbol_record(framework:, **opts)
      base = { id: -1, signature: nil, abi: nil, documentation: nil,
               parameters_json: "[]", requires_main_thread: false,
               content_hash: nil, fields_json: nil }
      case
      when opts.key?(:symbol)
        base.merge(name: opts[:symbol].to_s, kind: "function", abi: "c")
      when opts.key?(:class_method)
        base.merge(
          name: "#{opts[:klass]}.#{_canonical_method_name(opts[:class_method])}",
          kind: "objc_method_class",
          objc_class: opts[:klass].to_s, selector: opts[:class_method].to_s,
          params: opts[:params], return_kind: opts[:return_kind]
        )
      when opts.key?(:selector)
        base.merge(
          name: "#{opts[:klass]}.#{_canonical_method_name(opts[:selector])}",
          kind: "objc_method_instance",
          objc_class: opts[:klass].to_s, selector: opts[:selector].to_s,
          params: opts[:params], return_kind: opts[:return_kind]
        )
      when opts.key?(:swift_initializer)
        base.merge(
          name: "#{opts[:klass]}.#{opts[:swift_initializer]}",
          kind: "swift_init",
          swift_class: opts[:klass].to_s,
          swift_initializer: opts[:swift_initializer].to_s,
          params: opts[:params], return_kind: opts[:return_kind]
        )
      when opts.key?(:swift_property)
        base.merge(
          name: "#{opts[:klass]}.#{opts[:swift_property]}",
          kind: "swift_property",
          swift_class: opts[:klass].to_s,
          swift_property: opts[:swift_property].to_s,
          return_kind: opts[:return_kind]
        )
      when opts.key?(:swift_func)
        rec = base.merge(
          name: opts[:swift_func].to_s, kind: "swift_func",
          swift_func: opts[:swift_func].to_s,
          params: opts[:params], return_kind: opts[:return_kind]
        )
        rec[:type_args] = opts[:type_args] if opts.key?(:type_args)
        rec
      else
        raise AppleSDKMac::DiscoveryError,
          "Apple.discover requires one of: symbol, selector, class_method, swift_func, swift_initializer, swift_property"
      end
    end

    # T40 — selector → Swift-form method name converter (spec §3.4.1 +
    # Apple ObjC→Swift API bridging convention).
    # - single-segment (`stringWithUTF8String:`) → `stringWithUTF8String`
    # - multi-segment init (`initWithCGImage:options:`) → `init(cgImage:options:)`
    #   "With" prefix stripped、第1ラベルは lowerCamelCase 化（Apple bridging rule）
    # - multi-segment non-init (`requestWithURL:cachePolicy:`) →
    #   `requestWithURL(cachePolicy:)` 形式（rare、init 以外で必要時の fallback）
    def _canonical_method_name(selector)
      s = selector.to_s
      parts = s.split(":", -1).reject(&:empty?)
      return s if parts.empty?
      return parts[0] if parts.size == 1
      if parts[0].start_with?("init")
        # Strip "init" then optional "With" / "From" / "By" prefix, then
        # lowerCamelCase the remaining first label per Apple's bridging rule.
        head = parts[0].sub(/\Ainit/, "").sub(/\A(With|From|By|Using|For)/, "")
        head = _lower_first_camel(head)
        labels = head.empty? ? parts[1..] : ([head] + parts[1..])
        "init(" + labels.map { |l| "#{l}:" }.join + ")"
      else
        first = parts[0]
        rest = parts[1..]
        "#{first}(" + rest.map { |l| "#{l}:" }.join + ")"
      end
    end

    # Apple ObjC→Swift bridging の acronym handling。
    # `CGImage` → `cgImage`, `URL` → `url`, `HTTPHeader` → `httpHeader`,
    # `Image` → `image`. 先頭 uppercase 連続の acronym 部分のみ lowercase 化、
    # 後続単語の先頭大文字は維持。
    def _lower_first_camel(s)
      return "" if s.empty?
      upper = s.match(/\A[A-Z]+/)
      return s[0].downcase + (s[1..] || "") unless upper
      run = upper[0]
      if run.length == s.length
        s.downcase
      elsif run.length == 1
        s[0].downcase + s[1..]
      else
        # multi-letter acronym followed by uppercase-starting word: the last
        # uppercase of the run starts the next word.
        run[0..-2].downcase + run[-1] + s[run.length..]
      end
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

    # T41 — Apple.discover の install path を install_one 経由に。
    # build! 全走査の毎回コストが消え、transient synth record（DB に未収載
    # の objc/swift kinds）も install できるようになる（spec G2 fix）。
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
