# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

# public exception hierarchy contract. The Apple::Error tree is the
# user-facing rescue surface.
class TestErrors < Test::Unit::TestCase
  def test_apple_error_is_standard_error_subclass
    assert_operator Apple::Error, :<, StandardError
  end

  def test_discovery_error_inherits_apple_error
    assert_operator Apple::DiscoveryError, :<, Apple::Error
  end

  def test_compile_error_inherits_apple_error
    assert_operator Apple::CompileError, :<, Apple::Error
  end

  def test_apple_sdk_mac_error_aliases_apple_error
    # `rescue AppleSDKMac::Error` resolves to the same class as Apple::Error.
    assert_equal Apple::Error,          AppleSDKMac::Error
    assert_equal Apple::DiscoveryError, AppleSDKMac::DiscoveryError
    assert_equal Apple::CompileError,   AppleSDKMac::CompileError
  end

  def test_each_error_can_be_raised_and_carries_message
    [Apple::Error, Apple::DiscoveryError, Apple::CompileError].each do |klass|
      e = assert_raises(klass) { raise klass, "test #{klass}" }
      assert_equal "test #{klass}", e.message
    end
  end

  def test_call_error_retired
    refute Apple.const_defined?(:CallError, false),
      "Apple::CallError は Phase 3 で retire (ObjcError / SwiftError へ移行済)"
    refute AppleSDKMac.const_defined?(:CallError, false),
      "AppleSDKMac::CallError は Phase 3 で retire"
  end
end
