# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    module GlueAnalyzer
      module_function

      VALUE_RETURN = /\A(Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|Double|Float|CGFloat|Bool)\??\z/

      def extract_driver_inputs(swift_source)
        return nil if swift_source.nil?
        sig = swift_source.match(
          /public\s+func\s+glue_[A-Za-z0-9_]+\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_<>?.\s]+?)\s*)?\{/m
        )
        return nil unless sig
        return nil unless sig[1].strip.empty?
        ret = sig[2].to_s.strip
        kind = value_kind_for(ret)
        return nil unless kind
        call = extract_return_call(swift_source)
        return nil unless call
        { call_expr: call, invoke_args: [], value_kind: kind }
      end

      def value_kind_for(ret)
        return nil if ret.empty?
        return :value  if ret.match?(VALUE_RETURN)
        return :opaque if ret == "AnyObject" || ret.end_with?("?")
        nil
      end

      def extract_return_call(src)
        m = src.match(/\breturn\s+([^\n]+)/)
        return nil unless m
        expr = m[1].strip.sub(/;\z/, "").strip
        expr.match?(/\A[\w.]+\s*\(.*\)\z/) ? expr : nil
      end
    end
  end
end
