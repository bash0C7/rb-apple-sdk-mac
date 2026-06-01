# frozen_string_literal: true
require "json"
require_relative "selector_bridge"

module AppleSDKMac
  # Symbol-record domain transformations for Apple.discover. Public surface:
  # - synthesize_symbol_record: build a symbol record (Hash) from one of the
  #   seven keyword shapes (symbol/selector/class_method/swift_func/
  #   swift_initializer/swift_property/type_args). No Knowledge Base lookup.
  # - override_c_symbol_params: apply user-supplied params/return_kind to
  #   a Knowledge-Base-fetched record so the synthesized parameters_json +
  #   return_kind drive marshaller selection (used to bypass classifier
  #   choices for CFStringRef→string, buffer→is_out_param, Boolean returns,
  #   etc.).
  # - KIND_SYM_TO_TYPE: kind symbol → C type string lookup table.
  module DiscoveryShape
    # Knowledge Base 分類オーバーライドの kind → C type マップ。
    # Apple.discover の :symbol path で `:params` / `:return_kind` が明示された
    # 場合、 これを使って parameters_json を書き換える。
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

    # Build a symbol record (Hash) for the requested shape without touching
    # the Knowledge Base. Apple.discover wraps this with a transient register
    # + compile pipeline.
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
        if opts[:setter] == true
          # setter: true は is_settable プロパティの setter glue を起こす唯一の
          # public 経路。 emit_swift_property_setter は value 型を params[0] に
          # 必須とするため return_kind を value 型として params に積む。 name の
          # "=" suffix が NamespaceBuilder#ruby_method_name_for を通って Ruby の
          # `<prop>=` setter method を define させる。
          base.merge(
            name: "#{opts[:klass]}.#{opts[:swift_property]}=",
            kind: "swift_property_setter",
            swift_class: opts[:klass].to_s,
            swift_property: opts[:swift_property].to_s,
            params: [opts[:return_kind]],
            return_kind: :void,
            instance: opts[:instance] == true
          )
        else
          base.merge(
            name: "#{opts[:klass]}.#{opts[:swift_property]}",
            kind: "swift_property",
            swift_class: opts[:klass].to_s,
            swift_property: opts[:swift_property].to_s,
            return_kind: opts[:return_kind],
            instance: opts[:instance] == true
          )
        end
      when opts.key?(:constant)
        # global_constant の public 経路。 emit_global_constant は signature を
        # global_constant_value_kind で numeric token 判定するため、 user の
        # return_kind から numeric な signature を合成する (numeric のみ被覆、
        # CF/NS opaque 定数は emitter が nil で out-of-coverage に留める)。
        base.merge(
          name: opts[:constant].to_s, kind: "global_constant", abi: "c",
          signature: "extern #{global_constant_signature_type(opts[:return_kind])} #{opts[:constant]}"
        )
      when opts.key?(:swift_func)
        # swift_func は klass: で `Klass.func` static method 化、 または
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
          "Apple.discover requires one of: symbol, selector, class_method, swift_func, swift_initializer, swift_property (+ optional setter: true), constant"
      end
    end

    # global_constant の合成 signature 用 C type token。 emit_global_constant の
    # global_constant_value_kind が拾える numeric token に return_kind を写す。
    # numeric 以外は raw 文字列を返し、 emitter 側で nil (out-of-coverage) に倒す。
    def global_constant_signature_type(return_kind)
      case return_kind
      when :float then "double"
      when :int   then "NSInteger"
      when :uint  then "NSUInteger"
      else return_kind.to_s
      end
    end

    # Apply user-supplied params / return_kind to a Knowledge-Base-fetched C
    # symbol record. Rewrites parameters_json + embeds return_kind so the
    # downstream marshaller picks the user's classification (rather than the
    # one inferred from clang AST).
    #
    # `params` accepts both Symbol form (`:string`) and Hash form
    # (`{kind: :opaque_ref, type: "CFURLRef", nilable: false}`). Hash form
    # carries an explicit Swift type hint plus an optional `nilable` flag
    # the marshaller uses to emit `arg!` force-unwrap when the bridged API
    # requires non-Optional arguments.
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
