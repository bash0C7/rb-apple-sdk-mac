# frozen_string_literal: true
require "digest"
require "fileutils"
require_relative "glue_compiler/template_generator"
require_relative "glue_compiler/validation_gates"
require_relative "glue_compiler/swiftc_invoker"
require_relative "coverage_contract"
require_relative "irb_elicitation"

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
                    coverage_contract: nil,
                    inference_budget: 3,
                    glue_store: nil)
      @cache = cache
      @runtime_dylib_path = runtime_dylib_path
      @runtime_modules_paths = runtime_modules_paths
      @template = template_generator || GlueCompiler::TemplateGenerator.new(knowledge_cache: knowledge_cache)
      @gates = gates || GlueCompiler::ValidationGates.new
      @swiftc = swiftc_invoker || GlueCompiler::SwiftcInvoker.new
      @inference_backend = inference_backend
      @contract = coverage_contract || CoverageContract.new
      @inference_budget = inference_budget
      @glue_store = glue_store
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

    # budget 付き seed-inject 閉ループ。各 attempt の失敗 detail と reject された
    # glue を次 attempt の seed に返し、backend が文脈付きで修正できるようにする。
    # budget 枯渇で loud fail (OutOfCoverageError)。
    #
    # context: ユーザが retry_with(context:) 経由で渡すヒント。Task 3 で
    # OutOfCoverageError#retry_with から再投入される配線が入る。
    def try_inference(framework:, symbol:, reason:, context: nil)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      FileUtils.mkdir_p(File.join(base, "sources"))
      FileUtils.mkdir_p(File.join(base, "lib"))
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      exported = "glue_#{glue_id}_#{swift_id}"
      gen = "inference:#{@inference_backend.name}"

      rule_scaffold = @template.generate(framework: framework, symbol: symbol, glue_id: glue_id)

      last_failure = nil
      last_glue = nil

      @inference_budget.times do
        seed = {
          rule_scaffold: rule_scaffold,
          failure_detail: last_failure,
          last_glue: last_glue,
          context: context
        }
        swift_source = @inference_backend.generate_glue(
          framework: framework, symbol: symbol,
          glue_id: glue_id, exported: exported, seed: seed
        )
        if swift_source.nil? || swift_source.empty?
          last_failure = "backend returned nil or empty glue"
          next
        end
        gate_result = @gates.validate(swift_source, framework: framework,
                                                    glue_id: glue_id, symbol: swift_id)
        unless gate_result.pass?
          last_failure = "static_check: #{gate_result.errors.join('; ')}"
          last_glue = swift_source
          next
        end
        File.write(src, swift_source)
        ok, err = @swiftc.compile(source_path: src, dylib_path: dylib,
                                  runtime_dylib_path: @runtime_dylib_path,
                                  module_search_paths: @runtime_modules_paths)
        unless ok
          last_failure = "swiftc: #{err}"
          last_glue = swift_source
          next
        end
        @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                      swift_source: swift_source, dylib_path: dylib,
                      exported_symbol: exported, generator: gen)
        @glue_store&.store(framework: framework.to_s, symbol_name: symbol[:name].to_s,
                           swift_source: swift_source)
        return Result.new(success?: true, glue_id: glue_id, generator: gen,
                          dylib_path: dylib, exported_symbol: exported)
      end

      # §3b: 対話実行中 (IRB) なら budget 枯渇時にその場で context を問い合わせ、
      # 閉ループに再投入する。context.nil? ガードで retry_with(context:) 経由
      # (既に context あり) の再試行では elicit せず、無限ループを防ぐ。
      if context.nil? && IrbElicitation.available?
        hint = IrbElicitation.elicit(framework: framework.to_s, symbol_name: symbol[:name].to_s)
        if hint
          return try_inference(framework: framework, symbol: symbol, reason: reason, context: hint)
        end
      end

      @cache.record_attempt(framework: framework, symbol: symbol[:name],
                            generator: gen, error_stage: "inference_exhausted",
                            error_detail: last_failure)
      # budget 枯渇。ユーザが retry_with(context:) で gap ヒントを渡したら
      # 同 framework/symbol/reason の inference を context 付きで再開できるよう
      # 自己再帰 lambda を error に持たせる。
      retry_proc = ->(context:) {
        try_inference(framework: framework, symbol: symbol, reason: reason, context: context)
      }
      raise OutOfCoverageError.new(
        framework: framework.to_s, symbol: symbol[:name].to_s,
        pattern: symbol[:kind].to_s,
        reason: "#{reason}; inference exhausted budget=#{@inference_budget}",
        retry_proc: retry_proc,
        last_failure_detail: last_failure
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
