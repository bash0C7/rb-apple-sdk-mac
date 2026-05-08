# frozen_string_literal: true
require_relative "../test_helper"

class ProbeCapabilitiesTest < Test::Unit::TestCase
  # spec §4.7: server_context.client_capabilities を覗いて elicitation/sampling
  # 等を文字列で報告。引数なし。

  def test_tool_name
    assert_equal "apple_sdk_mac_probe_capabilities",
                 AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class.tool_name
  end

  def test_input_schema_takes_no_args
    schema = AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class.input_schema
    schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
    properties = schema_hash[:properties] || schema_hash["properties"] || {}
    assert_empty properties
  end

  def test_call_with_nil_server_context_reports_unknown
    tool_class = AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class
    response = tool_class.call(server_context: nil)
    text = extract_text(response)
    assert_match(/server_context/, text)
  end

  def test_call_with_capabilities_reports_them
    tool_class = AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class
    fake_context = Struct.new(:client_capabilities).new(
      { "elicitation" => {}, "sampling" => {} }
    )
    response = tool_class.call(server_context: fake_context)
    text = extract_text(response)
    assert_match(/elicitation/, text)
    assert_match(/sampling/, text)
  end

  private

  def extract_text(response)
    content = response.respond_to?(:content) ? response.content : response[:content]
    first = content.first
    first[:text] || first["text"]
  end
end
