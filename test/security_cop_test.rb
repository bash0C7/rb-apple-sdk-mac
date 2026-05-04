# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/security_cop/policy"

# Tests cover the SecurityCop policy module (allow/allowed?/deny!) in isolation.
# The global Object/Kernel/File patches in security_cop.rb cannot be exercised
# inside this test process: applying them would also break the test runner.
# Box-scoped behaviour is verified manually or via a CoreMIDI integration smoke
# test that loads security_cop into a Ruby::Box.

class TestSecurityCopPolicy < Test::Unit::TestCase
  EVAL_LABEL = "the eval-family"

  def setup
    Thread.current[AppleSDKMac::SecurityCop::THREAD_KEY] = nil
  end

  def teardown
    Thread.current[AppleSDKMac::SecurityCop::THREAD_KEY] = nil
  end

  def test_allowed_is_false_by_default
    refute AppleSDKMac::SecurityCop.allowed?
  end

  def test_allow_block_flips_flag
    inside = nil
    AppleSDKMac::SecurityCop.allow do
      inside = AppleSDKMac::SecurityCop.allowed?
    end
    assert inside, "allowed? must be true inside the allow block"
    refute AppleSDKMac::SecurityCop.allowed?, "flag must be cleared after the block"
  end

  def test_allow_unwinds_on_exception
    assert_raise(RuntimeError) do
      AppleSDKMac::SecurityCop.allow { raise "boom" }
    end
    refute AppleSDKMac::SecurityCop.allowed?
  end

  def test_allow_nests_correctly
    AppleSDKMac::SecurityCop.allow do
      AppleSDKMac::SecurityCop.allow do
        assert AppleSDKMac::SecurityCop.allowed?
      end
      assert AppleSDKMac::SecurityCop.allowed?, "outer allow stays active"
    end
    refute AppleSDKMac::SecurityCop.allowed?
  end

  def test_deny_raises_security_violation_when_not_allowed
    assert_raise(AppleSDKMac::SecurityViolation) do
      AppleSDKMac::SecurityCop.deny!(EVAL_LABEL)
    end
  end

  def test_deny_is_silent_when_allowed
    AppleSDKMac::SecurityCop.allow do
      assert_nothing_raised do
        AppleSDKMac::SecurityCop.deny!(EVAL_LABEL)
      end
    end
  end

  def test_security_violation_is_a_security_error
    assert AppleSDKMac::SecurityViolation < SecurityError
  end
end
