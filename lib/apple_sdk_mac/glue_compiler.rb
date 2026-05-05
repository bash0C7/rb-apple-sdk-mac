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

    MAX_LLM_RETRIES = 3

    def initialize(cache:, runtime_dylib_path:, runtime_modules_paths: [], llm_generator: nil, swiftc_invoker: nil)
      @cache = cache
      @runtime_dylib_path = runtime_dylib_path
      @runtime_modules_paths = runtime_modules_paths
      @template = GlueCompiler::TemplateGenerator.new
      @llm = llm_generator
      @gates = GlueCompiler::ValidationGates.new
      @swiftc = swiftc_invoker || GlueCompiler::SwiftcInvoker.new
    end

    def compile(framework:, symbol:)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
      exported = "glue_#{glue_id}_#{symbol[:name]}"

      swift_source = @template.generate(framework: framework, symbol: symbol, glue_id: glue_id)

      if swift_source.nil?
        return llm_path(framework, symbol, glue_id, src, dylib, exported)
      end

      gate_result = @gates.validate(swift_source, framework: framework,
                                                  glue_id: glue_id, symbol: symbol[:name])
      unless gate_result.pass?
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                               generator: "template",
                               error_stage: "static_check",
                               error_detail: gate_result.errors.join("; "))
        return llm_path(framework, symbol, glue_id, src, dylib, exported)
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

    private

    def llm_path(framework, symbol, glue_id, src, dylib, exported)
      return Result.new(success?: false, error_stage: "no_llm",
                         error_detail: "LLM generator not provided") unless @llm

      MAX_LLM_RETRIES.times do |attempt|
        swift_source = @llm.generate(framework: framework, symbol: symbol, glue_id: glue_id)
        if swift_source.nil? || swift_source.strip.empty?
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm",
                                 error_stage: "llm_empty",
                                 error_detail: "LLM returned empty on attempt #{attempt}")
          next
        end

        gate_result = @gates.validate(swift_source, framework: framework,
                                                    glue_id: glue_id, symbol: symbol[:name])
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
                  error_detail: "LLM exhausted #{MAX_LLM_RETRIES} attempts")
    end

    def compute_glue_id(framework, symbol)
      Digest::SHA256.hexdigest(
        "#{framework}|#{symbol[:name]}|#{symbol[:signature]}|#{symbol[:parameters_json]}"
      )[0, 16]
    end
  end
end
