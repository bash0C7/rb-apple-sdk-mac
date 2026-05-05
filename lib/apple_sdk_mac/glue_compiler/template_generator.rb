# frozen_string_literal: true
require "json"

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

        let Qfalse: UInt = 0
        let Qnil:   UInt = 8
        let Qtrue:  UInt = 20
      SWIFT

      def generate(framework:, symbol:, glue_id:)
        return nil unless symbol[:kind] == "function" && symbol[:abi] == "c"
        params = parse_params(symbol[:parameters_json])
        return nil if params.any? { |p| p[:kind] == "unsupported" }

        in_params  = params.reject { |p| p[:is_out_param] }
        out_params = params.select { |p| p[:is_out_param] }
        return nil if out_params.length > 1

        out = out_params.first
        in_loads = in_params.each_with_index.map { |p, i| load_in_param(p, i) }

        call_args = params.map { |p| p[:is_out_param] ? "&outRef" : p[:name] }.join(", ")

        body = []
        body.concat(in_loads)
        if out
          ref_type = strip_pointer(out[:type])
          body << "var outRef: #{ref_type} = #{ref_type}()"
          body << "let status = #{symbol[:name]}(#{call_args})"
          body << %(if status != 0 { rb_raise(rb_eRuntimeError, "OSStatus") })
          body << "return #{to_ruby_expr(out, "outRef")}"
        else
          ret_kind = return_kind(symbol[:signature])
          body << "let result = #{symbol[:name]}(#{call_args})"
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

      def load_in_param(p, i)
        name = p[:name]
        case p[:kind]
        when "string"
          cast = p[:type].include?("CFString") ? " as CFString" :
                 p[:type].include?("NSString") ? " as NSString" : ""
          "var v#{i} = argv[#{i}]; let #{name} = String(cString: rb_string_value_cstr(&v#{i}))#{cast}"
        when "int"
          "let #{name}: Int64 = rb_num2ll(argv[#{i}])"
        when "bool"
          "let #{name}: Bool = (argv[#{i}] != Qfalse && argv[#{i}] != Qnil)"
        when "float"
          "let #{name}: Double = rb_num2dbl(argv[#{i}])"
        when "opaque_ref"
          ref_type = strip_pointer(p[:type])
          if unsigned?(p[:type])
            "let #{name} = #{ref_type}(rb_num2ull(argv[#{i}]))"
          else
            "let #{name} = #{ref_type}(rb_num2ll(argv[#{i}]))"
          end
        end
      end

      def to_ruby_expr(p, swift_var)
        case p[:kind]
        when "string"     then "rb_str_new_cstr(#{swift_var})"
        when "int"        then "rb_ll2inum(Int64(#{swift_var}))"
        when "bool"       then "(#{swift_var} ? Qtrue : Qfalse)"
        when "float"      then "rb_float_new(#{swift_var})"
        when "opaque_ref"
          if unsigned?(p[:type])
            "rb_ull2inum(UInt64(#{swift_var}))"
          else
            "rb_ll2inum(Int64(#{swift_var}))"
          end
        end
      end

      def return_kind(signature)
        sig = signature.to_s.strip
        return "void"   if sig =~ /\A(?:void)\b/
        return "string" if sig =~ /\A(?:CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
        return "bool"   if sig =~ /\A(?:_Bool|Bool|BOOL)\b/
        return "float"  if sig =~ /\A(?:double|float|CGFloat)\b/
        if sig =~ /\A(?:OSStatus|kern_return_t|int|signed|unsigned|U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t)\b/
          return "status_int"
        end
        return "opaque_ref" if sig =~ /\A\w+Ref\b/
        "unsupported"
      end

      def to_ruby_expr_by_kind(kind, signature, swift_var)
        case kind
        when "string"     then "rb_str_new_cstr(#{swift_var})"
        when "bool"       then "(#{swift_var} ? Qtrue : Qfalse)"
        when "float"      then "rb_float_new(#{swift_var})"
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

      def strip_pointer(t)
        t.sub(/\s*\*.*\z/, "").gsub(/\b_(Nonnull|Nullable)\b/, "").strip
      end

      def unsigned?(t)
        return true  if t.match?(/\b(UInt|UInt8|UInt16|UInt32|UInt64|uint(8|16|32|64)_t|unsigned)\b/)
        return false if t.match?(/\b(SInt|SInt8|SInt16|SInt32|SInt64|int(8|16|32|64)_t|signed)\b/)
        # Apple SDK convention: *Ref typedefs without explicit signedness marker
        # are unsigned 32-bit handles (MIDIClientRef, AudioComponentInstance, etc.).
        t.match?(/\b\w+Ref\b/)
      end
    end
  end
end
