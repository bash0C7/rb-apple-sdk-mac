# frozen_string_literal: true
require "json"
require "set"
require_relative "marshallers"

module AppleSDKMac
  class GlueCompiler
    class TemplateGenerator
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
        @_silgen_name("rb_gv_get")
        func rb_gv_get(_ name: UnsafePointer<CChar>) -> UInt
        @_silgen_name("runtime_callback_pillar_register_midi_notify")
        func runtime_callback_pillar_register_midi_notify(_ procId: UInt64) -> Int32
        @_silgen_name("runtime_callback_pillar_get_midi_notify_fnptr")
        func runtime_callback_pillar_get_midi_notify_fnptr(_ slot: Int32) -> UInt64

        let Qfalse: UInt = 0
        let Qnil:   UInt = 4
        let Qtrue:  UInt = 20
      SWIFT

      def initialize(knowledge_cache: nil)
        @kc = knowledge_cache
      end

      def generate(framework:, symbol:, glue_id:)
        return nil unless symbol[:kind] == "function" && symbol[:abi] == "c"
        params = parse_params(symbol[:parameters_json])
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
          ret_kind = return_kind(symbol[:signature])
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

        <<~SWIFT
          import #{framework}
          import Foundation

          #{HEADER}
          @c
          public func glue_#{glue_id}_#{symbol[:name]}(
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

      def return_kind(signature)
        sig = signature.to_s.strip
        return "void"   if sig =~ /\A(?:void)\b/
        return "string" if sig =~ /\A(?:CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
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
