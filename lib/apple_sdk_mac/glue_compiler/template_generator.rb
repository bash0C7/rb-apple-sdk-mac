# frozen_string_literal: true
require "json"
require "set"
require_relative "../errors"
require_relative "marshallers"
require_relative "swift_bridge_name"
require_relative "../selector_bridge"
require_relative "objc_marshalling"

module AppleSDKMac
  class GlueCompiler
    class TemplateGenerator
      CALLBACK_BRIDGE_DECLS = ::AppleSDKMac::GlueCompiler::CALLBACK_PILLAR_ROUTES
        .values.uniq.map { |route|
          <<~SWIFT.chomp
            @_silgen_name("runtime_callback_pillar_register_#{route}")
            func runtime_callback_pillar_register_#{route}(_ procId: UInt64) -> Int32
            @_silgen_name("runtime_callback_pillar_get_#{route}_fnptr")
            func runtime_callback_pillar_get_#{route}_fnptr(_ slot: Int32) -> UInt64
          SWIFT
        }.join("\n").freeze

      HEADER = <<~SWIFT.freeze
        // CRuby symbols resolved at dlopen via -undefined dynamic_lookup
        @_silgen_name("rb_string_value_cstr")
        func rb_string_value_cstr(_ value: UnsafeMutablePointer<UInt>) -> UnsafePointer<CChar>
        @_silgen_name("rb_str_new_cstr")
        func rb_str_new_cstr(_ s: UnsafePointer<CChar>) -> UInt
        @_silgen_name("rb_num2ll")
        func rb_num2ll(_ v: UInt) -> Int64
        @_silgen_name("rb_num2ull")
        func rb_num2ull(_ v: UInt) -> UInt64
        @_silgen_name("rb_ll2inum")
        func rb_ll2inum(_ v: Int64) -> UInt
        @_silgen_name("rb_ull2inum")
        func rb_ull2inum(_ v: UInt64) -> UInt
        @_silgen_name("rb_num2dbl")
        func rb_num2dbl(_ v: UInt) -> Double
        @_silgen_name("rb_float_new")
        func rb_float_new(_ d: Double) -> UInt
        @_silgen_name("rb_raise")
        func rb_raise(_ klass: UInt, _ fmt: UnsafePointer<CChar>) -> Never
        @_silgen_name("rb_eRuntimeError")
        var rb_eRuntimeError: UInt
        @_silgen_name("rb_hash_new")
        func rb_hash_new() -> UInt
        @_silgen_name("rb_hash_aref")
        func rb_hash_aref(_ hash: UInt, _ key: UInt) -> UInt
        @_silgen_name("rb_hash_aset")
        func rb_hash_aset(_ hash: UInt, _ key: UInt, _ val: UInt) -> UInt
        @_silgen_name("rb_block_given_p")
        func rb_block_given_p() -> Int32
        @_silgen_name("rb_block_proc")
        func rb_block_proc() -> UInt
        @_silgen_name("rb_obj_id")
        func rb_obj_id(_ v: UInt) -> UInt
        @_silgen_name("rb_ary_entry")
        func rb_ary_entry(_ ary: UInt, _ off: Int) -> UInt
        @_silgen_name("rb_ary_new")
        func rb_ary_new() -> UInt
        @_silgen_name("rb_ary_push")
        func rb_ary_push(_ ary: UInt, _ val: UInt) -> UInt
        @_silgen_name("runtime_rb_array_len")
        func runtime_rb_array_len(_ ary: UInt) -> Int
        @_silgen_name("runtime_proc_registry_get")
        func runtime_proc_registry_get() -> UInt
        @_silgen_name("runtime_arc_box_cftype")
        func runtime_arc_box_cftype(_ raw: UInt) -> UInt
        @_silgen_name("runtime_arc_unbox_cftype")
        func runtime_arc_unbox_cftype(_ raw: UInt) -> UInt
        @_silgen_name("runtime_threading_enqueue")
        func runtime_threading_enqueue(_ procId: UInt64, _ arg: Int64)
        @_silgen_name("runtime_threading_enqueue_3")
        func runtime_threading_enqueue_3(_ procId: UInt64, _ a: Int64, _ b: Int64, _ c: Int64)
        @_silgen_name("runtime_callback_register_block_persistent")
        func runtime_callback_register_block_persistent(_ procId: UInt64) -> UInt64
        @_silgen_name("rb_cObject")
        var rb_cObject: UInt
        @_silgen_name("rb_const_get")
        func rb_const_get(_ klass: UInt, _ id: UInt) -> UInt
        @_silgen_name("rb_intern")
        func rb_intern(_ name: UnsafePointer<CChar>) -> UInt
        #{CALLBACK_BRIDGE_DECLS}

        let Qfalse: UInt = 0
        let Qnil:   UInt = 4
        let Qtrue:  UInt = 20
      SWIFT

      def initialize(knowledge_cache: nil)
        @kc = knowledge_cache
      end

      def generate(framework:, symbol:, glue_id:)
        if @kc
          rec = @kc.lookup_symbol(framework: framework, symbol: symbol[:name])
          if rec && rec[:unsupported_pattern]
            raise AppleSDKMac::UnsupportedPatternError.new(
              pattern: rec[:unsupported_pattern],
              framework: framework,
              symbol: symbol[:name].to_s,
              hint: hint_for_pattern(rec[:unsupported_pattern])
            )
          end
        end

        case symbol[:kind]
        when "objc_method_class"
          return emit_objc_class_method(framework: framework, symbol: symbol, glue_id: glue_id)
        when "objc_method_instance"
          return emit_objc_instance_method(framework: framework, symbol: symbol, glue_id: glue_id)
        when "swift_init"
          return emit_swift_init(framework: framework, symbol: symbol, glue_id: glue_id)
        when "swift_property"
          return emit_swift_property(framework: framework, symbol: symbol, glue_id: glue_id)
        when "swift_property_setter"
          return emit_swift_property_setter(framework: framework, symbol: symbol, glue_id: glue_id)
        when "swift_func"
          return emit_swift_func(framework: framework, symbol: symbol, glue_id: glue_id)
        when "global_constant"
          return emit_global_constant(framework: framework, symbol: symbol, glue_id: glue_id)
        end
        return nil unless symbol[:kind] == "function" && symbol[:abi] == "c"
        params = parse_params(symbol[:parameters_json])
        if escape_hatch_params?(params)
          return emit_c_function_escape_hatch(framework: framework, symbol: symbol, glue_id: glue_id, params: params)
        end
        params.each do |p|
          p[:is_out_param] = false if p[:kind] == "void_ptr_nilable"
        end
        ctx = { framework: framework, knowledge_cache: @kc, struct_visited: Set.new }
        marshallers = params.map.with_index { |p, i| Marshaller.for(p, i, ctx) }
        return nil if marshallers.any?(&:nil?)
        return nil if marshallers.any? { |m|
          m.param[:is_out_param] && m.out_handling.nil?
        }

        out_marshallers = marshallers.select { |m| m.param[:is_out_param] }

        in_loads = marshallers.reject { |m| m.param[:is_out_param] }
                              .map(&:in_load).compact

        call_args = marshallers.map { |m|
          m.param[:is_out_param] ? m.out_handling[:addr] : m.call_arg
        }.join(", ")

        call_expr = "#{symbol[:name]}(#{call_args})"
        if marshallers.any? { |m| m.is_a?(VariadicMarshaller) }
          call_expr = "withVaList(__cVarArgs) { __va in\n        return #{call_expr}\n    }"
        end

        body = []
        body.concat(in_loads)

        if out_marshallers.length == 1
          out = out_marshallers.first.out_handling
          body << out[:init]
          body << "let status = #{call_expr}"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          post = out_marshallers.first.out_post_call
          body << post if post
          body << "return #{out[:to_ruby]}"
        elsif out_marshallers.length >= 2
          out_marshallers.each { |m| body << m.out_handling[:init] }
          body << "let status = #{call_expr}"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          body << "let multi_out_h = rb_hash_new()"
          out_marshallers.each do |m|
            post = m.out_post_call
            body << post if post
            body << "rb_hash_aset(multi_out_h, rb_str_new_cstr(\"#{m.param[:name]}\"), #{m.out_handling[:to_ruby]})"
          end
          body << "return multi_out_h"
        else
          ret_kind = effective_return_kind(symbol, framework: framework)
          if ret_kind == "cftype_ref_autoarc"
            body << "let raw = #{call_expr}"
            body << "let raw_uint = UInt(bitPattern: unsafeBitCast(raw, to: OpaquePointer.self))"
            body << "return rb_ull2inum(UInt64(runtime_arc_box_cftype(raw_uint)))"
          else
            body << "let result = #{call_expr}"
            if ret_kind == "status_int"
              body << %(if result != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
              body << "return Qnil"
            elsif ret_kind == "plain_int"
              body << "return rb_ll2inum(Int64(result))"
            elsif ret_kind == "void"
              body << "return Qnil"
            else
              body << "return #{to_ruby_expr_by_kind(ret_kind, symbol[:signature], "result")}"
            end
          end
        end

        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func glue_#{glue_id}_#{swift_id}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def emit_objc_class_method(framework:, symbol:, glue_id:)
        klass = symbol[:objc_class].to_s
        swift_klass = swift_bridged_class_name(klass)
        selector = symbol[:selector].to_s
        params = symbol[:params] || []
        return_kind = symbol[:return_kind] || :void
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
        call_expr = swift_call_for_class_method(swift_klass, selector, params, framework: framework)

        body = in_loads + ["let raw = #{call_expr}"] + ObjcMarshalling.return_lines(return_kind, "raw")

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def emit_objc_instance_method(framework:, symbol:, glue_id:)
        klass = symbol[:objc_class].to_s
        swift_klass = swift_bridged_class_name(klass)
        selector = symbol[:selector].to_s
        params = symbol[:params] || []
        return_kind = symbol[:return_kind] || :void
        return_kind_sym = ObjcMarshalling.unpack_return_kind(return_kind)[0]
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        throws_bridge = selector.end_with?(":error:") || selector.match?(/(?:AndReturn|Returning)Error:\z/)
        effective_selector =
          if throws_bridge
            selector.sub(/(?::error:|(?:AndReturn|Returning)Error:)\z/, "")
          else
            selector
          end

        body =
          if selector.start_with?("init")
            in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
            call_expr = swift_init_call(swift_klass, selector, params)
            in_loads + ["let raw = #{call_expr}"] + ObjcMarshalling.return_lines(return_kind, "raw")
          else
            receiver_load = <<~SWIFT.chomp
              let receiver = unsafeBitCast(
                  OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
                  to: #{swift_klass}.self
              )
            SWIFT
            in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i, argv_offset: 1) }
            call_expr = swift_call_for_instance_method(effective_selector, params)
            if throws_bridge
              [receiver_load] + in_loads + [
                "do {",
                "    try #{call_expr}",
                "    return Qtrue",
                "} catch {",
                "    return Qfalse",
                "}"
              ]
            else
              if params.empty? && return_kind_sym != :void
                call_expr = call_expr.sub(/\(\s*\)\z/, "")
              end
              call_statement = return_kind_sym == :void ? call_expr : "let raw = #{call_expr}"
              [receiver_load] + in_loads + [call_statement] + ObjcMarshalling.return_lines(return_kind, "raw")
            end
          end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def emit_swift_init(framework:, symbol:, glue_id:)
        klass = symbol[:swift_class].to_s
        swift_klass = swift_bridged_class_name(klass)
        initializer = symbol[:swift_initializer].to_s
        params = symbol[:params] || []
        return_kind = (symbol[:return_kind] || :opaque_ref).to_sym
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        labels = kb_labels(framework, symbol[:name]) || swift_init_labels(initializer)
        in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
        call_expr =
          if labels.empty?
            "#{swift_klass}()"
          else
            args = params.each_index.map { |i| "arg#{i}" }
            "#{swift_klass}(" + labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ") + ")"
          end

        failable = kb_flag(framework, symbol[:name], :is_failable) { initializer.to_s.include?("?") }
        throwing = kb_flag(framework, symbol[:name], :is_throws) { initializer.to_s.include?("throws") }
        init_binding =
          if throwing
            throws_error_type = kb_flag(framework, symbol[:name], :throws_error_type) { nil }
            module_lookup = %(rb_const_get(rb_cObject, rb_intern("AppleSDKMac")))
            err_class_name = throws_error_type == "NSError" ? "ObjcError" : "SwiftError"
            err_class_lookup = %(rb_const_get(#{module_lookup}, rb_intern("#{err_class_name}")))
            <<~SWIFT.chomp
              let v: #{swift_klass}
              do {
                  v = try #{call_expr}
              } catch {
                  rb_raise(#{err_class_lookup}, "#{framework}.#{symbol[:name]}: \\(error.localizedDescription)")
              }
            SWIFT
          elsif labels.empty? || !failable
            "let v = #{call_expr}"
          else
            "guard let v = #{call_expr} else { return Qnil }"
          end
        body = in_loads + [init_binding, *swift_init_return_lines(return_kind, "v")]

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def emit_swift_func(framework:, symbol:, glue_id:)
        klass = symbol[:swift_class].to_s
        func = symbol[:swift_func].to_s
        params = symbol[:params] || []
        return_kind = (symbol[:return_kind] || :void).to_sym
        type_args = symbol[:type_args]
        is_async = kb_flag(framework, symbol[:name], :is_async) { symbol[:async] == true }
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        in_loads = params.each_with_index.map { |k, i| ObjcMarshalling.in_load(k, i) }
        args_str = params.each_index.map { |i| "arg#{i}" }.join(", ")
        type_args_str = type_args ? "<#{Array(type_args).join(', ')}>" : ""
        callee = klass.empty? ? "#{func}#{type_args_str}" : "#{klass}.#{func}#{type_args_str}"
        plain_call = "#{callee}(#{args_str})"

        body =
          if is_async
            swift_t = swift_type_for_return(return_kind)
            [
              *in_loads,
              "let sema = DispatchSemaphore(value: 0)",
              "var result: #{swift_t}?",
              "var captured: Error?",
              "Task {",
              "    do { result = try await #{plain_call} }",
              "    catch { captured = error }",
              "    sema.signal()",
              "}",
              "sema.wait()",
              %(if let e = captured { rb_raise(rb_eRuntimeError, "\\(e)") }),
              *swift_async_return_lines(return_kind, "result!")
            ]
          else
            in_loads + ["let raw = #{plain_call}"] + swift_init_return_lines(return_kind, "raw")
          end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def swift_type_for_return(return_kind)
        case return_kind.to_sym
        when :int   then "Int64"
        when :bool  then "Bool"
        when :float then "Double"
        when :opaque_ref, :cftype_ref then "AnyObject"
        when :void  then "Void"
        else "AnyObject"
        end
      end

      def swift_async_return_lines(return_kind, var)
        case return_kind.to_sym
        when :void
          ["return Qnil"]
        else
          swift_init_return_lines(return_kind, var)
        end
      end

      def emit_swift_property(framework:, symbol:, glue_id:)
        klass = swift_bridged_class_name(symbol[:swift_class].to_s)
        prop = symbol[:swift_property].to_s
        return_kind = symbol[:return_kind] || :opaque_ref
        instance = symbol[:instance] == true
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        body =
          if instance
            receiver_load = <<~SWIFT.chomp
              let receiver = unsafeBitCast(
                  OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
                  to: #{klass}.self
              )
            SWIFT
            [receiver_load, "let raw = receiver.#{prop}"] +
              swift_init_return_lines(return_kind, "raw")
          else
            ["let raw = #{klass}.#{prop}"] +
              swift_init_return_lines(return_kind, "raw")
          end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def emit_swift_property_setter(framework:, symbol:, glue_id:)
        klass = swift_bridged_class_name(symbol[:swift_class].to_s)
        prop = symbol[:swift_property].to_s
        instance = symbol[:instance] == true
        params = symbol[:params] || []
        if params.empty?
          raise ArgumentError,
            "emit_swift_property_setter requires symbol[:params] with >=1 element " \
            "(setter value type) for #{symbol[:name]}"
        end
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        body =
          if instance
            arg0_load = ObjcMarshalling.in_load(params[0], 1)
            [
              "let receiver = unsafeBitCast(",
              "    OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,",
              "    to: #{klass}.self",
              ")",
              "let arg0 = #{arg0_load}",
              "receiver.#{prop} = arg0",
              "return Qnil"
            ]
          else
            arg0_load = ObjcMarshalling.in_load(params[0], 0)
            [
              "let arg0 = #{arg0_load}",
              "#{klass}.#{prop} = arg0",
              "return Qnil"
            ]
          end

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def emit_global_constant(framework:, symbol:, glue_id:)
        const_name = symbol[:name].to_s
        kind = global_constant_value_kind(symbol[:signature])
        return nil if kind.nil?

        swift_id = const_name.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        return_line =
          case kind
          when :float
            "return rb_float_new(Double(raw))"
          when :int
            "return rb_ll2inum(Int64(raw))"
          when :uint
            "return rb_ull2inum(UInt64(raw))"
          end

        body = ["let raw = #{const_name}", return_line]

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func #{exported}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      def global_constant_value_kind(signature)
        sig = signature.to_s
        return nil if sig.empty?
        return nil if sig.include?("*")
        return nil if sig.include?("[")
        return nil if sig =~ /\benum case\b/

        return :uint if sig =~ /\b(?:NSUInteger|UInt(?:8|16|32|64)?|uint(?:8|16|32|64)_t|unsigned)\b/
        return :float if sig =~ /\b(?:double|float|CGFloat|CFAbsoluteTime|CFTimeInterval|NSTimeInterval|TimeInterval)\b/
        return :int if sig =~ /\b(?:NSInteger|SInt(?:8|16|32|64)?|int(?:8|16|32|64)_t|int|signed|long|short)\b/
        nil
      end

      def swift_init_labels(initializer)
        m = initializer.match(/\Ainit\??\((.*)\)(?:\s+throws)?\z/)
        return [] unless m
        m[1].split(":", -1).reject(&:empty?)
      end

      OBJC_BRIDGE_PREPOSITIONS = %w[For By Using From At In To On].freeze
      def split_preposition_verb(sole)
        OBJC_BRIDGE_PREPOSITIONS.each do |prep|
          if (m = sole.match(/\A([a-z][a-zA-Z0-9]*?)#{prep}([A-Z]\w*)\z/))
            verb = m[1]
            type_part = m[2]
            label = AppleSDKMac::SelectorBridge.lower_first_camel(prep + type_part)
            return [verb, label]
          end
        end
        nil
      end

      NS_STRIP_PRESERVE_LIST = %w[NSData NSString NSArray NSDictionary NSSet
                                  NSMutableArray NSMutableDictionary NSMutableSet
                                  NSMutableString NSError].freeze

      def swift_bridged_class_name(klass)
        return klass.to_s if NS_STRIP_PRESERVE_LIST.include?(klass.to_s)
        klass.to_s.sub(/\ANS([A-Z])/, '\1')
      end

      def swift_init_return_lines(return_kind, var)
        kind_sym, _meta = ObjcMarshalling.unpack_return_kind(return_kind)
        case kind_sym
        when :opaque_ref
          [
            "let p = Unmanaged.passRetained(#{var} as AnyObject).toOpaque()",
            "return rb_ull2inum(UInt64(UInt(bitPattern: p)))"
          ]
        else
          ObjcMarshalling.return_lines(return_kind, var)
        end
      end

      def swift_call_for_instance_method(selector, params, receiver_var: "receiver")
        parts = selector.split(":", -1).reject(&:empty?)
        args = params.each_index.map { |i| "arg#{i}" }
        if parts.size == 1
          "#{receiver_var}.#{parts[0]}(#{args.join(', ')})"
        else
          if (m = parts[0].match(/\A(\w+?)With([A-Z]\w+)\z/))
            method_name = m[1]
            labels = ["with"] + parts[1..]
          else
            method_name = parts[0]
            labels = [nil] + parts[1..]
          end
          label_args = labels.zip(args).map { |l, a|
            l.nil? ? a.to_s : "#{l}: #{a}"
          }.join(", ")
          "#{receiver_var}.#{method_name}(#{label_args})"
        end
      end

      def swift_init_call(klass, selector, params)
        parts = selector.split(":", -1).reject(&:empty?)
        head = parts[0].sub(/\Ainit/, "").sub(/\A(With|From|By|Using|For)/, "")
        head = AppleSDKMac::SelectorBridge.lower_first_camel(head)
        labels = head.empty? ? parts[1..] : ([head] + parts[1..])
        if labels.empty?
          "#{klass}()"
        else
          args = params.each_index.map { |i| "arg#{i}" }
          label_args = labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ")
          "#{klass}(#{label_args})"
        end
      end

      def swift_call_for_class_method(klass, selector, params, framework: nil)
        if (kb_or_override = SwiftBridgeName.resolve(
              framework: framework, klass: klass,
              selector: selector, params: params, kc: @kc,
            ))
          return kb_or_override
        end

        parts = selector.split(":", -1).reject(&:empty?)
        if parts.size == 1
          sole = parts[0]
          if (m = sole.match(/\A([A-Za-z][a-zA-Z0-9]*?)With([A-Z]\w*)\z/))
            label = AppleSDKMac::SelectorBridge.lower_first_camel(m[2])
            arg0_expr = %w[utf8String cString].include?(label) ? "arg0_cstr" : "arg0"
            "#{klass}(#{label}: #{arg0_expr})"
          elsif (verb_label = split_preposition_verb(sole))
            verb, label = verb_label
            "#{klass}.#{verb}(#{label}: arg0)"
          else
            args_str = params.each_index.map { |i| "arg#{i}" }.join(", ")
            "#{klass}.#{sole}(#{args_str})"
          end
        else
          head = parts[0].sub(/\A[a-z]+With/, "")
          head = AppleSDKMac::SelectorBridge.lower_first_camel(head)
          labels = head.empty? ? parts[1..] : ([head] + parts[1..])
          args = params.each_index.map { |i| "arg#{i}" }
          label_args = labels.zip(args).map { |l, a| "#{l}: #{a}" }.join(", ")
          "#{klass}(#{label_args})"
        end
      end


      ESCAPE_HATCH_KINDS = %w[opaque_ref cstring uint32 int bool float].freeze

      def escape_hatch_params?(params)
        return false if params.empty?
        params.all? { |p|
          ESCAPE_HATCH_KINDS.include?(p[:kind].to_s) && !p[:is_out_param]
        } && params.any? { |p| %w[cstring uint32].include?(p[:kind].to_s) }
      end

      def escape_hatch_swift_arg_type(kind)
        case kind.to_s
        when "cstring"    then "UnsafePointer<CChar>?"
        when "uint32"     then "UInt32"
        when "int"        then "Int64"
        when "bool"       then "Bool"
        when "float"      then "Double"
        when "opaque_ref" then "UnsafeRawPointer?"
        else                   "UnsafeRawPointer?"
        end
      end

      def escape_hatch_in_load(kind, index)
        case kind.to_s
        when "cstring"
          <<~SWIFT.chomp
            var v#{index} = argv[#{index}]
                let arg#{index}: UnsafePointer<CChar>? = (argv[#{index}] == Qnil) ? nil : rb_string_value_cstr(&v#{index})
          SWIFT
        when "uint32"
          "let arg#{index}: UInt32 = UInt32(rb_num2ull(argv[#{index}]))"
        when "int"
          "let arg#{index}: Int64 = rb_num2ll(argv[#{index}])"
        when "bool"
          "let arg#{index}: Bool = (argv[#{index}] != Qfalse && argv[#{index}] != Qnil)"
        when "float"
          "let arg#{index}: Double = rb_num2dbl(argv[#{index}])"
        when "opaque_ref"
          <<~SWIFT.chomp
            let arg#{index}_raw: UInt = (argv[#{index}] == Qnil) ? 0 : UInt(rb_num2ull(argv[#{index}]))
                let arg#{index}: UnsafeRawPointer? = (arg#{index}_raw == 0) ? nil : UnsafeRawPointer(bitPattern: arg#{index}_raw)
          SWIFT
        else
          raise ArgumentError, "escape_hatch_in_load: unsupported kind #{kind.inspect}"
        end
      end

      def emit_c_function_escape_hatch(framework:, symbol:, glue_id:, params:)
        c_symbol = symbol[:name].to_s
        return_kind_sym = (symbol[:return_kind] || :void).to_sym

        shadow_name = "__escape_#{c_symbol}"
        arg_types = params.map { |p| escape_hatch_swift_arg_type(p[:kind]) }
        ret_type =
          case return_kind_sym
          when :opaque_ref, :cftype_ref then "UnsafeRawPointer?"
          when :int                     then "Int64"
          when :bool                    then "Bool"
          when :float                   then "Double"
          when :uint32                  then "UInt32"
          when :void                    then "Void"
          else "UnsafeRawPointer?"
          end

        shadow_decl = <<~SWIFT.chomp
          @_silgen_name("#{c_symbol}")
          func #{shadow_name}(#{arg_types.each_with_index.map { |t, i| "_ a#{i}: #{t}" }.join(', ')}) -> #{ret_type}
        SWIFT

        in_loads = params.each_with_index.map { |p, i| escape_hatch_in_load(p[:kind], i) }
        call_args = params.each_index.map { |i| "arg#{i}" }.join(", ")
        call_expr = "#{shadow_name}(#{call_args})"

        body = in_loads.dup
        case return_kind_sym
        when :opaque_ref, :cftype_ref
          body << "let raw = #{call_expr}"
          body << "let raw_uint: UInt = raw.map { UInt(bitPattern: $0) } ?? 0"
          if cf_returns_retained?(framework: framework, symbol_name: c_symbol)
            body << "return rb_ull2inum(UInt64(runtime_arc_box_cftype(raw_uint)))"
          else
            body << "return rb_ull2inum(UInt64(raw_uint))"
          end
        when :int
          body << "let raw = #{call_expr}"
          body << "return rb_ll2inum(raw)"
        when :uint32
          body << "let raw = #{call_expr}"
          body << "return rb_ull2inum(UInt64(raw))"
        when :bool
          body << "let raw = #{call_expr}"
          body << "return raw ? Qtrue : Qfalse"
        when :float
          body << "let raw = #{call_expr}"
          body << "return rb_float_new(raw)"
        when :void
          body << "_ = #{call_expr}"
          body << "return Qnil"
        else
          body << "let raw = #{call_expr}"
          body << "return rb_ull2inum(UInt64(UInt(bitPattern: raw)))"
        end

        swift_id = c_symbol.gsub(/[^A-Za-z0-9_]/, "_")
        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          #{shadow_decl}
          @c
          public func glue_#{glue_id}_#{swift_id}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{body.join("\n    ")}
          }
        SWIFT
      end

      private

      def parse_params(json)
        return [] if json.nil? || json.empty?
        JSON.parse(json, symbolize_names: true)
      end

      RETURN_KIND_OVERRIDE_TO_TEMPLATE = {
        int: "plain_int", bool: "bool", float: "float", void: "void",
        string: "string", opaque_ref: "opaque_ref",
        cftype_ref: "cftype_ref", cftype_ref_autoarc: "cftype_ref_autoarc"
      }.freeze

      def effective_return_kind(symbol, framework:)
        if symbol[:return_kind] && (mapped = RETURN_KIND_OVERRIDE_TO_TEMPLATE[symbol[:return_kind].to_sym])
          return mapped
        end
        kind = return_kind(symbol[:signature])
        return kind unless kind == "cftype_ref"
        return "cftype_ref_autoarc" if cf_returns_retained?(framework: framework, symbol_name: symbol[:name])
        kind
      end

      def cf_create_naming?(name)
        name.to_s =~ /\A(?:CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w*(?:Create|Copy)/
      end

      def cf_returns_retained?(framework:, symbol_name:)
        framework = framework.to_s
        if @kc
          rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
          if rec && rec[:return_ownership]
            return rec[:return_ownership] == "cf_returns_retained"
          end
        end
        cf_create_naming?(symbol_name) ? true : false
      end

      def kb_flag(framework, symbol_name, column)
        return yield unless @kc
        rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
        return yield unless rec
        v = rec[column]
        v.nil? ? yield : v
      end

      def kb_labels(framework, symbol_name)
        return nil unless @kc
        rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
        return nil unless rec && rec[:parameters_json]
        parsed = JSON.parse(rec[:parameters_json])
        return nil unless parsed.is_a?(Array) && parsed.any?
        labels = parsed.map { |p| p.is_a?(Hash) && p["external_label"] }
        return nil if labels.any? { |l| l.nil? || l == "" || l == "_" }
        labels
      end

      PATTERN_HINTS = {
        "swift_macro"            => "Create a Swift package wrapping the macro-generated API as a public func, then add via apple:knowledge:add-framework.",
        "swift_result_builder"   => "Result builders are compile-time DSLs; provide a builder-evaluated Swift wrapper func and add to Knowledge Base.",
        "static_inline_function" => "Static inline C functions cannot be dlopen'd; provide a Swift / C wrapper function with external linkage and add to Knowledge Base.",
        "function_like_macro"    => "C function-like macros are expansion-only; reimplement as Swift / C function and add to Knowledge Base."
      }.freeze

      def hint_for_pattern(pattern)
        PATTERN_HINTS[pattern.to_s] ||
          "Pattern '#{pattern}' is not directly bridgeable. Provide a public Swift/C wrapper and add it to the Knowledge Base."
      end

      def resolve_callback_route(framework:, symbol_name:)
        return nil unless @kc
        rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
        return nil unless rec && rec[:callback_signature_json]
        parsed = JSON.parse(rec[:callback_signature_json])
        normalized = parsed["normalized"] || parsed[:normalized]
        return nil unless normalized
        route_table = ::AppleSDKMac::GlueCompiler::CALLBACK_PILLAR_ROUTES
        hit = route_table.values.uniq.find { |r| r.to_s == normalized.to_s }
        return hit if hit
        raise AppleSDKMac::UnsupportedPatternError.new(
          pattern: "callback_signature_unregistered",
          framework: framework,
          symbol: symbol_name,
          hint: "callback signature '#{normalized}' is not registered in ext/apple_sdk_mac_runtime/. " \
                "Add runtime_callback_pillar_register_#{normalized} / get_#{normalized}_fnptr + " \
                "Marshaller route map entry."
        )
      end

      def return_kind(signature)
        sig = signature.to_s.strip
        return "void"   if sig =~ /\A(?:void)\b/
        return "string" if sig =~ /\A(?:char\s*\*|const\s+char\s*\*)/
        return "bool"   if sig =~ /\A(?:_Bool|Bool|BOOL)\b/
        return "float"  if sig =~ /\A(?:double|float|CGFloat|CFAbsoluteTime|CFTimeInterval|NSTimeInterval|TimeInterval)\b/
        if sig =~ /\A(?:OSStatus|kern_return_t|int|signed|unsigned|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t)\b/
          return "status_int"
        end
        return "cftype_ref" if sig =~ /\A(?:CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w+Ref\b/
        return "opaque_ref" if sig =~ /\A\w+Ref\b/
        "unsupported"
      end

      def to_ruby_expr_by_kind(kind, signature, swift_var)
        case kind
        when "string"     then "rb_str_new_cstr(#{swift_var})"
        when "bool"       then "(#{swift_var} ? Qtrue : Qfalse)"
        when "float"      then "rb_float_new(#{swift_var})"
        when "cftype_ref"
          "rb_ull2inum(UInt64(UInt(bitPattern: unsafeBitCast(#{swift_var}, to: OpaquePointer.self))))"
        when "opaque_ref"
          if signature && signature.match?(/\A(?:UInt|uint)/)
            "rb_ull2inum(UInt64(#{swift_var}))"
          else
            "rb_ll2inum(Int64(#{swift_var}))"
          end
        else
          "rb_ll2inum(Int64(#{swift_var}))"
        end
      end
    end
  end
end
