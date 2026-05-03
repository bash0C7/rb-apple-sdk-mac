# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/header_parser"

class TestHeaderParser < Test::Unit::TestCase
  FIXTURE = File.expand_path("fixtures/MiniHeader.h", __dir__)

  def setup
    @parser = AppleSDKKnowledge::Importer::HeaderParser.new
    @symbols = @parser.parse_file(FIXTURE)
  end

  def test_extracts_extern_function
    fn = @symbols.find { |s| s[:name] == "MiniCreate" && s[:kind] == "function" }
    assert_not_nil fn
    assert_equal "c", fn[:abi]
  end

  def test_extracts_typedef_struct_pointer_as_type
    t = @symbols.find { |s| s[:name] == "MiniClientRef" && s[:kind] == "struct" }
    assert_not_nil t
  end

  def test_extracts_enum_cases_as_global_constants
    cases = @symbols.select { |s| s[:abi] == "c" && s[:kind] == "global_constant" && %w[kMiniErrorNone kMiniErrorBadInput].include?(s[:name]) }
    assert_equal 2, cases.length
  end

  def test_extracts_extern_const
    c = @symbols.find { |s| s[:name] == "kMiniDefaultName" && s[:kind] == "global_constant" }
    assert_not_nil c
  end

  def test_does_not_classify_function_pointer_typedef_as_struct
    cb = @symbols.find { |s| s[:name] == "MiniCallback" }
    if cb
      assert_not_equal "struct", cb[:kind],
        "function-pointer typedef should not be classified as struct"
    end
    # Either it's not emitted at all, or it's emitted with a non-struct kind.
    # The current acceptable shapes are: omitted, or kind=function_pointer (future).
  end
end
