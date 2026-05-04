# frozen_string_literal: true

module AppleSDKMac
  class NamespaceBuilder
    KIND_TO_DEFINER = {
      "function" => :method,
      "global_constant" => :method,
      "class" => :constant,
      "struct" => :constant,
      "actor" => :constant,
      "protocol" => :constant,
      "enum_module" => :constant
    }.freeze

    def initialize(knowledge_cache:, target:, dispatcher:)
      @knowledge = knowledge_cache
      @target = target
      @dispatcher = dispatcher
    end

    def build!
      @knowledge.list_frameworks.each do |fw|
        framework_module = define_framework_module(fw)
        symbols = @knowledge.list_framework_symbols(framework: fw)
        symbols.each do |sym|
          install_symbol(framework_module, fw, sym)
        end
      end
    end

    private

    def define_framework_module(name)
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

    def define_type_constant(mod, framework, type_name)
      return if mod.const_defined?(type_name, false)
      proxy_class = Class.new do
        define_singleton_method(:framework) { framework }
        define_singleton_method(:type_name) { type_name }
      end
      mod.const_set(type_name, proxy_class)
    end
  end
end
