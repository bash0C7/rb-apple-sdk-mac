# frozen_string_literal: true
require_relative "../test_helper"
require "json"
require "set"

class ValidateCallTest < Test::Unit::TestCase
  FakeKB = Struct.new(:known) do
    def lookup_symbol(framework:, symbol:)
      known.include?([framework.to_s, symbol.to_s]) ? { name: symbol.to_s } : nil
    end

    def lookup_klass_method(framework:, klass:, method:)
      known.include?([framework.to_s, klass.to_s, method.to_s]) ? { name: method.to_s } : nil
    end
  end

  def setup
    @kb = FakeKB.new(Set.new([
      ["Foundation", "URL"],
      ["Foundation", "URLSession"],
      ["CoreMIDI", "MIDIClientCreate"]
    ]))
  end

  def test_tool_name
    tc = AppleSDKMac::MCP::Tools::ValidateCall.tool_class(kb: @kb)
    assert_equal "apple_sdk_mac_validate_call", tc.tool_name
  end

  def test_input_requires_ruby_code
    tc = AppleSDKMac::MCP::Tools::ValidateCall.tool_class(kb: @kb)
    schema = tc.input_schema
    schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
    required = schema_hash[:required] || schema_hash["required"] || []
    assert_includes required, "ruby_code"
  end

  def test_known_symbol_passes
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: @kb)
    code = 'Apple.discover(framework: :Foundation, symbol: :URL)'
    result = tool.call(ruby_code: code)
    parsed = JSON.parse(result)
    assert_empty parsed["issues"]
    assert_equal true, parsed["valid"]
  end

  def test_unknown_symbol_warns
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: @kb)
    code = 'Apple.discover(framework: :Foundation, symbol: :NoSuchThing)'
    result = tool.call(ruby_code: code)
    parsed = JSON.parse(result)
    assert_operator parsed["issues"].size, :>=, 1
    assert_match(/NoSuchThing/, parsed["issues"].first["message"])
    assert_equal false, parsed["valid"]
  end

  def test_multiple_calls_in_code
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: @kb)
    code = <<~RUBY
      Apple.discover(framework: :Foundation, symbol: :URL)
      Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
      Apple.discover(framework: :Foundation, symbol: :NoSuchThing)
    RUBY
    result = tool.call(ruby_code: code)
    parsed = JSON.parse(result)
    assert_equal 1, parsed["issues"].size
  end

  def test_no_apple_calls_returns_empty_valid
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: @kb)
    code = 'puts "hello"'
    result = tool.call(ruby_code: code)
    parsed = JSON.parse(result)
    assert_empty parsed["issues"]
    assert_equal true, parsed["valid"]
  end

  def test_direct_klass_method_call_known_passes
    kb = FakeKB.new(Set.new([["Foundation", "URL", "appendingPathComponent"]]))
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: kb)
    code = 'Apple::Foundation::URL.appendingPathComponent("foo")'
    parsed = JSON.parse(tool.call(ruby_code: code))
    assert_empty parsed["issues"]
    assert_equal 1, parsed["checked_count"]
  end

  def test_direct_klass_method_call_unknown_warns
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: @kb)
    code = 'Apple::Foundation::URL.noSuchMethod()'
    parsed = JSON.parse(tool.call(ruby_code: code))
    assert_operator parsed["issues"].size, :>=, 1
    assert_match(/URL\.noSuchMethod/, parsed["issues"].first["message"])
  end

  def test_direct_framework_function_call_known_passes
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: @kb)
    code = 'Apple::CoreMIDI.MIDIClientCreate("MyClient")'
    parsed = JSON.parse(tool.call(ruby_code: code))
    assert_empty parsed["issues"]
    assert_equal 1, parsed["checked_count"]
  end

  def test_direct_calls_combine_with_discover_calls
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: @kb)
    code = <<~RUBY
      Apple.discover(framework: :Foundation, symbol: :URL)
      Apple::CoreMIDI.MIDIClientCreate(refnil, out)
    RUBY
    parsed = JSON.parse(tool.call(ruby_code: code))
    assert_empty parsed["issues"]
    assert_equal 2, parsed["checked_count"]
  end

  def test_direct_call_after_literal_backslash_n_is_detected
    kb = FakeKB.new(Set.new([
      ["Foundation", "URL"],
      ["Foundation", "URL", "appendingPathComponent"]
    ]))
    tool = AppleSDKMac::MCP::Tools::ValidateCall.new(kb: kb)
    code = 'Apple.discover(framework: :Foundation, symbol: :URL)\nApple::Foundation::URL.appendingPathComponent("foo")'
    parsed = JSON.parse(tool.call(ruby_code: code))
    assert_equal 2, parsed["checked_count"], "discover + direct の 2 件抽出すべき"
    assert_empty parsed["issues"]
  end
end
