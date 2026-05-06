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
        define_method_under_klass(framework_module, framework_name, sym)
      when :constant
        define_type_constant(framework_module, framework_name, sym[:name])
      end
    end

    def define_function_method(mod, framework, symbol_name)
      dispatcher = @dispatcher
      mod.singleton_class.send(:define_method, symbol_name) do |*args|
        dispatcher.call(framework: framework, symbol: symbol_name, args: args)
      end
    end

    # T41 — :method_under_klass install path. canonical_name "<Klass>.<method>"
    # を split し、Apple::<FW>::<Klass> proxy class を ensure → singleton method
    # を define、内部で dispatcher.call(symbol: canonical_name, args:) を呼ぶ。
    def define_method_under_klass(mod, framework, sym)
      canonical = sym[:name].to_s
      klass_name, _, method_part = canonical.partition(".")
      return if klass_name.empty? || method_part.empty?
      return unless klass_name =~ /\A[A-Z]/

      proxy_class = ensure_proxy_class(mod, framework, klass_name)
      ruby_method = ruby_method_name_for(method_part)
      return if ruby_method.empty?

      dispatcher = @dispatcher
      proxy_class.singleton_class.send(:define_method, ruby_method) do |*args|
        dispatcher.call(framework: framework, symbol: canonical, args: args)
      end
    end

    def ensure_proxy_class(mod, framework, klass_name)
      if mod.const_defined?(klass_name, false)
        mod.const_get(klass_name)
      else
        proxy = Class.new do
          define_singleton_method(:framework) { framework }
          define_singleton_method(:type_name) { klass_name }
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
