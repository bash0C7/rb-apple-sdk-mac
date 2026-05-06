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

  # Task 11: callback_nilable / callback_non_nil Marshallers (stub: rb_raise on non-nil branch).
  def test_callback_nilable_emits_qnil_branch_with_rb_raise_stub
    sym = {
      kind: "function", abi: "c", name: "Foo", signature: "void Foo(MyCallback)",
      parameters_json: '[{"name":"cb","type":"MyCallback _Nullable","kind":"callback_nilable","is_out_param":false,"nullability":"nullable"}]'
    }
    swift = @gen.generate(framework: "Acme", symbol: sym, glue_id: "ab12")
    refute_nil swift
    assert_match(/let cb: MyCallback\?/, swift)
    assert_match(/if argv\[0\] == Qnil/, swift)
    assert_match(/cb = nil/, swift)
    assert_match(/rb_raise\(rb_eRuntimeError, "non-nil callback not yet supported"\)/, swift)
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

  # Phase 6 (callback pillar): MIDINotifyProc routes to CallbackPillar register
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

  # Phase 7 T2a: BlockNilableMarshaller — noescape completion blocks.
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
    refute_match(/runtime_callback_register_block_persistent/, swift,
      "block_nilable must NOT use the persistent slot table")
    assert_match(/if argv\[0\] == Qnil/, swift)
    assert_match(/completion = nil/, swift)
  end

  # Phase 7 T2b: BlockPersistentMarshaller — escaping completion blocks.
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

  # T42 — kind=objc_method_class が template path で Swift glue を出す。
  # Apple.discover の class_method: shape は LLM ではなく決定論的 template で
  # 解決されること（spec §3.4.1）。selector → Swift call form は T43 で
  # init-bridge / class-method の dual emit に。ここでは emit 自体と shape
  # invariants をピン止めする。
  def test_objc_method_class_emits_template_glue_with_correct_shape
    sym = {
      name: "NSString.stringWithUTF8String",
      kind: "objc_method_class",
      objc_class: "NSString", selector: "stringWithUTF8String:",
      params: [:string], return_kind: :opaque_ref,
      signature: nil, abi: nil, parameters_json: "[]"
    }
    swift = @gen.generate(framework: "Foundation", symbol: sym, glue_id: "ocm1")
    refute_nil swift, "T42: objc_method_class must produce template glue, not fall to LLM"
    assert_match(/import Foundation/, swift)
    assert_match(/glue_ocm1_NSString_stringWithUTF8String/, swift,
      "T42: exported func name must be sanitized swift_identifier")
    assert_match(/Unmanaged\.passRetained/, swift,
      "T42: opaque_ref return must passRetain the ObjC instance pointer")
    assert_match(/rb_ull2inum/, swift)
  end

  # T43 — Swift 6 は `<verb>With<Type>:` shape の ObjC convenience constructors
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
    assert_match(/NSString\(utf8String:\s*arg0\)/, swift,
      "T43: <verb>With<Type>: → init(<type>:) Swift bridging form")
  end

  # T43 — class method で init-bridge に当てはまらないものは class method form。
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
    assert_match(/NSDate\.date\(\)/, swift,
      "T43: non-bridged class methods keep Klass.swiftMethod form")
  end

  # T42 — int param marshaling は kind=int で rb_num2ll 経由。
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
      "T42: int param uses rb_num2ll for argv[0]")
    # T43 — `makeWithInt:` matches <verb>With<Type>:, so init form.
    assert_match(/MyClass\(int:\s*arg0\)/, swift)
  end

  # T44 — kind=objc_method_instance、receiver = argv[0]、引数は argv[1..]。
  # spec §3.4.2 の receiver bitCast pattern を emit すること。
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
      "T44: receiver は argv[0] から OpaquePointer + bitCast で取得")
    assert_match(/to:\s*NSString\.self/, swift,
      "T44: bitCast ターゲットは objc_class の Swift 名")
    # 呼び出しは receiver.length()
    assert_match(/receiver\.length\(\)/, swift)
    # int 戻り値
    assert_match(/rb_ll2inum/, swift)
  end

  # T44 — instance method with arg: argv[0]=receiver, argv[1]=user arg。
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
      "T44: 引数 index は receiver 用 +1 offset (argv[1] が user arg0)")
    refute_match(/rb_num2ll\(argv\[0\]\)/, swift,
      "T44: argv[0] は receiver 専用、user arg として使ってはいけない")
    assert_match(/receiver\.characterAtIndex\(arg0\)/, swift)
  end

  # T44 — selector が `init*` で始まる場合は Swift init form (no receiver)。
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
      "T44: init shape は receiver を持たない")
    assert_match(/VNImageRequestHandler\(cgImage:\s*arg0,\s*options:\s*arg1\)/, swift,
      "T44: init multi-segment は Swift bridged init(cgImage:options:) form")
    assert_match(/Unmanaged\.passRetained/, swift,
      "T44: opaque_ref 戻り値は +1 retained pointer")
  end

  # Phase 7 T4: CF Create-rule auto-ARC. A symbol whose knowledge record has
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
