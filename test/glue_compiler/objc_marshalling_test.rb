# frozen_string_literal: true
require "test_helper"

# ObjcMarshalling — pure marshalling-by-kind logic for ObjC method param
# load + return marshaling. Stateless module-level methods. Extracted from
# TemplateGenerator (objc_in_load + objc_return_lines) to slim the
# generator's surface area; the actual emit_* methods now compose this
# module with the swift-call construction logic.
class TestObjcMarshalling < Test::Unit::TestCase
  M = AppleSDKMac::GlueCompiler::ObjcMarshalling

  # ----- in_load -----

  def test_in_load_string_emits_swift_string_via_cstr_binding
    swift = M.in_load(:string, 0)
    assert_match(/var v0 = argv\[0\]/, swift)
    assert_match(/let arg0_cstr = rb_string_value_cstr\(&v0\)/, swift)
    assert_match(/let arg0 = String\(cString: arg0_cstr\)/, swift)
  end

  def test_in_load_int_emits_swift_int
    swift = M.in_load(:int, 1)
    assert_match(/let arg1: Int = Int\(rb_num2ll\(argv\[1\]\)\)/, swift)
  end

  def test_in_load_opaque_ref_no_type_hint_emits_raw_opaque_pointer
    # No type_hint → bare OpaquePointer for general C ABI consumers.
    swift = M.in_load(:opaque_ref, 0)
    assert_match(/let arg0 = OpaquePointer\(bitPattern: UInt\(rb_num2ull\(argv\[0\]\)\)\)/, swift)
  end

  def test_in_load_opaque_ref_with_type_hint_emits_unsafe_bitcast
    swift = M.in_load({ kind: :opaque_ref, type: "VNRequest" }, 2)
    assert_match(/unsafeBitCast\(arg2_ptr_v, to: VNRequest\.self\)/, swift)
  end

  def test_in_load_opaque_ref_value_type_bridges_via_ns_class
    # URL is a Swift value-type → struct unsafeBitCast SIGTRAPs; bridge
    # through NSURL then `as URL`.
    swift = M.in_load({ kind: :opaque_ref, type: "URL" }, 0)
    assert_match(/unsafeBitCast\(arg0_ptr_v, to: NSURL\.self\) as URL/, swift)
  end

  def test_in_load_array_of_opaque_ref_with_type_hint_emits_typed_swift_array
    swift = M.in_load({ kind: :array_of_opaque_ref, type: "VNRecognizedTextObservation" }, 1)
    assert_match(/let arg1_count_v = runtime_rb_array_len\(argv\[1\]\)/, swift)
    assert_match(/as! \[VNRecognizedTextObservation\]/, swift)
  end

  def test_in_load_argv_offset_shifts_argv_index
    # Receiver-bearing instance methods reserve argv[0]; offsets 0→1 etc.
    swift = M.in_load(:int, 0, argv_offset: 1)
    assert_match(/Int\(rb_num2ll\(argv\[1\]\)\)/, swift)
  end

  def test_in_load_block_persistent_arity_3_emits_typed_completion_block
    swift = M.in_load(
      { kind: :block_persistent, arity: 3,
        types: ["NSData?", "NSURLResponse?", "NSError?"] },
      0
    )
    assert_match(/@convention\(block\) \(NSData\?, NSURLResponse\?, NSError\?\) -> Void/, swift)
    assert_match(/runtime_threading_enqueue_3/, swift)
  end

  # ----- return_lines -----

  def test_return_lines_opaque_ref_uses_passretained
    lines = M.return_lines(:opaque_ref, "result")
    joined = lines.join("\n")
    assert_match(/Unmanaged\.passRetained\(__ret\)\.toOpaque\(\)/, joined)
  end

  def test_return_lines_string_marshals_swift_optional_string
    lines = M.return_lines(:string, "result")
    joined = lines.join("\n")
    assert_match(/result as String\?/, joined)
    assert_match(/withCString \{ rb_str_new_cstr\(\$0\) \}/, joined)
  end

  def test_return_lines_int_emits_int64_wrap
    lines = M.return_lines(:int, "n")
    assert_equal ["return rb_ll2inum(Int64(n))"], lines
  end

  def test_return_lines_array_of_opaque_ref_with_type_hint_marshals_each_element
    lines = M.return_lines({ kind: :array_of_opaque_ref, type: "VNRecognizedTextObservation" }, "result")
    joined = lines.join("\n")
    assert_match(/result as\? \[VNRecognizedTextObservation\]/, joined)
    assert_match(/Unmanaged\.passRetained\(__obj as AnyObject\)\.toOpaque\(\)/, joined)
  end

  def test_return_lines_void_returns_qnil
    assert_equal ["return Qnil"], M.return_lines(:void, "result")
  end
end
