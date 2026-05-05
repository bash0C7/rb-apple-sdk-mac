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
        next unless framework_module
        symbols = @knowledge.list_framework_symbols(framework: fw)
        symbols.each do |sym|
          install_symbol(framework_module, fw, sym)
        end
      end
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
