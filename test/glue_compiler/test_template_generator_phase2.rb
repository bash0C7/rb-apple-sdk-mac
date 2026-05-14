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

  def test_emit_swift_func_async_from_kb_is_async_column
    kc = FakeKnowledgeCache.new(
      ["Foundation", "URLSession.data(from:)"] => {
        is_throws: true, is_failable: false, is_async: true
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "Foundation",
      symbol: {
        kind: "swift_func",
        name: "URLSession.data(from:)",
        swift_class: "URLSession",
        swift_func: "data",
        params: [:opaque_ref],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_match(/Task \{/, swift, "is_async=true should emit Task skeleton")
    assert_match(/DispatchSemaphore/, swift)
    assert_match(/try await /, swift)
  end

  def test_emit_swift_func_sync_from_kb_no_async_column
    kc = FakeKnowledgeCache.new(
      ["Foundation", "ProcessInfo.osVersion"] => {
        is_throws: false, is_failable: false, is_async: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "Foundation",
      symbol: {
        kind: "swift_func",
        name: "ProcessInfo.osVersion",
        swift_class: "ProcessInfo",
        swift_func: "osVersion",
        params: [],
        return_kind: :int
      },
      glue_id: "abcd1234"
    )
    assert_no_match(/Task \{/, swift, "is_async=false should NOT emit Task skeleton")
    assert_no_match(/DispatchSemaphore/, swift)
  end

  def test_emit_swift_init_labels_from_kb_parameters_json
    kc = FakeKnowledgeCache.new(
      ["AVFoundation", "AVAudioFile.init(forReading:)"] => {
        is_throws: true, is_failable: false, is_async: false,
        parameters_json: JSON.generate([
          { "external_label" => "forReading", "internal_name" => "url", "type" => "URL" }
        ])
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "AVFoundation",
      symbol: {
        kind: "swift_init",
        name: "AVAudioFile.init(forReading:)",
        swift_class: "AVAudioFile",
        swift_initializer: "init()",  # 文字列 fallback では label 0 個 (誤判定)、 Knowledge Base driven なら正しく取れる
        params: [:opaque_ref],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_match(/AVAudioFile\(forReading: arg0\)/, swift,
      "labels should come from parameters_json external_label, not initializer string")
  end

  def test_cf_returns_retained_uses_kb_return_ownership_over_name_regex
    kc = FakeKnowledgeCache.new(
      # 名前が CFCreate / CFCopy で始まらないが Knowledge Base で cf_returns_retained と marked
      ["CoreFoundation", "CFBundleGetMainBundleCopyExecutableURL"] => {
        return_ownership: "cf_returns_retained"
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    retained = tg.send(:cf_returns_retained?,
      framework: "CoreFoundation",
      symbol_name: "CFBundleGetMainBundleCopyExecutableURL"
    )
    assert_equal true, retained,
      "Knowledge Base return_ownership='cf_returns_retained' should override name regex"
  end

  def test_cf_returns_retained_falls_back_to_name_regex_when_kb_miss
    kc = FakeKnowledgeCache.new({})  # 空 store、 lookup miss
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    # CFCreate で始まる名前 (cf_create_naming? が true 返す想定)
    retained = tg.send(:cf_returns_retained?,
      framework: "CoreFoundation",
      symbol_name: "CFStringCreateWithCString"
    )
    assert_equal true, retained, "name regex fallback should detect CFCreate"
  end

  def test_cf_returns_retained_returns_false_when_kb_miss_and_no_naming_match
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    retained = tg.send(:cf_returns_retained?,
      framework: "CoreFoundation",
      symbol_name: "CFArrayGetCount"  # CFCreate / CFCopy なし、 Knowledge Base miss
    )
    assert_equal false, retained, "no Knowledge Base record + no CFCreate/CFCopy prefix should yield false"
  end
end
