# test/integration/retry_reloads_recompiled_glue_test.rb
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "fileutils"
require "rb_apple_sdk_knowledge"
require_relative "../../lib/apple_sdk_mac"
require_relative "../../lib/apple_sdk_mac/glue_compiler"
require_relative "../../lib/apple_sdk_mac/round_trip/production_runner"
require_relative "../../lib/apple_sdk_mac/inference/backend"

# 回帰テスト: try_inference の閉ループで attempt 2 以降が「再コンパイルした新しい glue」を
# 実際に再 invoke できることを、実 swiftc / 実 ProductionRunner / 実 GlueLoader で実証する。
# 実 claude -p は使わない (決定論 backend) のでミリ秒〜秒で走る。
#
# 失敗モード (fix 前): 全 attempt が同一 exported symbol + 同一 dylib パスを使い、
# ProductionRunner の GlueLoader が attempt 1 の関数ポインタをキャッシュ短絡し、
# かつ dlopen が同一パスの再コンパイル済みイメージを再ロードしない。結果、attempt 2 が
# 正しい glue を出しても ruby 側は attempt 1 の値で固定 → round-trip RED 固定 → 精度の天井。
class RetryReloadsRecompiledGlueTest < Test::Unit::TestCase
  GEM_ROOT = File.expand_path("../..", __dir__)

  # attempt 1 は ruby=999 を返す glue (swift=42 と不一致 → RED)、
  # attempt 2 以降は ruby=42 を返す glue (swift=42 と一致 → GREEN) を返す。
  # 返り値は Ruby Fixnum エンコード (n<<1)|1 を直接組むので Apple API も rb_* extern も不要。
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

  # gate 検証はこのテストの関心外 (staleness とは直交) なので素通しする。
  class PassGates
    Res = Struct.new(:pass?, :errors)
    def validate(*) = Res.new(true, [])
  end

  # try_inference が触る最小限 (base_dir / sdk_version / insert / record_attempt)。
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
    dylib = File.join(GEM_ROOT, "ext/apple_sdk_mac_runtime/.build/arm64-apple-macosx/release/libAppleSDKMacRuntime.dylib")
    File.exist?(dylib) ? dylib : nil
  end

  def runtime_modules_paths
    [File.join(GEM_ROOT, "ext/apple_sdk_mac_runtime/.build/arm64-apple-macosx/release/Modules")].select { |p| File.directory?(p) }
  end
end
