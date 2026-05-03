# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/swift_interface_parser"

class TestSwiftInterfaceParser < Test::Unit::TestCase
  FIXTURE = File.expand_path("fixtures/MiniFramework.swiftinterface", __dir__)

  def setup
    @parser = AppleSDKKnowledge::Importer::SwiftInterfaceParser.new
    @symbols = @parser.parse_file(FIXTURE)
  end

  def test_extracts_top_level_function
    fn = @symbols.find { |s| s[:name] == "miniFunction" && s[:kind] == "function" }
    assert_not_nil fn
    assert_equal "swift", fn[:abi]
    assert_match(/Swift\.String.*Swift\.Int/, fn[:signature])
  end

  def test_extracts_class_with_methods
    cls = @symbols.find { |s| s[:name] == "MiniClass" && s[:kind] == "class" }
    assert_not_nil cls
    methods = @symbols.select { |s| s[:parent_name] == "MiniClass" && s[:kind] == "instance_method" }
    assert_includes methods.map { |m| m[:name] }, "doThing"
  end

  def test_extracts_enum_with_cases
    enum_sym = @symbols.find { |s| s[:name] == "MiniEnum" && s[:kind] == "enum_module" }
    assert_not_nil enum_sym
    cases = @symbols.select { |s| s[:parent_name] == "MiniEnum" && s[:kind] == "enum_case" }
    assert_equal 3, cases.length
    assert_includes cases.map { |c| c[:name] }, "alpha"
  end

  def test_extracts_struct
    s = @symbols.find { |s| s[:name] == "MiniStruct" && s[:kind] == "struct" }
    assert_not_nil s
  end

  def test_extracts_protocol
    p = @symbols.find { |s| s[:name] == "MiniProtocol" && s[:kind] == "protocol" }
    assert_not_nil p
  end
end
