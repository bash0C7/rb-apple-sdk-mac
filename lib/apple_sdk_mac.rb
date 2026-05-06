# frozen_string_literal: true

require_relative "apple_sdk_mac/version"
require_relative "apple_sdk_mac/errors"
require_relative "apple_sdk_mac/apple_sdk_mac_runtime"
require_relative "apple_sdk_mac/public_api"

if defined?(Ruby::Box) && Ruby::Box.enabled?
  Object.send(:remove_const, :Apple) if Object.const_defined?(:Apple, false)
  Object.const_set(:Apple, Ruby::Box.new)
  Apple.require File.expand_path("../apple_sdk_mac/security_cop", __FILE__)
else
  warn "[rb-apple-sdk-mac] RUBY_BOX=1 not set; falling back to plain Module (isolation degraded)" if $VERBOSE
  Object.const_set(:Apple, Module.new) unless Object.const_defined?(:Apple, false)
end

module Apple
  def self.discover(**kwargs); ::AppleSDKMac.discover(**kwargs); end
  def self.event_loop(&block); ::AppleSDKMac.event_loop(&block); end
  def self.configure(&block); ::AppleSDKMac.configure(&block); end

  # Eagerly populate Apple::<Framework> modules and their constants from the
  # knowledge base without compiling any glue. Method calls on the populated
  # modules still trigger lazy discover/compile per symbol on first invocation.
  # Useful for examples that introspect the namespace before calling anything.
  def self.bootstrap!
    ::AppleSDKMac.bootstrap!
  end
end
