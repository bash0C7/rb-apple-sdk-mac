# frozen_string_literal: true
require "digest"
require "fileutils"
require_relative "glue_compiler/template_generator"
require_relative "glue_compiler/validation_gates"
require_relative "glue_compiler/swiftc_invoker"
require_relative "coverage_contract"

module AppleSDKMac
  class GlueCompiler
    Result = Struct.new(:success?, :glue_id, :generator, :dylib_path,
                         :exported_symbol, :error_stage, :error_detail,
                         keyword_init: true)

    def initialize(cache:, runtime_dylib_path:, runtime_modules_paths: [],
                    swiftc_invoker: nil,
                    template_generator: nil,
                    knowledge_cache: nil,
                    gates: nil,
                    inference_backend: nil,
                    coverage_contract: nil)
      @cache = cache
      @runtime_dylib_path = runtime_dylib_path
      @runtime_modules_paths = runtime_modules_paths
      @template = template_generator || GlueCompiler::TemplateGenerator.new(knowledge_cache: knowledge_cache)
      @gates = gates || GlueCompiler::ValidationGates.new
      @swiftc = swiftc_invoker || GlueCompiler::SwiftcInvoker.new
      @inference_backend = inference_backend
      @contract = coverage_contract || CoverageContract.new
    end

    def compile(framework:, symbol:)
      result = try_template(framework: framework, symbol: symbol)
      return result if result.success?

      # template が成功しなかった。契約範囲内なら「穴」= バグなので
      # Result(success?:false) をそのまま返す(呼び出し側で別途修正対象)。
      # 範囲外なら inference backend に委譲、無効なら loud fail。
      if @contract.covered?(symbol)
        return result
      end

      reason = @contract.uncovered_reason(symbol) || "uncovered shape"
      if @inference_backend
        return try_inference(framework: framework, symbol: symbol, reason: reason)
      end

      raise OutOfCoverageError.new(
        framework: framework.to_s, symbol: symbol[:name].to_s,
        pattern: symbol[:kind].to_s, reason: reason
      )
    end

    private

    def try_inference(framework:, symbol:, reason:)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      FileUtils.mkdir_p(File.join(base, "sources"))
      FileUtils.mkdir_p(File.join(base, "lib"))
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      exported = "glue_#{glue_id}_#{swift_id}"
      gen = "inference:#{@inference_backend.name}"

      swift_source = @inference_backend.generate_glue(
        framework: framework, symbol: symbol, glue_id: glue_id, exported: exported
      )
      # gate / swiftc 失敗時は失敗 detail を添えて 1 回だけ再投入。
      attempt = 0
      while attempt < 2
        if swift_source.nil? || swift_source.empty?
          break
        end
        gate_result = @gates.validate(swift_source, framework: framework,
                                                    glue_id: glue_id, symbol: swift_id)
        if gate_result.pass?
          File.write(src, swift_source)
          ok, err = @swiftc.compile(source_path: src, dylib_path: dylib,
                                    runtime_dylib_path: @runtime_dylib_path,
                                    module_search_paths: @runtime_modules_paths)
          if ok
            @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                          swift_source: swift_source, dylib_path: dylib,
                          exported_symbol: exported, generator: gen)
            return Result.new(success?: true, glue_id: glue_id, generator: gen,
                              dylib_path: dylib, exported_symbol: exported)
          end
          fail_detail = "swiftc: #{err}"
        else
          fail_detail = "static_check: #{gate_result.errors.join('; ')}"
        end
        attempt += 1
        break if attempt >= 2
        # 1 回だけ失敗 detail を添えて再投入 (backend が retry hint を受けない
        # 実装なら同じ結果になるが、契約上 1 回試みる)。
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                              generator: gen, error_stage: "inference_retry",
                              error_detail: fail_detail)
        swift_source = @inference_backend.generate_glue(
          framework: framework, symbol: symbol, glue_id: glue_id, exported: exported
        )
      end

      @cache.record_attempt(framework: framework, symbol: symbol[:name],
                            generator: gen, error_stage: "inference_failed",
                            error_detail: reason)
      raise OutOfCoverageError.new(
        framework: framework.to_s, symbol: symbol[:name].to_s,
        pattern: symbol[:kind].to_s,
        reason: "#{reason}; inference backend #{@inference_backend.name} could not produce valid glue"
      )
    end

    def try_template(framework:, symbol:)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
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

    def compute_glue_id(framework, symbol)
      Digest::SHA256.hexdigest(
        "#{framework}|#{symbol[:name]}|#{symbol[:signature]}|#{symbol[:parameters_json]}"
      )[0, 16]
    end
  end
end
