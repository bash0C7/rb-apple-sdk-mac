# frozen_string_literal: true
require_relative "../test_helper"
require "json"

class DryRunTemplateTest < Test::Unit::TestCase
  # spec §4.5 — TemplateGenerator#generate だけ呼んで Swift glue source 文字列を
  # 返す (swiftc は走らせない)。 trust-but-verify ループ用。

  FakeKB = Struct.new(:fixture) do
    def lookup_symbol(framework:, symbol:)
      fixture[[framework, symbol]]
    end
  end

  class FakeTemplate
    attr_reader :calls
    def initialize(return_value)
      @return_value = return_value
      @calls = []
    end

    def generate(framework:, symbol:, glue_id:)
      @calls << { framework: framework, symbol_name: symbol[:name], glue_id: glue_id }
      @return_value
    end
  end

  def setup
    fixture = {
      ["CoreMIDI", "MIDIClientCreate"] => { id: 1, name: "MIDIClientCreate", kind: "function" }
    }
    @kb = FakeKB.new(fixture)
  end

  def test_tool_name
    tc = AppleSDKMac::MCP::Tools::DryRunTemplate.tool_class(kb: @kb)
    assert_equal "apple_sdk_mac_dry_run_template", tc.tool_name
  end

  def test_input_requires_framework_and_symbol
    tc = AppleSDKMac::MCP::Tools::DryRunTemplate.tool_class(kb: @kb)
    schema = tc.input_schema
    schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
    required = schema_hash[:required] || schema_hash["required"] || []
    assert_includes required, "framework"
    assert_includes required, "symbol"
  end

  def test_returns_swift_source_when_template_succeeds
    tool = AppleSDKMac::MCP::Tools::DryRunTemplate.new(
      kb: @kb, template: FakeTemplate.new("// generated swift here")
    )
    result = tool.call(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    parsed = JSON.parse(result)
    assert_equal "success", parsed["result"]
    assert_match(/generated swift/, parsed["swift_source"])
    assert_equal "template", parsed["generator"]
  end

  def test_returns_declined_when_template_returns_nil
    tool = AppleSDKMac::MCP::Tools::DryRunTemplate.new(
      kb: @kb, template: FakeTemplate.new(nil)
    )
    result = tool.call(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    parsed = JSON.parse(result)
    assert_equal "declined", parsed["result"]
  end

  def test_returns_error_when_symbol_missing
    tool = AppleSDKMac::MCP::Tools::DryRunTemplate.new(
      kb: @kb, template: FakeTemplate.new("never called")
    )
    result = tool.call(framework: "Foundation", symbol: "DoesNotExist")
    parsed = JSON.parse(result)
    assert_match(/not found/, parsed["error"])
  end
end
