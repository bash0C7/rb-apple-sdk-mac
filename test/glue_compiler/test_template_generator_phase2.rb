# frozen_string_literal: true
require "test-unit"
require "json"
require "apple_sdk_mac/glue_compiler/template_generator"

class TestTemplateGeneratorPhase2 < Test::Unit::TestCase
  class FakeKnowledgeCache
    def initialize(records = {})
      @records = records
    end

    def lookup_symbol(framework:, symbol:)
      @records[[framework, symbol]]
    end

    def lookup_klass_method(framework:, klass:, method:)
      @records[[framework, klass, method]]
    end
  end

  def test_emit_swift_init_throws_from_kb_is_throws_column
    kc = FakeKnowledgeCache.new(
      ["AVFoundation", "AVAudioFile.init(forReading:)"] => {
        is_throws: true, is_failable: false, is_async: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "AVFoundation",
      symbol: {
        kind: "swift_init",
        name: "AVAudioFile.init(forReading:)",
        swift_class: "AVAudioFile",
        swift_initializer: "init(forReading:)",
        params: [:opaque_ref],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_not_nil swift, "emit_swift_init should produce Swift source"
    assert_match(/try\?/, swift, "is_throws=true should emit try? wrap")
    assert_match(/guard let v = try\?/, swift)
  end

  def test_emit_swift_init_failable_from_kb_is_failable_column
    kc = FakeKnowledgeCache.new(
      ["Foundation", "URL.init(string:)"] => {
        is_throws: false, is_failable: true, is_async: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "Foundation",
      symbol: {
        kind: "swift_init",
        name: "URL.init(string:)",
        swift_class: "URL",
        swift_initializer: "init(string:)",
        params: [:string],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_match(/guard let v = /, swift, "is_failable=true should emit guard let")
    assert_match(/return Qnil/, swift)
  end

  def test_emit_swift_init_non_failable_non_throws_from_kb
    kc = FakeKnowledgeCache.new(
      ["AppKit", "NSWindow.init(contentRect:styleMask:backing:defer:)"] => {
        is_throws: false, is_failable: false, is_async: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "AppKit",
      symbol: {
        kind: "swift_init",
        name: "NSWindow.init(contentRect:styleMask:backing:defer:)",
        swift_class: "NSWindow",
        swift_initializer: "init(contentRect:styleMask:backing:defer:)",
        params: [:int, :int, :int, :bool],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_match(/let v = /, swift, "non-failable + non-throws should emit plain let")
    assert_no_match(/guard let v/, swift)
    assert_no_match(/try\?/, swift)
  end
end
