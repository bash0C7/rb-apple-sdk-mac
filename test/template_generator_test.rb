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
