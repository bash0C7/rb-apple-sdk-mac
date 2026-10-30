# frozen_string_literal: true
require "json"

module AppleSDKMac
  class CoverageContract
    COVERED_KINDS = %w[
      function
      objc_method_class objc_method_instance
      swift_init swift_property swift_property_setter swift_func
      global_constant
    ].freeze

    SUPPORTED_PARAM_KINDS = %w[
      string int bool float
      opaque_ref cftype_ref
      callback_nilable callback_non_nil
      block_nilable block_persistent block_persistent_void
      void_ptr_nilable
      array_of_opaque_ref
      struct_in struct_out struct_in_pointer
      variadic_args
    ].freeze

    def covered?(symbol)
      uncovered_reason(symbol).nil?
    end

    def uncovered_reason(symbol)
      kind = symbol[:kind].to_s
      unless COVERED_KINDS.include?(kind)
        return "kind '#{kind}' is not in the covered set (#{COVERED_KINDS.join(', ')})"
      end
      if kind == "function"
        if symbol[:abi].to_s != "c"
          return "kind 'function' requires abi 'c' (got #{symbol[:abi].inspect})"
        end
        bad = parse_params(symbol).reject { |p| supported_param?(p) }
        unless bad.empty?
          return "unsupported parameter type(s): #{bad.map { |p| param_label(p) }.join(', ')}"
        end
      end
      nil
    end

    private

    def supported_param?(param)
      SUPPORTED_PARAM_KINDS.include?(param_kind(param))
    end

    def param_kind(param)
      (param["kind"] || param[:kind]).to_s
    end

    def param_label(param)
      kind = param_kind(param)
      type = (param["type"] || param[:type]).to_s
      type.empty? ? kind : "#{type} (kind '#{kind}')"
    end

    def parse_params(symbol)
      raw = (symbol[:parameters_json] || symbol["parameters_json"]).to_s
      return [] if raw.empty?
      parsed = JSON.parse(raw)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end
  end
end
