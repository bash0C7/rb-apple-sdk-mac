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
    # Out-param vars are named after the param itself (`o`), so multi-out-param
    # call sites can have one var per out-param without name collisions.
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
  # CF input handling: declares an Optional of the
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

  # single-segment class method の preposition-aware bridge。
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
    refute_nil out, "must emit"
    assert_match(/Thread\.sleep\(forTimeInterval:\s*arg0\)/, out,
                 "For-preposition verb must split as `sleep(forTimeInterval:)`")
    refute_match(/Thread\.sleepForTimeInterval\(arg0\)/, out,
                 "must not emit obsoleted ObjC method form")
  end

  # objc_in_load :opaque_ref に Hash 形 type ヒント対応。
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
    refute_nil out, "must emit"
    assert_match(/unsafeBitCast\([^)]+,\s*to:\s*Operation\.self\)/, out,
                 "typed Swift cast (unsafeBitCast to: Operation.self) must be emitted")
  end

  # multi-segment instance method (verb-with-type pattern 非該当) の
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
    refute_nil out, "must emit"
    assert_match(/receiver\.addOperations\(arg0,\s*waitUntilFinished:\s*arg1\)/, out,
                 "first arg must be unlabeled (Apple SDK ObjC→Swift bridge convention)")
    refute_match(/receiver\.addOperations\(waitUntilFinished:\s*arg0\)/, out,
                 "must not assign first segment as first arg label")
  end

  # emit_objc_class_method の klass NS-strip。
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
    refute_nil out, "must emit"
    # Swift type 参照 (call site, type 注釈) で NS-prefix が出てはいけない。
    # export identifier (`glue_abc_NSBlockOperation_blockOperationWithBlock_`)
    # は SDK 内部の symbol 名なので除外する。
    refute_match(/NSBlockOperation\(/, out,
                 "NS-prefix must not appear in Swift call site")
    refute_match(/to:\s*NSBlockOperation\b/, out,
                 "NS-prefix must not appear in Swift type annotation")
    assert_match(/BlockOperation\(block:\s*arg0\)/, out,
                 "must call Swift bridged BlockOperation(block: arg0)")
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
                 "non-optional Self 戻り値で raw == nil 比較は禁止 (warning)")
    refute_match(/raw!\s+as\s+AnyObject/, out,
                 "non-optional Self 戻り値で raw! force unwrap は禁止 (compile error)")
  end

  # objc_in_load (emit_objc_class_method / emit_objc_instance_method /
  # emit_swift_init から共通呼び出し) が新 kinds + Hash 形 type ヒントに
  # 対応すること。
  # 1: Marshaller::REGISTRY 経路 (C function) と objc_in_load 経路
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
    refute_nil out, "objc_method_class with block_persistent_void must emit"
    assert_match(/@convention\(block\)\s*\(\)\s*->\s*Void/, out,
                 "must emit @convention(block) () -> Void closure type via objc_in_load")
    assert_match(/runtime_threading_enqueue/, out,
                 "must dispatch to Ruby Proc via runtime_threading_enqueue")
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
    refute_nil out, "objc_method_instance with Hash array_of_opaque_ref must emit"
    assert_match(/NSMutableArray/, out,
                 "must build NSMutableArray for Hash-form array_of_opaque_ref")
    assert_match(/as!\s*\[Operation\]|as\s+\[Operation\]/, out,
                 "must cast to typed array using Hash :type ('Operation')")
    assert_match(/runtime_rb_array_len/, out,
                 "must iterate via runtime_rb_array_len")
  end

  # Swift 6 ObjC class bridge: NS-prefix strip + non-failable init。
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
    refute_nil out, "swift_init must emit"
    assert_match(/OperationQueue\(\)/, out,
                 "NS-prefix must be stripped in emitted Swift init call")
    refute_match(/NSOperationQueue\(\)/, out,
                 "ObjC NS-prefixed name must not appear in Swift init call (Swift 6 rename)")
    assert_match(/let v = OperationQueue\(\)/, out,
                 "non-failable init must emit 'let v = ...' (no guard)")
    refute_match(/guard let v = OperationQueue\(\)/, out,
                 "non-failable Swift init must not be wrapped in guard let")
  end

  # () -> Void escaping block (NSBlockOperation の +blockOperationWithBlock:)。
  # 既存 block_persistent は (Arg?) -> Void 形 (BoxedBlockHandle 経由) で、
  # void→void block を直接 emit するパスがなかった。
  def test_emits_block_persistent_void_kind_for_zero_arity_callback
    s = sym(name: "F",
            signature: "void F(void (^block)(void))",
            parameters: [{ name: "block", type: "void (^)(void)",
                           kind: "block_persistent_void", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    refute_nil out, "block_persistent_void kind must be supported"
    assert_match(/@convention\(block\)\s*\(\)\s*->\s*Void/, out,
                 "must emit @convention(block) () -> Void closure type")
    assert_match(/ThreadingBridge\.enqueueFromAppleThread/, out,
                 "must dispatch to Ruby Proc via ThreadingBridge")
    assert_match(/rb_hash_aset\(runtime_proc_registry_get\(\)/, out,
                 "must pin Ruby Proc in proc_registry")
  end

  # Ruby Array → Swift [<OpaqueType>] marshaller. NSOperationQueue の
  # addOperations:waitUntilFinished: と VNImageRequestHandler の
  # performRequests:error: の共通依存。 Apple framework instance method の
  # NSArray-of-opaque-ref パラメータを事前宣言なしで通す。
  def test_emits_array_of_opaque_ref_kind_uses_nsmutablearray_loop
    s = sym(name: "F",
            signature: "void F(NSArray<VNRequest *> *_Nonnull requests)",
            parameters: [{ name: "requests", type: "VNRequest",
                           kind: "array_of_opaque_ref", is_out_param: false }])
    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "array_of_opaque_ref kind must be supported"
    assert_match(/NSMutableArray/, out, "must build NSMutableArray")
    assert_match(/RARRAY_LEN|rb_ary_entry/, out,
                 "must iterate Ruby Array via RARRAY_LEN/rb_ary_entry")
    assert_match(/as!\s*\[VNRequest\]|as\s+\[VNRequest\]/, out,
                 "must cast NSMutableArray to Swift [VNRequest]")
  end

  # :block_persistent Hash 形 (arity, types) で URLSession completion
  # handler のような multi-arg typed escaping block を emit する。 既存の
  # :block_persistent (Symbol 形) は (Data?, URLResponse?, Error?) -> Void に
  # 固定で、 Ruby callback には err 単一 Int64 (nil → 0, non-nil → -1) しか
  # 渡らない。 data_ref / response_ref / error_ref 3 個を Ruby block の引数に
  # 渡すため、 N-arg dispatch が必須。
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
    refute_nil out, "block_persistent Hash 形 (arity 3) must emit"
    assert_match(/runtime_threading_enqueue_3/, out,
                 "arity 3 must dispatch via runtime_threading_enqueue_3 (3 Int64 args)")
    assert_match(/NSData\?/, out,
                 "typed Swift signature must include NSData?")
    assert_match(/NSURLResponse\?/, out,
                 "typed Swift signature must include NSURLResponse?")
    assert_match(/NSError\?/, out,
                 "typed Swift signature must include NSError?")
    assert_match(/rb_hash_aset\(runtime_proc_registry_get\(\)/, out,
                 "must pin Ruby Proc in proc_registry (lifecycle)")
  end

  # swift_call_for_class_method の `<verb>With<Type>:` regex は
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
    refute_nil out, "must emit"
    assert_match(/URL\(string:\s*arg0\)/, out,
                 "NSURL の URLWithString は init(string:) bridge に変換")
    refute_match(/URL\.URLWithString\(/, out,
                 "旧 ObjC method form は禁止 (Swift 6 has no URLWithString member)")
  end

  # objc_in_load の :string が UnsafePointer<CChar> 直渡しのため、 Swift
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
    refute_nil out, "must emit"
    assert_match(/let arg0\s*=\s*String\(cString:/, out,
                 ":string in objc_in_load must convert to Swift String")
    assert_match(/URL\(string:\s*arg0\)/, out,
                 "URL init must receive Swift String arg0 (not raw cstr)")
  end

  # `+stringWithUTF8String:` は raw cstr を取る init bridge
  # (`String(utf8String: <UnsafePointer<CChar>>)`)。 in_load の Swift String 化に
  # 伴い、 この init bridge は cstr 補助名 `argN_cstr` を経由した emit に切り
  # 替えてある。
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
    refute_nil out, "must emit"
    assert_match(/String\(utf8String:\s*arg0_cstr\)/, out,
                 "stringWithUTF8String は raw cstr 補助名 (arg0_cstr) を使う")
  end

  # emit_swift_property の klass は Swift 6 の NS-rename (URLSession 等) に
  # 揃える必要がある。 emit_swift_init / emit_objc_*_method と同様、
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
    refute_nil out, "must emit"
    assert_match(/URLSession\.shared/, out,
                 "NS-prefix must be stripped (URLSession.shared)")
    refute_match(/NSURLSession\.shared/, out,
                 "ObjC NS-prefixed name must not appear (Swift 6 rename)")
  end

  # NS-strip 対象外: NSData / NSString / NSArray / NSDictionary / NSSet /
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
    refute_nil out, "must emit"
    assert_match(/to:\s*NSData\.self/, out,
                 "NSData は NS-strip しない (Swift bridge Data struct は length 未定義)")
    refute_match(/to:\s*Data\.self/, out,
                 "NSData NS-strip 禁止 (value-type bridge は API divergent)")
  end

  # zero-arg ObjC selector + non-void return は Swift bridge で
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
    refute_nil out, "must emit"
    assert_match(/let raw = receiver\.length\b/, out,
                 "zero-arg + non-void return は property access (parens なし) 形")
    refute_match(/receiver\.length\(\)/, out,
                 "parens 形は method call、 property bridge には不適切")
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
    refute_nil out, "must emit"
    assert_match(/receiver\.resume\(\)/, out,
                 "zero-arg + void return は method call (parens あり) 形")
  end

  # `:raw_ptr` return kind を追加。 NSData.bytes / その他 const void* /
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
    refute_nil out, "must emit"
    assert_match(/return rb_ull2inum\(UInt64\(UInt\(bitPattern:\s*raw\)\)\)/, out,
                 ":raw_ptr return は raw bit pattern を Ruby Integer に")
    refute_match(/Unmanaged\.passRetained/, out,
                 ":raw_ptr は retain しない (data 内部 buffer は NSObject ではない)")
  end

  # :opaque_ref Hash 形で type が value-type (URL/Data/String/Array 等)
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
    refute_nil out, "must emit"
    assert_match(/unsafeBitCast\([^)]+,\s*to:\s*NSURL\.self\)\s*as\s*URL/, out,
                 "value-type URL は NSURL 経由で bridge")
    refute_match(/unsafeBitCast\([^)]+,\s*to:\s*URL\.self\)/, out,
                 "URL struct への直接 unsafeBitCast は SIGTRAP リスク、 emit しない")
  end

  # :cftype_ref Hash 形 (`{kind: :cftype_ref, type: "CGImage"}`) で
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
    refute_nil out, "must emit"
    assert_match(/unsafeBitCast\([^)]+,\s*to:\s*CGImage\.self\)/, out,
                 ":cftype_ref Hash 形 type=CGImage は unsafeBitCast(ptr, to: CGImage.self) で typed cast")
  end

  # :nil_literal kind を新設。 Swift native Dict (`[VNImageOption: Any]?`)
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
    refute_nil out, "must emit"
    assert_match(/let arg1:\s*\[VNImageOption: Any\]\?\s*=\s*nil/, out,
                 ":nil_literal Hash 形は typed nil literal を emit")
  end

  # selector 末尾 `:error:` を Swift throws bridge に変換。 ObjC
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
    refute_nil out, "must emit"
    assert_match(/do\s*\{/, out, "try call must be wrapped in do/catch")
    assert_match(/try\s+receiver\.perform\(arg0\)/, out,
                 "error: drop し try で throws bridge call (first arg unlabeled)")
    assert_match(/return Qtrue/, out,
                 "success path で Qtrue 返却")
    assert_match(/catch\b/, out, "throws をキャッチする catch 節")
    assert_match(/return Qfalse/, out,
                 "throw path で Qfalse 返却")
  end

  # return_kind に :array_of_opaque_ref Hash 形を新設。 Swift typed
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
    refute_nil out, "must emit"
    assert_match(/rb_ary_new/, out, "新規 Ruby Array を構築")
    assert_match(/rb_ary_push/, out, "各要素を Array に push")
    assert_match(/Unmanaged\.passRetained/, out,
                 "各要素を opaque ref として retain")
    assert_match(/return Qnil/, out, "nilable nil 時は Qnil")
  end

  # single-segment instance method `topCandidates(_:)` で :int arg を
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
    refute_nil out, "must emit"
    assert_match(/receiver\.topCandidates\(arg0\)/, out,
                 "single-segment selector で label なし call")
    assert_match(/rb_ary_new/, out, "array return marshal")
    assert_match(/Unmanaged\.passRetained/, out,
                 "各要素を opaque ref として retain")
  end

  # return_kind :string を swift_init_return_lines / objc_return_lines に
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
    refute_nil out, "must emit"
    assert_match(/withCString/, out,
                 "Swift String を CString 経由で marshal")
    assert_match(/rb_str_new_cstr/, out,
                 "Ruby String VALUE 化は rb_str_new_cstr 経由")
  end

  # objc_in_load の :int を Swift Int に emit。 Apple SDK の Swift
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
    refute_nil out, "must emit"
    assert_match(/let arg0:\s*Int\s*=\s*Int\(rb_num2ll\(argv\[1\]\)\)/, out,
                 "objc_in_load :int は Swift Int で emit (Apple SDK 互換)")
  end

  # :cftype_ref Hash 形は autoarc box pointer も受ける必要がある。
  # CGImageSourceCreateImageAtIndex 等 CF*Create* 関数の戻り値は box pointer
  # (autoarc) であり、 次の Apple.discover (VNImageRequestHandler.init(cgImage:))
  # に渡す時に runtime_arc_unbox_cftype で内部 CGImage pointer に unwrap が
  # 必要。
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
    refute_nil out, "must emit"
    assert_match(/runtime_arc_unbox_cftype/, out,
                 ":cftype_ref Hash 形は autoarc box を unwrap して内部 CF pointer を取り出す")
  end

  # :nil_literal Hash 形に :value 指定を追加。 Apple SDK の non-Optional
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
    refute_nil out, "must emit"
    assert_match(/let arg1:\s*\[VNImageOption: Any\]\s*=\s*\[:\]/, out,
                 "value 指定で Optional? なし non-nil literal を emit")
    refute_match(/\[VNImageOption: Any\]\?\s*=\s*nil/, out,
                 "value 指定では nil literal は emit しない")
  end

  # 引数つき swift_init の failability は initializer 文字列の `?` で
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
    refute_nil out, "must emit"
    assert_match(/let v = VNImageRequestHandler\(cgImage:/, out,
                 "? なし init は non-failable form (`let v = ...`)")
    refute_match(/guard let v = VNImageRequestHandler\(/, out,
                 "non-failable init は guard let を出さない")
  end

  # swift_property の instance: true で receiver argv[0] を取る instance
  # property emit。 既存 (instance: false / 不在) は class static property
  # (URLSession.shared 互換)。 Apple SDK の Swift property は instance
  # property が majority (Vision の VNRecognizeTextRequest.results 等)。
  def test_emit_swift_property_instance_takes_receiver_from_argv0
    s = sym(name: "VNRecognizeTextRequest.results",
            kind: "swift_property",
            signature: nil,
            parameters: [])
    s[:swift_class] = "VNRecognizeTextRequest"
    s[:swift_property] = "results"
    s[:instance] = true
    s[:return_kind] = {kind: :array_of_opaque_ref,
                      type: "VNRecognizedTextObservation",
                      nilable: true}

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "must emit"
    assert_match(/let receiver = unsafeBitCast/, out,
                 "instance property は argv[0] receiver を取る")
    assert_match(/to: VNRecognizeTextRequest\.self/, out,
                 "receiver は typed Swift class に cast")
    assert_match(/let raw = receiver\.results/, out,
                 "receiver.prop で instance property をアクセス")
  end

  # :float return kind の Swift Float (= VNConfidence) を Double に明示
  # 変換して rb_float_new に渡す。 Swift 6 は Float → Double の暗黙変換を行わず
  # `cannot convert value of type 'Float' to expected argument type 'Double'`
  # で compile error。
  def test_emit_swift_property_float_return_casts_to_double_for_rb_float_new
    s = sym(name: "VNRecognizedText.confidence",
            kind: "swift_property",
            signature: nil, parameters: [])
    s[:swift_class] = "VNRecognizedText"
    s[:swift_property] = "confidence"
    s[:instance] = true
    s[:return_kind] = :float

    out = gen.generate(framework: "Vision", symbol: s, glue_id: "abc")
    refute_nil out, "must emit"
    assert_match(/rb_float_new\(Double\(raw\)\)/, out,
                 ":float return は Double に明示 cast (Swift 6 互換)")
  end

  # postmortem 2026-05-14 #3 regression net: swift_init で `:uint32` param。
  # AVAudioFormat(standardFormatWithSampleRate:channels:) の channels は
  # AVAudioChannelCount (typealias UInt32)。 ObjcMarshalling.in_load の :uint32
  # case が swift_init 経路にも適用されることを pin する。
  def test_emit_swift_init_uint32_param_emits_uint32_narrow
    s = sym(name: "AVAudioFormat.init(standardFormatWithSampleRate:channels:)",
            kind: "swift_init",
            signature: "init(standardFormatWithSampleRate:channels:)",
            parameters: [])
    s[:swift_class] = "AVAudioFormat"
    s[:swift_initializer] = "init(standardFormatWithSampleRate:channels:)"
    s[:params] = [:float, :uint32]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "AVFAudio", symbol: s, glue_id: "abc")
    refute_nil out, ":uint32 param must be supported in swift_init path"
    assert_match(/let arg1:\s*UInt32\s*=\s*UInt32\(rb_num2ull\(argv\[1\]\)\)/, out,
                 ":uint32 in_load は rb_num2ull → UInt32 narrow")
    assert_match(/AVAudioFormat\(standardFormatWithSampleRate:\s*arg0,\s*channels:\s*arg1\)/, out,
                 "labels と args が swift_initializer signature に従う")
  end

  # postmortem 2026-05-14 #3 regression net: objc_method_instance で `:uint32`。
  # AVAudioPlayerNode.scheduleFile(..., at: AVAudioTime?, completionHandler:) 等
  # 直接 :uint32 を取る instance method は少ないが、 in_load matrix の網羅性
  # のため pin する (ObjcMarshalling.in_load :uint32 case が argv_offset: 1
  # 経由でも正しく出ること)。
  def test_emit_objc_instance_method_uint32_param_offsets_argv
    s = sym(name: "AVAudioBuffer.setFrameLength:",
            kind: "objc_method_instance",
            signature: nil, parameters: [])
    s[:objc_class] = "AVAudioBuffer"
    s[:selector] = "setFrameLength:"
    s[:params] = [:uint32]
    s[:return_kind] = :void

    out = gen.generate(framework: "AVFAudio", symbol: s, glue_id: "abc")
    refute_nil out, ":uint32 must be supported in objc_method_instance path"
    assert_match(/let arg0:\s*UInt32\s*=\s*UInt32\(rb_num2ull\(argv\[1\]\)\)/, out,
                 ":uint32 in_load は argv_offset 1 (receiver 後) で emit")
  end

  # postmortem 2026-05-14 #4 regression net: swift_initializer 末尾 `throws`。
  # AVAudioFile.init(forReading:) は throws、 user が
  # `swift_initializer: "init(forReading:) throws"` と書くと emit_swift_init が
  # try? + guard let で wrap して失敗時 Qnil を返す。 swift_init_labels regex も
  # 末尾 throws を許容して labels 抽出が止まらないことが必要。
  def test_emit_swift_init_throws_wraps_in_try_question
    s = sym(name: "AVAudioFile.init(forReading:)",
            kind: "swift_init",
            signature: nil, parameters: [])
    s[:swift_class] = "AVAudioFile"
    s[:swift_initializer] = "init(forReading:) throws"
    s[:params] = [:opaque_ref]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "AVFAudio", symbol: s, glue_id: "abc")
    refute_nil out, "throws swift_initializer must emit"
    assert_match(/guard let v = try\?\s*AVAudioFile\(forReading:\s*arg0\)\s*else\s*\{\s*return Qnil\s*\}/, out,
                 "throws init は try? + guard let で wrap、 失敗時 Qnil")
    refute_match(/init\(forReading:\)\s+throws/, out,
                 "Swift コード本体に末尾 throws マーカーが漏れたら label 抽出が壊れた印")
  end

  # postmortem 2026-05-14 #5 regression net: ObjC single-segment
  # `<verb>AndReturnError:` の throws bridge。 `:error:` multi-segment と並んで
  # AVAudioEngine.startAndReturnError: のような single-segment 末尾も同じ
  # do/catch bridge に乗ること。
  def test_emit_objc_instance_method_single_segment_and_return_error_throws_bridge
    s = sym(name: "AVAudioEngine.startAndReturnError",
            kind: "objc_method_instance",
            signature: "- (BOOL)startAndReturnError:(NSError **)err",
            parameters: [])
    s[:objc_class] = "AVAudioEngine"
    s[:selector] = "startAndReturnError:"
    s[:params] = []
    s[:return_kind] = :bool

    out = gen.generate(framework: "AVFAudio", symbol: s, glue_id: "abc")
    refute_nil out, "single-segment AndReturnError selector must emit"
    assert_match(/do\s*\{/, out, "try call must be wrapped in do/catch")
    assert_match(/try\s+receiver\.start\(\)/, out,
                 "AndReturnError suffix を drop し try で Swift bridged start() call")
    assert_match(/return Qtrue/, out, "success → Qtrue")
    assert_match(/catch\b/, out, "throw を catch")
    assert_match(/return Qfalse/, out, "throw → Qfalse")
  end

  # postmortem 2026-05-14 #7 regression net: void return の objc_method_instance
  # は `let raw = receiver.method(args)` ではなく単独 statement `receiver.method(args)`
  # で emit する。 `let raw` を Void に bind すると Swift 6 warning
  # (`constant 'raw' inferred to have type 'Void'`)、 ValidationGates の
  # error_stage が warning と本物 error を混同する原因になる。
  def test_emit_objc_instance_method_void_return_emits_bare_statement
    s = sym(name: "AVAudioEngine.attach",
            kind: "objc_method_instance",
            signature: nil, parameters: [])
    s[:objc_class] = "AVAudioEngine"
    s[:selector] = "attach:"
    s[:params] = [{kind: :opaque_ref, type: "AVAudioNode"}]
    s[:return_kind] = :void

    out = gen.generate(framework: "AVFAudio", symbol: s, glue_id: "abc")
    refute_nil out, "void return objc_method_instance must emit"
    assert_match(/^\s{4}receiver\.attach\(arg0\)$/, out,
                 "void return は単独 statement で emit (let raw bind しない)")
    refute_match(/let raw\s*=\s*receiver\.attach\(arg0\)/, out,
                 "void return を `let raw` に bind すると Swift 6 warning")
    assert_match(/return Qnil/, out, "void return は Ruby 側に Qnil 返却")
  end
end
class TestTemplateGenerator < Test::Unit::TestCase
  def setup
    @gen = AppleSDKMac::GlueCompiler::TemplateGenerator.new
  end

  def test_recognizes_pure_c_function_with_string_args
    sym = {
      name: "MIDIClientCreate",
      kind: "function",
      abi: "c",
      signature: "OSStatus MIDIClientCreate(CFStringRef name, MIDIClientRef *outRef)",
      parameters_json: JSON.dump([
        { "name" => "name", "type" => "CFStringRef",
          "kind" => "string", "is_out_param" => false, "nullability" => "unspecified" },
        { "name" => "outRef", "type" => "MIDIClientRef *",
          "kind" => "opaque_ref", "is_out_param" => true, "nullability" => "unspecified" }
      ])
    }
    swift = @gen.generate(framework: "CoreMIDI", symbol: sym, glue_id: "abc")
    refute_nil swift
    assert_match(/import CoreMIDI/, swift)
    assert_match(/glue_abc_MIDIClientCreate/, swift)
  end

  def test_returns_nil_for_unknown_shape
    sym = {
      name: "WeirdGenericFn",
      kind: "function",
      abi: "swift",
      signature: "func WeirdGenericFn<T: Equatable, U: Hashable>(...) async throws -> AsyncStream<T>"
    }
    swift = @gen.generate(framework: "Foo", symbol: sym, glue_id: "x")
    assert_nil swift
  end

  # Task 16: variadic_args Marshaller emits withVaList wrapper.
  def test_variadic_args_emits_with_va_list
    sym = {
      kind: "function", abi: "c", name: "MyLog", signature: "void MyLog(const char *, ...)",
      parameters_json: '[
        {"name":"fmt","type":"const char *","kind":"string","is_out_param":false,"nullability":"unspecified"},
        {"name":"vargs","type":"...","kind":"variadic_args","is_out_param":false,"nullability":"unspecified"}
      ]'
    }
    swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
      framework: "Acme", symbol: sym, glue_id: "ab12"
    )
    refute_nil swift
    assert_match(/withVaList\(/, swift)
    assert_match(/rubyValueToCVarArg/, swift)
  end

  # Task 15: multi-out-param returns Ruby Hash with named keys.
  def test_multi_out_param_returns_hash_with_named_keys
    sym = {
      kind: "function", abi: "c", name: "TwoOut", signature: "OSStatus TwoOut(MIDIClientRef *, MIDIClientRef *)",
      parameters_json: '[
        {"name":"a","type":"MIDIClientRef * _Nonnull","kind":"opaque_ref","is_out_param":true,"nullability":"nonnull"},
        {"name":"b","type":"MIDIClientRef * _Nonnull","kind":"opaque_ref","is_out_param":true,"nullability":"nonnull"}
      ]'
    }
    swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new.generate(
      framework: "Acme", symbol: sym, glue_id: "ab12"
    )
    refute_nil swift
    assert_match(/let multi_out_h = rb_hash_new\(\)/, swift)
    assert_match(/rb_hash_aset\(multi_out_h, rb_str_new_cstr\("a"\)/, swift)
    assert_match(/rb_hash_aset\(multi_out_h, rb_str_new_cstr\("b"\)/, swift)
    assert_match(/return multi_out_h/, swift)
  end

  # Task 14: struct_out Marshaller emits rb_hash_new + per-field rb_hash_aset.
  def test_struct_out_emits_hash_new_aset_per_field
    kc = FakeKC.new({
      "Status" => { name: "Status", fields_json: JSON.dump([
        { name: "ok",   type: "Bool",  kind: "bool" },
        { name: "code", type: "Int32", kind: "int" }
      ]) }
    })
    sym = {
      kind: "function", abi: "c", name: "GetStatus", signature: "OSStatus GetStatus(Status *)",
      parameters_json: '[{"name":"out","type":"Status * _Nonnull","kind":"struct_out","is_out_param":true,"nullability":"nonnull"}]'
    }
    swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc).generate(
      framework: "Acme", symbol: sym, glue_id: "ab12"
    )
    refute_nil swift
    assert_match(/var out_struct = Status\(\)/, swift)
    assert_match(/let status = GetStatus\(&out_struct\)/, swift)
    assert_match(/rb_hash_aset.*"ok"/, swift)
    assert_match(/rb_hash_aset.*"code"/, swift)
    assert_match(/return out_h/, swift)
  end

  # Task 13: struct_in Marshaller — flat, nested depth-1, cycle detection.
  class FakeKC
    def initialize(map); @map = map; end
    def lookup_symbol(framework:, symbol:); @map[symbol]; end
    def close; end
  end

  def test_struct_in_emits_field_by_field_hash_aref
    kc = FakeKC.new({
      "Point" => { name: "Point", fields_json: JSON.dump([
        { name: "x", type: "Int32", kind: "int" },
        { name: "y", type: "Int32", kind: "int" }
      ]) }
    })
    sym = {
      kind: "function", abi: "c", name: "DrawPoint", signature: "void DrawPoint(Point *)",
      parameters_json: '[{"name":"p","type":"Point * _Nonnull","kind":"struct_in","is_out_param":false,"nullability":"nonnull"}]'
    }
    swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc).generate(
      framework: "Acme", symbol: sym, glue_id: "ab12"
    )
    refute_nil swift
    assert_match(/var p_struct = Point\(\)/, swift)
    assert_match(/p_struct\.x = Int32\(rb_num2ll\(rb_hash_aref\(.*"x".*\)\)\)/, swift)
    assert_match(/p_struct\.y = Int32\(rb_num2ll\(rb_hash_aref\(.*"y".*\)\)\)/, swift)
    assert_match(/DrawPoint\(&p_struct\)/, swift)
  end

  def test_struct_in_handles_nested_depth_1
    kc = FakeKC.new({
      "Rect" => { name: "Rect", fields_json: JSON.dump([
        { name: "origin", type: "Point", kind: "struct_in" },
        { name: "size",   type: "Size",  kind: "struct_in" }
      ]) },
      "Point" => { name: "Point", fields_json: JSON.dump([
        { name: "x", type: "Int32", kind: "int" },
        { name: "y", type: "Int32", kind: "int" }
      ]) },
      "Size" => { name: "Size", fields_json: JSON.dump([
        { name: "w", type: "Int32", kind: "int" },
        { name: "h", type: "Int32", kind: "int" }
      ]) }
    })
    sym = {
      kind: "function", abi: "c", name: "DrawRect", signature: "void DrawRect(Rect *)",
      parameters_json: '[{"name":"r","type":"Rect * _Nonnull","kind":"struct_in","is_out_param":false,"nullability":"nonnull"}]'
    }
    swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc).generate(
      framework: "Acme", symbol: sym, glue_id: "ab12"
    )
    refute_nil swift
    assert_match(/r_struct\.origin\.x =/, swift)
    assert_match(/r_struct\.size\.h =/, swift)
  end

  def test_struct_in_cycle_detection_returns_nil
    kc = FakeKC.new({
      "Node" => { name: "Node", fields_json: JSON.dump([
        { name: "value", type: "Int32", kind: "int" },
        { name: "next",  type: "Node",  kind: "struct_in" }
      ]) }
    })
    sym = {
      kind: "function", abi: "c", name: "Visit", signature: "void Visit(Node *)",
      parameters_json: '[{"name":"n","type":"Node * _Nonnull","kind":"struct_in","is_out_param":false,"nullability":"nonnull"}]'
    }
    swift = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc).generate(
      framework: "Acme", symbol: sym, glue_id: "ab12"
    )
    assert_nil swift, "self-referential struct should escape to LLM"
  end

  # Task 12: void_ptr_nilable Marshaller emits UnsafeMutableRawPointer? bitPattern.
  def test_void_ptr_nilable_emits_bitpattern
    sym = {
      kind: "function", abi: "c", name: "Foo", signature: "void Foo(void *)",
      parameters_json: '[{"name":"refcon","type":"void * _Nullable","kind":"void_ptr_nilable","is_out_param":false,"nullability":"nullable"}]'
    }
    swift = @gen.generate(framework: "Acme", symbol: sym, glue_id: "ab12")
    refute_nil swift
    assert_match(/let refcon: UnsafeMutableRawPointer\?/, swift)
    assert_match(/UnsafeMutableRawPointer\(bitPattern: Int\(rb_num2ll\(argv\[0\]\)\)\)/, swift)
  end

  def test_callback_non_nil_unsupported_falls_through_to_nil
    # Non-catalog non-nil callbacks cannot be synthesized into a working
    # `@convention(c)` function pointer without a per-signature trampoline,
    # so the marshaller marks itself broken; the template generator returns
    # nil so the symbol can fall through to LLM fallback / unsupported.
    sym = {
      kind: "function", abi: "c", name: "Foo", signature: "void Foo(MyCallback)",
      parameters_json: '[{"name":"cb","type":"MyCallback _Nonnull","kind":"callback_non_nil","is_out_param":false,"nullability":"nonnull"}]'
    }
    swift = @gen.generate(framework: "Acme", symbol: sym, glue_id: "ab12")
    assert_nil swift, "non-catalog callback_non_nil must not produce glue"
  end

  # (callback pillar): MIDINotifyProc routes to CallbackPillar register
  # instead of rb_raise stub.
  def test_callback_nilable_midinotifyproc_emits_callback_pillar_register
    sym = {
      kind: "function", abi: "c", name: "Foo", signature: "void Foo(MIDINotifyProc)",
      parameters_json: '[{"name":"cb","type":"MIDINotifyProc _Nullable","kind":"callback_nilable","is_out_param":false,"nullability":"nullable"}]'
    }
    swift = @gen.generate(framework: "CoreMIDI", symbol: sym, glue_id: "ab12")
    refute_nil swift
    assert_match(/let cb: MIDINotifyProc\?/, swift)
    assert_match(/if argv\[0\] == Qnil/, swift)
    assert_match(/cb = nil/, swift)
    assert_match(/runtime_callback_pillar_register_midi_notify/, swift)
    assert_match(/runtime_callback_pillar_get_midi_notify_fnptr/, swift)
    assert_match(/unsafeBitCast/, swift)
    refute_match(/rb_raise\(rb_eRuntimeError, "non-nil callback not yet supported"\)/, swift)
  end

  def test_header_includes_runtime_callback_pillar_silgen_names
    h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
    assert_match(/@_silgen_name\("runtime_callback_pillar_register_midi_notify"\)/, h)
    assert_match(/@_silgen_name\("runtime_callback_pillar_get_midi_notify_fnptr"\)/, h)
    assert_match(/@_silgen_name\("rb_obj_id"\)/, h)
    # Glue Swift fetches the proc_registry hash via runtime_proc_registry_get
    # (exported from libAppleSDKMacRuntime.dylib in flat namespace) — replaces
    # the previous rb_gv_get($__apple_sdk_mac_proc_registry) approach that
    # broke under RUBY_BOX=1 (Box-wrapped global vs C-static VALUE divergence).
    assert_match(/@_silgen_name\("runtime_proc_registry_get"\)/, h)
  end

  # struct_in_pointer kind: Ruby user passes a UInt encoding a pointer
  # (commonly built via Fiddle); marshaller casts to UnsafePointer<T> at
  # the C call site. Use case: MIDISend(..., const MIDIPacketList * _Nonnull).
  def test_struct_in_pointer_emits_unsafepointer_cast
    sym = {
      kind: "function", abi: "c", name: "MIDISend",
      signature: "OSStatus MIDISend(MIDIPortRef, MIDIEndpointRef, const MIDIPacketList *)",
      parameters_json: '[' \
        '{"name":"port","type":"MIDIPortRef","kind":"opaque_ref","is_out_param":false,"nullability":"unspecified"},' \
        '{"name":"dest","type":"MIDIEndpointRef","kind":"opaque_ref","is_out_param":false,"nullability":"unspecified"},' \
        '{"name":"pktlist","type":"const MIDIPacketList * _Nonnull","kind":"struct_in_pointer","is_out_param":false,"nullability":"nonnull"}' \
      ']'
    }
    swift = @gen.generate(framework: "CoreMIDI", symbol: sym, glue_id: "ab12")
    refute_nil swift, "struct_in_pointer must produce non-nil glue"
    assert_match(/let pktlist: UnsafePointer<MIDIPacketList>/, swift)
    assert_match(/UnsafePointer<MIDIPacketList>\(bitPattern: UInt\(rb_num2ull\(argv\[2\]\)\)\)!/, swift)
    assert_match(/MIDISend\(port, dest, pktlist\)/, swift)
  end

  # Task 10: HEADER extension with rb_hash_*, rb_block_*.
  def test_header_includes_rb_hash_and_rb_block_silgen_names
    h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
    assert_match(/@_silgen_name\("rb_hash_new"\)/, h)
    assert_match(/@_silgen_name\("rb_hash_aref"\)/, h)
    assert_match(/@_silgen_name\("rb_hash_aset"\)/, h)
    assert_match(/@_silgen_name\("rb_block_given_p"\)/, h)
    assert_match(/@_silgen_name\("rb_block_proc"\)/, h)
  end

  # Task 9 characterization: every existing kind dispatches and produces
  # non-nil Swift containing the kind's signature marshalling expression.
  # This pins behavior before the Marshaller refactor.
  def test_marshaller_dispatch_byte_identical_for_existing_kinds
    fixtures = [
      { kind: "string",     params: '[{"name":"s","type":"const char *","kind":"string","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(const char *)",
        expect: /String\(cString: rb_string_value_cstr/ },
      { kind: "int",        params: '[{"name":"n","type":"int","kind":"int","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(int)",
        expect: /let n: Int64 = rb_num2ll/ },
      { kind: "bool",       params: '[{"name":"b","type":"BOOL","kind":"bool","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(BOOL)",
        expect: /let b: Bool = / },
      { kind: "float",      params: '[{"name":"f","type":"double","kind":"float","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(double)",
        expect: /let f: Double = rb_num2dbl/ },
      { kind: "opaque_ref", params: '[{"name":"r","type":"MIDIClientRef","kind":"opaque_ref","is_out_param":false,"nullability":"unspecified"}]',
        sig: "void Foo(MIDIClientRef)",
        expect: /MIDIClientRef\(rb_num2ull/ }
    ]
    fixtures.each do |fx|
      sym = { kind: "function", abi: "c", name: "Foo", signature: fx[:sig],
              parameters_json: fx[:params] }
      swift = @gen.generate(framework: "Acme", symbol: sym, glue_id: "ab12")
      refute_nil swift, "kind=#{fx[:kind]} should generate Swift"
      assert_match fx[:expect], swift,
        "kind=#{fx[:kind]} expected pattern #{fx[:expect]}"
    end
  end

  # T2a: BlockNilableMarshaller — noescape completion blocks.
  # __attribute__((noescape)) lifetime; the @convention(block) literal lives
  # on the Swift stack for the duration of the call. The Ruby Proc is pinned
  # in the runtime proc registry by object_id so it survives the call without
  # being GC'd, and fired via ThreadingBridge.enqueueFromAppleThread.
  def test_block_nilable_marshaller_emits_stack_local_convention_block
    sym = {
      name: "exampleWithCompletion",
      kind: "function",
      abi: "c",
      signature: "void exampleWithCompletion(void (^completion)(NSError *))",
      parameters_json: JSON.dump([
        { "name" => "completion", "type" => "void (^)(NSError *)",
          "kind" => "block_nilable", "is_out_param" => false,
          "nullability" => "nullable" }
      ])
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "blkn")
    refute_nil swift, "block_nilable should produce template glue"
    assert_match(/let completion: \(@convention\(block\)/, swift)
    assert_match(/runtime_proc_registry_get\(\)/, swift)
    assert_match(/ThreadingBridge\.enqueueFromAppleThread/, swift)
    # block_nilable must NOT call into the persistent slot table.
    # HEADER に @_silgen_name 宣言があるため、 `func register_block_persistent
    # (_ procId:` (declaration) と call site (`register_block_persistent(<var>)`) を
    # 区別する。 call site は underscore-prefix の引数 label を持たない。
    refute_match(/runtime_callback_register_block_persistent\([^_]/, swift,
      "block_nilable must NOT call runtime_callback_register_block_persistent")
    assert_match(/if argv\[0\] == Qnil/, swift)
    assert_match(/completion = nil/, swift)
  end

  # T2b: BlockPersistentMarshaller — escaping completion blocks.
  # No __attribute__((noescape)); the block must outlive the call. We register
  # a slot on the persistent slot table via runtime_callback_register_block_persistent
  # and wrap the slot id in a BoxedBlockHandle. The Box's deinit unregisters
  # the slot (auto lifetime), so escaping blocks released by Ruby GC don't leak.
  def test_block_persistent_marshaller_emits_register_call_and_box_handle
    sym = {
      name: "downloadWithCompletion",
      kind: "function",
      abi: "c",
      signature: "void downloadWithCompletion(void (^completion)(NSData *, NSURLResponse *, NSError *))",
      parameters_json: JSON.dump([
        { "name" => "completion", "type" => "void (^)(NSData *, NSURLResponse *, NSError *)",
          "kind" => "block_persistent", "is_out_param" => false,
          "nullability" => "nullable" }
      ])
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "blkp")
    refute_nil swift, "block_persistent should produce template glue"
    assert_match(/runtime_callback_register_block_persistent\(/, swift)
    assert_match(/BoxedBlockHandle\(slotId:/, swift)
    assert_match(/runtime_proc_registry_get\(\)/, swift)
    assert_match(/if argv\[0\] == Qnil/, swift)
  end

  # kind=objc_method_class が template path で Swift glue を出す。
  # Apple.discover の class_method: shape は LLM ではなく決定論的 template で
  # 解決されること。 selector → Swift call form は init-bridge / class-method
  # の dual emit。 ここでは emit 自体と shape invariants をピン止めする。
  def test_objc_method_class_emits_template_glue_with_correct_shape
    sym = {
      name: "NSString.stringWithUTF8String",
      kind: "objc_method_class",
      objc_class: "NSString", selector: "stringWithUTF8String:",
      params: [:string], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "ocm1")
    refute_nil swift, "objc_method_class must produce template glue, not fall to LLM"
    assert_match(/import Foundation/, swift)
    assert_match(/glue_ocm1_NSString_stringWithUTF8String/, swift,
      "exported func name must be sanitized swift_identifier")
    assert_match(/Unmanaged\.passRetained/, swift,
      "opaque_ref return must passRetain the ObjC instance pointer")
    assert_match(/rb_ull2inum/, swift)
  end

  # Swift 6 は `<verb>With<Type>:` shape の ObjC convenience constructors
  # を init に rename する (NS_SWIFT_NAME / API_RENAMED)。emit_objc_class_method
  # はこの形式を検出し `Klass(label: arg)` init form を出す。
  # `+stringWithUTF8String:` → `NSString(utf8String: arg0)`。
  def test_objc_class_method_uses_swift_init_bridge_for_with_type_shape
    sym = {
      name: "NSString.stringWithUTF8String",
      kind: "objc_method_class",
      objc_class: "NSString", selector: "stringWithUTF8String:",
      params: [:string], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "ocm1")
    refute_nil swift
    # utf8String は historically raw cstr を取る init bridge なので
    # Swift String 化された arg0 ではなく cstr 補助名 arg0_cstr を渡す。
    assert_match(/NSString\(utf8String:\s*arg0_cstr\)/, swift,
      "<verb>With<Type>: → init(<type>: arg0_cstr) Swift bridging form")
  end

  # class method で init-bridge に当てはまらないものは class method form。
  # `+date` selector の場合 NSDate.date()。selector に `With` 単語が無いので
  # fall through。
  def test_objc_class_method_uses_class_method_form_for_non_init_bridge
    sym = {
      name: "NSDate.date",
      kind: "objc_method_class",
      objc_class: "NSDate", selector: "date",
      params: [], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "ocm3")
    refute_nil swift
    # NSDate は Swift 6 で Date に rename (NS-strip)。
    assert_match(/Date\.date\(\)/, swift,
      "non-bridged class methods keep Klass.swiftMethod form (NS-stripped)")
  end

  # int param marshaling は kind=int で rb_num2ll 経由。
  def test_objc_method_class_with_int_param_emits_int_in_load
    sym = {
      name: "MyClass.makeWithInt",
      kind: "objc_method_class",
      objc_class: "MyClass", selector: "makeWithInt:",
      params: [:int], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "ocm2")
    refute_nil swift
    assert_match(/rb_num2ll\(argv\[0\]\)/, swift,
      "int param uses rb_num2ll for argv[0]")
    # `makeWithInt:` matches <verb>With<Type>:, so init form.
    assert_match(/MyClass\(int:\s*arg0\)/, swift)
  end

  # kind=objc_method_instance、receiver = argv[0]、引数は argv[1..]。
  # ObjC instance method receiver bitCast pattern を emit すること。
  def test_objc_method_instance_emits_receiver_load_and_method_call
    sym = {
      name: "NSString.length",
      kind: "objc_method_instance",
      objc_class: "NSString", selector: "length",
      params: [], return_kind: :int,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "oim1")
    refute_nil swift
    assert_match(/import Foundation/, swift)
    # receiver = argv[0]
    assert_match(/let receiver = unsafeBitCast/, swift,
      "receiver は argv[0] から OpaquePointer + bitCast で取得")
    assert_match(/to:\s*NSString\.self/, swift,
      "bitCast ターゲットは objc_class の Swift 名")
    # zero-arg + non-void return は ObjC property bridge form (parens なし)。
    assert_match(/receiver\.length\b/, swift)
    refute_match(/receiver\.length\(\)/, swift,
      "zero-arg property bridge は parens なし")
    # int 戻り値
    assert_match(/rb_ll2inum/, swift)
  end

  # instance method with arg: argv[0]=receiver, argv[1]=user arg。
  def test_objc_method_instance_with_arg_uses_argv_offset_1
    sym = {
      name: "NSString.characterAtIndex",
      kind: "objc_method_instance",
      objc_class: "NSString", selector: "characterAtIndex:",
      params: [:int], return_kind: :int,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "oim2")
    refute_nil swift
    assert_match(/let receiver = unsafeBitCast/, swift)
    # First user arg loaded from argv[1] (not argv[0]).
    assert_match(/rb_num2ll\(argv\[1\]\)/, swift,
      "引数 index は receiver 用 +1 offset (argv[1] が user arg0)")
    refute_match(/rb_num2ll\(argv\[0\]\)/, swift,
      "argv[0] は receiver 専用、user arg として使ってはいけない")
    assert_match(/receiver\.characterAtIndex\(arg0\)/, swift)
  end

  # selector が `init*` で始まる場合は Swift init form (no receiver)。
  # ObjC `+alloc/-init` chain は Swift で `Klass(label: arg)` に統合されている。
  def test_objc_method_instance_init_selector_emits_swift_init_form
    sym = {
      name: "VNImageRequestHandler.init(cgImage:options:)",
      kind: "objc_method_instance",
      objc_class: "VNImageRequestHandler",
      selector: "initWithCGImage:options:",
      params: [:opaque_ref, :void_ptr_nilable], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Vision", symbol: sym, glue_id: "oim3")
    refute_nil swift
    refute_match(/let receiver = unsafeBitCast/, swift,
      "init shape は receiver を持たない")
    assert_match(/VNImageRequestHandler\(cgImage:\s*arg0,\s*options:\s*arg1\)/, swift,
      "init multi-segment は Swift bridged init(cgImage:options:) form")
    assert_match(/Unmanaged\.passRetained/, swift,
      "opaque_ref 戻り値は +1 retained pointer")
  end

  # kind=swift_init は Swift initializer 直接呼び出し form。
  # Swift initializer の `guard let v = Klass(args) else { return Qnil }` shape。
  def test_swift_init_no_args_emits_klass_paren_call
    sym = {
      name: "VNRecognizeTextRequest.init()",
      kind: "swift_init",
      swift_class: "VNRecognizeTextRequest",
      swift_initializer: "init()",
      params: [], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Vision", symbol: sym, glue_id: "swi1")
    refute_nil swift, "swift_init must produce template glue"
    assert_match(/import Vision/, swift)
    assert_match(/VNRecognizeTextRequest\(\)/, swift)
    assert_match(/Unmanaged\.passRetained/, swift,
      "opaque_ref 戻り値は +1 retained pointer")
  end

  def test_swift_init_single_label_emits_init_with_arg
    sym = {
      name: "URL.init(string:)",
      kind: "swift_init",
      swift_class: "URL",
      # failable init は initializer 文字列に `?` を含めて指定。
      # URL.init?(string:) は failable なので `init?(string:)` で渡す。
      swift_initializer: "init?(string:)",
      params: [:string], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "swi2")
    refute_nil swift
    assert_match(/URL\(string:\s*arg0\)/, swift,
      "init(string:) → URL(string: arg0)")
    assert_match(/guard let v = URL\(.*\) else \{ return Qnil \}/, swift,
      "failable init (?) は guard let で nil 時に Qnil 返す")
  end

  def test_swift_init_multi_label_emits_each_label
    sym = {
      name: "VNImageRequestHandler.init(cgImage:options:)",
      kind: "swift_init",
      swift_class: "VNImageRequestHandler",
      swift_initializer: "init(cgImage:options:)",
      params: [:opaque_ref, :void_ptr_nilable], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Vision", symbol: sym, glue_id: "swi3")
    refute_nil swift
    assert_match(/VNImageRequestHandler\(cgImage:\s*arg0,\s*options:\s*arg1\)/, swift,
      "multi-label init は labeled args full set")
  end

  # kind=swift_property は class-side static property access form。
  # Swift property base shape。 NSURLSession.shared, ProcessInfo.processInfo 等。
  # 戻り値 marshaling は return_kind に従う。
  def test_swift_property_static_emits_klass_dot_property
    sym = {
      name: "NSURLSession.shared",
      kind: "swift_property",
      swift_class: "NSURLSession",
      swift_property: "shared",
      return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "swp1")
    refute_nil swift, "swift_property must produce template glue"
    assert_match(/import Foundation/, swift)
    # NSURLSession は Swift 6 で URLSession に rename (NS-strip)。
    assert_match(/let raw = URLSession\.shared/, swift,
      "static property access form `Klass.prop` (NS-stripped)")
    assert_match(/Unmanaged\.passRetained/, swift,
      "opaque_ref 戻り値は passRetained で raw pointer")
  end

  def test_swift_property_returns_int
    sym = {
      name: "ProcessInfo.processInfo",  # 適当な int-returning property を想定
      kind: "swift_property",
      swift_class: "ProcessInfo",
      swift_property: "processInfo",  # 実際は ProcessInfo を返すが test 用に return_kind 上書き
      return_kind: :int,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "swp2")
    refute_nil swift
    assert_match(/let raw = ProcessInfo\.processInfo/, swift)
    assert_match(/rb_ll2inum/, swift,
      "int 戻り値は rb_ll2inum")
  end

  # kind=swift_func 同期形式。
  # top-level: runtime_async_test_taskgroup_double(arg0, arg1, arg2)
  def test_swift_func_sync_top_level_emits_func_call
    sym = {
      name: "runtime_marshal_int_round_trip",
      kind: "swift_func",
      swift_func: "runtime_marshal_int_round_trip",
      params: [:int], return_kind: :int,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "swf1")
    refute_nil swift, "swift_func must produce template glue"
    assert_match(/let raw = runtime_marshal_int_round_trip\(arg0\)/, swift,
      "top-level swift func は そのまま <func>(args) 形式")
    refute_match(/DispatchSemaphore/, swift,
      "同期 func は async skeleton 含まない")
    assert_match(/rb_ll2inum/, swift)
  end

  # Klass 付き static method。`Klass.<func>(args)`。
  def test_swift_func_sync_with_klass_emits_static_call
    sym = {
      name: "URL.someStaticHelper",
      kind: "swift_func",
      swift_class: "URL",
      swift_func: "someStaticHelper",
      params: [], return_kind: :int,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "swf2")
    refute_nil swift
    assert_match(/let raw = URL\.someStaticHelper\(\)/, swift,
      "swift_class があれば Klass.func form")
  end

  # async swift_func は DispatchSemaphore + Task + sema.wait skeleton
  #。ValidationGates.async_shape 通過。
  def test_swift_func_async_emits_dispatchsemaphore_skeleton
    sym = {
      name: "runtime_async_test_taskgroup_double",
      kind: "swift_func",
      swift_func: "runtime_async_test_taskgroup_double",
      params: [:int, :int, :int], return_kind: :int,
      async: true,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "swfa1")
    refute_nil swift, "async swift_func も template path で emit"
    assert_match(/DispatchSemaphore\(value:\s*0\)/, swift,
      "async は DispatchSemaphore で sync 化")
    assert_match(/Task\s*\{/, swift, "async は Task block 内で実行")
    assert_match(/try await runtime_async_test_taskgroup_double\(arg0,\s*arg1,\s*arg2\)/, swift)
    assert_match(/sema\.wait\(\)/, swift)
    assert_match(/sema\.signal\(\)/, swift)
    assert_match(/captured/, swift, "error を post-wait raise 用に capture")
  end

  # escaping completion block path。NSURLSession.dataTask(with:completionHandler:)
  # 形式 (instance method + multi-segment selector + 末尾 :block_persistent param)。
  # Ruby Proc を proc_registry に pin し、closure を組んで Apple に渡す。
  # closure 内で runtime_threading_enqueue を呼んで Ruby callback を起動する。
  def test_objc_instance_method_with_block_persistent_param_emits_register_and_closure
    sym = {
      name: "NSURLSession.dataTask(with:completionHandler:)",
      kind: "objc_method_instance",
      objc_class: "NSURLSession",
      selector: "dataTaskWithURL:completionHandler:",
      params: [:opaque_ref, :block_persistent], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "blkp1")
    refute_nil swift
    # receiver = argv[0], opaque_ref URL = argv[1], block_persistent = argv[2]
    assert_match(/let receiver = unsafeBitCast/, swift)
    assert_match(/rb_obj_id\(argv\[2\]\)/, swift,
      "block_persistent param は argv[2] (receiver +1, opaque_ref +1)")
    # Proc を runtime_proc_registry に pin
    assert_match(/rb_hash_aset\(runtime_proc_registry_get\(\)/, swift)
    # persistent slot register (cleanup 用 handle 確保)
    assert_match(/runtime_callback_register_block_persistent/, swift)
    # closure 構築 — URLSession の signature
    assert_match(/let arg1: \(Data\?, URLResponse\?, Error\?\) -> Void/, swift,
      "completion block の Swift signature")
    # closure 内で runtime_threading_enqueue 経由で Ruby に enqueue
    assert_match(/runtime_threading_enqueue/, swift,
      "closure 内は @_silgen_name 経由で ThreadingBridge を呼ぶ")
    # call site は label 付き
    assert_match(/receiver\.dataTask\(with:\s*arg0,\s*completionHandler:\s*arg1\)/, swift,
      "multi-segment selector の Swift bridged label-aware call form")
  end

  # HEADER に runtime_threading_enqueue の @_silgen_name 宣言が必要。
  def test_header_includes_runtime_threading_enqueue_silgen_name
    h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
    assert_match(/@_silgen_name\("runtime_threading_enqueue"\)/, h,
      "closure からの enqueue ルートを @_silgen_name で参照可能に")
    assert_match(/@_silgen_name\("runtime_callback_register_block_persistent"\)/, h,
      "persistent slot register も @_silgen_name 経由")
  end

  # CFTypeRefMarshaller in_load は runtime_arc_unbox_cftype 経由で
  # autoarc box pointer を unwrap する (round-trip 完成の前提)。
  # box でない raw CF pointer を渡されたケースは unbox が 0 を返すので
  # raw input にフォールバックする (CFTypeRefMarshaller の実装契約)。
  def test_cftype_ref_marshaller_unboxes_via_runtime_arc_unbox_cftype
    sym = {
      kind: "function", abi: "c",
      name: "CFStringGetLength",
      signature: "CFIndex CFStringGetLength(CFStringRef theString)",
      parameters_json: '[{"name":"theString","type":"CFStringRef","kind":"cftype_ref","is_out_param":false,"nullability":"unspecified"}]'
    }
    swift = @gen.generate(framework: "CoreFoundation", symbol: sym, glue_id: "cfgl1")
    refute_nil swift
    assert_match(/runtime_arc_unbox_cftype/, swift,
      "cftype_ref param 経由の入力は runtime_arc_unbox_cftype で unwrap")
  end

  # HEADER に runtime_arc_unbox_cftype の @_silgen_name 宣言が必要。
  def test_header_includes_runtime_arc_unbox_cftype_silgen_name
    h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
    assert_match(/@_silgen_name\("runtime_arc_unbox_cftype"\)/, h,
      "glue から runtime_arc_unbox_cftype を呼べるよう HEADER で declare")
  end

  # T4: CF Create-rule auto-ARC. A symbol whose knowledge record has
  # cf_create_rule=true gets its CF-typed return value automatically wrapped
  # via the runtime ARC pillar's runtime_arc_box_cftype entry point. The
  # entry point performs the Unmanaged.takeRetainedValue + BoxedCFType wrap
  # inside the runtime dylib (per LLM rule 3: glue Swift must not import
  # AppleSDKMacRuntime, so BoxedCFType lives in the runtime, not the glue).
  # User code never calls CFRelease — the Box deinit handles release.
  def test_cftype_ref_autoarc_routes_through_runtime_arc_box
    sym = {
      name: "CFStringCreateWithCString",
      kind: "function",
      abi: "c",
      cf_create_rule: true,
      signature: "CFStringRef CFStringCreateWithCString(CFAllocatorRef alloc, const char *cstr, CFStringEncoding encoding)",
      parameters_json: JSON.dump([
        { "name" => "alloc", "type" => "CFAllocatorRef", "kind" => "void_ptr_nilable",
          "is_out_param" => false, "nullability" => "nullable" },
        { "name" => "cstr", "type" => "const char *", "kind" => "string",
          "is_out_param" => false, "nullability" => "unspecified" },
        { "name" => "encoding", "type" => "CFStringEncoding", "kind" => "int",
          "is_out_param" => false, "nullability" => "unspecified" }
      ])
    }
    swift = @gen.generate(framework: "CoreFoundation", symbol: sym, glue_id: "cfac")
    refute_nil swift, "cf_create_rule symbols must produce template glue"
    assert_match(/runtime_arc_box_cftype/, swift,
      "auto-ARC glue must route through the runtime entry point")
    refute_match(/CFRelease/, swift,
      "auto-ARC glue must NOT call CFRelease — runtime Box deinit handles release")
    refute_match(/import\s+AppleSDKMacRuntime/, swift,
      "glue must not import AppleSDKMacRuntime (LLM rule 3)")
  end
end
