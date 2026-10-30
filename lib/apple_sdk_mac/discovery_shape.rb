# frozen_string_literal: true
require "json"
require_relative "selector_bridge"

module AppleSDKMac
  module DiscoveryShape
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

    module_function

    def synthesize_symbol_record(framework:, **opts)
      base = { id: -1, signature: nil, abi: nil, documentation: nil,
               parameters_json: "[]", requires_main_thread: false,
               content_hash: nil, fields_json: nil }
      case
      when opts.key?(:symbol)
        base.merge(name: opts[:symbol].to_s, kind: "function", abi: "c")
      when opts.key?(:class_method)
        base.merge(
          name: "#{opts[:klass]}.#{SelectorBridge.canonical_method_name(opts[:class_method])}",
          kind: "objc_method_class",
          objc_class: opts[:klass].to_s, selector: opts[:class_method].to_s,
          params: opts[:params], return_kind: opts[:return_kind],
          return_klass: opts[:return_klass]
        )
      when opts.key?(:selector)
        base.merge(
          name: "#{opts[:klass]}.#{SelectorBridge.canonical_method_name(opts[:selector])}",
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

    def override_c_symbol_params(sym_meta, params: nil, return_kind: nil)
      if params
        new_params = params.each_with_index.map do |entry, i|
          if entry.is_a?(Hash)
            kind_sym = (entry[:kind] || entry["kind"]).to_sym
            type     = entry[:type] || entry["type"] || KIND_SYM_TO_TYPE.fetch(kind_sym, "void *")
            nilable  = entry.key?(:nilable) ? entry[:nilable] : (entry.key?("nilable") ? entry["nilable"] : nil)
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
      if return_kind
        sym_meta = sym_meta.merge(return_kind: return_kind)
      end
      sym_meta
    end
  end
end
