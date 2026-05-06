# frozen_string_literal: true
require "json"
require "set"
require_relative "marshallers"

module AppleSDKMac
  class GlueCompiler
    class TemplateGenerator
      # @_silgen_name declarations for the per-route CallbackPillar wrappers,
      # built from CALLBACK_PILLAR_ROUTES so adding a new signature is one YAML
      # entry + one Marshaller route map line — no manual HEADER edit.
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
        @_silgen_name("runtime_proc_registry_get")
        func runtime_proc_registry_get() -> UInt
        @_silgen_name("runtime_arc_box_cftype")
        func runtime_arc_box_cftype(_ raw: UInt) -> UInt
        #{CALLBACK_BRIDGE_DECLS}

        let Qfalse: UInt = 0
        let Qnil:   UInt = 4
        let Qtrue:  UInt = 20
      SWIFT

      def initialize(knowledge_cache: nil)
        @kc = knowledge_cache
      end

      def generate(framework:, symbol:, glue_id:)
        # T42-T48 — kind dispatcher。Apple.discover の synth record で
        # objc/swift kinds が来たら専用 emitter に routing。C-function 経路は
        # 既存 path を維持。未対応 kind は nil で LLM fallback へ流す。
        case symbol[:kind]
        when "objc_method_class"
          return emit_objc_class_method(framework: framework, symbol: symbol, glue_id: glue_id)
        end
        return nil unless symbol[:kind] == "function" && symbol[:abi] == "c"
        params = parse_params(symbol[:parameters_json])
        # Phase 7 — KB-side classification fix-up. `void *` single-pointer
        # parameters carry an in-cookie (refCon) by Apple-API convention
        # but the knowledge importer occasionally tags nullable void*
        # as is_out_param=true (true out-pointers are double-pointers,
        # `void **`). Force the flag back to in so the call shape is
        # not corrupted (`MIDIPortConnectSource(port, source, )` etc.).
        params.each do |p|
          p[:is_out_param] = false if p[:kind] == "void_ptr_nilable"
        end
        ctx = { framework: framework, knowledge_cache: @kc, struct_visited: Set.new }
        marshallers = params.map.with_index { |p, i| Marshaller.for(p, i, ctx) }
        return nil if marshallers.any?(&:nil?)

        out_marshallers = marshallers.select { |m| m.param[:is_out_param] }

        in_loads = marshallers.reject { |m| m.param[:is_out_param] }
                              .map(&:in_load).compact

        call_args = marshallers.map { |m|
          m.param[:is_out_param] ? m.out_addr : m.call_arg
        }.join(", ")

        call_expr = "#{symbol[:name]}(#{call_args})"
        if marshallers.any? { |m| m.is_a?(VariadicMarshaller) }
          call_expr = "withVaList(__cVarArgs) { __va in\n        return #{call_expr}\n    }"
        end

        body = []
        body.concat(in_loads)

        if out_marshallers.length == 1
          out = out_marshallers.first
          body << out.out_init
          body << "let status = #{call_expr}"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          post = out.out_post_call
          body << post if post
          body << "return #{out.out_to_ruby}"
        elsif out_marshallers.length >= 2
          # Multi-out: status check then build a Ruby Hash with one key per out-param.
          out_marshallers.each { |m| body << m.out_init }
          body << "let status = #{call_expr}"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          body << "let multi_out_h = rb_hash_new()"
          out_marshallers.each do |m|
            post = m.out_post_call
            body << post if post
            body << "rb_hash_aset(multi_out_h, rb_str_new_cstr(\"#{m.param[:name]}\"), #{m.out_to_ruby})"
          end
          body << "return multi_out_h"
        else
          ret_kind = effective_return_kind(symbol)
          if ret_kind == "cftype_ref_autoarc"
            # Phase 7 T4 — CF Create-rule auto-ARC. Route the +1-retained CF
            # return value through the runtime ARC pillar's
            # runtime_arc_box_cftype entry point, which wraps in a BoxedCFType
            # whose deinit releases via ARC. User code never calls CFRelease.
            # The Box wrap happens inside the runtime dylib so glue Swift
            # doesn't need to import AppleSDKMacRuntime (LLM rule 3).
            body << "let raw = #{call_expr}"
            body << "let raw_uint = UInt(bitPattern: unsafeBitCast(raw, to: OpaquePointer.self))"
            body << "return rb_ull2inum(UInt64(runtime_arc_box_cftype(raw_uint)))"
          else
            body << "let result = #{call_expr}"
            if ret_kind == "status_int"
              body << %(if result != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
              body << "return Qnil"
            elsif ret_kind == "void"
              body << "return Qnil"
            else
              body << "return #{to_ruby_expr_by_kind(ret_kind, symbol[:signature], "result")}"
            end
          end
        end

        # T40 — function name uses sanitized swift_identifier so canonical
        # names containing `.` / `:` / `(` / `)` (objc/swift kinds) emit valid
        # Swift. C-symbol names contain only [A-Za-z0-9_] so the gsub is a
        # no-op for the existing template path; the call here is forward-
        # compatible with kind-dispatched emitters in T42-T48.
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

      # T42 — ObjC class method emit (spec §3.4.1)。
      # Apple.discover(class_method: "stringWithUTF8String:", ...) で来た synth
      # record を Swift glue に。selector 末尾 colon を strip し、
      # `Klass.swiftMethod(args)` 形式の call site を emit。
      def emit_objc_class_method(framework:, symbol:, glue_id:)
        klass = symbol[:objc_class].to_s
        selector = symbol[:selector].to_s
        swift_method = swift_method_name_from_selector(selector)
        params = symbol[:params] || []
        return_kind = (symbol[:return_kind] || :void).to_sym
        swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
        exported = "glue_#{glue_id}_#{swift_id}"

        in_loads = params.each_with_index.map { |k, i| objc_in_load(k, i) }
        call_args = params.each_with_index.map { |_, i| "arg#{i}" }.join(", ")
        call_expr = "#{klass}.#{swift_method}(#{call_args})"

        body = in_loads + ["let raw = #{call_expr}"] + objc_return_lines(return_kind, "raw")

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

      # selector → Swift method 名 (spec §3.4.1)。
      # single-segment `stringWithUTF8String:` → `stringWithUTF8String`
      # multi-segment は init 専用が大半（T44 の instance method で本格対応）。
      # class method の multi-segment は rare、暫定的に最初の segment を採用。
      def swift_method_name_from_selector(selector)
        parts = selector.split(":", -1).reject(&:empty?)
        return selector if parts.empty?
        return parts[0] if parts.size == 1
        parts[0]
      end

      # objc/swift kind 用の inline argv binding。`:params` array の kind symbol
      # に応じて `let arg<i>` を Swift で declare。既存 Marshaller 経路は
      # parameters_json + clang AST type を要求するので、synth record（params:
      # symbol kinds の配列）専用に inline 展開する。
      def objc_in_load(kind_sym, index)
        case kind_sym.to_sym
        when :string
          "var v#{index} = argv[#{index}]; let arg#{index} = rb_string_value_cstr(&v#{index})"
        when :int
          "let arg#{index}: Int64 = rb_num2ll(argv[#{index}])"
        when :bool
          "let arg#{index}: Bool = (argv[#{index}] != Qfalse && argv[#{index}] != Qnil)"
        when :float
          "let arg#{index}: Double = rb_num2dbl(argv[#{index}])"
        when :opaque_ref
          "let arg#{index} = OpaquePointer(bitPattern: UInt(rb_num2ull(argv[#{index}])))"
        when :cftype_ref
          "let arg#{index} = OpaquePointer(bitPattern: UInt(rb_num2ull(argv[#{index}])))"
        when :void_ptr_nilable
          "let arg#{index}: UnsafeMutableRawPointer? = (argv[#{index}] == Qnil) ? nil : UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[#{index}])))"
        else
          raise ArgumentError, "objc_in_load: unsupported param kind #{kind_sym.inspect}"
        end
      end

      # synth record の return_kind を Ruby VALUE 化する Swift snippet 列。
      # opaque_ref は ObjC instance を Unmanaged.passRetained で raw pointer 化。
      def objc_return_lines(return_kind, var)
        case return_kind.to_sym
        when :opaque_ref
          [
            "if #{var} == nil { return Qnil }",
            "let p = Unmanaged.passRetained(#{var}! as AnyObject).toOpaque()",
            "return rb_ull2inum(UInt64(UInt(bitPattern: p)))"
          ]
        when :int
          ["return rb_ll2inum(Int64(#{var}))"]
        when :bool
          ["return #{var} ? Qtrue : Qfalse"]
        when :float
          ["return rb_float_new(#{var})"]
        when :void
          ["return Qnil"]
        else
          raise ArgumentError, "objc_return_lines: unsupported return_kind #{return_kind.inspect}"
        end
      end

      private

      def parse_params(json)
        return [] if json.nil? || json.empty?
        JSON.parse(json, symbolize_names: true)
      end

      # Phase 7 T4 — when the knowledge record marks a symbol with
      # cf_create_rule (clang AST CF_RETURNS_RETAINED / Create / Copy naming
      # heuristic), upgrade a CF*Ref return to cftype_ref_autoarc so the
      # auto-ARC path fires.
      def effective_return_kind(symbol)
        kind = return_kind(symbol[:signature])
        return kind unless kind == "cftype_ref"
        return "cftype_ref_autoarc" if symbol[:cf_create_rule]
        # Spec §5: naming-prefix heuristic ("Create" / "Copy") fills the gap
        # when the clang AST attribute is missing. Per CF ownership rules,
        # any CF*Create* / CF*Copy* function returns a +1-retained reference
        # the caller must release — so it's auto-ARC eligible.
        return "cftype_ref_autoarc" if cf_create_naming?(symbol[:name])
        kind
      end

      def cf_create_naming?(name)
        name.to_s =~ /\A(?:CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w*(?:Create|Copy)/
      end

      def return_kind(signature)
        sig = signature.to_s.strip
        return "void"   if sig =~ /\A(?:void)\b/
        # NOTE: CFStringRef / NSString * are CF / ObjC opaque types, NOT
        # raw cstrings — passing them to rb_str_new_cstr is a type error.
        # Only the `char *` family is treated as a cstring return; CF/NS
        # text types fall through to cftype_ref / opaque_ref handling.
        return "string" if sig =~ /\A(?:char\s*\*|const\s+char\s*\*)/
        return "bool"   if sig =~ /\A(?:_Bool|Bool|BOOL)\b/
        return "float"  if sig =~ /\A(?:double|float|CGFloat|CFAbsoluteTime|CFTimeInterval|NSTimeInterval|TimeInterval)\b/
        if sig =~ /\A(?:OSStatus|kern_return_t|int|signed|unsigned|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t)\b/
          return "status_int"
        end
        # Pointer-typed Refs (CF/CG/CV/CT/CM/CL/IO/Sec/AX). See cftype_ref Marshaller.
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
          # Encode CF pointer as Ruby Integer via OpaquePointer raw bit-pattern.
          # User is responsible for CFRelease (no ARC bridging in Phase 7).
          "rb_ull2inum(UInt64(UInt(bitPattern: unsafeBitCast(#{swift_var}, to: OpaquePointer.self))))"
        when "opaque_ref"
          if signature.match?(/\A(?:UInt|uint)/)
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
