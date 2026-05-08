# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb"
require "apple_sdk_mac/irb/llm_resolver"

# LLMResolver generates doc on the fly when DocResolver returned nil
# (Swift-overlay Apple symbols with empty documentation, or Ruby
# stdlib classes outside the KB scope). Same `resolve(matched) ⇒ str|nil`
# contract as DocResolver, so DocDialog can chain them transparently.
class TestLLMResolver < Test::Unit::TestCase
  LLMResolver = AppleSDKMac::IRB::LLMResolver

  def make_kb(signatures: {})
    kb = Object.new
    kb.define_singleton_method(:lookup_signature) do |framework:, klass: nil, name:|
      signatures[[framework, klass, name]]
    end
    kb
  end

  # --- Apple symbol generation ------------------------------------------

  def test_resolves_apple_class_method_via_llm
    seen_prompt = nil
    llm = ->(prompt) { seen_prompt = prompt; "Returns a new URL with the path component appended." }
    out = LLMResolver.new(llm_proc: llm)
      .resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_equal "Returns a new URL with the path component appended.", out
    assert_match(/Foundation/, seen_prompt)
    assert_match(/URL/, seen_prompt)
    assert_match(/appendingPathComponent/, seen_prompt)
  end

  def test_apple_prompt_uses_api_wording_not_bare_symbol
    # Live verification (2026-05-08) showed Apple's on-device model
    # interpreting bare "Apple SDK symbol" as a visual icon and returning
    # nonsense like "a rectangle with a blue circle in the middle and a
    # diagonal line crossing through it." The prompt must use API-doc
    # wording (API element / framework API / method) so the model treats
    # the input as a programming construct.
    seen = nil
    llm = ->(p) { seen = p; "x" }
    LLMResolver.new(llm_proc: llm).resolve("Apple::Foundation::URL.appendingPathComponent")
    refute_match(/Apple SDK symbol/i, seen,
      "prompt must not use the bare word 'symbol' which the on-device model misreads as a glyph")
    assert_match(/API|method|function|property|type/i, seen,
      "prompt should anchor the model on programming-construct vocabulary")
  end

  def test_apple_prompt_includes_signature_when_kb_supplies_it
    kb = make_kb(signatures: {
      ["Foundation", "URL", "appendingPathComponent"] =>
        "public func appendingPathComponent(_ pathComponent: String) -> URL"
    })
    seen_prompt = nil
    llm = ->(prompt) { seen_prompt = prompt; "doc" }
    LLMResolver.new(llm_proc: llm, knowledge_cache: kb)
      .resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_match(/public func appendingPathComponent/, seen_prompt)
  end

  def test_resolves_apple_module_via_llm
    seen_prompt = nil
    llm = ->(prompt) { seen_prompt = prompt; "URL value type" }
    out = LLMResolver.new(llm_proc: llm).resolve("Apple::Foundation::URL")
    assert_equal "URL value type", out
    assert_match(/Foundation/, seen_prompt)
    assert_match(/URL/, seen_prompt)
  end

  def test_resolves_apple_root_via_llm
    seen_prompt = nil
    llm = ->(prompt) { seen_prompt = prompt; "ARKit framework provides AR" }
    out = LLMResolver.new(llm_proc: llm).resolve("Apple::ARKit")
    assert_equal "ARKit framework provides AR", out
    assert_match(/ARKit/, seen_prompt)
  end

  # --- Non-Apple (Ruby stdlib) generation -------------------------------

  def test_resolves_ruby_stdlib_input
    seen_prompt = nil
    llm = ->(prompt) { seen_prompt = prompt; "Returns string representation." }
    out = LLMResolver.new(llm_proc: llm).resolve("String.to_s")
    assert_equal "Returns string representation.", out
    assert_match(/String\.to_s|String#to_s/, seen_prompt)
  end

  # --- Failure modes -----------------------------------------------------

  def test_returns_nil_when_llm_proc_raises
    llm = ->(_prompt) { raise "model unavailable" }
    out = nil
    assert_nothing_raised do
      out = LLMResolver.new(llm_proc: llm).resolve("Apple::Foundation::URL.appendingPathComponent")
    end
    assert_nil out
  end

  def test_returns_nil_when_llm_proc_returns_nil
    llm = ->(_prompt) { nil }
    assert_nil LLMResolver.new(llm_proc: llm).resolve("String.to_s")
  end

  def test_returns_nil_when_llm_proc_returns_empty
    llm = ->(_prompt) { "   \n  " }
    assert_nil LLMResolver.new(llm_proc: llm).resolve("String.to_s")
  end

  def test_returns_nil_for_blank_input
    llm = ->(_p) { raise "should not be called" }
    assert_nil LLMResolver.new(llm_proc: llm).resolve(nil)
    assert_nil LLMResolver.new(llm_proc: llm).resolve("")
  end

  # --- Cache + transform -------------------------------------------------

  def test_caches_per_input
    counter = 0
    llm = ->(_p) { counter += 1; "doc#{counter}" }
    r = LLMResolver.new(llm_proc: llm)
    a = r.resolve("Apple::Foundation::URL.appendingPathComponent")
    b = r.resolve("Apple::Foundation::URL.appendingPathComponent")
    c = r.resolve("Apple::Foundation::URL.appendingPathExtension")
    assert_equal a, b
    assert_not_equal a, c
    assert_equal 2, counter
  end

  def test_doc_transform_applied_after_generation
    llm = ->(_p) { "raw doc" }
    r = LLMResolver.new(
      llm_proc: llm,
      doc_transform: ->(doc, _ctx) { "wrapped(#{doc})" }
    )
    out = r.resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_equal "wrapped(raw doc)", out
  end

  def test_doc_transform_receives_context_when_apple
    seen_ctx = nil
    r = LLMResolver.new(
      llm_proc: ->(_p) { "doc" },
      doc_transform: ->(doc, ctx) { seen_ctx = ctx; doc }
    )
    r.resolve("Apple::Foundation::URL.appendingPathComponent")
    assert_equal "Foundation", seen_ctx&.framework
    assert_equal "URL", seen_ctx&.klass
  end

  def test_doc_transform_receives_nil_ctx_for_ruby_input
    seen_ctx = :unset
    r = LLMResolver.new(
      llm_proc: ->(_p) { "doc" },
      doc_transform: ->(doc, ctx) { seen_ctx = ctx; doc }
    )
    r.resolve("String.to_s")
    assert_nil seen_ctx
  end
end
