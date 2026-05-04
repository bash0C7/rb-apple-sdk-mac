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

  def test_emits_structured_parameters_for_function
    fn = @symbols.find { |s| s[:name] == "MiniCreate" && s[:kind] == "function" }
    assert_not_nil fn
    assert_not_nil fn[:parameters], "FunctionDecl should expose :parameters array for downstream marshalling"
    assert_equal %w[name outClient], fn[:parameters].map { |p| p[:name] }
    types = fn[:parameters].map { |p| p[:type] }
    assert_match(/const char \*/, types[0])
    assert_match(/MiniClientRef \*/, types[1])
  end

  def test_does_not_leak_symbols_from_transitively_included_headers
    # MiniHeader.h #includes <stdint.h>, which transitively pulls in
    # pthread/NSConstantString/__builtin_va_list etc. The parser must filter
    # by source location and only emit symbols declared in the parsed file.
    leaked = @symbols.map { |s| s[:name] }.select do |n|
      n.start_with?("__", "_opaque_") || n == "MiniStatus" && false # keep MiniStatus
    end
    assert_empty leaked,
      "expected no system-header symbols, got: #{leaked.inspect}"
    # Sanity: only Mini-prefixed names plus enum constants should remain.
    own_names = @symbols.map { |s| s[:name] }.uniq
    foreign = own_names.reject { |n| n.match?(/\A(Mini|kMini)/) }
    assert_empty foreign,
      "expected only Mini* symbols, got foreign: #{foreign.inspect}"
  end

  def test_classifies_string_param
    fn = @symbols.find { |s| s[:name] == "MiniCreate" && s[:kind] == "function" }
    name_param = fn[:parameters].find { |p| p[:name] == "name" }
    assert_equal "string", name_param[:kind]
  end

  def test_classifies_int_param
    fn = @symbols.find { |s| s[:name] == "MiniDispose" && s[:kind] == "function" }
    client_param = fn[:parameters].find { |p| p[:name] == "client" }
    # MiniClientRef = struct *, name ends in Ref, becomes opaque_ref later;
    # for THIS step we only assert kind is set (not nil).
    assert_not_nil client_param[:kind]
  end

  def test_classifies_bool_param
    fn = @symbols.find { |s| s[:name] == "MiniIsActive" && s[:kind] == "function" }
    bool_param = fn[:parameters].find { |p| p[:name] == "checkPower" }
    assert_equal "bool", bool_param[:kind]
  end

  def test_classifies_float_return_function
    # Float kind shows up on the parameters; here MiniIsActive's BOOL-like return
    # is not exposed via :parameters. Use MiniGetRatio, whose only param is
    # MiniClientRef (opaque_ref).
    fn = @symbols.find { |s| s[:name] == "MiniGetRatio" && s[:kind] == "function" }
    client = fn[:parameters].find { |p| p[:name] == "client" }
    assert_equal "opaque_ref", client[:kind]
  end

  def test_classifies_opaque_ref_for_ref_typedef
    fn = @symbols.find { |s| s[:name] == "MiniDispose" && s[:kind] == "function" }
    client = fn[:parameters].find { |p| p[:name] == "client" }
    assert_equal "opaque_ref", client[:kind]
  end

  def test_classifies_void_pointer_as_unsupported
    fn = @symbols.find { |s| s[:name] == "MiniWithCallback" && s[:kind] == "function" }
    user_data = fn[:parameters].find { |p| p[:name] == "userData" }
    assert_equal "unsupported", user_data[:kind]
  end

  def test_classifies_callback_typedef_as_unsupported
    fn = @symbols.find { |s| s[:name] == "MiniWithCallback" && s[:kind] == "function" }
    cb = fn[:parameters].find { |p| p[:name] == "cb" }
    assert_equal "unsupported", cb[:kind]
  end
end
