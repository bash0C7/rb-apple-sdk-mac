# test/integration/inference_round_trip_poc_test.rb
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"
require "json"
require "rb_apple_sdk_knowledge"
require_relative "../../lib/apple_sdk_mac"
require_relative "../../lib/apple_sdk_mac/round_trip/harness"
require_relative "../../lib/apple_sdk_mac/round_trip/poc_loop"
require_relative "../../lib/apple_sdk_mac/inference/claude_p_backend"
require_relative "../../lib/apple_sdk_mac/glue_compiler/swiftc_invoker"
require_relative "../../lib/apple_sdk_mac/glue_compiler/template_generator"
require_relative "../../lib/apple_sdk_mac/glue_loader"

# Phase 0 PoC: env-gated proof that inference can drive a round-trip harness to
# green. Gate OFF (default) => all tests omit cleanly. Gate ON
# (RB_APPLE_SDK_MAC_POC=1) runs the real `claude -p` backend.
#
# The harness compares a directly-run Swift driver (native call) against the
# Ruby-via-glue path (compile generated glue -> dlopen -> invoke). Both sides
# observe the SAME live system value, so green means the generated glue is
# behaviorally equivalent to a hand-written native call.
class InferenceRoundTripPocTest < Test::Unit::TestCase
  # CoreAudio system-object device-list query. These exact constants are shared
  # by test/integration/audio_device_count_e2e_test.rb, so both the Swift driver
  # and the Ruby-via-glue side observe the identical byte size.
  AUDIO_OBJECT_SYSTEM = 1                # kAudioObjectSystemObject
  AUDIO_PROP_DEVICES  = 0x64657623       # 'dev#' kAudioHardwarePropertyDevices
  AUDIO_SCOPE_GLOBAL  = 0x676c6f62       # 'glob' kAudioObjectPropertyScopeGlobal
  AUDIO_ELEMENT_MAIN  = 0

  # A generated glue that fails to compile (or is malformed) is a failed attempt,
  # i.e. a round-trip RED — exactly what the closed loop must catch, feed back,
  # and retry (matching production GlueCompiler, where a compile failure yields
  # success?=false). It is NOT a test-infrastructure failure, so it must not
  # flunk: harness_check_for rescues it into green?=false so PocLoop can retry.
  GlueRed = Class.new(StandardError)

  def setup
    omit "PoC gate off (set RB_APPLE_SDK_MAC_POC=1)" unless ENV["RB_APPLE_SDK_MAC_POC"] == "1"
  end

  # 実証 1: value-type。推論が green round-trip glue を生成できる。
  def test_value_type_audio_device_count_reaches_green
    symbol = value_symbol
    backend = AppleSDKMac::Inference::ClaudePBackend.new
    loop_ = AppleSDKMac::RoundTrip::PocLoop.new(
      backend: wrap_backend(backend, symbol),
      harness_check: harness_check_for(symbol),
      budget: 4
    )
    begin
      outcome = loop_.run(
        framework: "CoreAudio", symbol: symbol, rule_scaffold: rule_scaffold_for(symbol)
      )
    rescue AppleSDKMac::RoundTrip::PocLoop::LoudFail => e
      flunk "推論が budget 内に green round-trip glue を生成できなかった: #{e.message}"
    end
    assert_true outcome.green?,
                "推論が green round-trip glue を #{outcome.attempts} 回以内に生成できること"
  end

  # 実証 2: context-resume。RED を context 注入で green に転じる。
  #
  # Strategy: run the inference loop WITHOUT framework/rule context first
  # (context: nil). The glue prompt alone may produce a RED glue (wrong key
  # lookup, wrong out-param handling). On LoudFail, retry the loop with the
  # rule scaffold injected as context — the worked template path shows the
  # exact struct-key / out-param shape — and assert it reaches green.
  def test_context_resume_turns_red_into_green
    symbol = value_symbol
    backend = AppleSDKMac::Inference::ClaudePBackend.new

    bare_loop = AppleSDKMac::RoundTrip::PocLoop.new(
      backend: wrap_backend(backend, symbol, context: nil),
      harness_check: harness_check_for(symbol),
      budget: 2
    )
    bare_outcome =
      begin
        bare_loop.run(framework: "CoreAudio", symbol: symbol, rule_scaffold: nil)
      rescue AppleSDKMac::RoundTrip::PocLoop::LoudFail
        nil # RED within bare budget — expected; resume with context below.
      end

    resume_loop = AppleSDKMac::RoundTrip::PocLoop.new(
      backend: wrap_backend(backend, symbol, context: rule_scaffold_for(symbol)),
      harness_check: harness_check_for(symbol),
      budget: 4
    )
    begin
      resume_outcome = resume_loop.run(
        framework: "CoreAudio", symbol: symbol, rule_scaffold: rule_scaffold_for(symbol)
      )
    rescue AppleSDKMac::RoundTrip::PocLoop::LoudFail => e
      flunk "context 注入後も green に転じなかった: bare=#{bare_outcome.inspect} #{e.message}\n" \
            "last glue RED detail: #{@last_glue_red}"
    end
    assert_true resume_outcome.green?,
                "context 注入で RED が green に転じること (resume attempts=#{resume_outcome.attempts})"
  end

  # ----------------------------------------------------------------------------
  # helpers (grounded in the real glue compile/invoke path)
  # ----------------------------------------------------------------------------

  private

  # value-type symbol meta for the round-trip harness. call_expr is a single
  # Swift expression yielding the byte size (immediately-invoked closure that
  # wraps the OSStatus + out-param native API the same way the Ruby glue does).
  def value_symbol
    closure = <<~SWIFT.chomp
      { () -> UInt32 in
            var addr = AudioObjectPropertyAddress(mSelector: #{AUDIO_PROP_DEVICES}, mScope: #{AUDIO_SCOPE_GLOBAL}, mElement: #{AUDIO_ELEMENT_MAIN})
            var size: UInt32 = 0
            _ = AudioObjectGetPropertyDataSize(AudioObjectID(#{AUDIO_OBJECT_SYSTEM}), &addr, 0, nil, &size)
            return size
          }()
    SWIFT
    {
      name: "AudioObjectGetPropertyDataSize",
      kind: "function",
      abi: "c",
      call_expr: closure
    }
  end

  # The args the Ruby-via-glue side passes through invoke_glue. Must match the
  # constants the Swift driver closure observes so the round-trip compares
  # like-for-like.
  def glue_invoke_args
    addr = {
      "mSelector" => AUDIO_PROP_DEVICES,
      "mScope"    => AUDIO_SCOPE_GLOBAL,
      "mElement"  => AUDIO_ELEMENT_MAIN
    }
    [AUDIO_OBJECT_SYSTEM, addr, 0, nil]
  end

  def harness_check_for(symbol)
    lambda do |glue|
      harness = AppleSDKMac::RoundTrip::Harness.new(
        swift_runner: method(:run_swift_driver),
        ruby_runner: -> { call_ruby_via_glue(glue) }
      )
      harness.check(framework: "CoreAudio", symbol: symbol, value_kind: :value).green?
    rescue GlueRed => e
      # Glue did not compile / was malformed: round-trip RED. Stash the detail so
      # an end-of-run diagnostic can surface it, then signal RED so PocLoop feeds
      # the failure back and retries (or LoudFails when budget is exhausted).
      @last_glue_red = e.message
      false
    end
  end

  # Compile the Swift driver as an EXECUTABLE (no -parse-as-library /
  # -emit-library — those skip top-level code), run it, return stdout.
  # Reuses SwiftcInvoker's -sdk/-target flags but not its library-emit flags.
  def run_swift_driver(swift_source)
    sdk = AppleSDKKnowledge::SDK.path
    swiftc = ENV["RB_APPLE_SDK_MAC_SWIFTC"] || "swiftc"
    Dir.mktmpdir("rt_driver") do |dir|
      src = File.join(dir, "driver.swift")
      bin = File.join(dir, "driver")
      File.write(src, swift_source)
      args = ["-target", "arm64-apple-macos26.0", "-sdk", sdk, "-o", bin, src]
      out, err, status = Open3.capture3(swiftc, *args)
      unless status.success?
        flunk "swift driver compile failed: #{err}\n--- source ---\n#{swift_source}"
      end
      run_out, run_err, run_status = Open3.capture3(bin)
      unless run_status.success?
        flunk "swift driver run failed: #{run_err}\n#{run_out}"
      end
      run_out
    end
  end

  # Take a generated glue Swift source string, compile it to a dylib via the
  # real SwiftcInvoker (the production library-emit path), load via GlueLoader,
  # invoke with the matching args, return the Int.
  #
  # The exported symbol name is parsed from the glue source itself
  # (`public func glue_<id>_<name>`), so this works for both the hand-written
  # known-good glue and inference-generated glue.
  def call_ruby_via_glue(glue)
    exported = extract_exported_symbol(glue)
    Dir.mktmpdir("rt_glue") do |dir|
      src = File.join(dir, "glue.swift")
      dylib = File.join(dir, "glue.dylib")
      File.write(src, glue)
      invoker = AppleSDKMac::GlueCompiler::SwiftcInvoker.new
      ok, err = invoker.compile(
        source_path: src, dylib_path: dylib,
        runtime_dylib_path: runtime_dylib_path,
        module_search_paths: runtime_modules_paths
      )
      raise GlueRed, "glue did not compile (round-trip RED): #{err}\n--- source ---\n#{glue}" unless ok
      loader = AppleSDKMac::GlueLoader.new
      fn_ptr = loader.load(dylib_path: dylib, exported_symbol: exported)
      loader.invoke(fn_ptr, glue_invoke_args)
    end
  end

  # Adapter: PocLoop calls backend.generate_glue(framework:, symbol:, seed:),
  # but ClaudePBackend#generate_glue takes (framework:, symbol:, glue_id:,
  # exported:). This wrapper computes a stable glue_id/exported for the symbol,
  # folds the seed (rule_scaffold / failure_detail / last_glue / context) into the
  # symbol meta the backend prompts on, and delegates to the real backend.
  def wrap_backend(backend, symbol, context: nil)
    test = self
    glue_id = test.send(:glue_id_for, symbol)
    swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
    exported = "glue_#{glue_id}_#{swift_id}"
    Object.new.tap do |adapter|
      adapter.define_singleton_method(:generate_glue) do |framework:, symbol:, seed:|
        enriched = test.send(:enrich_symbol_with_seed, symbol, seed, context)
        # ClaudePBackend は BackendResult を返す。PocLoop は glue 文字列を期待する
        # ので swift_source を取り出す (round-trip 駆動入力は PoC では未使用)。
        result = backend.generate_glue(
          framework: framework, symbol: enriched,
          glue_id: glue_id, exported: exported
        )
        result&.swift_source
      end
    end
  end

  # Fold seed/context into the symbol's signature/parameters_json fields so the
  # real ClaudePBackend prompt (which only reads symbol[:signature] and
  # symbol[:parameters_json]) carries the rule scaffold and prior-failure
  # context. This is the only channel ClaudePBackend#build_prompt exposes.
  def enrich_symbol_with_seed(symbol, seed, context)
    sig_parts = [native_signature]
    rule = seed && (seed[:rule_scaffold] || context)
    if rule
      sig_parts << "// Reference (rule scaffold) — emit glue with the SAME struct-key lookups, out-param handling, and exported function name:\n#{rule}"
    end
    if seed && seed[:failure_detail]
      sig_parts << "// Previous attempt was REJECTED (round-trip RED): #{seed[:failure_detail]}. Fix the glue."
    end
    if seed && seed[:last_glue]
      sig_parts << "// Previous (rejected) glue:\n#{seed[:last_glue]}"
    end
    enriched = symbol.dup
    enriched[:signature] = sig_parts.join("\n")
    enriched[:parameters_json] = native_parameters_json
    enriched
  end

  # Native C signature + params for AudioObjectGetPropertyDataSize. The backend
  # prompt reads these so the model knows the call shape.
  def native_signature
    "OSStatus AudioObjectGetPropertyDataSize(AudioObjectID inObjectID, " \
    "const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, " \
    "const void *inQualifierData, UInt32 *outDataSize)"
  end

  def native_parameters_json
    JSON.dump([
      { "name" => "inObjectID", "kind" => "uint32" },
      { "name" => "inAddress", "kind" => "struct_in", "struct" => "AudioObjectPropertyAddress",
        "keys" => %w[mSelector mScope mElement] },
      { "name" => "inQualifierDataSize", "kind" => "uint32" },
      { "name" => "inQualifierData", "kind" => "void_ptr_nilable" },
      { "name" => "outDataSize", "kind" => "uint32", "is_out_param" => true }
    ])
  end

  # rule scaffold seed = the real template-generated glue for this symbol. Uses
  # the production TemplateGenerator against the Knowledge Base so the seed is
  # the canonical worked example, not a hand-stub.
  def rule_scaffold_for(symbol)
    AppleSDKMac.bootstrap!
    kc = AppleSDKMac.knowledge_cache
    rec = kc.lookup_symbol(framework: "CoreAudio", symbol: symbol[:name])
    omit "Knowledge Base miss for #{symbol[:name]}; cannot build rule scaffold" unless rec
    gen = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    src = gen.generate(framework: "CoreAudio", symbol: rec, glue_id: glue_id_for(symbol))
    omit "TemplateGenerator returned nil for #{symbol[:name]}" if src.nil?
    src
  end

  def glue_id_for(symbol)
    Digest::SHA256.hexdigest("poc|CoreAudio|#{symbol[:name]}")[0, 16]
  end

  # Parse `public func glue_<id>_<name>(` to recover the exported C symbol.
  def extract_exported_symbol(glue)
    m = glue.match(/public\s+func\s+(glue_[A-Za-z0-9_]+)\s*\(/)
    raise GlueRed, "malformed glue (round-trip RED): no exported glue_<id>_<name> function found" unless m
    m[1]
  end

  # Mirror PublicAPI's private runtime_dylib_path / runtime_modules_paths so the
  # glue links against the Swift runtime when present. These reference
  # AppleSDKMacRuntime symbols (runtime_arc_box_cftype etc.) only when used; the
  # value-type path does not, but linking is harmless.
  # test file lives at <gem>/test/integration/, so gem root is two levels up.
  GEM_ROOT = File.expand_path("../..", __dir__)

  def runtime_dylib_path
    dylib = File.join(GEM_ROOT, "ext/apple_sdk_mac_runtime/.build/arm64-apple-macosx/release/libAppleSDKMacRuntime.dylib")
    File.exist?(dylib) ? dylib : nil
  end

  def runtime_modules_paths
    [File.join(GEM_ROOT, "ext/apple_sdk_mac_runtime/.build/arm64-apple-macosx/release/Modules")].select { |p| File.directory?(p) }
  end
end
