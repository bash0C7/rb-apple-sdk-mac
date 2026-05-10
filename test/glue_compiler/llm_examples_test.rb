# frozen_string_literal: true
require "test_helper"

# LLMExamples — worked-example catalogue for the LLM fallback Swift glue
# generator. Public surface: EXAMPLES (Hash mapping example key → Swift
# source string) and KEEP_FOR_FAMILY (Hash mapping kind family →
# array of example keys to keep when building the per-family
# instructions). Extracted from llm_generator.rb so the driver can focus
# on session lifecycle / prompt assembly without the example catalogue
# inflating the file's surface area.
class TestLLMExamples < Test::Unit::TestCase
  E = AppleSDKMac::GlueCompiler::LLMExamples

  EXPECTED_KEYS = [
    :int_in_string_out,
    :string_in_status_out,
    :struct_in,
    :multi_out_hash,
    :async_e1,
    :async_e2,
    :async_e3,
    :async_e4,
    :objc_f1,
    :objc_f2,
    :objc_g
  ].freeze

  def test_examples_constant_has_all_eleven_keys
    assert_equal EXPECTED_KEYS.sort, E::EXAMPLES.keys.sort,
      "EXAMPLES must carry exactly the 11 worked-example keys"
  end

  def test_each_example_is_non_empty_swift_source
    EXPECTED_KEYS.each do |key|
      source = E::EXAMPLES[key]
      assert_kind_of String, source
      refute source.empty?, "EXAMPLES[#{key.inspect}] must be non-empty Swift source"
      assert_match(/import /, source,
        "EXAMPLES[#{key.inspect}] must contain at least one Swift import")
    end
  end

  def test_int_in_string_out_example_demonstrates_rb_num2ll_and_str_new_cstr
    src = E::EXAMPLES[:int_in_string_out]
    assert_match(/rb_num2ll/, src)
    assert_match(/rb_str_new_cstr/, src)
  end

  def test_string_in_status_out_example_demonstrates_bound_var_pattern
    src = E::EXAMPLES[:string_in_status_out]
    assert_match(/var v0 = argv\[0\]/, src)
    assert_match(/rb_string_value_cstr\(&v0\)/, src)
  end

  def test_async_e1_demonstrates_dispatch_semaphore_skeleton
    src = E::EXAMPLES[:async_e1]
    assert_match(/DispatchSemaphore/, src)
    assert_match(/sema\.signal\(\)/, src)
    assert_match(/sema\.wait\(\)/, src)
  end

  def test_objc_f2_demonstrates_unmanaged_passretained
    src = E::EXAMPLES[:objc_f2]
    assert_match(/Unmanaged\.passRetained/, src)
  end

  def test_keep_for_family_carries_one_entry_per_kind_family
    map = E::KEEP_FOR_FAMILY
    assert_equal [:c, :objc, :swift], map.keys.sort
    map.each_value do |keys|
      assert_kind_of Array, keys
      refute keys.empty?, "KEEP_FOR_FAMILY entries must list at least one example key"
      keys.each do |k|
        assert E::EXAMPLES.key?(k),
          "KEEP_FOR_FAMILY references unknown example key #{k.inspect}"
      end
    end
  end

  def test_keep_for_family_c_picks_string_in_status_out
    assert_equal [:string_in_status_out], E::KEEP_FOR_FAMILY[:c]
  end

  def test_keep_for_family_swift_picks_async_e1
    assert_equal [:async_e1], E::KEEP_FOR_FAMILY[:swift]
  end

  def test_keep_for_family_objc_picks_objc_f2
    assert_equal [:objc_f2], E::KEEP_FOR_FAMILY[:objc]
  end
end
