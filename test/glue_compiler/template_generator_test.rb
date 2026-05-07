# frozen_string_literal: true
require "test_helper"
require "json"
require "apple_sdk_mac/glue_compiler/template_generator"

class TestTemplateGeneratorKindDispatch < Test::Unit::TestCase
  def gen
    AppleSDKMac::GlueCompiler::TemplateGenerator.new
  end

  def sym(name:, signature:, parameters:, kind: "function", abi: "c")
    { name: name, kind: kind, abi: abi, signature: signature,
      parameters_json: JSON.generate(parameters) }
  end

  def test_returns_nil_for_unsupported_kind
    s = sym(name: "F", signature: "void F(void *p)",
            parameters: [{ name: "p", type: "void *", kind: "unsupported", is_out_param: false }])
    assert_nil gen.generate(framework: "X", symbol: s, glue_id: "abc")
  end

  def test_emits_silgen_name_header
    s = sym(name: "F", signature: "void F(int x)",
            parameters: [{ name: "x", type: "int", kind: "int", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/@_silgen_name\("rb_num2ll"\)/, out)
    assert_match(/@_silgen_name\("rb_raise"\)/, out)
    assert_match(/@_silgen_name\("rb_str_new_cstr"\)/, out)
  end

  def test_emits_string_kind_with_cfstring_cast
    s = sym(name: "F", signature: "void F(CFStringRef _Nonnull s)",
            parameters: [{ name: "s", type: "CFStringRef _Nonnull", kind: "string",
                           is_out_param: false, nullability: "nonnull" }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let s = String\(cString: rb_string_value_cstr\(&v0\)\) as CFString/, out)
  end

  def test_emits_int_kind_using_rb_num2ll
    s = sym(name: "F", signature: "void F(int x)",
            parameters: [{ name: "x", type: "int", kind: "int", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let x: Int64 = rb_num2ll\(argv\[0\]\)/, out)
  end

  def test_emits_bool_kind
    s = sym(name: "F", signature: "void F(_Bool b)",
            parameters: [{ name: "b", type: "_Bool", kind: "bool", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let b: Bool = \(argv\[0\] != Qfalse && argv\[0\] != Qnil\)/, out)
  end

  def test_emits_float_kind
    s = sym(name: "F", signature: "void F(double d)",
            parameters: [{ name: "d", type: "double", kind: "float", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_match(/let d: Double = rb_num2dbl\(argv\[0\]\)/, out)
  end

  def test_emits_opaque_ref_kind_in
    s = sym(name: "F", signature: "void F(MIDIClientRef c)",
            parameters: [{ name: "c", type: "MIDIClientRef", kind: "opaque_ref", is_out_param: false }])
    out = gen.generate(framework: "CoreMIDI", symbol: s, glue_id: "abc")
    assert_match(/let c = MIDIClientRef\(rb_num2ull\(argv\[0\]\)\)/, out)
  end

  def test_emits_out_param_and_status_check
    s = sym(name: "MIDIClientCreate",
            signature: "OSStatus MIDIClientCreate(CFStringRef _Nonnull n, MIDIClientRef *_Nonnull o)",
            parameters: [
              { name: "n", type: "CFStringRef _Nonnull", kind: "string", is_out_param: false },
              { name: "o", type: "MIDIClientRef *", kind: "opaque_ref", is_out_param: true }
            ])
    out = gen.generate(framework: "CoreMIDI", symbol: s, glue_id: "abc")
    # Out-param vars are named after the param itself (`o`) instead of the
    # legacy hardcoded `outRef`, so multi-out-param call sites can have one var
    # per out-param without name collisions.
    assert_match(/var o: MIDIClientRef = MIDIClientRef\(\)/, out)
    assert_match(/let status = MIDIClientCreate\(n, &o\)/, out)
    assert_match(/if status != 0 \{ rb_raise\(rb_eRuntimeError/, out)
    assert_match(/return rb_ull2inum\(UInt64\(o\)\)/, out)
  end

  def test_emits_status_check_for_status_int_return_without_outparam
    s = sym(name: "MIDIClientDispose",
            signature: "OSStatus MIDIClientDispose(MIDIClientRef client)",
            parameters: [{ name: "client", type: "MIDIClientRef", kind: "opaque_ref", is_out_param: false }])
    out = gen.generate(framework: "CoreMIDI", symbol: s, glue_id: "abc")
    assert_match(/let result = MIDIClientDispose\(client\)/, out)
    assert_match(/if result != 0 \{ rb_raise\(rb_eRuntimeError/, out)
    assert_match(/return Qnil/, out)
  end

  # CF pointer Refs (CFArrayRef, CGContextRef, CVPixelBufferRef, CFTypeRef
  # itself) are pointer typedefs, NOT integer typedefs. The OpaqueRefMarshaller
  # emits `T(rb_num2ull(...))` which only compiles for integer Refs (MIDI/Audio
  # family). For CF pointer Refs we must cast via OpaquePointer(bitPattern:)
  # then `unsafeBitCast` to the real Swift type.
  # Phase 7 — CF input handling: declares an Optional of the
  # Ref-stripped Swift type, branches on Qnil, and unsafeBitCasts the
  # OpaquePointer when present. Ref suffix removed because Swift 6
  # renamed CFTypeRef → CFType, CFArrayRef → CFArray, etc.
  def test_emits_cftype_ref_kind_in
    s = sym(name: "CFRetain", signature: "CFTypeRef CFRetain(CFTypeRef cf)",
            parameters: [{ name: "cf", type: "CFTypeRef", kind: "cftype_ref", is_out_param: false }])
    out = gen.generate(framework: "CoreFoundation", symbol: s, glue_id: "abc")
    assert_match(/let cf: CFType\?/, out)
    assert_match(/argv\[0\] == Qnil/, out)
    assert_match(/unsafeBitCast\(__ptr_0, to: CFType\.self\)/, out)
  end

  def test_emits_cftype_ref_kind_in_for_cf_array_ref
    s = sym(name: "CFArrayGetCount", signature: "CFIndex CFArrayGetCount(CFArrayRef array)",
            parameters: [{ name: "array", type: "CFArrayRef", kind: "cftype_ref", is_out_param: false }])
    out = gen.generate(framework: "CoreFoundation", symbol: s, glue_id: "abc")
    assert_match(/let array: CFArray\?/, out)
    assert_match(/argv\[0\] == Qnil/, out)
    assert_match(/unsafeBitCast\(__ptr_0, to: CFArray\.self\)/, out)
  end

  def test_does_not_reference_marshal_or_errorbridge
    s = sym(name: "F", signature: "void F(int x)",
            parameters: [{ name: "x", type: "int", kind: "int", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_not_match(/Marshal\.from/, out)
    assert_not_match(/Marshal\.toRuby/, out)
    assert_not_match(/ErrorBridge\.rb_raise_via_runtime/, out)
  end

  # T52g — single-segment class method の preposition-aware bridge。
  # `+sleepForTimeInterval:` は Swift 6 で `sleep(forTimeInterval:)` に rename。
  # ObjC→Swift bridge は "With" 以外の preposition (For/By/Using/From/At/In/To/On)
  # にも対応する必要がある。
  def test_emit_objc_class_method_for_preposition_bridge
    s = sym(name: "NSThread.sleepForTimeInterval:",
            kind: "objc_method_class",
            signature: "+ (void)sleepForTimeInterval:(NSTimeInterval)ti",
            parameters: [])
    s[:objc_class] = "NSThread"
    s[:selector] = "sleepForTimeInterval:"
    s[:params] = [:float]
    s[:return_kind] = :void

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52g: must emit"
    assert_match(/Thread\.sleep\(forTimeInterval:\s*arg0\)/, out,
                 "T52g: For-preposition verb must split as `sleep(forTimeInterval:)`")
    refute_match(/Thread\.sleepForTimeInterval\(arg0\)/, out,
                 "T52g: must not emit obsoleted ObjC method form")
  end

  # T52j — objc_in_load :opaque_ref に Hash 形 type ヒント対応。
  # NSOperationQueue.addOperation(_ op: Operation) 等の typed Swift instance
  # method に opaque ref を渡すには、 OpaquePointer から typed reference へ
  # unsafeBitCast する必要がある。
  def test_emit_objc_in_load_opaque_ref_hash_type_hint_emits_unsafe_bitcast
    s = sym(name: "NSOperationQueue.addOperation:",
            kind: "objc_method_instance",
            signature: "- (void)addOperation:(NSOperation *)op",
            parameters: [])
    s[:objc_class] = "NSOperationQueue"
    s[:selector] = "addOperation:"
    s[:params] = [{kind: :opaque_ref, type: "Operation"}]
    s[:return_kind] = :void

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52j: must emit"
    assert_match(/unsafeBitCast\([^)]+,\s*to:\s*Operation\.self\)/, out,
                 "T52j: typed Swift cast (unsafeBitCast to: Operation.self) must be emitted")
  end

  # T52f — multi-segment instance method (verb-with-type pattern 非該当) の
  # first-arg unlabeled bridge。
  # ObjC selector `addOperations:waitUntilFinished:` の Swift bridged signature
  # は `addOperations(_ ops: [Operation], waitUntilFinished wait: Bool)` で、
  # 第1 引数は label 無し。現実装は first segment を first label として扱う
  # bug があり `receiver.addOperations(waitUntilFinished: arg0)` を emit して
  # しまっていた。
  def test_emit_objc_instance_method_multi_segment_first_arg_unlabeled
    s = sym(name: "NSOperationQueue.addOperations:waitUntilFinished:",
            kind: "objc_method_instance",
            signature: "- (void)addOperations:(NSArray *)ops waitUntilFinished:(BOOL)wait",
            parameters: [])
    s[:objc_class] = "NSOperationQueue"
    s[:selector] = "addOperations:waitUntilFinished:"
    s[:params] = [{kind: :array_of_opaque_ref, type: "Operation"}, :bool]
    s[:return_kind] = :void

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52f: must emit"
    assert_match(/receiver\.addOperations\(arg0,\s*waitUntilFinished:\s*arg1\)/, out,
                 "T52f: first arg must be unlabeled (Apple SDK ObjC→Swift bridge convention)")
    refute_match(/receiver\.addOperations\(waitUntilFinished:\s*arg0\)/, out,
                 "T52f: must not assign first segment as first arg label")
  end

  # T52e — emit_objc_class_method の klass NS-strip。
  # NSBlockOperation +blockOperationWithBlock: → BlockOperation(block:) 形に
  # 変換 (Swift 6 で NSBlockOperation は obsoleted、blockOperationWithBlock も
  # init(block:) に rename された)。さらに戻り値は non-optional Self なので
  # `raw == nil` / `raw!` を含めない non-optional 耐性 emit を要求。
  def test_emit_objc_class_method_strips_ns_prefix_for_block_operation
    s = sym(name: "NSBlockOperation.blockOperationWithBlock:",
            kind: "objc_method_class",
            signature: "+ (instancetype)blockOperationWithBlock:(void (^)(void))block",
            parameters: [])
    s[:objc_class] = "NSBlockOperation"
    s[:selector] = "blockOperationWithBlock:"
    s[:params] = [:block_persistent_void]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52e: must emit"
    # Swift type 参照 (call site, type 注釈) で NS-prefix が出てはいけない。
    # export identifier (`glue_abc_NSBlockOperation_blockOperationWithBlock_`)
    # は SDK 内部の symbol 名なので除外する。
    refute_match(/NSBlockOperation\(/, out,
                 "T52e: NS-prefix must not appear in Swift call site")
    refute_match(/to:\s*NSBlockOperation\b/, out,
                 "T52e: NS-prefix must not appear in Swift type annotation")
    assert_match(/BlockOperation\(block:\s*arg0\)/, out,
                 "T52e: must call Swift bridged BlockOperation(block: arg0)")
  end

  def test_emit_objc_class_method_opaque_ref_return_handles_non_optional_self
    s = sym(name: "NSBlockOperation.blockOperationWithBlock:",
            kind: "objc_method_class",
            signature: "+ (instancetype)blockOperationWithBlock:(void (^)(void))block",
            parameters: [])
    s[:objc_class] = "NSBlockOperation"
    s[:selector] = "blockOperationWithBlock:"
    s[:params] = [:block_persistent_void]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    # Non-optional 戻り値に対し `raw == nil` 比較や `raw!` force unwrap が出ると
    # Swift 6 で compile error。Optional 化は AnyObject? 経由などで耐性化する。
    refute_match(/raw\s*==\s*nil/, out,
                 "T52e: non-optional Self 戻り値で raw == nil 比較は禁止 (warning)")
    refute_match(/raw!\s+as\s+AnyObject/, out,
                 "T52e: non-optional Self 戻り値で raw! force unwrap は禁止 (compile error)")
  end

  # T52d — objc_in_load (emit_objc_class_method / emit_objc_instance_method /
  # emit_swift_init から共通呼び出し) が新 kinds + Hash 形 type ヒントに
  # 対応すること。
  # spec § 4.5.-1: Marshaller::REGISTRY 経路 (C function) と objc_in_load 経路
  # の双方をサポートしないと、example の Apple.discover (class_method:/selector:)
  # 呼び出しでは新 kinds が unsupported になる。
  def test_objc_in_load_supports_block_persistent_void_via_class_method
    s = sym(name: "NSBlockOperation.blockOperationWithBlock:",
            kind: "objc_method_class",
            signature: "+ (instancetype)blockOperationWithBlock:(void (^)(void))block",
            parameters: [])
    s[:objc_class] = "NSBlockOperation"
    s[:selector] = "blockOperationWithBlock:"
    s[:params] = [:block_persistent_void]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52d: objc_method_class with block_persistent_void must emit"
    assert_match(/@convention\(block\)\s*\(\)\s*->\s*Void/, out,
                 "T52d: must emit @convention(block) () -> Void closure type via objc_in_load")
    assert_match(/runtime_threading_enqueue/, out,
                 "T52d: must dispatch to Ruby Proc via runtime_threading_enqueue")
  end

  def test_objc_in_load_supports_array_of_opaque_ref_hash_type_hint
    s = sym(name: "NSOperationQueue.addOperations:waitUntilFinished:",
            kind: "objc_method_instance",
            signature: "- (void)addOperations:(NSArray<NSOperation *>*)ops waitUntilFinished:(BOOL)wait",
            parameters: [])
    s[:objc_class] = "NSOperationQueue"
    s[:selector] = "addOperations:waitUntilFinished:"
    s[:params] = [{kind: :array_of_opaque_ref, type: "Operation"}, :bool]
    s[:return_kind] = :void

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52d: objc_method_instance with Hash array_of_opaque_ref must emit"
    assert_match(/NSMutableArray/, out,
                 "T52d: must build NSMutableArray for Hash-form array_of_opaque_ref")
    assert_match(/as!\s*\[Operation\]|as\s+\[Operation\]/, out,
                 "T52d: must cast to typed array using Hash :type ('Operation')")
    assert_match(/runtime_rb_array_len/, out,
                 "T52d: must iterate via runtime_rb_array_len")
  end

  # T52c — Swift 6 ObjC class bridge: NS-prefix strip + non-failable init。
  # NSOperationQueue / NSBlockOperation 等は Swift 6 で OperationQueue /
  # BlockOperation に rename され、no-arg init は non-failable (Optional ではない)。
  # emit_swift_init はこれを反映して NS-stripped class name と `let v = Klass()`
  # 形 (guard let ではなく) を emit せねばならない。
  def test_emit_swift_init_strips_ns_prefix_and_uses_non_failable_let
    s = sym(name: "NSOperationQueue.init()",
            kind: "swift_init",
            signature: "init()", parameters: [])
    s[:swift_class] = "NSOperationQueue"
    s[:swift_initializer] = "init()"
    s[:params] = []
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52c: swift_init must emit"
    assert_match(/OperationQueue\(\)/, out,
                 "T52c: NS-prefix must be stripped in emitted Swift init call")
    refute_match(/NSOperationQueue\(\)/, out,
                 "T52c: ObjC NS-prefixed name must not appear in Swift init call (Swift 6 rename)")
    assert_match(/let v = OperationQueue\(\)/, out,
                 "T52c: non-failable init must emit 'let v = ...' (no guard)")
    refute_match(/guard let v = OperationQueue\(\)/, out,
                 "T52c: non-failable Swift init must not be wrapped in guard let")
  end

  # T52a — () -> Void escaping block (NSBlockOperation の +blockOperationWithBlock:)。
  # 既存 block_persistent は (Arg?) -> Void 形 (BoxedBlockHandle 経由) で、
  # void→void block を直接 emit するパスがなかった。
  def test_emits_block_persistent_void_kind_for_zero_arity_callback
    s = sym(name: "F",
            signature: "void F(void (^block)(void))",
            parameters: [{ name: "block", type: "void (^)(void)",
                           kind: "block_persistent_void", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T52a: block_persistent_void kind must be supported"
    assert_match(/@convention\(block\)\s*\(\)\s*->\s*Void/, out,
                 "T52a: must emit @convention(block) () -> Void closure type")
    assert_match(/ThreadingBridge\.enqueueFromAppleThread/, out,
                 "T52a: must dispatch to Ruby Proc via ThreadingBridge")
    assert_match(/rb_hash_aset\(runtime_proc_registry_get\(\)/, out,
                 "T52a: must pin Ruby Proc in proc_registry")
  end

  # T54a — Ruby Array → Swift [<OpaqueType>] marshaller. T52 (NSOperationQueue
  # addOperations:waitUntilFinished:) と T54 (VNImageRequestHandler
  # performRequests:error:) の共通依存。Apple framework instance method の
  # NSArray-of-opaque-ref パラメータを事前宣言なしで通す。
  def test_emits_array_of_opaque_ref_kind_uses_nsmutablearray_loop
    s = sym(name: "F",
            signature: "void F(NSArray<VNRequest *> *_Nonnull requests)",
            parameters: [{ name: "requests", type: "VNRequest",
                           kind: "array_of_opaque_ref", is_out_param: false }])
    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54a: array_of_opaque_ref kind must be supported"
    assert_match(/NSMutableArray/, out, "T54a: must build NSMutableArray")
    assert_match(/RARRAY_LEN|rb_ary_entry/, out,
                 "T54a: must iterate Ruby Array via RARRAY_LEN/rb_ary_entry")
    assert_match(/as!\s*\[VNRequest\]|as\s+\[VNRequest\]/, out,
                 "T54a: must cast NSMutableArray to Swift [VNRequest]")
  end
end
