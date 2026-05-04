# frozen_string_literal: true
require "test_helper"

class TestRunLoopBridge < Test::Unit::TestCase
  def test_pump_returns_quickly_with_zero_timeout
    started = Time.now
    AppleSDKMacRuntime.runloop_pump(0.0)
    assert (Time.now - started) < 0.05
  end

  def test_pump_respects_timeout
    started = Time.now
    AppleSDKMacRuntime.runloop_pump(0.1)
    elapsed = Time.now - started
    assert elapsed >= 0.08
    assert elapsed < 0.5
  end
end
