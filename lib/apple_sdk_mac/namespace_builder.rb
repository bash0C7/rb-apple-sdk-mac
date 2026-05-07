# frozen_string_literal: true

module AppleSDKMac
  class NamespaceBuilder
    # T41 — KIND_TO_DEFINER 拡張 (spec §3.3)。
    # :method            — top-level on framework module（C function, Swift func）
    # :method_under_klass — singleton method on Apple::<FW>::<Klass> proxy class
    # :constant          — type proxy constant on framework module
    KIND_TO_DEFINER = {
      "function"             => :method,
      "global_constant"      => :method,
      "swift_func"           => :method,
      "objc_method_class"    => :method_under_klass,
      "objc_method_instance" => :method_under_klass,
      "swift_init"           => :method_under_klass,
      "swift_property"       => :method_under_klass,
      "class"                => :constant,
      "struct"               => :constant,
      "actor"                => :constant,
      "protocol"             => :constant,
      "enum_module"          => :constant
    }.freeze

    def initialize(knowledge_cache:, target:, dispatcher:)
      @knowledge = knowledge_cache
      @target = target
      @dispatcher = dispatcher
    end

    def build!
      @knowledge.list_frameworks.each do |fw|
        framework_module = define_framework_module(fw)
        next unless framework_module
        symbols = @knowledge.list_framework_symbols(framework: fw)
        symbols.each do |sym|
          install_symbol(framework_module, fw, sym)
        end
      end
    end

    # T41 — per-symbol install API. Apple.discover の transient synth record
    # を namespace に install する経路。build! と違って DB 全走査せず、
    # 渡された 1 record のみを install する（spec §3.3 G2 fix）。
    def install_one(framework_name, sym_record)
      fw_module = define_framework_module(framework_name.to_s)
      return nil unless fw_module
      install_symbol(fw_module, framework_name.to_s, sym_record)
      fw_module
    end

    private

    def define_framework_module(name)
      # Apple knowledge base contains private/legacy framework names like
      # `_ARKit_SwiftUI` (leading underscore) that aren't valid Ruby constants.
      # Skip them; the dispatcher addresses these by string name when needed.
      return nil unless name =~ /\A[A-Z]/
      if @target.const_defined?(name, false)
        @target.const_get(name)
      else
        m = Module.new
        @target.const_set(name, m)
        m
      end
    end

    def install_symbol(framework_module, framework_name, sym)
      mode = KIND_TO_DEFINER[sym[:kind]]
      return unless mode

      case mode
      when :method
        define_function_method(framework_module, framework_name, sym[:name])
      when :method_under_klass
        if sym[:kind] == "objc_method_instance" && !init_form_selector?(sym[:selector])
          # T52b — proxy instance method receiver path. selector が `init`
          # で始まる場合 (alloc.init 経路) は emit_objc_instance_method が
          # receiver を取らない form を生成するため、class singleton method
          # として install する旧 path を保持する。
          define_instance_method_under_klass(framework_module, framework_name, sym)
        elsif sym[:kind] == "swift_property" && sym[:instance] == true
          # T54u — swift_property instance: true は emit が receiver argv[0]
          # を取る instance property template を出すため、 namespace 側も
          # proxy instance method として install。
          define_instance_method_under_klass(framework_module, framework_name, sym)
        else
          define_method_under_klass(framework_module, framework_name, sym)
        end
      when :constant
        define_type_constant(framework_module, framework_name, sym[:name])
      end
    end

    def define_function_method(mod, framework, symbol_name)
      dispatcher = @dispatcher
      builder = self
      mod.singleton_class.send(:define_method, symbol_name) do |*args|
        # T54w — C function (`Apple::ImageIO.CGImageSourceCreateWithURL` 等) の
        # 引数列に Apple proxy instance (NSURL 等) が含まれる場合、 raw opaque
        # ref Integer に再帰 unwrap (T52h と同 path、 instance method 以外でも
        # 適用)。
        unwrapped = builder.send(:unwrap_proxy_args, args)
        dispatcher.call(framework: framework, symbol: symbol_name, args: unwrapped)
      end
    end

    # T41 — :method_under_klass install path. canonical_name "<Klass>.<method>"
    # を split し、Apple::<FW>::<Klass> proxy class を ensure → singleton method
    # を define、内部で dispatcher.call(symbol: canonical_name, args:) を呼ぶ。
    # T52b — return_kind が opaque_ref / cftype_ref の場合、dispatcher の raw
    # Integer 戻り値を proxy instance に auto-wrap して返す (chain 用)。
    def define_method_under_klass(mod, framework, sym)
      canonical = sym[:name].to_s
      klass_name, _, method_part = canonical.partition(".")
      return if klass_name.empty? || method_part.empty?
      return unless klass_name =~ /\A[A-Z]/

      proxy_class = ensure_proxy_class(mod, framework, klass_name)
      ruby_method = ruby_method_name_for(method_part)
      return if ruby_method.empty?

      dispatcher = @dispatcher
      wrap_proxy = opaque_ref_return?(sym)
      # T53j — return_klass: で wrap 先 class を override (受信 class と異なる
      # 戻り値型の場合)。 未指定なら従来通り receiver の proxy class で wrap。
      wrap_class = wrap_class_for(mod, framework, sym, default_proxy: proxy_class)
      builder = self
      proxy_class.singleton_class.send(:define_method, ruby_method) do |*args|
        unwrapped = builder.send(:unwrap_proxy_args, args)
        result = dispatcher.call(framework: framework, symbol: canonical, args: unwrapped)
        if wrap_proxy && result.is_a?(Integer)
          wrap_class.from_ref(result)
        else
          result
        end
      end
    end

    # T52b — proxy class の instance method として install。
    # canonical_name "<Klass>.<method>" を split し、proxy class の
    # **instance method** を define、内部で receiver の `__opaque_ref` を
    # 引数列の先頭に prepend して dispatcher.call(symbol: canonical, args:) を
    # 呼ぶ。ObjC instance method の Swift 側 receiver は argv[0] を
    # `unsafeBitCast(OpaquePointer(bitPattern: rb_num2ull(argv[0])), to: Klass.self)`
    # で取り出す形 (template_generator.rb emit_objc_instance_method)。
    def define_instance_method_under_klass(mod, framework, sym)
      canonical = sym[:name].to_s
      klass_name, _, method_part = canonical.partition(".")
      return if klass_name.empty? || method_part.empty?
      return unless klass_name =~ /\A[A-Z]/

      proxy_class = ensure_proxy_class(mod, framework, klass_name)
      ruby_method = ruby_method_name_for(method_part)
      return if ruby_method.empty?

      dispatcher = @dispatcher
      wrap_proxy = opaque_ref_return?(sym)
      # T53j — return_klass: で wrap 先 class を override
      wrap_class = wrap_class_for(mod, framework, sym, default_proxy: proxy_class)
      builder = self
      proxy_class.send(:define_method, ruby_method) do |*args|
        unwrapped = builder.send(:unwrap_proxy_args, args)
        result = dispatcher.call(
          framework: framework, symbol: canonical,
          args: [@__opaque_ref, *unwrapped]
        )
        if wrap_proxy && result.is_a?(Integer)
          wrap_class.from_ref(result)
        else
          result
        end
      end
    end

    # T52h — Apple proxy instance を含む引数列を raw opaque ref Integer に
    # 再帰的に unwrap。Array 要素も element-wise に unwrap (T54a Marshaller の
    # array_of_opaque_ref は要素を rb_num2ull で読むため Integer 必須)。
    # それ以外の値はそのまま pass-through。
    def unwrap_proxy_args(args)
      args.map { |a| unwrap_one(a) }
    end

    def unwrap_one(value)
      return value.__opaque_ref if value.respond_to?(:__opaque_ref) && !value.is_a?(Module)
      return value.map { |x| unwrap_one(x) } if value.is_a?(Array)
      value
    end

    # T52b — selector が ObjC alloc.init 経路 (`initWith...` / `init`) かを判定。
    # template_generator.rb emit_objc_instance_method は selector.start_with?("init")
    # の場合 receiver を取らない form を emit する。namespace_builder 側もこれと
    # 揃え、init form は class singleton method として install する。
    def init_form_selector?(selector)
      return false if selector.nil?
      selector.to_s.start_with?("init")
    end

    # T53j — proxy auto-wrap 先 class を decide。 sym[:return_klass] が指定されて
    # いればその class の proxy を ensure、 そうでなければ default (受信 class
    # の proxy) を使う。 NSURLSession#dataTask が NSURLSessionDataTask を返す
    # ようなケースで wrap class を receiver と分離する。
    def wrap_class_for(mod, framework, sym, default_proxy:)
      rk = sym[:return_klass]
      return default_proxy if rk.nil? || rk.to_s.empty?
      ensure_proxy_class(mod, framework, rk.to_s)
    end

    # T52b — opaque_ref / cftype_ref return_kind 判定。
    # Apple.discover で渡された return_kind は Symbol で、_synthesize_symbol_record
    # 経由で sym[:return_kind] に格納される。proxy にwrap するのはこの2種類のみ。
    def opaque_ref_return?(sym)
      kind = sym[:return_kind]
      return false if kind.nil?
      return true if kind.is_a?(Symbol) && (kind == :opaque_ref || kind == :cftype_ref)
      return true if kind.is_a?(Hash) && (kind[:kind] == :opaque_ref || kind[:kind] == :cftype_ref)
      false
    end

    def ensure_proxy_class(mod, framework, klass_name)
      if mod.const_defined?(klass_name, false)
        mod.const_get(klass_name)
      else
        proxy = Class.new do
          define_singleton_method(:framework) { framework }
          define_singleton_method(:type_name) { klass_name }
          # T52b — proxy instance は raw opaque ref (Integer) を保持する。
          # from_ref(raw) は new(raw) と等価のクラスヘルパー (公開 API)。
          attr_reader :__opaque_ref
          define_method(:initialize) do |raw_ref|
            @__opaque_ref = raw_ref
          end
          define_singleton_method(:from_ref) do |raw_ref|
            new(raw_ref)
          end
        end
        mod.const_set(klass_name, proxy)
        proxy
      end
    end

    # canonical の dot 後ろを Ruby identifier に sanitize。
    # `stringWithUTF8String` → `stringWithUTF8String`（変化なし）
    # `init(string:)`        → `init_string`
    # `init(cgImage:options:)` → `init_cgImage_options`
    # `(` → `_`, `)` → drop, `:` → `_`, 連続 `_` を 1 つに、末尾 `_` を drop。
    def ruby_method_name_for(method_part)
      method_part.gsub("(", "_")
                 .gsub(")", "")
                 .gsub(":", "_")
                 .gsub(/_+/, "_")
                 .sub(/_\z/, "")
    end

    def define_type_constant(mod, framework, type_name)
      # Ruby constants must start with an uppercase letter. Apple SDK exposes
      # some C struct tags in snake_case (e.g. ar_anchor_s, swift_interop_t);
      # skip those rather than raising NameError. Future enhancement could
      # camelize them, but the dispatcher reaches Apple's typed APIs by symbol
      # name not by Ruby constant, so the snake_case ones simply have no Ruby
      # constant proxy.
      return unless type_name =~ /\A[A-Z]/
      return if mod.const_defined?(type_name, false)
      proxy_class = Class.new do
        define_singleton_method(:framework) { framework }
        define_singleton_method(:type_name) { type_name }
      end
      mod.const_set(type_name, proxy_class)
    end
  end
end
