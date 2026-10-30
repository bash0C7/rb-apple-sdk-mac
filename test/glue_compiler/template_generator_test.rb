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
    refute_match(/raw\s*==\s*nil/, out,
                 "non-optional Self 戻り値で raw == nil 比較は禁止 (warning)")
    refute_match(/raw!\s+as\s+AnyObject/, out,
                 "non-optional Self 戻り値で raw! force unwrap は禁止 (compile error)")
  end

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

  def test_emit_swift_init_throws_emits_do_catch
    s = sym(name: "AVAudioFile.init(forReading:)",
            kind: "swift_init",
            signature: nil, parameters: [])
    s[:swift_class] = "AVAudioFile"
    s[:swift_initializer] = "init(forReading:) throws"
    s[:params] = [:opaque_ref]
    s[:return_kind] = :opaque_ref

    out = gen.generate(framework: "AVFAudio", symbol: s, glue_id: "abc")
    refute_nil out, "throws swift_initializer must emit"
    assert_match(/do \{/, out, "throws init must wrap in do block")
    assert_match(/try AVAudioFile\(forReading:\s*arg0\)/, out,
                 "do block must contain unwrapped try call (no try?)")
    assert_no_match(/guard let v = try\?/, out,
                    "silent try? else Qnil must be eliminated (T8)")
    assert_match(/rb_raise\(/, out, "catch block must call rb_raise")
    refute_match(/init\(forReading:\)\s+throws/, out,
                 "Swift コード本体に末尾 throws マーカーが漏れたら label 抽出が壊れた印")
  end

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
    sym = {
      kind: "function", abi: "c", name: "Foo", signature: "void Foo(MyCallback)",
      parameters_json: '[{"name":"cb","type":"MyCallback _Nonnull","kind":"callback_non_nil","is_out_param":false,"nullability":"nonnull"}]'
    }
    swift = @gen.generate(framework: "Acme", symbol: sym, glue_id: "ab12")
    assert_nil swift, "non-catalog callback_non_nil must not produce glue"
  end

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
    assert_match(/@_silgen_name\("runtime_proc_registry_get"\)/, h)
  end

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

  def test_header_includes_rb_hash_and_rb_block_silgen_names
    h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
    assert_match(/@_silgen_name\("rb_hash_new"\)/, h)
    assert_match(/@_silgen_name\("rb_hash_aref"\)/, h)
    assert_match(/@_silgen_name\("rb_hash_aset"\)/, h)
    assert_match(/@_silgen_name\("rb_block_given_p"\)/, h)
    assert_match(/@_silgen_name\("rb_block_proc"\)/, h)
  end

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
    refute_match(/runtime_callback_register_block_persistent\([^_]/, swift,
      "block_nilable must NOT call runtime_callback_register_block_persistent")
    assert_match(/if argv\[0\] == Qnil/, swift)
    assert_match(/completion = nil/, swift)
  end

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
    assert_match(/NSString\(utf8String:\s*arg0_cstr\)/, swift,
      "<verb>With<Type>: → init(<type>: arg0_cstr) Swift bridging form")
  end

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
    assert_match(/Date\.date\(\)/, swift,
      "non-bridged class methods keep Klass.swiftMethod form (NS-stripped)")
  end

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
    assert_match(/MyClass\(int:\s*arg0\)/, swift)
  end

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
    assert_match(/let receiver = unsafeBitCast/, swift,
      "receiver は argv[0] から OpaquePointer + bitCast で取得")
    assert_match(/to:\s*NSString\.self/, swift,
      "bitCast ターゲットは objc_class の Swift 名")
    assert_match(/receiver\.length\b/, swift)
    refute_match(/receiver\.length\(\)/, swift,
      "zero-arg property bridge は parens なし")
    assert_match(/rb_ll2inum/, swift)
  end

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
    assert_match(/rb_num2ll\(argv\[1\]\)/, swift,
      "引数 index は receiver 用 +1 offset (argv[1] が user arg0)")
    refute_match(/rb_num2ll\(argv\[0\]\)/, swift,
      "argv[0] は receiver 専用、user arg として使ってはいけない")
    assert_match(/receiver\.characterAtIndex\(arg0\)/, swift)
  end

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
    assert_match(/let raw = URLSession\.shared/, swift,
      "static property access form `Klass.prop` (NS-stripped)")
    assert_match(/Unmanaged\.passRetained/, swift,
      "opaque_ref 戻り値は passRetained で raw pointer")
  end

  def test_swift_property_returns_int
    sym = {
      name: "ProcessInfo.processInfo",
      kind: "swift_property",
      swift_class: "ProcessInfo",
      swift_property: "processInfo",
      return_kind: :int,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "swp2")
    refute_nil swift
    assert_match(/let raw = ProcessInfo\.processInfo/, swift)
    assert_match(/rb_ll2inum/, swift,
      "int 戻り値は rb_ll2inum")
  end

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
    assert_match(/let receiver = unsafeBitCast/, swift)
    assert_match(/rb_obj_id\(argv\[2\]\)/, swift,
      "block_persistent param は argv[2] (receiver +1, opaque_ref +1)")
    assert_match(/rb_hash_aset\(runtime_proc_registry_get\(\)/, swift)
    assert_match(/runtime_callback_register_block_persistent/, swift)
    assert_match(/let arg1: \(Data\?, URLResponse\?, Error\?\) -> Void/, swift,
      "completion block の Swift signature")
    assert_match(/runtime_threading_enqueue/, swift,
      "closure 内は @_silgen_name 経由で ThreadingBridge を呼ぶ")
    assert_match(/receiver\.dataTask\(with:\s*arg0,\s*completionHandler:\s*arg1\)/, swift,
      "multi-segment selector の Swift bridged label-aware call form")
  end

  def test_header_includes_runtime_threading_enqueue_silgen_name
    h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
    assert_match(/@_silgen_name\("runtime_threading_enqueue"\)/, h,
      "closure からの enqueue ルートを @_silgen_name で参照可能に")
    assert_match(/@_silgen_name\("runtime_callback_register_block_persistent"\)/, h,
      "persistent slot register も @_silgen_name 経由")
  end

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

  def test_header_includes_runtime_arc_unbox_cftype_silgen_name
    h = AppleSDKMac::GlueCompiler::TemplateGenerator::HEADER
    assert_match(/@_silgen_name\("runtime_arc_unbox_cftype"\)/, h,
      "glue から runtime_arc_unbox_cftype を呼べるよう HEADER で declare")
  end

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
