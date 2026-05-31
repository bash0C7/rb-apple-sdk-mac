# frozen_string_literal: true
require "json"

module AppleSDKMac
  # Machine-readable statement of which (kind, parameter-shape) combinations the
  # rule-based template generator GUARANTEES to round-trip. `covered? == true`
  # MUST compile and invoke — a failure there is a bug to fix in the generator,
  # not an inference-fallback trigger. `covered? == false` is the loud-fail /
  # inference boundary. Keeps the boundary explicit instead of relying on the
  # generator silently returning nil.
  #
  # The values below are derived 1:1 from the real generator + marshaller, NOT
  # from the plan's draft:
  #   * COVERED_KINDS == the symbol kinds TemplateGenerator#generate dispatches
  #     on (the `case symbol[:kind]` arms + the C-function path guarded by
  #     `symbol[:kind] == "function" && symbol[:abi] == "c"`).
  #   * SUPPORTED_PARAM_KINDS == the keys registered in
  #     GlueCompiler::Marshaller::REGISTRY. Marshaller.for dispatches on
  #     param[:kind] (NOT param[:type]); the type string is only consumed by an
  #     already-selected marshaller. So coverage of a parameter is decided by
  #     its `kind`, with `is_out_param` an orthogonal boolean every out-capable
  #     marshaller honours.
  class CoverageContract
    # Symbol kinds the project COMMITS to round-tripping through the rule-based
    # generator. C functions additionally require abi == "c" (checked in
    # covered?). Everything else routes to LLM / loud-fail.
    #
    # NOTE: global_constant is declared covered because the project commits to
    # making it round-trip. The generator emitter for global_constant is a known
    # hole closed in a separate Track-1 task; the contract truthfully declares
    # the 8-kind boundary the project owns, not the generator's current state.
    COVERED_KINDS = %w[
      function
      objc_method_class objc_method_instance
      swift_init swift_property swift_property_setter swift_func
      global_constant
    ].freeze

    # Parameter kinds the marshaller REGISTRY can realize. 1:1 with
    # GlueCompiler::Marshaller::REGISTRY keys at the time of writing.
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

    # 範囲外の理由を返す。範囲内なら nil。
    def uncovered_reason(symbol)
      kind = symbol[:kind].to_s
      unless COVERED_KINDS.include?(kind)
        return "kind '#{kind}' is not in the covered set (#{COVERED_KINDS.join(', ')})"
      end
      # The C-function path is the only one driven by parameters_json; objc/swift
      # kinds carry their args in symbol[:params] (already resolved by discover).
      # So parameter-shape coverage only constrains C functions here.
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

    # A parameter is covered when its marshaller kind is in the REGISTRY set.
    # Real metadata tags every param with an explicit "kind" (1:1 with
    # Marshaller.for, which dispatches on param[:kind]); is_out_param is an
    # orthogonal boolean each out-capable marshaller honours. A param the
    # importer cannot bridge carries a kind outside SUPPORTED_PARAM_KINDS
    # (e.g. "unsupported"), which reads as uncovered with no special-casing.
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
