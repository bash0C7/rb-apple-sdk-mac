# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/kind"

class TestKind < Test::Unit::TestCase
  K = AppleSDKKnowledge::Importer::Kind

  def test_classifies_string_for_const_char_pointer
    assert_equal "string", K.classify_kind("const char *")
  end

  def test_classifies_string_for_cfstring_ref
    assert_equal "string", K.classify_kind("CFStringRef")
  end

  def test_classifies_bool
    assert_equal "bool", K.classify_kind("_Bool")
  end

  def test_classifies_float
    assert_equal "float", K.classify_kind("double")
  end

  def test_classifies_int_for_osstatus
    assert_equal "int", K.classify_kind("OSStatus")
  end

  def test_classifies_opaque_ref_for_ref_typedef
    assert_equal "opaque_ref", K.classify_kind("MIDIClientRef")
  end

  def test_classifies_void_pointer_unspecified_as_void_ptr_nilable
    # Policy: unspecified nullability is treated as nilable (safe default).
    assert_equal "void_ptr_nilable", K.classify_kind("void *", "void *", "unspecified")
  end

  def test_classifies_void_pointer_nullable_as_void_ptr_nilable
    assert_equal "void_ptr_nilable",
      K.classify_kind("void * _Nullable", "void *", "nullable")
  end

  def test_classifies_callback_typedef_by_name_pattern_when_desugared_unavailable
    # Reclassifier doesn't preserve desugared; rely on Apple convention:
    # *Proc / *Callback / *Handler typedefs are function pointers.
    assert_equal "callback_nilable",
      K.classify_kind("MIDINotifyProc _Nullable", "MIDINotifyProc _Nullable", "nullable")
    assert_equal "callback_non_nil",
      K.classify_kind("CFAllocatorAllocateCallBack _Nonnull",
                      "CFAllocatorAllocateCallBack _Nonnull", "nonnull")
    assert_equal "callback_nilable",
      K.classify_kind("MyHandler _Nullable", "MyHandler _Nullable", "nullable")
  end

  def test_classifies_function_pointer_unspecified_as_callback_nilable
    assert_equal "callback_nilable",
      K.classify_kind("MIDINotifyProc",
                      "void (*)(const MIDINotification *, void *)",
                      "unspecified")
  end

  def test_classifies_function_pointer_nullable_as_callback_nilable
    assert_equal "callback_nilable",
      K.classify_kind("MIDINotifyProc _Nullable",
                      "void (*)(const MIDINotification *, void *)",
                      "nullable")
  end

  def test_classifies_function_pointer_nonnull_as_callback_non_nil
    assert_equal "callback_non_nil",
      K.classify_kind("MIDINotifyProc _Nonnull",
                      "void (*)(const MIDINotification *, void *)",
                      "nonnull")
  end

  def test_out_param_true_for_last_pointer
    assert_equal true, K.out_param?("MIDIClientRef *", "outClient", true)
  end

  def test_out_param_true_for_out_prefix_name
    assert_equal true, K.out_param?("Int32 *", "outNode", false)
  end

  def test_out_param_false_for_non_pointer
    assert_equal false, K.out_param?("CFStringRef", "name", false)
  end

  # `const T *` is an INPUT pointer (read-only) — never an out-param,
  # even if it's the last pointer in the signature. Without this guard,
  # MIDISend(MIDIPortRef, MIDIEndpointRef, const MIDIPacketList * _Nonnull)
  # tags pktlist as is_out_param=true and the marshaller dispatcher
  # mis-routes the input as an out-param.
  def test_out_param_false_for_const_struct_pointer
    assert_equal false,
      K.out_param?("const MIDIPacketList * _Nonnull", "pktlist", true)
  end

  # `const X * _Nonnull` for a struct typedef without _Ref/_Proc/_Callback
  # suffix is "struct_in_pointer": Ruby user passes UInt (a pointer encoded
  # as integer), the marshaller casts to UnsafePointer<X> at the call site.
  def test_classifies_struct_in_pointer_for_const_struct_pointer
    assert_equal "struct_in_pointer",
      K.classify_kind("const MIDIPacketList * _Nonnull",
                      "const MIDIPacketList * _Nonnull",
                      "nonnull")
  end

  def test_nullability_nonnull
    assert_equal "nonnull", K.nullability_of("CFStringRef _Nonnull")
  end

  def test_nullability_nullable
    assert_equal "nullable", K.nullability_of("MIDIClientRef _Nullable")
  end

  def test_nullability_unspecified
    assert_equal "unspecified", K.nullability_of("CFStringRef")
  end

  # CF/CG/CV/CT/CM/CL pointer-typed Refs (CFArrayRef, CGContextRef, CVPixelBufferRef
  # etc.) are NOT integer handles — they're pointer typedefs. The Marshaller
  # must cast via OpaquePointer(bitPattern:) rather than `T(rb_num2ull(...))`.
  # Distinguish them from MIDIClientRef-class integer Refs at classify time.
  def test_classifies_cftype_ref_for_cf_array_ref
    assert_equal "cftype_ref", K.classify_kind("CFArrayRef")
  end

  def test_classifies_cftype_ref_for_cf_dictionary_ref
    assert_equal "cftype_ref", K.classify_kind("CFDictionaryRef")
  end

  def test_classifies_cftype_ref_for_generic_cftype_ref
    assert_equal "cftype_ref", K.classify_kind("CFTypeRef")
  end

  def test_classifies_cftype_ref_for_cg_context_ref
    assert_equal "cftype_ref", K.classify_kind("CGContextRef")
  end

  def test_classifies_cftype_ref_for_cv_pixel_buffer_ref
    assert_equal "cftype_ref", K.classify_kind("CVPixelBufferRef")
  end

  def test_classifies_cftype_ref_with_nullability
    assert_equal "cftype_ref",
      K.classify_kind("CFArrayRef _Nullable", "CFArrayRef _Nullable", "nullable")
  end

  # Regression: CFStringRef is special-cased as "string" (toll-free ↔ Ruby String).
  # Must continue to classify as "string", not "cftype_ref".
  def test_cfstring_ref_still_classifies_as_string
    assert_equal "string", K.classify_kind("CFStringRef")
  end

  # Regression: integer-typed Refs (MIDIClientRef = UInt32, AudioComponentInstance
  # etc.) keep "opaque_ref". The cftype_ref check must not steal them.
  def test_midi_client_ref_still_classifies_as_opaque_ref
    assert_equal "opaque_ref", K.classify_kind("MIDIClientRef")
  end

  # Float typedef expansion (Phase 7 blocker 2): CFAbsoluteTime / CFTimeInterval
  # / NSTimeInterval are all `double` underneath. Must classify as "float", not "int".
  def test_classifies_float_for_cf_absolute_time
    assert_equal "float", K.classify_kind("CFAbsoluteTime")
  end

  def test_classifies_float_for_cf_time_interval
    assert_equal "float", K.classify_kind("CFTimeInterval")
  end

  def test_classifies_float_for_ns_time_interval
    assert_equal "float", K.classify_kind("NSTimeInterval")
  end
end
