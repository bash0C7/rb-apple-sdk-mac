# frozen_string_literal: true
require "test_helper"

class TestAsyncBridge < Test::Unit::TestCase
  def test_await_runs_async_swift_task_and_returns_result
    started = Time.now
    result = AppleSDKMacRuntime::Test.async_await_sleep_and_double(50)
    assert result >= 100
    assert (Time.now - started) >= 0.04
  end

  def test_taskgroup_double_runs_three_parallel_swift_tasks
    started = Time.now
    sum = AppleSDKMacRuntime::Test.async_taskgroup_double(50, 60, 70)
    elapsed = Time.now - started
    assert_equal (50 + 60 + 70) * 2, sum
    assert elapsed < 0.18, "elapsed=#{elapsed}s suggests sequential execution"
    assert elapsed >= 0.07, "elapsed=#{elapsed}s suggests sleep didn't run"
  end
end
