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
    # Symbol kinds the template generator emits glue for. C functions additionally
    # require abi == "c" (checked in covered?). Everything else routes to LLM /
    # loud-fail.
    COVERED_KINDS = %w[
      function
      objc_method_class objc_method_instance
      swift_init swift_property swift_property_setter swift_func
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
    # Real metadata tags each param with an explicit "kind" (matching
    # REGISTRY); when that is absent we infer the kind from the available
    # shape hints (type string / is_out_param / is_struct_in) so the contract
    # can also reason about partially-specified param hashes.
    def supported_param?(param)
      SUPPORTED_PARAM_KINDS.include?(param_kind(param))
    end

    def param_kind(param)
      explicit = param["kind"] || param[:kind]
      return explicit.to_s if explicit
      infer_kind(param)
    end

    # Best-effort kind inference for params that omit an explicit "kind".
    # Mirrors the shapes the importer / discover layer would tag. Anything we
    # cannot map returns a sentinel ("unknown") that is never in
    # SUPPORTED_PARAM_KINDS, so it reads as uncovered.
    def infer_kind(param)
      return "struct_in" if truthy(param["is_struct_in"] || param[:is_struct_in])
      type = (param["type"] || param[:type]).to_s
      out  = truthy(param["is_out_param"] || param[:is_out_param])
      case type
      when /\A(const\s+)?char\s*\*/                       then "string"
      when /\A(U?Int(8|16|32|64)?|AudioObjectID|OSStatus|kern_return_t|CFIndex|NSInteger|NSUInteger|ItemCount)\s*\*?\z/
        "int"
      when /\A(Bool|BOOL|_Bool)\s*\*?\z/                  then "bool"
      when /\A(Float|Double|CGFloat)\s*\*?\z/             then "float"
      when /(CF|CG|CV|CT|CM|CL|IO|Sec|AX)\w+Ref/          then "cftype_ref"
      when /\w+Ref\s*\*?\z/                               then "opaque_ref"
      else
        # An out-pointer to an otherwise-scalar type is still int/float-shaped;
        # but a fully unknown type (e.g. C++ std::vector<...>) stays uncovered.
        out ? "unknown_out" : "unknown"
      end
    end

    def truthy(v)
      v == true || v == "true"
    end

    def param_label(param)
      (param["type"] || param[:type] || param["kind"] || param[:kind]).to_s
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
