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

  def test_does_not_reference_marshal_or_errorbridge
    s = sym(name: "F", signature: "void F(int x)",
            parameters: [{ name: "x", type: "int", kind: "int", is_out_param: false }])
    out = gen.generate(framework: "Foundation", symbol: s, glue_id: "abc")
    assert_not_match(/Marshal\.from/, out)
    assert_not_match(/Marshal\.toRuby/, out)
    assert_not_match(/ErrorBridge\.rb_raise_via_runtime/, out)
  end
end
