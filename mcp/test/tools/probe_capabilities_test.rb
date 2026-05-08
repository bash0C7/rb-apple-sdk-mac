# frozen_string_literal: true
require_relative "../test_helper"
require "json"

class ProbeCapabilitiesTest < Test::Unit::TestCase
  # spec §4.7 (修正): client_capabilities hash 覗きでなく、 chiebukuro-mcp 流に
  # server_context.create_form_elicitation / create_sampling_message を実呼び
  # して例外で判定する実証型に変更。 mcp gem の client_capabilities は host 側
  # transport の実装で必ずしも populate されないため、 実呼びの方が信頼できる。

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

  def test_call_with_nil_server_context_returns_error_status
    tool_class = AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class
    response   = nil
    capture_stderr { response = tool_class.call(server_context: nil) }
    parsed     = JSON.parse(extract_text(response))
    assert_equal "error", parsed["status"]
    assert_match(/server_context/, parsed["error"])
  end

  def test_supported_when_methods_succeed
    tool_class   = AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class
    fake_context = SupportedContext.new
    response     = nil
    capture_stderr { response = tool_class.call(server_context: fake_context) }
    parsed       = JSON.parse(extract_text(response))
    assert_equal "supported", parsed["elicitation"]["status"]
    assert_equal "supported", parsed["sampling"]["status"]
  end

  def test_unsupported_when_methods_raise
    tool_class   = AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class
    fake_context = UnsupportedContext.new
    response     = nil
    capture_stderr { response = tool_class.call(server_context: fake_context) }
    parsed       = JSON.parse(extract_text(response))
    assert_equal "unsupported", parsed["elicitation"]["status"]
    assert_equal "unsupported", parsed["sampling"]["status"]
    assert_match(/elicit boom/,   parsed["elicitation"]["error"])
    assert_match(/sampling boom/, parsed["sampling"]["error"])
  end

  def test_elicitation_supported_sampling_unsupported_mixed
    # 実 host (Claude Code 含む) でよくある状態: 片方だけ実装。
    tool_class   = AppleSDKMac::MCP::Tools::ProbeCapabilities.tool_class
    fake_context = MixedContext.new
    response     = nil
    capture_stderr { response = tool_class.call(server_context: fake_context) }
    parsed       = JSON.parse(extract_text(response))
    assert_equal "supported",   parsed["elicitation"]["status"]
    assert_equal "unsupported", parsed["sampling"]["status"]
  end

  class SupportedContext
    def create_form_elicitation(message:, requested_schema:)
      { action: "decline" }
    end
    def create_sampling_message(messages:, max_tokens:, system_prompt: nil)
      { model: "fake-model", content: { type: "text", text: "pong" } }
    end
  end

  class UnsupportedContext
    def create_form_elicitation(**_)
      raise "elicit boom"
    end
    def create_sampling_message(**_)
      raise "sampling boom"
    end
  end

  class MixedContext
    def create_form_elicitation(**_)
      { action: "decline" }
    end
    def create_sampling_message(**_)
      raise NoMethodError, "create_sampling_message not implemented by host"
    end
  end

  private

  def extract_text(response)
    content = response.respond_to?(:content) ? response.content : response[:content]
    first = content.first
    first[:text] || first["text"]
  end
end
