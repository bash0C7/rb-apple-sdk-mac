# frozen_string_literal: true
require_relative "../test_helper"
require "json"

class SuggestDiscoverCallTest < Test::Unit::TestCase
  # spec §4.4 + §6 — intent → Apple.discover kwargs 生成。
  # 候補 1 個なら elicitation なし即決、 2 個以上なら server_context.create_form_elicitation
  # で user に選ばせる。 accept / decline / cancel 3 分岐。

  FakeKB = Struct.new(:fixture) do
    def search(framework:, query:, limit: 5)
      fixture.select { |r|
        (framework.nil? || r[:framework] == framework) &&
        r[:name].downcase.include?(query.downcase)
      }.first(limit)
    end

    def list_frameworks
      fixture.map { |r| r[:framework] }.uniq
    end
  end

  class FakeServerContext
    attr_reader :elicitation_calls
    def initialize(canned_response)
      @canned = canned_response
      @elicitation_calls = []
    end

    def create_form_elicitation(message:, requested_schema:)
      @elicitation_calls << { message: message, schema: requested_schema }
      @canned
    end
  end

  FIXTURE = [
    { framework: "Foundation", name: "URL", kind: "struct",
      signature: "public struct URL" },
    { framework: "Foundation", name: "URLSession", kind: "class",
      signature: "public class URLSession" },
    { framework: "CoreMIDI", name: "MIDIClientCreate", kind: "function",
      signature: "OSStatus MIDIClientCreate(...)" },
    { framework: "Foundation", name: "URL.appendingPathComponent(_:)",
      kind: "swift_func", signature: "func appendingPathComponent(_:)" }
  ].freeze

  def setup
    @kb = FakeKB.new(FIXTURE.dup)
  end

  def test_tool_name
    tc = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.tool_class(kb: @kb)
    assert_equal "apple_sdk_mac_suggest_discover_call", tc.tool_name
  end

  def test_intent_required
    tc = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.tool_class(kb: @kb)
    schema = tc.input_schema
    schema_hash = schema.respond_to?(:to_h) ? schema.to_h : schema
    required = schema_hash[:required] || schema_hash["required"] || []
    assert_includes required, "intent"
  end

  def test_no_match_returns_no_match_action
    tool = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: @kb)
    result = tool.call(intent: "totally_unknown_xyz", framework: nil, server_context: nil)
    parsed = JSON.parse(result)
    assert_equal "no_match", parsed["action"]
  end

  def test_single_match_returns_kwargs_without_elicitation
    tool = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: @kb)
    ctx = FakeServerContext.new({ action: "accept", content: {} })
    result = tool.call(intent: "MIDIClientCreate", framework: "CoreMIDI", server_context: ctx)
    parsed = JSON.parse(result)
    assert_equal "accept", parsed["action"]
    assert_equal "CoreMIDI", parsed["kwargs"]["framework"]
    assert_equal "MIDIClientCreate", parsed["kwargs"]["symbol"]
    assert_empty ctx.elicitation_calls
  end

  def test_multiple_matches_invokes_elicitation
    tool = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: @kb)
    ctx = FakeServerContext.new({
      action: "accept",
      content: { choice: "Foundation::URL (struct)" }
    })
    result = tool.call(intent: "URL", framework: "Foundation", server_context: ctx)
    parsed = JSON.parse(result)
    assert_equal 1, ctx.elicitation_calls.size
    assert_equal "accept", parsed["action"]
    assert_equal "Foundation", parsed["kwargs"]["framework"]
    assert_equal "URL", parsed["kwargs"]["klass"]
  end

  def test_elicitation_decline
    tool = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: @kb)
    ctx = FakeServerContext.new({ action: "decline", content: {} })
    result = tool.call(intent: "URL", framework: "Foundation", server_context: ctx)
    parsed = JSON.parse(result)
    assert_equal "decline", parsed["action"]
  end

  def test_elicitation_cancel
    tool = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: @kb)
    ctx = FakeServerContext.new({ action: "cancel", content: {} })
    result = tool.call(intent: "URL", framework: "Foundation", server_context: ctx)
    parsed = JSON.parse(result)
    assert_equal "cancel", parsed["action"]
  end

  def test_kwargs_for_swift_func_with_klass_in_name
    tool = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: @kb)
    ctx = FakeServerContext.new({
      action: "accept",
      content: { choice: "Foundation::URL.appendingPathComponent(_:) (swift_func)" }
    })
    result = tool.call(intent: "appendingPathComponent", framework: "Foundation", server_context: ctx)
    parsed = JSON.parse(result)
    assert_equal "accept", parsed["action"]
    assert_equal "Foundation", parsed["kwargs"]["framework"]
    assert_equal "URL", parsed["kwargs"]["klass"]
    assert_equal "appendingPathComponent(_:)", parsed["kwargs"]["swift_func"]
  end

  def test_multiple_matches_without_server_context_returns_candidates
    tool = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: @kb)
    result = tool.call(intent: "URL", framework: "Foundation", server_context: nil)
    parsed = JSON.parse(result)
    assert_equal "candidates", parsed["action"]
    assert_kind_of Array, parsed["candidates"]
    assert_operator parsed["candidates"].size, :>=, 2
  end

  # Phase C-1 — accept response の record は lookup_symbol で fetch した
  # 完全 record (documentation / parameters_json 等込み) に置き換える。
  # AI agent は record を見て override 判断できるので、 search row では薄すぎる。

  RichKB = Struct.new(:search_fixture, :lookup_fixture) do
    def search(framework:, query:, limit: 5)
      search_fixture.select { |r|
        (framework.nil? || r[:framework] == framework) &&
        r[:name].downcase.include?(query.downcase)
      }.first(limit)
    end
    def lookup_symbol(framework:, name:)
      lookup_fixture[[framework, name]]
    end
    def list_frameworks
      search_fixture.map { |r| r[:framework] }.uniq
    end
  end

  def test_accept_response_uses_lookup_symbol_for_richer_record
    search_fix = [{ framework: "CoreMIDI", name: "MIDIClientCreate", kind: "function",
                    signature: "OSStatus MIDIClientCreate(...)" }]
    lookup_fix = {
      ["CoreMIDI", "MIDIClientCreate"] => {
        framework:       "CoreMIDI",
        name:            "MIDIClientCreate",
        kind:            "function",
        signature:       "OSStatus MIDIClientCreate(...)",
        documentation:   "Creates a MIDI client object.",
        parameters_json: "[{\"kind\":\"cstring\"}]"
      }
    }
    kb     = RichKB.new(search_fix, lookup_fix)
    tool   = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: kb)
    parsed = JSON.parse(tool.call(intent: "MIDIClientCreate", framework: "CoreMIDI", server_context: nil))
    assert_equal "accept", parsed["action"]
    assert_equal "Creates a MIDI client object.", parsed["record"]["documentation"]
    assert_match(/cstring/, parsed["record"]["parameters_json"])
  end

  def test_accept_falls_back_to_search_row_when_lookup_symbol_returns_nil
    search_fix = [{ framework: "CoreMIDI", name: "MIDIClientCreate", kind: "function",
                    signature: "OSStatus MIDIClientCreate(...)" }]
    lookup_fix = {} # lookup_symbol が nil を返す
    kb     = RichKB.new(search_fix, lookup_fix)
    tool   = AppleSDKMac::MCP::Tools::SuggestDiscoverCall.new(kb: kb)
    parsed = JSON.parse(tool.call(intent: "MIDIClientCreate", framework: "CoreMIDI", server_context: nil))
    assert_equal "accept", parsed["action"]
    assert_equal "MIDIClientCreate", parsed["record"]["name"]
    assert_equal "function", parsed["record"]["kind"]
  end
end
