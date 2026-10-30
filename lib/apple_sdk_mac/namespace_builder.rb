# frozen_string_literal: true

module AppleSDKMac
  class NamespaceBuilder
    KIND_TO_DEFINER = {
      "function"             => :method,
      "global_constant"      => :method,
      "swift_func"           => :method,
      "objc_method_class"    => :method_under_klass,
      "objc_method_instance" => :method_under_klass,
      "swift_init"           => :method_under_klass,
      "swift_property"        => :method_under_klass,
      "swift_property_setter" => :method_under_klass,
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

    def install_one(framework_name, sym_record)
      fw_module = define_framework_module(framework_name.to_s)
      return nil unless fw_module
      install_symbol(fw_module, framework_name.to_s, sym_record)
      fw_module
    end

    private

    def define_framework_module(name)
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
          define_instance_method_under_klass(framework_module, framework_name, sym)
        elsif sym[:kind] == "swift_property" && sym[:instance] == true
          define_instance_method_under_klass(framework_module, framework_name, sym)
        elsif sym[:kind] == "swift_property_setter" && sym[:instance] == true
          define_instance_method_under_klass(framework_module, framework_name, sym)
        elsif sym[:kind] == "swift_property_setter"
          define_method_under_klass(framework_module, framework_name, sym)
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
        unwrapped = builder.send(:unwrap_proxy_args, args)
        dispatcher.call(framework: framework, symbol: symbol_name, args: unwrapped)
      end
    end

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

    def unwrap_proxy_args(args)
      args.map { |a| unwrap_one(a) }
    end

    def unwrap_one(value)
      return value.__opaque_ref if value.respond_to?(:__opaque_ref) && !value.is_a?(Module)
      return value.map { |x| unwrap_one(x) } if value.is_a?(Array)
      value
    end

    def init_form_selector?(selector)
      return false if selector.nil?
      selector.to_s.start_with?("init")
    end

    def wrap_class_for(mod, framework, sym, default_proxy:)
      rk = sym[:return_klass]
      return default_proxy if rk.nil? || rk.to_s.empty?
      ensure_proxy_class(mod, framework, rk.to_s)
    end

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
        proxy = build_proxy_class(framework, klass_name)
        mod.const_set(klass_name, proxy)
        proxy
      end
    end

    def build_proxy_class(framework, klass_name)
      Class.new do
        define_singleton_method(:framework) { framework }
        define_singleton_method(:type_name) { klass_name }
        attr_reader :__opaque_ref
        define_method(:initialize) do |raw_ref|
          @__opaque_ref = raw_ref
        end
        define_singleton_method(:from_ref) do |raw_ref|
          new(raw_ref)
        end
      end
    end

    def ruby_method_name_for(method_part)
      method_part.sub(/\s+throws\z/, "")
                 .gsub("(", "_")
                 .gsub(")", "")
                 .gsub(":", "_")
                 .gsub(/_+/, "_")
                 .sub(/_\z/, "")
    end

    def define_type_constant(mod, framework, type_name)
      return unless type_name =~ /\A[A-Z]/
      return if mod.const_defined?(type_name, false)
      mod.const_set(type_name, build_proxy_class(framework, type_name))
    end
  end
end
