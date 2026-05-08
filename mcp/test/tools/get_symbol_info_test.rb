# frozen_string_literal: true
require_relative "../test_helper"
require "json"

class GetSymbolInfoTest < Test::Unit::TestCase
  # spec §4.2 — symbol full record (parameters_json 込み)。
  # input: framework + symbol (both required)
  # behavior: KnowledgeCache#lookup_symbol を呼ぶ、 transient → DB 優先順

  FakeKB = Struct.new(:fixture) do
    def lookup_symbol(framework:, symbol:)
      fixture[[framework, symbol]]
    end
  end

  def setup
    fixture = {
      ["Foundation", "URL"] => {
        id: 42, name: "URL", kind: "struct",
        signature: "public struct URL : Sendable { ... }",
        parameters_json: "[]"
      }
    }
    @kb = FakeKB.new(fixture)
  end

  def test_tool_name
    tc = AppleSDKMac::MCP::Tools::GetSymbolInfo.tool_class(kb: @kb)
    assert_equal "apple_sdk_mac_get_symbol_info", tc.tool_name
  end

  def test_input_schema_requires_framework_and_symbol
    tc = AppleSDKMac::MCP::Tools::GetSymbolInfo.tool_class(kb: @kb)
    schema = tc.input_schema
    schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
    required = schema_hash[:required] || schema_hash["required"] || []
    assert_includes required, "framework"
    assert_includes required, "symbol"
  end

  def test_lookup_existing_symbol_returns_full_record
    tool = AppleSDKMac::MCP::Tools::GetSymbolInfo.new(kb: @kb)
    result = tool.call(framework: "Foundation", symbol: "URL")
    parsed = JSON.parse(result)
    assert_equal "URL", parsed["name"]
    assert_equal "struct", parsed["kind"]
    assert_match(/Sendable/, parsed["signature"])
  end

  def test_lookup_missing_symbol_returns_null_json
    tool = AppleSDKMac::MCP::Tools::GetSymbolInfo.new(kb: @kb)
    result = tool.call(framework: "Foundation", symbol: "DoesNotExist")
    assert_equal "null", result.strip
  end
end
