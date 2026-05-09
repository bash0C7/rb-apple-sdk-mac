# frozen_string_literal: true
require "digest"
require_relative "glue_compiler/template_generator"
require_relative "glue_compiler/llm_generator"
require_relative "glue_compiler/validation_gates"
require_relative "glue_compiler/swiftc_invoker"

module AppleSDKMac
  class GlueCompiler
    Result = Struct.new(:success?, :glue_id, :generator, :dylib_path,
                         :exported_symbol, :error_stage, :error_detail,
                         keyword_init: true)

    # Raised from 3 to absorb Foundation Model on-device's ~1/3 off-format
    # response rate (per spec verification 2026-05-05). At budget=3, a single
    # off-format attempt could exhaust two-thirds of the allowance before any
    # well-formed retry had a chance to land.
    DEFAULT_MAX_LLM_RETRIES = 6

    def initialize(cache:, runtime_dylib_path:, runtime_modules_paths: [],
                    llm_generator: nil, swiftc_invoker: nil,
                    template_generator: nil,
                    knowledge_cache: nil,
                    max_llm_retries: DEFAULT_MAX_LLM_RETRIES)
      @cache = cache
      @runtime_dylib_path = runtime_dylib_path
      @runtime_modules_paths = runtime_modules_paths
      @template = template_generator || GlueCompiler::TemplateGenerator.new(knowledge_cache: knowledge_cache)
      @llm = llm_generator
      @gates = GlueCompiler::ValidationGates.new
      @swiftc = swiftc_invoker || GlueCompiler::SwiftcInvoker.new
      @max_llm_retries = max_llm_retries
    end

    def compile(framework:, symbol:)
      result = try_template(framework: framework, symbol: symbol)
      return result if result.success?
      try_llm(framework: framework, symbol: symbol, prior_failure: result)
    end

    private

    def try_template(framework:, symbol:)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
      # T40 — exported_symbol must be a Swift identifier. canonical_name
      # contains `.` / `:` / `(` / `)` which are valid as a primary key but
      # invalid as a Swift function name. Mechanically derive swift_identifier
      # via gsub of non-[A-Za-z0-9_] (spec §3.2 Name 体系).
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      exported = "glue_#{glue_id}_#{swift_id}"

      swift_source = @template.generate(framework: framework, symbol: symbol, glue_id: glue_id)

      if swift_source.nil?
        return Result.new(success?: false, error_stage: "template_nil",
                           error_detail: "template returned nil")
      end

      gate_result = @gates.validate(swift_source, framework: framework,
                                                  glue_id: glue_id, symbol: swift_id)
      unless gate_result.pass?
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                               generator: "template",
                               error_stage: "static_check",
                               error_detail: gate_result.errors.join("; "))
        return Result.new(success?: false, error_stage: "static_check",
                           error_detail: gate_result.errors.join("; "))
      end

      File.write(src, swift_source)
      ok, err = @swiftc.compile(
        source_path: src, dylib_path: dylib,
        runtime_dylib_path: @runtime_dylib_path,
        module_search_paths: @runtime_modules_paths
      )
      unless ok
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                               generator: "template",
                               error_stage: "swiftc",
                               error_detail: err)
        return Result.new(success?: false, error_stage: "swiftc", error_detail: err)
      end

      @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                     swift_source: swift_source, dylib_path: dylib,
                     exported_symbol: exported, generator: "template")
      Result.new(success?: true, glue_id: glue_id, generator: "template",
                  dylib_path: dylib, exported_symbol: exported)
    end

    def try_llm(framework:, symbol:, prior_failure: nil)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")

      return Result.new(success?: false, error_stage: "no_llm",
                         error_detail: "LLM generator not provided") unless @llm

      # T40 — same swift_id sanitization as the template path so GATE 5
      # (`@c public func glue_<id>_<symbol>`) accepts the LLM's output for
      # canonical-name shapes like "NSString.stringWithUTF8String".
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      exported = "glue_#{glue_id}_#{swift_id}"

      @max_llm_retries.times do |attempt|
        swift_source = begin
          @llm.generate(framework: framework, symbol: symbol, glue_id: glue_id)
        rescue StandardError => e
          # Phase 7 — wrap LLM-side raises (Foundation Models context
          # overflow, network failure, model load error) into a normal
          # compile-history attempt row so Apple.discover gets a clean
          # CompileError instead of an unhandled framework exception.
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm",
                                 error_stage: "llm_raise",
                                 error_detail: "#{e.class}: #{e.message[0..400]}")
          nil
        end
        if swift_source.nil? || swift_source.strip.empty?
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm",
                                 error_stage: "llm_empty",
                                 error_detail: "LLM returned empty on attempt #{attempt}")
          next
        end

        gate_result = @gates.validate(swift_source, framework: framework,
                                                    glue_id: glue_id, symbol: swift_id)
        unless gate_result.pass?
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm",
                                 llm_response: swift_source,
                                 error_stage: "static_check",
                                 error_detail: gate_result.errors.join("; "))
          next
        end

        File.write(src, swift_source)
        ok, err = @swiftc.compile(source_path: src, dylib_path: dylib,
                                   runtime_dylib_path: @runtime_dylib_path,
                                   module_search_paths: @runtime_modules_paths)
        unless ok
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm", llm_response: swift_source,
                                 error_stage: "swiftc", error_detail: err)
          next
        end

        @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                       swift_source: swift_source, dylib_path: dylib,
                       exported_symbol: exported, generator: "llm")
        return Result.new(success?: true, glue_id: glue_id, generator: "llm",
                           dylib_path: dylib, exported_symbol: exported)
      end

      Result.new(success?: false, error_stage: "llm_max_retries",
                  error_detail: "LLM exhausted #{@max_llm_retries} attempts")
    end

    def compute_glue_id(framework, symbol)
      Digest::SHA256.hexdigest(
        "#{framework}|#{symbol[:name]}|#{symbol[:signature]}|#{symbol[:parameters_json]}"
      )[0, 16]
    end
  end
end
