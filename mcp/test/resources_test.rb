# frozen_string_literal: true
require_relative "test_helper"

class ResourcesTest < Test::Unit::TestCase
  # spec §5 — 8 個の Resources (静的 markdown 6 + KB 動的 2)。
  # v0.6 gate: resources/list で 8 件返る、 resources/read で内容取得できる。

  FakeKB = Struct.new(:list_frameworks) do
    def search(framework:, query:, limit: 5); []; end
    def lookup_symbol(framework:, symbol:); nil; end
    def list_klass_methods(framework:, klass:); []; end
    def list_framework_symbols(framework:, kinds: nil); []; end
    def db; FakeDB.new; end

    class FakeDB
      def execute(_sql, *_)
        [[10, 100]]
      end
    end
  end

  def setup
    @kb = FakeKB.new(["Foundation", "CoreMIDI"])
  end

  EXPECTED_URIS = [
    "apple-sdk-mac://discover-shapes",
    "apple-sdk-mac://dispatch-flow",
    "apple-sdk-mac://kind-catalog",
    "apple-sdk-mac://override-recipes",
    "apple-sdk-mac://proxy-wrap-rules",
    "apple-sdk-mac://callback-patterns",
    "apple-sdk-mac://framework-list",
    "apple-sdk-mac://stats"
  ].freeze

  def test_resources_list_has_eight_entries
    facade = AppleSDKMac::MCP::Server.new(kb: @kb).build_mcp_server
    assert_equal 8, facade.resource_list.size
  end

  def test_all_expected_uris_present
    facade = AppleSDKMac::MCP::Server.new(kb: @kb).build_mcp_server
    uris = facade.resource_list.map(&:uri)
    EXPECTED_URIS.each do |expected|
      assert_includes uris, expected
    end
  end

  def test_static_doc_resource_reads_markdown_file
    handler = AppleSDKMac::MCP::Resources::StaticDocResource.new(filename: "discover-shapes.md")
    content = handler.call
    assert_kind_of String, content
    assert content.length > 0
  end

  def test_framework_list_resource_uses_kb
    handler = AppleSDKMac::MCP::Resources::FrameworkListResource.new(kb: @kb)
    content = handler.call
    assert_match(/Foundation/, content)
    assert_match(/CoreMIDI/, content)
  end

  def test_stats_resource_uses_kb
    handler = AppleSDKMac::MCP::Resources::StatsResource.new(kb: @kb)
    content = handler.call
    assert_kind_of String, content
    assert content.length > 0
  end
end
