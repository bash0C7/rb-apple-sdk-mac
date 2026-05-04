# frozen_string_literal: true
require "test_helper"

class TestAsyncBridge < Test::Unit::TestCase
  def test_await_runs_async_swift_task_and_returns_result
    started = Time.now
    result = AppleSDKMacRuntime::Test.async_await_sleep_and_double(50)
    assert result >= 100
    assert (Time.now - started) >= 0.04
  end
end
