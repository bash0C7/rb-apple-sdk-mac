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

    begin
      Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
      Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientDispose)
    rescue AppleSDKMac::Error => e
      omit "discover failed: #{e.message}"
    end

    client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac smoke test", nil, nil)
    assert_not_nil client
    Apple::CoreMIDI.MIDIClientDispose(client)
  end

  def test_receive_notification
    frameworks = begin
      AppleSDKMac.knowledge_cache.list_frameworks
    rescue StandardError => e
      omit "knowledge base not available: #{e.message}"
    end
    omit "CoreMIDI not in knowledge base" unless frameworks.include?("CoreMIDI")

    begin
      Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
      Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientDispose)
      Apple.discover(framework: :CoreMIDI, symbol: :MIDISourceCreate)
      Apple.discover(framework: :CoreMIDI, symbol: :MIDIEndpointDispose)
    rescue AppleSDKMac::Error => e
      omit "discover failed: #{e.message}"
    end

    notifs = []
    block = ->(message_id) { notifs << message_id }
    client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac recv smoke", block, nil)
    assert_not_nil client

    source = Apple::CoreMIDI.MIDISourceCreate(client, "smoke-source")
    assert_not_nil source

    # CoreMIDI delivers SetupAdded / ObjectAdded notifications asynchronously;
    # pump the cross-thread queue in slices up to ~1.5s.
    deadline = Time.now + 1.5
    while notifs.empty? && Time.now < deadline
      AppleSDKMacRuntime.threading_poll(0.3)
    end

    Apple::CoreMIDI.MIDIEndpointDispose(source)
    Apple::CoreMIDI.MIDIClientDispose(client)

    assert !notifs.empty?, "expected at least one MIDI notification (got #{notifs.inspect})"
  end
end
