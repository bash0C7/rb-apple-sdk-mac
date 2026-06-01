# test/integration/inference_production_round_trip_test.rb
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "fileutils"
require "json"
require "rb_apple_sdk_knowledge"
require_relative "../../lib/apple_sdk_mac"
require_relative "../../lib/apple_sdk_mac/glue_compiler"
require_relative "../../lib/apple_sdk_mac/glue_store"
require_relative "../../lib/apple_sdk_mac/export_bundle"
require_relative "../../lib/apple_sdk_mac/inference/claude_p_backend"
require_relative "../../lib/apple_sdk_mac/round_trip/production_runner"
require_relative "../../lib/apple_sdk_mac/compiled_glue_cache"

# gate-ON end-to-end 価値実証: ルールで覆えない実在 symbol が、実 claude -p 推論で
# round-trip GREEN な glue を生み、それが Tier 1 に round_trip_test 付きで永続化され、
# Tier 3 export が round_trip_outcome 付き green 証跡を含む。実 claude -p / 実 swiftc /
# 実 ProductionRunner を production default 配線で通す (mock 無し)。
#
# Gate OFF (default) => omit。Gate ON (RB_APPLE_SDK_MAC_POC=1) => 実走。
class InferenceProductionRoundTripTest < Test::Unit::TestCase
  # 常に uncovered を返す契約 + 常に nil を返す template。compile は「template 成功
  # なら即 return」なので、inference 経路を exercise するには template が覆えない
  # (nil) かつ契約が uncovered を返す状況が要る = 「rule base がこの symbol を
  # 覆っていない」の忠実な再現。symbol のメタ (real signature / params_json) は実物の
  # まま LLM prompt に流れ、glue は live system に対して round-trip 検証される。
  class AlwaysUncovered
    def covered?(_symbol) = false
    def uncovered_reason(_symbol) = "uncovered shape: e2e forced inference boundary"
  end

  class NilTemplate
    def generate(framework:, symbol:, glue_id:) = nil
  end

  GEM_ROOT = File.expand_path("../..", __dir__)

  def setup
    omit "PoC gate off (set RB_APPLE_SDK_MAC_POC=1)" unless ENV["RB_APPLE_SDK_MAC_POC"] == "1"
    @project_dir = Dir.mktmpdir("rt_e2e_store")
    @cache_dir = Dir.mktmpdir("rt_e2e_cache")
  end

  def teardown
    [@project_dir, @cache_dir].each { |d| FileUtils.remove_entry(d) if d && File.exist?(d) }
  end

  def test_uncovered_symbol_reaches_green_round_trip_and_persists_through_tier3
    AppleSDKMac.bootstrap!
    sdk_version = AppleSDKKnowledge::SDK.version
    kc = AppleSDKMac.knowledge_cache

    # 実在 symbol: CoreAudio システムオブジェクトのプロパティバイトサイズ取得。
    # 値は live system 設定なので 2 経路 (swift 直走 / ruby-via-glue) で安定一致する。
    record = kc.lookup_symbol(framework: "CoreAudio", symbol: "AudioObjectGetPropertyDataSize")
    omit "Knowledge Base miss for AudioObjectGetPropertyDataSize" unless record

    cache = AppleSDKMac::CompiledGlueCache.open(@cache_dir, sdk_version: sdk_version)
    glue_store = AppleSDKMac::GlueStore.new(project_dir: @project_dir, sdk_version: sdk_version)

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache,
      runtime_dylib_path: runtime_dylib_path,
      runtime_modules_paths: runtime_modules_paths,
      knowledge_cache: kc,
      template_generator: NilTemplate.new,
      inference_backend: AppleSDKMac::Inference::ClaudePBackend.new,
      coverage_contract: AlwaysUncovered.new,
      round_trip_runner: AppleSDKMac::RoundTrip::ProductionRunner.new(sdk_path: AppleSDKKnowledge::SDK.path),
      glue_store: glue_store,
      inference_budget: 5
    )

    result = compiler.compile(framework: "CoreAudio", symbol: record)
    assert_true result.success?,
                "uncovered symbol must reach a green round-trip via inference: #{result.error_detail}"
    assert_equal "inference:claude_p", result.generator

    # Tier 1: round_trip_test が永続化され非空。
    rtt_path = glue_store.round_trip_test_path(framework: "CoreAudio",
                                               symbol_name: "AudioObjectGetPropertyDataSize")
    assert File.exist?(rtt_path), "round_trip_test must be persisted in Tier 1"
    assert_false File.read(rtt_path).empty?, "round_trip_test must be non-empty"

    # provenance: round_trip_outcome が green 証跡。
    prov = glue_store.provenance_entries.first
    assert_not_nil prov, "provenance sidecar must exist"
    assert_match(/\Agreen:/, prov["round_trip_outcome"],
                 "round_trip_outcome must record a green proof")

    # Tier 3: ExportBundle まで green 証跡が流れる。
    rec = AppleSDKMac::ExportBundle.from_glue_store(glue_store).first
    assert_not_nil rec
    assert_match(/\Agreen:/, rec.round_trip_outcome,
                 "Tier 3 export must carry the round_trip_outcome green proof")
  ensure
    cache&.close
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
