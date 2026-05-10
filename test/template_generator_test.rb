# frozen_string_literal: true
require "test_helper"
require "json"
require "apple_sdk_mac/glue_compiler/template_generator"

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
