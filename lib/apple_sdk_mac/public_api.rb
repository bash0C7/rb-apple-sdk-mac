# frozen_string_literal: true
require "json"
require_relative "config"
require_relative "cache_dir"
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
        # T50 — KB の分類間違い (CFStringRef を string とした、buffer を
        # is_out_param=true にした、Boolean を unrecognised return にした、
        # 等) を回避する `params:` / `return_kind:` override。
        # User が明示的に渡した kind 配列 / return_kind で parameters_json と
        # signature を上書きする。
        if opts[:params] || opts[:return_kind]
          sym_meta = _override_c_symbol_params(sym_meta, opts)
        end
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
          params: opts[:params], return_kind: opts[:return_kind],
          return_klass: opts[:return_klass]
        )
      when opts.key?(:selector)
        base.merge(
          name: "#{opts[:klass]}.#{_canonical_method_name(opts[:selector])}",
          kind: "objc_method_instance",
          objc_class: opts[:klass].to_s, selector: opts[:selector].to_s,
          params: opts[:params], return_kind: opts[:return_kind],
          return_klass: opts[:return_klass]
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
          return_kind: opts[:return_kind],
          instance: opts[:instance] == true
        )
      when opts.key?(:swift_func)
        # T47 — swift_func は klass: で `Klass.func` static method 化、または
        # async: true で `try await ... + DispatchSemaphore` skeleton 化。
        canonical_name = opts[:klass] ? "#{opts[:klass]}.#{opts[:swift_func]}" : opts[:swift_func].to_s
        rec = base.merge(
          name: canonical_name, kind: "swift_func",
          swift_func: opts[:swift_func].to_s,
          params: opts[:params], return_kind: opts[:return_kind]
        )
        rec[:swift_class] = opts[:klass].to_s if opts[:klass]
        rec[:type_args] = opts[:type_args] if opts.key?(:type_args)
        rec[:async] = opts[:async] if opts.key?(:async)
        rec
      else
        raise AppleSDKMac::DiscoveryError,
          "Apple.discover requires one of: symbol, selector, class_method, swift_func, swift_initializer, swift_property"
      end
    end

    # T50 — KB 分類オーバーライド。Apple.discover の :symbol path で `:params`
    # / `:return_kind` が明示された場合、KB の parameters_json と signature を
    # 書き換える。kind sym → `{name, type, kind, is_out_param, nullability}`
    # 形式の Hash 配列に変換、parameters_json に詰め直す。
    #
    # KB classifier が CFStringRef を `string` (clang AST 上は char* 同等扱い)
    # として、buffer (mutable char*) を `is_out_param=true` の string out として
    # mark するなど、CF round-trip 用の出力に対して正しくない classification を
    # する場合の救済。
    KIND_SYM_TO_TYPE = {
      string:           "const char *",
      int:              "Int64",
      bool:             "Bool",
      float:            "Double",
      opaque_ref:       "OpaquePointer",
      cftype_ref:       "CFTypeRef",
      void_ptr_nilable: "void *",
      block_persistent: "block_persistent_thunk"
    }.freeze

    def _override_c_symbol_params(sym_meta, opts)
      if opts[:params]
        new_params = opts[:params].each_with_index.map do |entry, i|
          if entry.is_a?(Hash)
            kind_sym = (entry[:kind] || entry["kind"]).to_sym
            type     = entry[:type] || entry["type"] || KIND_SYM_TO_TYPE.fetch(kind_sym, "void *")
            # T54 — Hash 形で nilable: false を指定すると Marshaller 側で
            # force-unwrap (`arg!`)。 Swift bridge で T (non-Optional) 必須の
            # API (CGImageSourceCreateWithURL の CFURL 等) で使う。
            nilable = entry.key?(:nilable) ? entry[:nilable] : (entry.key?("nilable") ? entry["nilable"] : nil)
          else
            kind_sym = entry.to_sym
            type     = KIND_SYM_TO_TYPE.fetch(kind_sym, "void *")
            nilable  = nil
          end
          rec = {
            name: "arg#{i}",
            type: type,
            kind: kind_sym.to_s,
            is_out_param: false,
            nullability: "unspecified"
          }
          rec[:nilable] = nilable unless nilable.nil?
          rec
        end
        sym_meta = sym_meta.merge(parameters_json: JSON.dump(new_params))
      end
      if opts[:return_kind]
        # T50 — :return_kind を sym_meta に直接埋め込む。template_generator の
        # effective_return_kind が signature regex より先にこれを参照する。
        sym_meta = sym_meta.merge(return_kind: opts[:return_kind])
      end
      sym_meta
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
      m = s.match(/\A[A-Z]+/)
      return s[0].downcase + (s[1..] || "") unless m
      run = m[0]
      return s.downcase if run.length == s.length
      return s[0].downcase + s[1..] if run.length == 1
      next_char = s[run.length]
      if next_char =~ /[a-z]/
        run[0..-2].downcase + run[-1] + s[run.length..]
      else
        # acronym followed by digit/non-letter: lowercase the entire run.
        run.downcase + s[run.length..]
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
