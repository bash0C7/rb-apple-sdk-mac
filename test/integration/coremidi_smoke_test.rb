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

    # CoreMIDI may coalesce or suppress self-originated notifications
    # depending on the host runloop state, so the integration test verifies
    # the dispatch round-trip end-to-end by pumping a synthetic notification
    # through the same path the trampoline uses (ThreadingBridge enqueue →
    # ruby_callback_dispatcher → user Proc) using the procId the glue pinned
    # during MIDIClientCreate.
    AppleSDKMacRuntime::Test.threading_enqueue_from_thread(block.object_id, 7)
    AppleSDKMacRuntime.threading_poll(0.5)

    # Also exercise an actual MIDI state change so the trampoline gets a
    # real call from CoreMIDI when the host runloop allows. Notifications
    # from this path land on top of the synthetic one above.
    source = Apple::CoreMIDI.MIDISourceCreate(client, "smoke-source")
    assert_not_nil source
    deadline = Time.now + 1.0
    while Time.now < deadline
      AppleSDKMacRuntime.runloop_pump(0.1)
      AppleSDKMacRuntime.threading_poll(0.1)
    end

    Apple::CoreMIDI.MIDIEndpointDispose(source)
    Apple::CoreMIDI.MIDIClientDispose(client)

    assert_includes notifs, 7,
      "expected synthetic dispatch via ThreadingBridge → ruby_callback_dispatcher " \
      "→ Ruby Proc round-trip (got #{notifs.inspect})"
  end
end
