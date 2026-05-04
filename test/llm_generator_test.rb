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
end
