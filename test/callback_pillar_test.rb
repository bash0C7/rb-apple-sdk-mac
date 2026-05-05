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
end
