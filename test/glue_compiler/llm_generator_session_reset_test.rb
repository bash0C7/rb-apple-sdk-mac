# frozen_string_literal: true
require "test/unit"
require "apple_sdk_mac/glue_compiler/llm_generator"

class LLMGeneratorSessionResetTest < Test::Unit::TestCase
  def test_each_generate_uses_fresh_session
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    sym = { name: "Foo", kind: "function", abi: "c", signature: "void Foo()", parameters_json: "[]" }
    # Capture sessions used across 2 generate() calls. They must be different objects.
    sessions = []
    gen.define_singleton_method(:foundation_model_session) do |_family|
      s = Object.new
      def s.respond(to:); "// fake response\n"; end
      sessions << s
      s
    end
    gen.generate(framework: "Foo", symbol: sym, glue_id: "deadbeef")
    gen.generate(framework: "Foo", symbol: sym, glue_id: "cafebabe")
    assert sessions.length >= 2, "Expected at least 2 session creations, got #{sessions.length}"
    refute_equal sessions[0].object_id, sessions[1].object_id,
      "Each generate() must use a fresh session (not reuse cached)"
  end
end
