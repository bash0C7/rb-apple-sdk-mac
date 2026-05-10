# frozen_string_literal: true
require_relative "test_helper"
require "json"

class ServerTest < Test::Unit::TestCase
  # v0.1 gate: tools/list で probe_capabilities、 resources/list で 0 件
  # v0.2 gate: tools/list に apple_sdk_mac_search が追加 (合計 2 件)
  # spec: docs/superpowers/specs/2026-05-08-rb-apple-sdk-mac-mcp-design.md §8

  FakeKB = Struct.new(:list_frameworks) do
    def search(framework:, query:, limit: 5); []; end
    def lookup_symbol(framework:, symbol:); nil; end
    def list_klass_methods(framework:, klass:); []; end
  end

  def setup
    @fake_kb = FakeKB.new([])
  end

  def test_build_mcp_server_returns_mcp_server
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    mcp_server = server.build_mcp_server
    assert_kind_of ::MCP::Server, mcp_server
  end

  def test_probe_capabilities_tool_present
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    tool_names = server.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_probe_capabilities"
  end

  def test_search_tool_present
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    tool_names = server.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_search"
  end

  def test_get_symbol_info_tool_present
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    tool_names = server.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_get_symbol_info"
  end

  def test_list_klass_methods_tool_present
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    tool_names = server.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_list_klass_methods"
  end

  def test_suggest_discover_call_tool_present
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    tool_names = server.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_suggest_discover_call"
  end

  def test_dry_run_template_tool_present
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    tool_names = server.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_dry_run_template"
  end

  def test_validate_call_tool_present
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    tool_names = server.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_validate_call"
  end

  def test_resources_registered
    # 8 個の Resources (静的 markdown 6 + KB 動的 2)。
    server = AppleSDKMac::MCP::Server.new(kb: @fake_kb)
    server.build_mcp_server
    assert_equal 8, server.resource_list.size
  end

  def test_build_mcp_server_response_responds_to_mcp_server_methods
    mcp_server = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    assert_respond_to mcp_server, :name
  end

  # Phase D — wrap_with_log は block を実行しつつ stderr に 1 行 JSON を吐き、
  # block の戻り値をそのまま返す。 chiebukuro-mcp の wrap_with_log_proc 同形。

  def test_wrap_with_log_emits_json_to_stderr_and_returns_block_value
    log = capture_stderr do
      result = AppleSDKMac::MCP::Server.wrap_with_log(tool_name: "test_tool") { "hello" }
      assert_equal "hello", result
    end
    parsed = JSON.parse(log.strip)
    assert_equal "tool_call", parsed["kind"]
    assert_equal "test_tool", parsed["tool"]
    assert_kind_of Integer, parsed["elapsed_ms"]
    assert_kind_of String, parsed["ts"]
  end

  def test_wrap_with_log_extract_row_count_for_array_payload
    response = ::MCP::Tool::Response.new([{ type: "text", text: "[1,2,3]" }])
    assert_equal 3, AppleSDKMac::MCP::Server.extract_row_count(response)
  end

  def test_wrap_with_log_extract_row_count_for_non_array
    response = ::MCP::Tool::Response.new([{ type: "text", text: "{\"action\":\"accept\"}" }])
    assert_equal 0, AppleSDKMac::MCP::Server.extract_row_count(response)
  end
end
