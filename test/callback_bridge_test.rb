# frozen_string_literal: true
require "test_helper"

class TestCallbackBridge < Test::Unit::TestCase
  def test_register_proc_and_invoke_via_swift
    invocations = []
    proc_id = AppleSDKMacRuntime.callback_register_test do |x|
      invocations << x
    end
    AppleSDKMacRuntime.callback_invoke_test(proc_id, 42)
    AppleSDKMacRuntime.callback_invoke_test(proc_id, 99)
    assert_equal [42, 99], invocations
  end
end
