# frozen_string_literal: true
require "test_helper"

class TestThreadingBridge < Test::Unit::TestCase
  def test_deferred_queue_drains_via_poll
    received = []
    proc_id = AppleSDKMacRuntime.callback_register_test do |x|
      received << x
    end
    AppleSDKMacRuntime.threading_enqueue_from_thread(proc_id, 1)
    AppleSDKMacRuntime.threading_enqueue_from_thread(proc_id, 2)
    AppleSDKMacRuntime.threading_enqueue_from_thread(proc_id, 3)
    AppleSDKMacRuntime.threading_poll(0.1)
    assert_equal [1, 2, 3], received
  end
end
