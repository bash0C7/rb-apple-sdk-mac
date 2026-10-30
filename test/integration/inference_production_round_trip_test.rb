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

class InferenceProductionRoundTripTest < Test::Unit::TestCase
  class AlwaysUncovered
    def covered?(_symbol) = false
    def uncovered_reason(_symbol) = "uncovered shape: e2e forced inference boundary"
  end

  class NilTemplate
    def generate(framework:, symbol:, glue_id:) = nil
  end


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

    rtt_path = glue_store.round_trip_test_path(framework: "CoreAudio",
                                               symbol_name: "AudioObjectGetPropertyDataSize")
    assert File.exist?(rtt_path), "round_trip_test must be persisted in Tier 1"
    assert_false File.read(rtt_path).empty?, "round_trip_test must be non-empty"

    prov = glue_store.provenance_entries.first
    assert_not_nil prov, "provenance sidecar must exist"
    assert_match(/\Agreen:/, prov["round_trip_outcome"],
                 "round_trip_outcome must record a green proof")

    rec = AppleSDKMac::ExportBundle.from_glue_store(glue_store).first
    assert_not_nil rec
    assert_match(/\Agreen:/, rec.round_trip_outcome,
                 "Tier 3 export must carry the round_trip_outcome green proof")
  ensure
    cache&.close
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
