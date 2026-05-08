# frozen_string_literal: true
require_relative "test_helper"

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

  def test_build_mcp_server_returns_facade
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    assert_kind_of AppleSDKMac::MCP::Server::ServerFacade, facade
  end

  def test_probe_capabilities_tool_present
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    tool_names = facade.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_probe_capabilities"
  end

  def test_search_tool_present
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    tool_names = facade.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_search"
  end

  def test_get_symbol_info_tool_present
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    tool_names = facade.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_get_symbol_info"
  end

  def test_list_klass_methods_tool_present
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    tool_names = facade.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_list_klass_methods"
  end

  def test_suggest_discover_call_tool_present
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    tool_names = facade.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_suggest_discover_call"
  end

  def test_dry_run_template_tool_present
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    tool_names = facade.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_dry_run_template"
  end

  def test_validate_call_tool_present
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    tool_names = facade.tool_classes.map(&:tool_name)
    assert_includes tool_names, "apple_sdk_mac_validate_call"
  end

  def test_resources_registered
    # v0.6 + v0.7 で 8 個の Resources。 v0.2 までは 0 件、 v0.6 で増える。
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    assert_equal 8, facade.resource_list.size
  end

  def test_facade_responds_to_mcp_server_methods
    facade = AppleSDKMac::MCP::Server.new(kb: @fake_kb).build_mcp_server
    assert_respond_to facade, :name
  end
end
