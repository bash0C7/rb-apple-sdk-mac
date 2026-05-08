# frozen_string_literal: true
require_relative "../test_helper"
require "json"

class ListKlassMethodsTest < Test::Unit::TestCase
  # spec §4.3 — クラス子要素列挙。
  # input: framework + klass (both required)
  # behavior: KnowledgeCache#list_klass_methods を呼ぶ
  # 用途: Apple::Foundation::URL.<TAB> で見える候補と同じ列を AI に渡す

  FakeKB = Struct.new(:fixture) do
    def list_klass_methods(framework:, klass:)
      fixture[[framework, klass]] || []
    end
  end

  def setup
    fixture = {
      ["Foundation", "URL"] => [
        { name: "appendingPathComponent(_:)", kind: "swift_func",
          signature: "func appendingPathComponent(_ pathComponent: String) -> URL" },
        { name: "path", kind: "swift_property",
          signature: "var path: String" },
        { name: "init(string:)", kind: "swift_init",
          signature: "init?(string: String)" }
      ]
    }
    @kb = FakeKB.new(fixture)
  end

  def test_tool_name
    tc = AppleSDKMac::MCP::Tools::ListKlassMethods.tool_class(kb: @kb)
    assert_equal "apple_sdk_mac_list_klass_methods", tc.tool_name
  end

  def test_input_schema_requires_framework_and_klass
    tc = AppleSDKMac::MCP::Tools::ListKlassMethods.tool_class(kb: @kb)
    schema = tc.input_schema
    schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
    required = schema_hash[:required] || schema_hash["required"] || []
    assert_includes required, "framework"
    assert_includes required, "klass"
  end

  def test_list_returns_json_array_of_klass_members
    tool = AppleSDKMac::MCP::Tools::ListKlassMethods.new(kb: @kb)
    result = tool.call(framework: "Foundation", klass: "URL")
    parsed = JSON.parse(result)
    assert_equal 3, parsed.size
    names = parsed.map { |r| r["name"] }
    assert_includes names, "appendingPathComponent(_:)"
    assert_includes names, "path"
    assert_includes names, "init(string:)"
  end

  def test_unknown_klass_returns_empty_array
    tool = AppleSDKMac::MCP::Tools::ListKlassMethods.new(kb: @kb)
    result = tool.call(framework: "Foundation", klass: "DoesNotExist")
    assert_equal [], JSON.parse(result)
  end
end
