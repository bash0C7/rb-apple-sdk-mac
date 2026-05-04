# frozen_string_literal: true
require "json"

module AppleSDKMac
  module GlueCompiler
    class TemplateGenerator
      def generate(framework:, symbol:, glue_id:)
        case [symbol[:kind], symbol[:abi]]
        when ["function", "c"]
          generate_c_function(framework, symbol, glue_id)
        when ["function", "swift"]
          generate_swift_function(framework, symbol, glue_id)
        else
          nil
        end
      end

      private

      def generate_c_function(framework, sym, glue_id)
        params = parse_params(sym[:parameters_json])
        return nil unless template_compatible?(params)

        param_load = params.each_with_index.map { |p, i| load_param(p, i) }.join("\n    ")
        call_args = params.reject { |p| out_param?(p) }
                          .map { |p| p[:name] }.join(", ")
        out_param = params.find { |p| out_param?(p) }

        <<~SWIFT
          import #{framework}
          import AppleSDKMacRuntime
          import Foundation

          @c
          public func glue_#{glue_id}_#{sym[:name]}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{param_load}
              #{out_param ? "var outRef = #{strip_pointer(out_param[:type])}()" : ''}
              let status = #{sym[:name]}(#{call_args}#{out_param ? ', &outRef' : ''})
              if status != 0 {
                  ErrorBridge.rb_raise_via_runtime(.runtimeError, "OSStatus \\(status)")
              }
              #{out_param ? 'return Marshal.toRuby(RefTable.retain(outRef as AnyObject))' : 'return Marshal.toRuby(Int(status))'}
          }
        SWIFT
      end

      def generate_swift_function(framework, sym, glue_id)
        return nil if sym[:signature].include?("async") || sym[:signature].include?("<")
        params = parse_params(sym[:parameters_json])
        return nil unless template_compatible?(params)

        param_load = params.each_with_index.map { |p, i| load_param(p, i) }.join("\n    ")
        call_args = params.map { |p| p[:name] }.join(", ")

        <<~SWIFT
          import #{framework}
          import AppleSDKMacRuntime
          import Foundation

          @c
          public func glue_#{glue_id}_#{sym[:name]}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{param_load}
              let result = #{sym[:name]}(#{call_args})
              return Marshal.toRuby(result)
          }
        SWIFT
      end

      def parse_params(json_str)
        return [] unless json_str
        JSON.parse(json_str).map do |p|
          { name: p["name"] || "_arg", type: p["type"] || "Any" }
        end
      end

      def template_compatible?(params)
        return false if params.any? { |p| p[:type].include?("...") }
        return false if params.any? { |p| p[:type].include?("@escaping") && p[:type].include?("(") }
        return false if params.any? { |p| p[:type].include?("Generic") || p[:type].match(/<\w/) }
        true
      end

      def out_param?(p)
        p[:type].include?("*") || p[:type].include?("inout")
      end

      def load_param(p, i)
        case p[:type]
        when /CFStringRef|String|NSString/
          %{guard argc > #{i} else { ErrorBridge.rb_raise_via_runtime(.argumentError, "missing arg #{i}"); return 0 }
              let #{p[:name]} = Marshal.fromRubyString(argv[#{i}]) as CFString}
        when /Int|Int32|Int64|UInt|UInt32|UInt64/
          "let #{p[:name]} = Int64(Marshal.fromRubyInt(argv[#{i}]))"
        when /Bool/
          "let #{p[:name]} = Marshal.fromRubyBool(argv[#{i}])"
        else
          "let #{p[:name]}: Any = Marshal.fromRubyAny(argv[#{i}])"
        end
      end

      def strip_pointer(t)
        t.sub(/\s*\*\s*$/, "").strip
      end
    end
  end
end
