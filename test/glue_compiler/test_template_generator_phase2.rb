# frozen_string_literal: true
require "test-unit"
require "json"
require "apple_sdk_mac/errors"
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

  # CF retained detection via generate public API.
  # Fixture: kind:"function" + abi:"c" + signature starting with CFStringRef
  # so effective_return_kind reaches cftype_ref, then cf_returns_retained? decides
  # whether to emit runtime_arc_box_cftype (retained) or raw rb_ull2inum (not retained).

  def test_cf_returns_retained_uses_kb_return_ownership_over_name_regex
    # 名前が CFCreate / CFCopy で始まらないが Knowledge Base で cf_returns_retained と marked。
    # generate 出力に runtime_arc_box_cftype(raw_uint) 呼び出しが現れることで Knowledge Base 優先を検証。
    # Note: HEADER に @_silgen_name 宣言が常に含まれるため、呼び出し側 "raw_uint" 引数パターンで区別。
    kc = FakeKnowledgeCache.new(
      ["CoreFoundation", "CFBundleGetMainBundleCopyExecutableURL"] => {
        return_ownership: "cf_returns_retained"
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "CoreFoundation",
      symbol: {
        kind: "function", abi: "c",
        name: "CFBundleGetMainBundleCopyExecutableURL",
        signature: "CFStringRef",
        params: nil
      },
      glue_id: "test001"
    )
    assert_not_nil swift, "generate should produce Swift source for cftype_ref function"
    assert_match(/runtime_arc_box_cftype\(raw_uint\)/, swift,
      "Knowledge Base return_ownership='cf_returns_retained' should emit arc_box call with raw_uint arg")
  end

  def test_cf_returns_retained_falls_back_to_name_regex_when_kb_miss
    # Knowledge Base miss + CFCreate prefix → 名前 regex fallback で retained と判定。
    # Note: HEADER に @_silgen_name 宣言が常に含まれるため、呼び出し側 "raw_uint" 引数パターンで区別。
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "CoreFoundation",
      symbol: {
        kind: "function", abi: "c",
        name: "CFStringCreateWithCString",
        signature: "CFStringRef",
        params: nil
      },
      glue_id: "test002"
    )
    assert_not_nil swift
    assert_match(/runtime_arc_box_cftype\(raw_uint\)/, swift,
      "name regex fallback should detect CFCreate and emit arc_box call with raw_uint arg")
  end

  def test_cf_returns_retained_returns_false_when_kb_miss_and_no_naming_match
    # Knowledge Base miss + 名前が CFCreate/CFCopy でない → retained=false → raw unsafeBitCast 経路。
    # Note: HEADER に @_silgen_name 宣言が常に含まれるため、呼び出し側 "raw_uint" 引数パターンで区別。
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "CoreFoundation",
      symbol: {
        kind: "function", abi: "c",
        name: "CFArrayGetCount",
        signature: "CFArrayRef",  # cftype_ref だが retained=false
        params: nil
      },
      glue_id: "test003"
    )
    assert_not_nil swift
    assert_no_match(/runtime_arc_box_cftype\(raw_uint\)/, swift,
      "no Knowledge Base record + no CFCreate/CFCopy prefix should not emit arc_box call")
    assert_match(/unsafeBitCast/, swift,
      "non-retained cftype_ref should emit raw unsafeBitCast path")
  end

  def test_resolve_callback_route_known_signature_returns_route_name
    # CALLBACK_PILLAR_ROUTES.values の中に必ず存在する route name を期待値とする。
    # ::AppleSDKMac::GlueCompiler::CALLBACK_PILLAR_ROUTES.values.uniq.first を取得して
    # それを stub の normalized 値とする (実 route と test data を結合)。
    routes = ::AppleSDKMac::GlueCompiler::CALLBACK_PILLAR_ROUTES.values.uniq
    omit "no callback routes registered" if routes.empty?
    known_route = routes.first
    kc = FakeKnowledgeCache.new(
      ["TestFramework", "TestAPI_knownCallback"] => {
        callback_signature_json: JSON.generate({
          "params" => ["dummy"], "return_type" => "void",
          "normalized" => known_route
        })
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    route = tg.send(:resolve_callback_route,
      framework: "TestFramework",
      symbol_name: "TestAPI_knownCallback"
    )
    assert_equal known_route, route
  end

  def test_resolve_callback_route_unregistered_raises_unsupported_pattern_error
    kc = FakeKnowledgeCache.new(
      ["MyFramework", "MyAPI_unknownCallback"] => {
        callback_signature_json: JSON.generate({
          "params" => ["MyCustomStruct*", "void*"],
          "return_type" => "int",
          "normalized" => "my_custom_unregistered_route_xyz_123"
        })
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
      tg.send(:resolve_callback_route,
        framework: "MyFramework",
        symbol_name: "MyAPI_unknownCallback"
      )
    end
    assert_equal "callback_signature_unregistered", err.pattern
    assert_equal "MyFramework", err.framework
    assert_equal "MyAPI_unknownCallback", err.symbol
    assert_match(/my_custom_unregistered_route_xyz_123/, err.message)
  end

  def test_resolve_callback_route_returns_nil_on_kb_miss
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    result = tg.send(:resolve_callback_route,
      framework: "Foo",
      symbol_name: "Bar"
    )
    assert_nil result
  end

  def test_resolve_callback_route_returns_nil_when_callback_signature_absent
    kc = FakeKnowledgeCache.new(
      ["Foo", "Bar"] => { is_throws: true }  # callback_signature_json 無し
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    result = tg.send(:resolve_callback_route, framework: "Foo", symbol_name: "Bar")
    assert_nil result
  end
end
