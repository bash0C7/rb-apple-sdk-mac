# frozen_string_literal: true
require "test_helper"

class TestCallbackBridge < Test::Unit::TestCase
  def test_register_proc_and_invoke_via_swift
    invocations = []
    proc_id = AppleSDKMacRuntime::Test.callback_register do |x|
      invocations << x
    end
    AppleSDKMacRuntime::Test.callback_invoke(proc_id, 42)
    AppleSDKMacRuntime::Test.callback_invoke(proc_id, 99)
    assert_equal [42, 99], invocations
  end
end
