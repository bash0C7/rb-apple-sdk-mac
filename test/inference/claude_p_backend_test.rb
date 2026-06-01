# frozen_string_literal: true

require "test_helper"

class ClaudePBackendTest < Test::Unit::TestCase
  SYM = {
    name: "AudioObjectGetPropertyDataSize", kind: "function", abi: "c",
    signature: "(AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32, UnsafeMutablePointer<UInt32>) -> OSStatus",
    parameters_json: "[]"
  }.freeze

  # runner を inject して claude を呼ばずにテスト。
  def build(runner)
    AppleSDKMac::Inference::ClaudePBackend.new(runner: runner)
  end

  def test_name_is_claude_p
    assert_equal "claude_p", build(->(_p) { "" }).name
  end

  def test_prompt_includes_gate_constraints_and_symbol
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc123", exported: "glue_abc123_AudioObjectGetPropertyDataSize")
    assert_match(/AudioObjectGetPropertyDataSize/, captured)
    assert_match(/glue_abc123_AudioObjectGetPropertyDataSize/, captured)
    assert_match(/import/i, captured)        # import 制約を明記
    assert_match(/AppleSDKMacRuntime/, captured)
    assert_match(/@c public func/, captured) # export shape を明記
  end

  # 主経路 A: round-trip 駆動入力 (call_expr / invoke_args / value_kind) を返す
  # json ブロックをプロンプトで要求する。
  def test_prompt_requests_driver_inputs_json_block
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc123", exported: "glue_abc123_x")
    assert_match(/```json/, captured)
    assert_match(/call_expr/, captured)
    assert_match(/invoke_args/, captured)
    assert_match(/value_kind/, captured)
  end

  def test_extracts_swift_into_backend_result
    runner = ->(_p) { "blah\n```swift\n@c public func glue_x() {}\n```\ntrailing" }
    result = build(runner).generate_glue(framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x")
    assert_equal "@c public func glue_x() {}", result.swift_source.strip
  end

  def test_returns_nil_when_no_swift_block
    runner = ->(_p) { "I cannot help with that." }
    result = build(runner).generate_glue(framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x")
    assert_nil result
  end

  # A path: swift + json の両ブロックが返れば driver_inputs を組み立てる。
  def test_parses_driver_inputs_from_json_block
    response = <<~RESP
      ```swift
      @c public func glue_x() -> UInt32 { 0 }
      ```
      ```json
      {"call_expr": "answer()", "invoke_args": [1, null, {"k": 2}], "value_kind": "value"}
      ```
    RESP
    result = build(->(_p) { response }).generate_glue(
      framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x"
    )
    assert_equal "answer()", result.driver_inputs[:call_expr]
    assert_equal [1, nil, { "k" => 2 }], result.driver_inputs[:invoke_args]
    assert_equal :value, result.driver_inputs[:value_kind]
  end

  # setter は read_expr / set_expr / set_value も拾う。
  def test_parses_setter_driver_inputs
    response = <<~RESP
      ```swift
      @c public func glue_x() {}
      ```
      ```json
      {"call_expr": "x", "value_kind": "setter", "read_expr": "r()", "set_expr": "s()", "set_value": "42"}
      ```
    RESP
    di = build(->(_p) { response }).generate_glue(
      framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x"
    ).driver_inputs
    assert_equal :setter, di[:value_kind]
    assert_equal "r()", di[:read_expr]
    assert_equal "s()", di[:set_expr]
    assert_equal "42", di[:set_value]
  end

  # C fallback に委ねるため、json 欠損は driver_inputs nil。
  def test_driver_inputs_nil_when_no_json_block
    runner = ->(_p) { "```swift\n@c public func glue_x() {}\n```" }
    result = build(runner).generate_glue(framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x")
    assert_not_nil result.swift_source
    assert_nil result.driver_inputs
  end

  # 壊れた json は loud に握り潰さず nil 縮退 (C fallback へ)。
  def test_driver_inputs_nil_on_malformed_json
    response = "```swift\n@c public func glue_x() {}\n```\n```json\n{not valid json\n```"
    result = build(->(_p) { response }).generate_glue(
      framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x"
    )
    assert_not_nil result.swift_source
    assert_nil result.driver_inputs
  end

  # 必須 key (call_expr / value_kind) 欠損も nil 縮退。
  def test_driver_inputs_nil_when_required_keys_missing
    response = "```swift\n@c public func glue_x() {}\n```\n```json\n{\"invoke_args\": []}\n```"
    result = build(->(_p) { response }).generate_glue(
      framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x"
    )
    assert_nil result.driver_inputs
  end

  # 失敗モード #2 固定: out-param OSStatus API で「glue が返す値」が戻り OSStatus か
  # out-param か曖昧で LLM が attempt 間で揺れる。prompt に対比的 worked example を
  # 焼き込み、(A) 直接値 / (B) OSStatus+out-param を並置して判別を pin する。
  def test_prompt_includes_worked_examples_for_call_expr
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc", exported: "glue_abc_Sym")
    assert_match(/WORKED EXAMPLE/, captured)
  end

  # out-param 例が「OSStatus 戻り値は値ではなく out-param が観測値」を明示すること。
  def test_worked_example_pins_outparam_over_osstatus
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc", exported: "glue_abc_Sym")
    assert_match(/out-param/i, captured)
    assert_match(/OSStatus/, captured)
    # call_expr が out-param 値を yield する形 (関数戻り値=status を返さない) を示すこと。
    assert_match(/NOT the (returned )?OSStatus|not the status|status code is NOT/i, captured)
  end

  # 精度の天井 (glue ABI 非決定性) 固定: prompt が runtime ABI 契約を明示し、
  # glue 署名が native Apple 署名ではなく (argv, argc) -> UInt であること、
  # 引数は argv[] から Ruby VALUE として decode し、戻り値は Ruby VALUE に
  # encode することを要求する。これが無いと LLM は native 署名 pass-through を
  # 出して invoke 時に ABI 不一致 garbage を返す attempt が混ざる。
  def test_prompt_pins_runtime_abi_signature
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc", exported: "glue_abc_Sym")
    # 署名は (argv: UnsafePointer<UInt>, argc: Int32) -> UInt に固定。
    assert_match(/UnsafePointer<UInt>/, captured)
    assert_match(/argc:\s*Int32/, captured)
    assert_match(/->\s*UInt\b/, captured)
    # argv からの decode を示す。
    assert_match(/argv\[/, captured)
  end

  def test_prompt_teaches_value_marshalling_helpers
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc", exported: "glue_abc_Sym")
    # 引数 decode helper (Ruby VALUE -> native)。
    assert_match(/rb_num2ull|rb_num2ll|rb_num2dbl/, captured)
    # 戻り値 encode helper (native -> Ruby VALUE)。
    assert_match(/rb_ull2inum|rb_ll2inum|rb_float_new/, captured)
    # CRuby symbol を自前で解決する @_silgen_name shadow を要求/提示する。
    assert_match(/@_silgen_name/, captured)
  end

  def test_prompt_warns_against_native_signature_passthrough
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc", exported: "glue_abc_Sym")
    # native Apple 署名をそのまま re-export してはならない旨を明示する。
    assert_match(/native|do NOT re-?export|must NOT|never.*native|raw native/i, captured)
  end

  def test_seed_scaffold_appears_in_prompt
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(
      framework: "CoreAudio", symbol: SYM, glue_id: "abc", exported: "glue_abc_Sym",
      seed: { rule_scaffold: "// SCAFFOLD CONTENT", failure_detail: nil }
    )
    assert_match(/REFERENCE SCAFFOLD/, captured)
    assert_match(/SCAFFOLD CONTENT/, captured)
  end

  def test_seed_failure_detail_appears_in_prompt
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(
      framework: "CoreAudio", symbol: SYM, glue_id: "abc", exported: "glue_abc_Sym",
      seed: { failure_detail: "swiftc: error: cannot convert Int to String" }
    )
    assert_match(/PREVIOUS ATTEMPT FAILED/, captured)
    assert_match(/swiftc: error: cannot convert Int to String/, captured)
  end

  def test_seed_last_glue_appears_in_prompt
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(
      framework: "CoreAudio", symbol: SYM, glue_id: "abc", exported: "glue_abc_Sym",
      seed: { last_glue: "@c public func glue_old() {}" }
    )
    assert_match(/PREVIOUS \(REJECTED\) GLUE/, captured)
    assert_match(/glue_old/, captured)
  end

  def test_seed_context_appears_in_prompt
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(
      framework: "CoreAudio", symbol: SYM, glue_id: "abc", exported: "glue_abc_Sym",
      seed: { context: "Return type is UInt32, use out-param pattern" }
    )
    assert_match(/USER CONTEXT/, captured)
    assert_match(/Return type is UInt32/, captured)
  end

  def test_nil_seed_omits_seed_section
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(
      framework: "CoreAudio", symbol: SYM, glue_id: "abc", exported: "glue_abc_Sym",
      seed: nil
    )
    refute_match(/REFERENCE SCAFFOLD/, captured)
    refute_match(/PREVIOUS ATTEMPT FAILED/, captured)
  end
end
