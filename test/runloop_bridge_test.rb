# frozen_string_literal: true
require "test_helper"

class TestRunLoopBridge < Test::Unit::TestCase
  def test_pump_returns_quickly_with_zero_timeout
    started = Time.now
    AppleSDKMacRuntime.runloop_pump(0.0)
    assert (Time.now - started) < 0.05
  end

  def test_pump_respects_timeout
    # Drain any residual runloop sources left by earlier tests so the timing
    # assertion isn't tripped by a CFRunLoopRunInMode early-exit when an
    # unrelated source happens to be pending. CFRunLoopRunInMode with
    # returnAfterSourceHandled=true exits as soon as one source is handled.
    8.times { AppleSDKMacRuntime.runloop_pump(0.0) }
    started = Time.now
    AppleSDKMacRuntime.runloop_pump(0.1)
    elapsed = Time.now - started
    assert elapsed >= 0.08
    assert elapsed < 0.5
  end
end
