# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "fileutils"
require "rb_apple_sdk_knowledge"
require_relative "../../lib/apple_sdk_mac"
require_relative "../../lib/apple_sdk_mac/glue_compiler"
require_relative "../../lib/apple_sdk_mac/round_trip/production_runner"
require_relative "../../lib/apple_sdk_mac/inference/backend"

class RetryReloadsRecompiledGlueTest < Test::Unit::TestCase

  class TwoAttemptBackend
    def initialize
      @calls = 0
    end

    def name = "claude_p"

    def generate_glue(framework:, symbol:, glue_id:, exported:, seed:)
      @calls += 1
      val = @calls == 1 ? 999 : 42
      swift = <<~SWIFT
        import Foundation
        import AppleSDKMacRuntime
        @c public func #{exported}(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
            return UInt(#{val}) << 1 | 1
        }
      SWIFT
      AppleSDKMac::Inference::BackendResult.new(
        swift_source: swift,
        driver_inputs: { call_expr: "42", invoke_args: [], value_kind: :value }
      )
    end
  end

  class PassGates
    Res = Struct.new(:pass?, :errors)
    def validate(*) = Res.new(true, [])
  end

  class FakeCache
    attr_reader :base_dir, :sdk_version
    def initialize(base_dir)
      @base_dir = base_dir
      @sdk_version = "test"
    end

    def insert(**) ; end
    def record_attempt(**) ; end
  end

  class NilTemplate
    def generate(framework:, symbol:, glue_id:) = nil
  end

  class AlwaysUncovered
    def covered?(_symbol) = false
    def uncovered_reason(_symbol) = "uncovered shape: retry-reload regression"
  end

  def setup
    omit "runtime dylib not built (run rake compile)" unless runtime_dylib_path
    @base = Dir.mktmpdir("retry_reload")
  end

  def teardown
    FileUtils.remove_entry(@base) if @base && File.exist?(@base)
  end

  def test_attempt2_recompiled_glue_is_reinvoked_and_reaches_green
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: FakeCache.new(@base),
      runtime_dylib_path: runtime_dylib_path,
      runtime_modules_paths: runtime_modules_paths,
      gates: PassGates.new,
      template_generator: NilTemplate.new,
      inference_backend: TwoAttemptBackend.new,
      coverage_contract: AlwaysUncovered.new,
      round_trip_runner: AppleSDKMac::RoundTrip::ProductionRunner.new(sdk_path: AppleSDKKnowledge::SDK.path),
      glue_store: nil,
      inference_budget: 3
    )
    sym = { name: "FakeReloadSym", signature: "int FakeReloadSym(void)",
            parameters_json: "[]", kind: "function" }

    result = compiler.compile(framework: "CoreAudio", symbol: sym)

    assert_true result.success?,
                "attempt2 の再コンパイル glue が実際に再 invoke されれば GREEN に到達する " \
                "(stale だと attempt1 の ruby=999 で固定され RED のまま): #{result.error_detail}"
    assert_equal "inference:claude_p", result.generator
  end

  private

  def runtime_dylib_path
    dylib = File.join(AppleSDKMac::RUNTIME_BUILD_DIR, "libAppleSDKMacRuntime.dylib")
    File.exist?(dylib) ? dylib : nil
  end

  def runtime_modules_paths
    [AppleSDKMac::RUNTIME_BUILD_DIR]
  end
end
