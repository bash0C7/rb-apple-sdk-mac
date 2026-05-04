# frozen_string_literal: true

module AppleSDKMac
  class SecurityViolation < SecurityError; end

  module SecurityCop
    THREAD_KEY = :__apple_sdk_mac_security_cop_allow__

    def self.allow
      prev = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = true
      yield
    ensure
      Thread.current[THREAD_KEY] = prev
    end

    def self.allowed?
      Thread.current[THREAD_KEY] == true
    end

    def self.deny!(operation)
      return if allowed?
      raise SecurityViolation,
            "#{operation} forbidden inside Apple box (wrap in AppleSDKMac::SecurityCop.allow for trusted internal calls)"
    end
  end
end
