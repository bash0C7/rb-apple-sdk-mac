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

  def test_extracts_swift_from_fenced_block
    runner = ->(_p) { "blah\n```swift\n@c public func glue_x() {}\n```\ntrailing" }
    src = build(runner).generate_glue(framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x")
    assert_equal "@c public func glue_x() {}", src.strip
  end

  def test_returns_nil_when_no_swift_block
    runner = ->(_p) { "I cannot help with that." }
    src = build(runner).generate_glue(framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x")
    assert_nil src
  end
end
