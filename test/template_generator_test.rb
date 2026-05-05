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

  def test_callback_non_nil_emits_unconditional_rb_raise_stub
    sym = {
      kind: "function", abi: "c", name: "Foo", signature: "void Foo(MyCallback)",
      parameters_json: '[{"name":"cb","type":"MyCallback _Nonnull","kind":"callback_non_nil","is_out_param":false,"nullability":"nonnull"}]'
    }
    swift = @gen.generate(framework: "Acme", symbol: sym, glue_id: "ab12")
    refute_nil swift
    assert_match(/rb_raise\(rb_eRuntimeError, "non-nil callback not yet supported"\)/, swift)
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
end
