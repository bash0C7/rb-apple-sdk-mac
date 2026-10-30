# frozen_string_literal: true

require_relative "apple_sdk_mac/version"
require_relative "apple_sdk_mac/errors"
require_relative "apple_sdk_mac/coverage_contract"
require_relative "apple_sdk_mac/inference/backend"
require_relative "apple_sdk_mac/inference/claude_p_backend"
require_relative "apple_sdk_mac/apple_sdk_mac_runtime"
require_relative "apple_sdk_mac/public_api"
require_relative "apple_sdk_mac/diagnostics"
require_relative "apple_sdk_mac/telemetry"

if defined?(Ruby::Box) && Ruby::Box.enabled?
  Object.send(:remove_const, :Apple) if Object.const_defined?(:Apple, false)
  Object.const_set(:Apple, Ruby::Box.new)
  Apple.require File.expand_path("../apple_sdk_mac/security_cop", __FILE__)
else
  warn "[rb-apple-sdk-mac] RUBY_BOX=1 not set; falling back to plain Module (isolation degraded)" if $VERBOSE
  Object.const_set(:Apple, Module.new) unless Object.const_defined?(:Apple, false)
end

module Apple
  Error          = ::AppleSDKMac::Error          unless const_defined?(:Error, false)
  DiscoveryError = ::AppleSDKMac::DiscoveryError unless const_defined?(:DiscoveryError, false)
  CompileError   = ::AppleSDKMac::CompileError   unless const_defined?(:CompileError, false)

  def self.discover(**kwargs); ::AppleSDKMac.discover(**kwargs); end
  def self.event_loop(&block); ::AppleSDKMac.event_loop(&block); end
  def self.configure(&block); ::AppleSDKMac.configure(&block); end
  def self.diagnostics; ::AppleSDKMac::Diagnostics.dump; end

  def self.bootstrap!
    ::AppleSDKMac.bootstrap!
  end
end
