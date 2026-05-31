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
    # T8: throws init now emits do { try ... } catch { rb_raise(...) }, no longer try?
    assert_match(/do \{/, swift, "is_throws=true should emit do block")
    assert_match(/try AVAudioFile\(/, swift, "do block should contain unwrapped try")
    assert_no_match(/guard let v = try\?/, swift, "silent try? swallow must be eliminated")
    assert_match(/rb_raise\(/, swift, "catch block should rb_raise")
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

  def test_emit_raises_unsupported_pattern_when_kb_has_swift_macro_marker
    kc = FakeKnowledgeCache.new(
      ["Foundation", "Observable.someMethod"] => {
        unsupported_pattern: "swift_macro"
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
      tg.generate(
        framework: "Foundation",
        symbol: {
          kind: "swift_func",
          name: "Observable.someMethod",
          swift_class: "Observable",
          swift_func: "someMethod",
          params: [],
          return_kind: :void
        },
        glue_id: "abcd1234"
      )
    end
    assert_equal "swift_macro", err.pattern
    assert_equal "Foundation", err.framework
    assert_equal "Observable.someMethod", err.symbol
    assert_match(/Swift package wrapping/, err.message,
      "hint should mention Swift package wrapper workaround")
  end

  def test_emit_raises_unsupported_pattern_with_generic_hint_for_unknown_marker
    kc = FakeKnowledgeCache.new(
      ["Foundation", "Foo.bar"] => {
        unsupported_pattern: "novel_pattern_xyz"
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
      tg.generate(
        framework: "Foundation",
        symbol: {
          kind: "swift_func", name: "Foo.bar",
          swift_class: "Foo", swift_func: "bar",
          params: [], return_kind: :void
        },
        glue_id: "abcd1234"
      )
    end
    assert_equal "novel_pattern_xyz", err.pattern
    assert_match(/not directly bridgeable/, err.message)
  end

  def test_emit_no_raise_when_kb_unsupported_pattern_is_nil
    kc = FakeKnowledgeCache.new(
      ["Foundation", "NSString.length"] => {
        unsupported_pattern: nil, is_throws: false, is_failable: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    begin
      tg.generate(
        framework: "Foundation",
        symbol: {
          kind: "swift_property",
          name: "NSString.length",
          swift_class: "NSString",
          swift_property: "length",
          return_kind: :int,
          instance: true
        },
        glue_id: "abcd1234"
      )
    rescue AppleSDKMac::UnsupportedPatternError => e
      flunk "should not raise UnsupportedPatternError when unsupported_pattern is nil, got: #{e.message}"
    end
  end

  def test_emit_no_raise_when_kb_miss
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    begin
      tg.generate(
        framework: "Foundation",
        symbol: {
          kind: "swift_func", name: "Foo.bar",
          swift_class: "Foo", swift_func: "bar",
          params: [], return_kind: :void
        },
        glue_id: "abcd1234"
      )
    rescue AppleSDKMac::UnsupportedPatternError
      flunk "should not raise when Knowledge Base lookup misses (no record)"
    end
  end

  def test_emit_swift_init_throws_emits_do_catch_with_swift_error_raise
    kc = FakeKnowledgeCache.new(
      ["AVFoundation", "AVAudioFile.init(forReading:)"] => {
        is_throws: true, is_failable: false, throws_error_type: nil  # untyped throws
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "AVFoundation",
      symbol: {
        kind: "swift_init",
        name: "AVAudioFile.init(forReading:)",
        swift_class: "AVAudioFile",
        swift_initializer: "init(forReading:) throws",
        params: [:opaque_ref], return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_not_nil swift
    assert_match(/do \{/, swift, "throws init should emit do block")
    assert_match(/try AVAudioFile\(/, swift, "do block should contain unwrapped try (no try?)")
    assert_no_match(/guard let v = try\? /, swift, "try? else Qnil silent swallow must be eliminated")
    # untyped throws (throws_error_type=nil) -> SwiftError dispatch
    assert_match(/rb_raise\(/, swift, "catch block should rb_raise")
  end

  def test_emit_swift_init_throws_with_nserror_dispatches_to_objc_error
    kc = FakeKnowledgeCache.new(
      ["UIKit", "UIDocument.init(fileURL:)"] => {
        is_throws: true, is_failable: false, throws_error_type: "NSError"
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "UIKit",
      symbol: {
        kind: "swift_init",
        name: "UIDocument.init(fileURL:)",
        swift_class: "UIDocument",
        swift_initializer: "init(fileURL:) throws",
        params: [:opaque_ref], return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    # ObjcError dispatch confirmation:
    # throws_error_type=NSError should route to ObjcError lookup
    assert_match(/ObjcError/, swift,
      "throws_error_type=NSError should route to ObjcError")
    assert_no_match(/SwiftError/, swift,
      "throws_error_type=NSError must NOT route to SwiftError")
  end

  def test_emit_swift_property_setter_when_is_settable_true
    kc = FakeKnowledgeCache.new(
      ["AppKit", "NSWindow.title="] => { is_settable: true }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "AppKit",
      symbol: {
        kind: "swift_property_setter",
        name: "NSWindow.title=",
        swift_class: "NSWindow",
        swift_property: "title",
        params: [:string],
        return_kind: :void,
        instance: true
      },
      glue_id: "abcd1234"
    )
    assert_not_nil swift
    assert_match(/receiver\.title = /, swift, "setter form should assign argv to property")
    assert_match(/return Qnil/, swift, "void-return setter should return Qnil")
  end

  def test_emit_swift_property_setter_class_static
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "Foundation",
      symbol: {
        kind: "swift_property_setter",
        name: "URLCache.shared=",
        swift_class: "URLCache",
        swift_property: "shared",
        params: [:opaque_ref],
        return_kind: :void,
        instance: false
      },
      glue_id: "abcd1234"
    )
    assert_not_nil swift
    assert_match(/URLCache\.shared = /, swift)
  end

  # global_constant emitter: numeric (double) representative round-trips.
  def test_emit_global_constant_double_references_constant_and_returns_float
    kc = FakeKnowledgeCache.new(
      ["CoreFoundation", "kCFCoreFoundationVersionNumber"] => {
        kind: "global_constant", abi: "c",
        signature: "extern double kCFCoreFoundationVersionNumber"
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "CoreFoundation",
      symbol: {
        kind: "global_constant", abi: "c",
        name: "kCFCoreFoundationVersionNumber",
        signature: "extern double kCFCoreFoundationVersionNumber"
      },
      glue_id: "gc000001"
    )
    assert_not_nil swift, "global_constant emitter should produce Swift source"
    assert_match(/@c\s+public func glue_gc000001_kCFCoreFoundationVersionNumber/, swift,
      "should export a @c public func for the constant")
    assert_match(/kCFCoreFoundationVersionNumber/, swift,
      "glue body must reference the constant by name")
    assert_match(/rb_float_new\(/, swift,
      "double constant should be returned via rb_float_new")
  end

  # global_constant emitter: integer family (NSUInteger) returns via rb_ull2inum/rb_ll2inum.
  def test_emit_global_constant_integer_returns_inum
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "Foundation",
      symbol: {
        kind: "global_constant", abi: "c",
        name: "NSIntegerMaxConst",
        signature: "extern const NSInteger NSIntegerMaxConst"
      },
      glue_id: "gc000002"
    )
    assert_not_nil swift, "integer global_constant should produce Swift source"
    assert_match(/NSIntegerMaxConst/, swift)
    assert_match(/rb_ll2inum\(|rb_ull2inum\(/, swift,
      "integer constant should be returned via an inum helper")
  end

  # global_constant emitter: types not robustly bridgeable (CFStringRef / NSString)
  # return nil so they stay out-of-coverage rather than emitting broken glue.
  def test_emit_global_constant_unbridgeable_type_returns_nil
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "Foundation",
      symbol: {
        kind: "global_constant", abi: "c",
        name: "NSSomeStringConstant",
        signature: "extern NSString *const _Nonnull NSSomeStringConstant"
      },
      glue_id: "gc000003"
    )
    assert_nil swift,
      "non-numeric (CF/NS opaque) constant should return nil (out of coverage), not broken glue"
  end

  def test_emit_swift_property_setter_raises_when_params_missing
    kc = FakeKnowledgeCache.new({})
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    err = assert_raise(ArgumentError) do
      tg.generate(
        framework: "AppKit",
        symbol: {
          kind: "swift_property_setter",
          name: "NSWindow.title=",
          swift_class: "NSWindow",
          swift_property: "title",
          # params 故意に未指定
          return_kind: :void,
          instance: true
        },
        glue_id: "abcd1234"
      )
    end
    assert_match(/params/, err.message)
  end
end
