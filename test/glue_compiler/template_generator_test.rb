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

  # T53a — :block_persistent Hash 形 (arity, types) で URLSession completion
  # handler のような multi-arg typed escaping block を emit する。 既存の
  # :block_persistent (Symbol 形) は (Data?, URLResponse?, Error?) -> Void に
  # 固定で、 Ruby callback には err 単一 Int64 (nil → 0, non-nil → -1) しか
  # 渡らない。 spec § 5.4 acceptance では data_ref / response_ref / error_ref
  # 3 個を Ruby block の引数に渡すため、 N-arg dispatch が必須。
  #
  # Hash 形 spec:
  #   {kind: :block_persistent, arity: 3, types: ["NSData?", "NSURLResponse?", "NSError?"]}
  #
  # 期待 emit:
  #   - Swift closure signature が `(NSData?, NSURLResponse?, NSError?) -> Void`
  #     形 (Hash :types を反映)
  #   - 内部で 3 個の Optional を Int64 raw pointer に変換 (nil → 0)
  #   - runtime_threading_enqueue_3 を呼び 3 つの Int64 を main thread に dispatch
  def test_emits_block_persistent_hash_form_arity_3_typed_dispatch
    s = sym(name: "NSURLSession.dataTaskWithURL:completionHandler:",
            kind: "objc_method_instance",
            signature: "- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h",
            parameters: [])
    s[:objc_class] = "NSURLSession"
    s[:selector] = "dataTaskWithURL:completionHandler:"
    s[:params] = [:opaque_ref,
                  {kind: :block_persistent, arity: 3,
                   types: ["NSData?", "NSURLResponse?", "NSError?"]}]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53a: block_persistent Hash 形 (arity 3) must emit"
    assert_match(/runtime_threading_enqueue_3/, out,
                 "T53a: arity 3 must dispatch via runtime_threading_enqueue_3 (3 Int64 args)")
    assert_match(/NSData\?/, out,
                 "T53a: typed Swift signature must include NSData?")
    assert_match(/NSURLResponse\?/, out,
                 "T53a: typed Swift signature must include NSURLResponse?")
    assert_match(/NSError\?/, out,
                 "T53a: typed Swift signature must include NSError?")
    assert_match(/rb_hash_aset\(runtime_proc_registry_get\(\)/, out,
                 "T53a: must pin Ruby Proc in proc_registry (lifecycle)")
  end

  # T53b — swift_call_for_class_method の `<verb>With<Type>:` regex は
  # 小文字始まり verb (`stringWith...`) のみ match する。 Apple SDK には
  # `+URLWithString:` (NSURL)、 `+UUID` (NSUUID class method 系)、 `+UTF8String`
  # 系 (NSString) のように大文字 acronym で始まる verb も多く存在し、 これらが
  # init bridge (`URL(string:)`) に変換されない bug がある。 regex を `[A-Za-z]`
  # 始まり許容に拡張し、 NSURL の URLWithString が `URL(string: arg0)` 形を
  # 出すようにする。
  def test_emit_objc_class_method_supports_uppercase_acronym_verb
    s = sym(name: "NSURL.URLWithString:",
            kind: "objc_method_class",
            signature: "+ (instancetype)URLWithString:(NSString *)str",
            parameters: [])
    s[:objc_class] = "NSURL"
    s[:selector] = "URLWithString:"
    s[:params] = [:string]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53b: must emit"
    assert_match(/URL\(string:\s*arg0\)/, out,
                 "T53b: NSURL の URLWithString は init(string:) bridge に変換")
    refute_match(/URL\.URLWithString\(/, out,
                 "T53b: 旧 ObjC method form は禁止 (Swift 6 has no URLWithString member)")
  end

  # T53c — objc_in_load の :string が UnsafePointer<CChar> 直渡しのため、 Swift
  # String を期待する init / method 引数 (URL.init(string:) 等) で compile error
  # になる。 Apple SDK の大半の ObjC string 引数は Swift bridge で String を
  # expect するので、 in_load は Swift String を emit すべき。 ただし
  # `+stringWithUTF8String:` のように raw cstr が必要な特殊 init は依然存在する
  # ため、 cstr 参照は `argN_cstr` 補助名で残す。
  def test_emit_objc_in_load_string_emits_swift_string_for_url_init
    s = sym(name: "NSURL.URLWithString:",
            kind: "objc_method_class",
            signature: "+ (instancetype)URLWithString:(NSString *)str",
            parameters: [])
    s[:objc_class] = "NSURL"
    s[:selector] = "URLWithString:"
    s[:params] = [:string]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53c: must emit"
    assert_match(/let arg0\s*=\s*String\(cString:/, out,
                 "T53c: :string in objc_in_load must convert to Swift String")
    assert_match(/URL\(string:\s*arg0\)/, out,
                 "T53c: URL init must receive Swift String arg0 (not raw cstr)")
  end

  # T53c 補完 — `+stringWithUTF8String:` は historically raw cstr を取る init
  # bridge (`String(utf8String: <UnsafePointer<CChar>>)`)。 in_load 変更後も
  # この init bridge が成立するよう、 cstr 補助名 `argN_cstr` を経由した
  # emit に切り替える。
  def test_emit_objc_class_method_string_with_utf8_string_uses_cstr_aux
    s = sym(name: "NSString.stringWithUTF8String:",
            kind: "objc_method_class",
            signature: "+ (instancetype)stringWithUTF8String:(const char *)str",
            parameters: [])
    s[:objc_class] = "NSString"
    s[:selector] = "stringWithUTF8String:"
    s[:params] = [:string]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53c: must emit"
    assert_match(/String\(utf8String:\s*arg0_cstr\)/, out,
                 "T53c: stringWithUTF8String は raw cstr 補助名 (arg0_cstr) を使う")
  end

  # T53d — emit_swift_property の klass は ObjC 名 (NSURLSession 等) のまま emit
  # されており、 Swift 6 の NS-rename (URLSession) に対応していない。
  # T52c の emit_swift_init / T52e の emit_objc_*_method と同様、
  # swift_bridged_class_name で NS-prefix を strip する。
  def test_emit_swift_property_strips_ns_prefix_for_url_session_shared
    s = sym(name: "NSURLSession.shared",
            kind: "swift_property",
            signature: "var shared: URLSession",
            parameters: [])
    s[:swift_class] = "NSURLSession"
    s[:swift_property] = "shared"
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53d: must emit"
    assert_match(/URLSession\.shared/, out,
                 "T53d: NS-prefix must be stripped (URLSession.shared)")
    refute_match(/NSURLSession\.shared/, out,
                 "T53d: ObjC NS-prefixed name must not appear (Swift 6 rename)")
  end

  # T53f — NS-strip 対象外: NSData / NSString / NSArray / NSDictionary / NSSet /
  # NSError は Swift bridge で value type (Data, String, ...) に struct rename
  # されているが API divergent (NSData.length vs Data.count 等)。 ユーザが明示
  # `klass: :NSData` で discover した場合はその ObjC class semantics を期待して
  # いるので NS-strip しない。
  def test_swift_bridged_class_name_preserves_value_type_ns_classes
    s = sym(name: "NSData.length",
            kind: "objc_method_instance",
            signature: "- (NSUInteger)length",
            parameters: [])
    s[:objc_class] = "NSData"
    s[:selector] = "length"
    s[:params] = []
    s[:return_kind] = :int

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53f: must emit"
    assert_match(/to:\s*NSData\.self/, out,
                 "T53f: NSData は NS-strip しない (Swift bridge Data struct は length 未定義)")
    refute_match(/to:\s*Data\.self/, out,
                 "T53f: NSData NS-strip 禁止 (value-type bridge は API divergent)")
  end

  # T53g — zero-arg ObjC selector + non-void return は Swift bridge で
  # property access (parens なし)、 zero-arg + void return は method call
  # (parens あり) として emit。
  # Apple ObjC→Swift bridge convention:
  # - NSData.length / NSData.bytes / NSArray.count → property (`obj.length`)
  # - NSURLSessionDataTask.resume / .suspend → method (`task.resume()`)
  # 判定 heuristic: return_kind が :void なら method、 それ以外なら property。
  def test_emit_objc_instance_method_zero_arg_property_form_for_length
    s = sym(name: "NSData.length",
            kind: "objc_method_instance",
            signature: "- (NSUInteger)length",
            parameters: [])
    s[:objc_class] = "NSData"
    s[:selector] = "length"
    s[:params] = []
    s[:return_kind] = :int

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53g: must emit"
    assert_match(/let raw = receiver\.length\b/, out,
                 "T53g: zero-arg + non-void return は property access (parens なし) 形")
    refute_match(/receiver\.length\(\)/, out,
                 "T53g: parens 形は method call、 property bridge には不適切")
  end

  def test_emit_objc_instance_method_zero_arg_method_form_for_resume
    s = sym(name: "NSURLSessionDataTask.resume",
            kind: "objc_method_instance",
            signature: "- (void)resume",
            parameters: [])
    s[:objc_class] = "NSURLSessionDataTask"
    s[:selector] = "resume"
    s[:params] = []
    s[:return_kind] = :void

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53g: must emit"
    assert_match(/receiver\.resume\(\)/, out,
                 "T53g: zero-arg + void return は method call (parens あり) 形")
  end

  # T53h — `:raw_ptr` return kind を追加。 NSData.bytes / その他 const void* /
  # UnsafeRawPointer 系 ObjC method の戻り値を Ruby Integer (raw bit pattern)
  # に marshal する。 Ruby 側で Fiddle::Pointer.new(int, len) で読み出す。
  # `:opaque_ref` と違い retain しない (raw pointer は dataの内部 buffer 等で
  # NSObject ではなく Unmanaged.passRetained を呼んではいけない)。
  def test_emit_objc_instance_method_raw_ptr_return_for_data_bytes
    s = sym(name: "NSData.bytes",
            kind: "objc_method_instance",
            signature: "- (const void *)bytes",
            parameters: [])
    s[:objc_class] = "NSData"
    s[:selector] = "bytes"
    s[:params] = []
    s[:return_kind] = :raw_ptr

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53h: must emit"
    assert_match(/return rb_ull2inum\(UInt64\(UInt\(bitPattern:\s*raw\)\)\)/, out,
                 "T53h: :raw_ptr return は raw bit pattern を Ruby Integer に")
    refute_match(/Unmanaged\.passRetained/, out,
                 "T53h: :raw_ptr は retain しない (data 内部 buffer は NSObject ではない)")
  end

  # T53i — :opaque_ref Hash 形で type が value-type (URL/Data/String/Array 等)
  # の場合、 unsafeBitCast(ptr, to: <Type>.self) は struct に対する未定義動作で
  # SIGTRAP になる。 NS-class (NSURL/NSData/...) 経由で bridge する必要がある:
  # `unsafeBitCast(ptr, to: NSURL.self) as URL`
  # URLSession.dataTask(with: URL) のような Swift bridged API に Ruby から
  # NSURL pointer を渡せるようにする必須機構。
  def test_emit_objc_in_load_opaque_ref_value_type_bridges_via_ns_class
    s = sym(name: "NSURLSession.dataTaskWithURL:completionHandler:",
            kind: "objc_method_instance",
            signature: "- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void(^)(NSData*, NSURLResponse*, NSError*))h",
            parameters: [])
    s[:objc_class] = "NSURLSession"
    s[:selector] = "dataTaskWithURL:completionHandler:"
    s[:params] = [{kind: :opaque_ref, type: "URL"},
                  {kind: :block_persistent, arity: 3,
                   types: ["Data?", "URLResponse?", "Error?"]}]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "T53i: must emit"
    assert_match(/unsafeBitCast\([^)]+,\s*to:\s*NSURL\.self\)\s*as\s*URL/, out,
                 "T53i: value-type URL は NSURL 経由で bridge")
    refute_match(/unsafeBitCast\([^)]+,\s*to:\s*URL\.self\)/, out,
                 "T53i: URL struct への直接 unsafeBitCast は SIGTRAP リスク、 emit しない")
  end

  # T54k — :cftype_ref Hash 形 (`{kind: :cftype_ref, type: "CGImage"}`) で
  # typed Swift CFType reference に unsafeBitCast する emit。 Vision の
  # `VNImageRequestHandler.init(cgImage: CGImage, options:)` 等、 Swift bridged
  # CFType class 引数を expect する path で必須。 現実装の :cftype_ref は
  # OpaquePointer に bitPattern で復元するだけで、 typed cast を emit せず
  # type mismatch error になっていた。
  def test_emit_objc_in_load_cftype_ref_hash_form_emits_typed_unsafe_bitcast
    s = sym(name: "VNImageRequestHandler.initWithCGImage:options:",
            kind: "objc_method_instance",
            signature: "- (instancetype)initWithCGImage:(CGImageRef)img options:(NSDictionary*)opts",
            parameters: [])
    s[:objc_class] = "VNImageRequestHandler"
    s[:selector] = "initWithCGImage:options:"
    s[:params] = [{kind: :cftype_ref, type: "CGImage"}, :opaque_ref]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54k: must emit"
    assert_match(/unsafeBitCast\([^)]+,\s*to:\s*CGImage\.self\)/, out,
                 "T54k: :cftype_ref Hash 形 type=CGImage は unsafeBitCast(ptr, to: CGImage.self) で typed cast")
  end

  # T54l — :nil_literal kind を新設。 Swift native Dict (`[VNImageOption: Any]?`)
  # 等、 raw pointer から復元できない引数を nil 固定で渡す経路。 Apple SDK で
  # options 引数のように nil 渡しが許容される API のための emit。 Hash 形
  # `{kind: :nil_literal, type: "[VNImageOption: Any]"}` で Swift 型注釈を指定。
  def test_emit_objc_in_load_nil_literal_emits_typed_nil_value
    s = sym(name: "VNImageRequestHandler.initWithCGImage:options:",
            kind: "objc_method_instance",
            signature: "- (instancetype)initWithCGImage:(CGImageRef)img options:(NSDictionary*)opts",
            parameters: [])
    s[:objc_class] = "VNImageRequestHandler"
    s[:selector] = "initWithCGImage:options:"
    s[:params] = [{kind: :cftype_ref, type: "CGImage"},
                  {kind: :nil_literal, type: "[VNImageOption: Any]"}]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54l: must emit"
    assert_match(/let arg1:\s*\[VNImageOption: Any\]\?\s*=\s*nil/, out,
                 "T54l: :nil_literal Hash 形は typed nil literal を emit")
  end

  # T54m — selector 末尾 `:error:` を Swift throws bridge に変換。 ObjC
  # `- (BOOL)method:(...)error:(NSError **)err` は Swift で
  # `func method(...) throws` に bridge される。 emit_objc_instance_method は
  # selector 末尾 `error:` を drop し、 do/catch ブロックで try call を包む。
  # success → Qtrue、 throw → Qfalse 戻り。 user 側 params 配列に error_out は
  # 含めない (= ObjC 引数数 - 1 個)。
  def test_emit_objc_instance_method_strips_error_out_emits_throws_bridge
    s = sym(name: "VNImageRequestHandler.perform:error:",
            kind: "objc_method_instance",
            signature: "- (BOOL)perform:(NSArray *)reqs error:(NSError **)err",
            parameters: [])
    s[:objc_class] = "VNImageRequestHandler"
    s[:selector] = "perform:error:"
    s[:params] = [{kind: :array_of_opaque_ref, type: "VNRequest"}]
    s[:return_kind] = :bool

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54m: must emit"
    assert_match(/do\s*\{/, out, "T54m: try call must be wrapped in do/catch")
    assert_match(/try\s+receiver\.perform\(arg0\)/, out,
                 "T54m: error: drop し try で throws bridge call (first arg unlabeled)")
    assert_match(/return Qtrue/, out,
                 "T54m: success path で Qtrue 返却")
    assert_match(/catch\b/, out, "T54m: throws をキャッチする catch 節")
    assert_match(/return Qfalse/, out,
                 "T54m: throw path で Qfalse 返却")
  end

  # T54n — return_kind に :array_of_opaque_ref Hash 形を新設。 Swift typed
  # array 戻り値 (`[VNRecognizedTextObservation]?` 等) を Ruby Array<Integer>
  # に marshal する。 各要素は Unmanaged.passRetained で raw pointer 化、
  # Ruby Integer として Array に push。 nilable: true なら nil → Qnil。
  def test_emit_swift_property_array_of_opaque_ref_marshals_to_ruby_array
    s = sym(name: "VNRecognizeTextRequest.results",
            kind: "swift_property",
            signature: nil,
            parameters: [])
    s[:swift_class] = "VNRecognizeTextRequest"
    s[:swift_property] = "results"
    s[:return_kind] = {kind: :array_of_opaque_ref,
                      type: "VNRecognizedTextObservation",
                      nilable: true}

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54n: must emit"
    assert_match(/rb_ary_new/, out, "T54n: 新規 Ruby Array を構築")
    assert_match(/rb_ary_push/, out, "T54n: 各要素を Array に push")
    assert_match(/Unmanaged\.passRetained/, out,
                 "T54n: 各要素を opaque ref として retain")
    assert_match(/return Qnil/, out, "T54n: nilable nil 時は Qnil")
  end

  # T54o — single-segment instance method `topCandidates(_:)` で :int arg を
  # 取り、 :array_of_opaque_ref Hash 形 return_kind で typed Swift array を
  # 返す。 emit_objc_instance_method の return_kind が Hash 形でも crash せず
  # array marshal を出すこと。 加えて :int arg を Swift bridged Int 期待 API
  # と互換に emit する (Int64 直渡しは Swift 6 で型 mismatch リスク)。
  def test_emit_objc_instance_method_array_of_opaque_ref_return_with_int_arg
    s = sym(name: "VNRecognizedTextObservation.topCandidates:",
            kind: "objc_method_instance",
            signature: "- (NSArray<VNRecognizedText *> *)topCandidates:(NSUInteger)maxCount",
            parameters: [])
    s[:objc_class] = "VNRecognizedTextObservation"
    s[:selector] = "topCandidates:"
    s[:params] = [:int]
    s[:return_kind] = {kind: :array_of_opaque_ref, type: "VNRecognizedText",
                      nilable: false}

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54o: must emit"
    assert_match(/receiver\.topCandidates\(arg0\)/, out,
                 "T54o: single-segment selector で label なし call")
    assert_match(/rb_ary_new/, out, "T54o: array return marshal")
    assert_match(/Unmanaged\.passRetained/, out,
                 "T54o: 各要素を opaque ref として retain")
  end

  # T54p — return_kind :string を swift_init_return_lines / objc_return_lines に
  # 追加。 Swift String? property (`VNRecognizedText.string` 等) を Ruby String
  # VALUE に marshal。 nil → Qnil、 non-nil → withCString → rb_str_new_cstr。
  def test_emit_swift_property_string_return_marshals_to_ruby_string
    s = sym(name: "VNRecognizedText.string",
            kind: "swift_property",
            signature: nil,
            parameters: [])
    s[:swift_class] = "VNRecognizedText"
    s[:swift_property] = "string"
    s[:return_kind] = :string

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54p: must emit"
    assert_match(/withCString/, out,
                 "T54p: Swift String を CString 経由で marshal")
    assert_match(/rb_str_new_cstr/, out,
                 "T54p: Ruby String VALUE 化は rb_str_new_cstr 経由")
  end

  # T54q — objc_in_load の :int を Swift Int に emit。 Apple SDK の Swift
  # bridged API (`topCandidates(_ maxCount: Int)` 等) は Int 期待が標準で、
  # Int64 直渡しは Swift 6 で型 mismatch error になる。 KB-stored C function
  # path (IntMarshaller) は引き続き Int64 を emit (regression なし)。
  def test_emit_objc_in_load_int_kind_emits_swift_int_for_apple_bridged_api
    s = sym(name: "VNRecognizedTextObservation.topCandidates:",
            kind: "objc_method_instance",
            signature: "- (NSArray *)topCandidates:(NSUInteger)maxCount",
            parameters: [])
    s[:objc_class] = "VNRecognizedTextObservation"
    s[:selector] = "topCandidates:"
    s[:params] = [:int]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54q: must emit"
    assert_match(/let arg0:\s*Int\s*=\s*Int\(rb_num2ll\(argv\[1\]\)\)/, out,
                 "T54q: objc_in_load :int は Swift Int で emit (Apple SDK 互換)")
  end

  # T54r — :cftype_ref Hash 形は autoarc box pointer も受ける必要がある。
  # CGImageSourceCreateImageAtIndex 等 CF*Create* 関数の戻り値は box pointer
  # (autoarc) であり、 次の Apple.discover (VNImageRequestHandler.init(cgImage:))
  # に渡す時に runtime_arc_unbox_cftype で内部 CGImage pointer に unwrap が
  # 必要。 T54k 初版は box unwrap せず直接 unsafeBitCast していたため box
  # pointer を CGImage と誤解してクラッシュしていた。
  def test_emit_objc_in_load_cftype_ref_hash_form_unwraps_autoarc_box
    s = sym(name: "VNImageRequestHandler.initWithCGImage:options:",
            kind: "objc_method_instance",
            signature: "- (instancetype)initWithCGImage:(CGImageRef)img options:(NSDictionary*)opts",
            parameters: [])
    s[:objc_class] = "VNImageRequestHandler"
    s[:selector] = "initWithCGImage:options:"
    s[:params] = [{kind: :cftype_ref, type: "CGImage"},
                  {kind: :nil_literal, type: "[VNImageOption: Any]"}]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54r: must emit"
    assert_match(/runtime_arc_unbox_cftype/, out,
                 "T54r: :cftype_ref Hash 形は autoarc box を unwrap して内部 CF pointer を取り出す")
  end

  # T54s — :nil_literal Hash 形に :value 指定を追加。 Apple SDK の non-Optional
  # native Swift type (`[VNImageOption: Any]` default `[:]`) を埋める path。
  # value: 指定時は Optional? を付けず value 直 literal を emit する。
  def test_emit_objc_in_load_nil_literal_value_override_emits_concrete_literal
    s = sym(name: "VNImageRequestHandler.initWithCGImage:options:",
            kind: "objc_method_instance",
            signature: "- (instancetype)initWithCGImage:(CGImageRef)img options:(NSDictionary*)opts",
            parameters: [])
    s[:objc_class] = "VNImageRequestHandler"
    s[:selector] = "initWithCGImage:options:"
    s[:params] = [{kind: :cftype_ref, type: "CGImage"},
                  {kind: :nil_literal, type: "[VNImageOption: Any]", value: "[:]"}]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54s: must emit"
    assert_match(/let arg1:\s*\[VNImageOption: Any\]\s*=\s*\[:\]/, out,
                 "T54s: value 指定で Optional? なし non-nil literal を emit")
    refute_match(/\[VNImageOption: Any\]\?\s*=\s*nil/, out,
                 "T54s: value 指定では nil literal は emit しない")
  end

  # T54t — 引数つき swift_init の failability は initializer 文字列の `?` で
  # 判定。 `init(cgImage:options:)` (no ?) は non-failable で `let v = Klass(...)`、
  # `init?(string:)` (with ?) は failable で `guard let v = ... else { Qnil }`。
  # Apple SDK の majority の class init は non-failable (Vision の
  # VNImageRequestHandler 等)、 既存挙動 (引数つき = 強制 failable) は API 互換
  # 不能で誤誘導の元。
  def test_emit_swift_init_with_args_uses_non_failable_when_no_question_mark
    s = sym(name: "VNImageRequestHandler.init(cgImage:options:)",
            kind: "swift_init",
            signature: "init(cgImage:options:)", parameters: [])
    s[:swift_class] = "VNImageRequestHandler"
    s[:swift_initializer] = "init(cgImage:options:)"
    s[:params] = [{kind: :cftype_ref, type: "CGImage"},
                  {kind: :nil_literal, type: "[VNImageOption: Any]", value: "[:]"}]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "T54t: must emit"
    assert_match(/let v = VNImageRequestHandler\(cgImage:/, out,
                 "T54t: ? なし init は non-failable form (`let v = ...`)")
    refute_match(/guard let v = VNImageRequestHandler\(/, out,
                 "T54t: non-failable init は guard let を出さない")
  end
end
