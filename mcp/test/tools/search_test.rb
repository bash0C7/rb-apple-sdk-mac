# frozen_string_literal: true
require_relative "../test_helper"
require "json"

class SearchTest < Test::Unit::TestCase
  # spec §4.1 — KB の semantic + lexical 検索。
  # input: query (required), framework? / kinds? / limit? (optional, default 10)
  # output: JSON text response

  FIXTURE = [
    { framework: "Foundation", name: "URL",         kind: "struct",          signature: "struct URL" },
    { framework: "Foundation", name: "URLSession",  kind: "class",           signature: "class URLSession" },
    { framework: "Foundation", name: "url",         kind: "instance_method", signature: "func url() -> URL" },
    { framework: "CoreMIDI",   name: "MIDIClientCreate", kind: "function",   signature: "OSStatus MIDIClientCreate(...)" }
  ].freeze

  FakeKB = Struct.new(:fixture) do
    def search(framework:, query:, limit: 5)
      fixture.select { |r|
        r[:framework] == framework && r[:name].downcase.include?(query.downcase)
      }.first(limit)
    end

    def list_frameworks
      fixture.map { |r| r[:framework] }.uniq
    end
  end

  def setup
    @kb = FakeKB.new(FIXTURE.dup)
  end

  def test_tool_name
    tc = AppleSDKMac::MCP::Tools::Search.tool_class(kb: @kb)
    assert_equal "apple_sdk_mac_search", tc.tool_name
  end

  def test_input_schema_query_required
    tc = AppleSDKMac::MCP::Tools::Search.tool_class(kb: @kb)
    schema = tc.input_schema
    schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
    required = schema_hash[:required] || schema_hash["required"] || []
    assert_includes required, "query"
  end

  def test_search_with_framework_returns_json_array
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: @kb)
    result = tool.call(query: "URL", framework: "Foundation")
    parsed = JSON.parse(result)
    assert_kind_of Array, parsed
    names = parsed.map { |r| r["name"] }
    assert_includes names, "URL"
    assert_includes names, "URLSession"
  end

  def test_search_kinds_filter
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: @kb)
    result = tool.call(query: "URL", framework: "Foundation", kinds: ["struct"])
    parsed = JSON.parse(result)
    assert_equal 1, parsed.size
    assert_equal "URL", parsed.first["name"]
  end

  def test_search_limit
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: @kb)
    result = tool.call(query: "URL", framework: "Foundation", limit: 1)
    parsed = JSON.parse(result)
    assert_equal 1, parsed.size
  end

  def test_search_cross_framework_when_framework_nil
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: @kb)
    result = tool.call(query: "URL", framework: nil)
    parsed = JSON.parse(result)
    frameworks = parsed.map { |r| r["framework"] }.uniq
    assert_includes frameworks, "Foundation"
  end

  def test_unknown_framework_returns_empty_array
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: @kb)
    result = tool.call(query: "anything", framework: "DoesNotExist")
    assert_equal [], JSON.parse(result)
  end

  # 自然言語 phrase の token 化 + OR 結合 — 親 gem の FTS5 が multi-token
  # AND default で 0 件返す問題への前処理 (debug 2026-05-08)。

  RecordingKB = Struct.new(:fixture, :calls) do
    def search(framework:, query:, limit: 5)
      calls << { framework: framework, query: query, limit: limit }
      []
    end
    def list_frameworks; []; end
  end

  def test_multi_token_natural_phrase_is_or_joined
    calls = []
    kb = RecordingKB.new([], calls)
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: kb)
    tool.call(query: "read EXIF metadata from image", framework: "ImageIO")
    received = calls.first[:query]
    assert_match(/\bOR\b/, received, "multi-token query should be OR-joined")
    assert_match(/EXIF/, received)
    assert_match(/metadata/, received)
    assert_match(/image/, received)
  end

  def test_single_token_query_passes_through
    calls = []
    kb = RecordingKB.new([], calls)
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: kb)
    tool.call(query: "EXIF", framework: "ImageIO")
    assert_equal "EXIF", calls.first[:query]
  end

  def test_empty_query_passes_through
    calls = []
    kb = RecordingKB.new([], calls)
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: kb)
    tool.call(query: "", framework: "ImageIO")
    assert_equal "", calls.first[:query]
  end

  def test_short_tokens_filtered
    # 1-char tokens (a, of) はノイズが大きいので除外、 2 文字以上のみ OR-join
    calls = []
    kb = RecordingKB.new([], calls)
    tool = AppleSDKMac::MCP::Tools::Search.new(kb: kb)
    tool.call(query: "URL of a session", framework: "Foundation")
    received = calls.first[:query]
    assert_match(/URL/, received)
    assert_match(/session/, received)
    refute_match(/\b(of|a)\b/, received)
  end

  # Phase D — tool_class 経由で .call すると wrap_with_log が動き、 stderr に
  # JSON ログが 1 行出る。 全 tool に同じ wiring を適用する代表 test。

  def test_tool_call_emits_log_line_to_stderr
    tool_class = AppleSDKMac::MCP::Tools::Search.tool_class(kb: @kb)
    log = capture_stderr do
      tool_class.call(query: "URL", framework: "Foundation")
    end
    parsed = JSON.parse(log.strip)
    assert_equal "tool_call", parsed["kind"]
    assert_equal "apple_sdk_mac_search", parsed["tool"]
  end
end
