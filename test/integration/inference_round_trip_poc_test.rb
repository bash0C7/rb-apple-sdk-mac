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

class InferenceRoundTripPocTest < Test::Unit::TestCase
  AUDIO_OBJECT_SYSTEM = 1
  AUDIO_PROP_DEVICES  = 0x64657623
  AUDIO_SCOPE_GLOBAL  = 0x676c6f62
  AUDIO_ELEMENT_MAIN  = 0

  GlueRed = Class.new(StandardError)

  def setup
    omit "PoC gate off (set RB_APPLE_SDK_MAC_POC=1)" unless ENV["RB_APPLE_SDK_MAC_POC"] == "1"
  end

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
        nil
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

  private

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
      @last_glue_red = e.message
      false
    end
  end

  def run_swift_driver(swift_source)
    sdk = AppleSDKKnowledge::SDK.path
    Dir.mktmpdir("rt_driver") do |dir|
      src = File.join(dir, "driver.swift")
      bin = File.join(dir, "driver")
      File.write(src, swift_source)
      args = ["-target", "arm64-apple-macos27.0", "-sdk", sdk, "-o", bin, src]
      out, err, status = Open3.capture3("xcrun", "swiftc", *args)
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

  def wrap_backend(backend, symbol, context: nil)
    test = self
    glue_id = test.send(:glue_id_for, symbol)
    swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
    exported = "glue_#{glue_id}_#{swift_id}"
    Object.new.tap do |adapter|
      adapter.define_singleton_method(:generate_glue) do |framework:, symbol:, seed:|
        enriched = test.send(:enrich_symbol_with_seed, symbol, seed, context)
        result = backend.generate_glue(
          framework: framework, symbol: enriched,
          glue_id: glue_id, exported: exported
        )
        result&.swift_source
      end
    end
  end

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

  def extract_exported_symbol(glue)
    m = glue.match(/public\s+func\s+(glue_[A-Za-z0-9_]+)\s*\(/)
    raise GlueRed, "malformed glue (round-trip RED): no exported glue_<id>_<name> function found" unless m
    m[1]
  end


  def runtime_dylib_path
    dylib = File.join(AppleSDKMac::RUNTIME_BUILD_DIR, "libAppleSDKMacRuntime.dylib")
    File.exist?(dylib) ? dylib : nil
  end

  def runtime_modules_paths
    [AppleSDKMac::RUNTIME_BUILD_DIR]
  end
end
