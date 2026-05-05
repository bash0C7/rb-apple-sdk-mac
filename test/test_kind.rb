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

  def test_nullability_nonnull
    assert_equal "nonnull", K.nullability_of("CFStringRef _Nonnull")
  end

  def test_nullability_nullable
    assert_equal "nullable", K.nullability_of("MIDIClientRef _Nullable")
  end

  def test_nullability_unspecified
    assert_equal "unspecified", K.nullability_of("CFStringRef")
  end
end
