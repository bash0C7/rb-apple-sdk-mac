# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

class TestCoreMIDISmoke < Test::Unit::TestCase
  def test_create_client_and_dispose
    frameworks = begin
      AppleSDKMac.knowledge_cache.list_frameworks
    rescue StandardError => e
      omit "knowledge base not available: #{e.message}"
    end
    omit "CoreMIDI not in knowledge base" unless frameworks.include?("CoreMIDI")

    Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate) rescue nil
    Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientDispose) rescue nil

    client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac smoke test", nil, nil)
    assert_not_nil client
    Apple::CoreMIDI.MIDIClientDispose(client)
  end
end
