# frozen_string_literal: true
require "test_helper"
require "json"
require "apple_sdk_mac/glue_compiler/llm_generator"

class TestLLMGenerator < Test::Unit::TestCase
  class StubSession
    attr_reader :captured_instructions, :captured_prompts, :scripted_response

    def initialize(scripted_response:, instructions: nil, model: nil)
      @scripted_response = scripted_response
      @captured_instructions = instructions
      @captured_prompts = []
    end

    def respond(to:)
      @captured_prompts << to
      @scripted_response
    end

    def close
    end
  end

  def test_generate_post_processes_markdown_fences
    canned = "```swift\nimport AcmeFW\n@c public func glue_deadbeef_asyncFetchTitle(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }\n```"
    stub = StubSession.new(scripted_response: canned)
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new(session: stub)
    sym = {
      name: "asyncFetchTitle",
      kind: "function", abi: "swift",
      signature: "func asyncFetchTitle(_ url: URL) async throws -> String",
      parameters_json: JSON.dump([{ "name" => "url", "type" => "URL" }])
    }
    swift = gen.generate(framework: "AcmeFW", symbol: sym, glue_id: "deadbeef")
    refute_nil swift
    assert_match(/import AcmeFW/, swift)
    assert_match(/glue_deadbeef_asyncFetchTitle/, swift)
    assert_no_match(/```/, swift)
  end

  def test_generate_returns_nil_for_empty_response
    stub = StubSession.new(scripted_response: "")
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new(session: stub)
    sym = { name: "X", kind: "function", abi: "swift", signature: "", parameters_json: "[]" }
    assert_nil gen.generate(framework: "Foo", symbol: sym, glue_id: "a")
  end

  def test_prompt_includes_framework_signature_and_glue_id
    stub = StubSession.new(scripted_response: "@c public func glue_g_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }")
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new(session: stub)
    sym = {
      name: "fetchTitle",
      kind: "function", abi: "swift",
      signature: "func fetchTitle(_ url: URL) -> String",
      parameters_json: JSON.dump([{ "name" => "url", "type" => "URL" }])
    }
    gen.generate(framework: "AcmeFW", symbol: sym, glue_id: "g")
    prompt = stub.captured_prompts.first
    assert_match(/framework: AcmeFW/, prompt)
    assert_match(/glue_id: g/, prompt)
    assert_match(/fetchTitle/, prompt)
  end

  def test_live_ollama_returns_some_swift
    omit "set RB_APPLE_SDK_MAC_LIVE_LLM=1 to exercise live Ollama" unless ENV["RB_APPLE_SDK_MAC_LIVE_LLM"] == "1"
    omit "rb-foundation-model-mac required for live LLM test" unless defined?(::AppleFoundationModel)
    sym = {
      name: "asyncFetchTitle",
      kind: "function", abi: "swift",
      signature: "func asyncFetchTitle(_ url: URL) async throws -> String",
      parameters_json: JSON.dump([{ "name" => "url", "type" => "URL" }])
    }
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    swift = gen.generate(framework: "AcmeFW", symbol: sym, glue_id: "deadbeef")
    refute_nil swift
    assert_match(/glue_deadbeef_asyncFetchTitle/, swift)
  end

  def test_instructions_specify_bare_at_c_attribute_on_own_line
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_includes instructions, "@c\npublic func",
      "INSTRUCTIONS must show `@c` on its own line above `public func` somewhere; " \
      "regex GATE 5 (`/@c\\s+public\\s+func\\s+(\\w+)/`) requires whitespace-separated tokens."
    assert_match(/^[ \t]+@c[ \t]*\n[ \t]+public func/, instructions,
      "Section 1 Rule 2's indented prose example must independently show " \
      "`@c` on its own indented line above `public func` — pinning Rule 2 " \
      "independently of WORKED_EXAMPLE so a Rule 2 regression is caught.")
  end

  def test_instructions_embed_silgen_name_header_literally
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_includes instructions, '@_silgen_name("rb_str_new_cstr")',
      "INSTRUCTIONS must embed the @_silgen_name header from TemplateGenerator::HEADER " \
      "so the LLM does not hallucinate signatures."
  end

  def test_instructions_have_no_phantom_runtime_api_references
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    refute_match(/Marshal\.(fromRuby|toRuby)/, instructions,
      "Marshal.fromRubyXXX / Marshal.toRuby do not exist in AppleSDKMacRuntime; " \
      "instructing the LLM to use them is the root cause of GATE 5 + compile failures.")
    refute_match(/ErrorBridge/, instructions,
      "ErrorBridge.swift was deleted in commit b262e18; raise via @_silgen_name rb_raise.")
    refute_match(/ConformanceBridge/, instructions,
      "ConformanceBridge.lookup does not exist with the prompt-implied signature; " \
      "the runtime ConformanceBridge has register/release/lookup(handle:) only.")
  end

  def test_instructions_do_not_reintroduce_at_c_attributed_prose
    refute_match(/@c-attributed/, AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS,
      "The phrase `@c-attributed` was the original GATE 5 trigger: the LLM " \
      "rendered the English prose as literal Swift syntax. This guard prevents " \
      "any future rule wording that would reintroduce the same hyphenated form.")
  end

  def test_instructions_rule_9_describes_callback_pillar_register_for_catalog_callbacks
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/runtime_callback_pillar_register_midi_notify/, instructions,
      "Rule 9 must describe the CallbackPillar register pathway for catalog " \
      "callbacks (currently MIDINotifyProc). The deterministic template path " \
      "uses this; the LLM fallback must agree to avoid contradictory glue.")
    assert_match(/unsafeBitCast/, instructions,
      "Rule 9 must show the unsafeBitCast step that converts the raw fnptr " \
      "from runtime_callback_pillar_get_<route>_fnptr to the typed Apple SDK " \
      "callback type.")
  end

  def test_instructions_demonstrate_string_input_marshalling_literally
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/var v0 = argv\[0\]/, instructions,
      "WORKED_EXAMPLE must include the literal `var v0 = argv[0]` binding line. " \
      "Comment-only mention (`var v_i = argv[i]`) leaves the LLM extrapolating " \
      "and getting it wrong — root cause of verification id=1 swiftc fail where " \
      "the model wrote `rb_string_value_cstr(argv[0])` (UInt, not pointer).")
    assert_match(/String\(cString: rb_string_value_cstr\(&v0\)\)/, instructions,
      "WORKED_EXAMPLE must show the full string-input chain: bound `var v0` " \
      "then `&v0` passed to `rb_string_value_cstr` inside `String(cString:)`. " \
      "Pinning all three pieces together prevents the LLM from substituting " \
      "any one piece independently (the failure mode in the verification log).")
  end

  # Task 18: HEADER auto-sync + new worked examples for struct_in and multi-out.
  def test_instructions_embed_extended_header_silgen_names
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_includes instructions, '@_silgen_name("rb_hash_new")'
    assert_includes instructions, '@_silgen_name("rb_hash_aref")'
    assert_includes instructions, '@_silgen_name("rb_hash_aset")'
  end

  def test_instructions_have_struct_in_worked_example
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/var\s+\w+_struct\s*=\s*\w+\(\)/, instructions,
      "INSTRUCTIONS must include a struct_in worked example showing " \
      "`var <name>_struct = <Type>()` so the LLM can follow the field-by-field " \
      "Hash-aref pattern when handling Apple struct parameters (CGRect, MIDIPacketList, etc.).")
    assert_match(/rb_hash_aref/, instructions,
      "struct_in worked example must show rb_hash_aref-based field load.")
  end

  def test_instructions_have_multi_out_hash_worked_example
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/let\s+\w+_h\s*=\s*rb_hash_new\(\)/, instructions,
      "INSTRUCTIONS must include a multi-out worked example showing " \
      "`let <name>_h = rb_hash_new()` so the LLM can build the named-key " \
      "Ruby Hash return for symbols with ≥2 out-params.")
    assert_match(/rb_hash_aset/, instructions)
  end

  # T3a — async Worked Examples E1-E4. These constrain the LLM to a
  # single fixed async-shape so ValidationGates can mechanically verify each
  # generated glue file (DispatchSemaphore + Task { do { try await ... } catch
  # { captured = error } sema.signal() } sema.wait() + post-wait raise).
  def test_instructions_contain_e1_single_await_pattern
    ins = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/Example E1/, ins,
      "Worked Example E1 (single await) must anchor the async-shape pattern.")
    assert_match(/DispatchSemaphore\(value:\s*0\)/, ins)
    assert_match(/sema\.wait\(\)/, ins)
    assert_match(/try\s+await/, ins)
  end

  def test_instructions_contain_e2_taskgroup_pattern
    ins = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/Example E2/, ins, "Worked Example E2 (TaskGroup) required.")
    assert_match(/withThrowingTaskGroup/, ins)
  end

  def test_instructions_contain_e3_async_let_pattern
    ins = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/Example E3/, ins, "Worked Example E3 (async let) required.")
    assert_match(/async\s+let/, ins)
  end

  def test_instructions_contain_e4_main_actor_pattern
    ins = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/Example E4/, ins, "Worked Example E4 (@MainActor.run) required.")
    assert_match(/await\s+MainActor\.run/, ins)
  end

  # T3b — ObjC Worked Examples F1, F2, G. ObjC method dispatch via
  # Swift's bridged class names; no manual objc_msgSend.
  def test_instructions_contain_f1_alloc_init
    ins = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/Example F1/, ins, "Worked Example F1 (alloc/init) required.")
    assert_match(/Unmanaged\.passRetained/, ins)
  end

  def test_instructions_contain_f2_class_method
    ins = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/Example F2/, ins, "Worked Example F2 (class method) required.")
    assert_match(/stringWithUTF8String/, ins)
  end

  def test_instructions_contain_g_objc_with_completion_block
    ins = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_match(/Example G/, ins, "Worked Example G (ObjC + completion block) required.")
  end

  # postmortem 2026-05-14 #2: Foundation Models LM の 4096-token context window
  # に対し、 KB miss 経路の prompt が 4089-4091 tokens で exceededContextWindowSize。
  # KEEP_FOR_FAMILY による example slicing は既に有り、 prose 側も family ごとに
  # 不要 rule を strip して margin を確保する。 :swift / :objc family は C function
  # pointer callback (rule 9) を一切扱わへんため、 instructions_for で strip。
  # :c family は維持 (CoreMIDI 等 C 関数の callback が常用される)。
  def test_instructions_for_swift_family_strips_c_callback_rule
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    text = gen.send(:instructions_for, :swift)
    refute_match(/MIDINotifyProc/, text,
      ":swift family の instructions は C callback rule (MIDINotifyProc) を含まない")
    refute_match(/runtime_callback_pillar_register_midi_notify/, text,
      ":swift family は callback pillar register を一切参照しない")
    assert_operator text.length, :<, AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS.length,
      ":swift family pruned text は full INSTRUCTIONS より短い"
  end

  def test_instructions_for_objc_family_strips_c_callback_rule
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    text = gen.send(:instructions_for, :objc)
    refute_match(/MIDINotifyProc/, text,
      ":objc family も ObjC 経路で C callback pillar を使わへんので strip")
    refute_match(/runtime_callback_pillar_register_midi_notify/, text,
      ":objc family は callback pillar register を一切参照しない")
  end

  def test_instructions_for_c_family_preserves_callback_rule
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    text = gen.send(:instructions_for, :c)
    assert_match(/MIDINotifyProc/, text,
      ":c family は C function callback (MIDINotifyProc) を扱うので prose 維持")
    assert_match(/runtime_callback_pillar_register_midi_notify/, text,
      ":c family は callback pillar register を参照する")
  end
end
