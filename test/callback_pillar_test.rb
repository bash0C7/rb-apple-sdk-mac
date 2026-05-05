# frozen_string_literal: true
require "test_helper"

class TestCallbackPillar < Test::Unit::TestCase
  def setup
    # Pool is process-global; clear all slots before each test.
    4.times { |i| AppleSDKMacRuntime::CallbackPillar.unregister_midi_notify(i) }
  end

  def test_register_returns_slot_and_fnptr
    slot, fnptr = AppleSDKMacRuntime::CallbackPillar.register_midi_notify(->(x) {})
    assert (0..3).include?(slot), "slot should be in 0..3, got #{slot.inspect}"
    assert fnptr > 0, "fnptr should be a non-null pointer, got #{fnptr.inspect}"
  end

  def test_pool_exhaustion_raises
    4.times { AppleSDKMacRuntime::CallbackPillar.register_midi_notify(->(x) {}) }
    assert_raise(RuntimeError) {
      AppleSDKMacRuntime::CallbackPillar.register_midi_notify(->(x) {})
    }
  end

  def test_unregister_frees_slot_for_reuse
    slot, _ = AppleSDKMacRuntime::CallbackPillar.register_midi_notify(->(x) {})
    AppleSDKMacRuntime::CallbackPillar.unregister_midi_notify(slot)
    slot_reused, _ = AppleSDKMacRuntime::CallbackPillar.register_midi_notify(->(x) {})
    assert_equal slot, slot_reused
  end

  # End-to-end dispatch path that the MIDINotifyProc trampoline takes:
  # register a Ruby Proc → invoke via callback_invoke (which is what
  # the trampoline body's ThreadingBridge.enqueue ultimately drives) →
  # observe the Proc was called.
  def test_register_and_dispatch_round_trip
    received = []
    proc = ->(x) { received << x }
    slot, _ = AppleSDKMacRuntime::CallbackPillar.register_midi_notify(proc)
    refute_nil slot
    AppleSDKMacRuntime::Test.callback_invoke(proc.object_id, 42)
    assert_equal [42], received
  end
end
