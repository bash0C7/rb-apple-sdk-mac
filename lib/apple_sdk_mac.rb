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
  # Alias the canonical exception hierarchy from AppleSDKMac into the Apple
  # Box. errors.rb defines them under AppleSDKMac so the class objects
  # survive the Box bootstrap above; here we re-expose them under Apple::*
  # so user code can `rescue Apple::Error => e` as documented.
  Error          = ::AppleSDKMac::Error          unless const_defined?(:Error, false)
  DiscoveryError = ::AppleSDKMac::DiscoveryError unless const_defined?(:DiscoveryError, false)
  CompileError   = ::AppleSDKMac::CompileError   unless const_defined?(:CompileError, false)

  def self.discover(**kwargs); ::AppleSDKMac.discover(**kwargs); end
  def self.event_loop(&block); ::AppleSDKMac.event_loop(&block); end
  def self.configure(&block); ::AppleSDKMac.configure(&block); end
  def self.diagnostics; ::AppleSDKMac::Diagnostics.dump; end

  # Eagerly populate Apple::<Framework> modules and their constants from the
  # knowledge base without compiling any glue. Method calls on the populated
  # modules still trigger lazy discover/compile per symbol on first invocation.
  # Useful for examples that introspect the namespace before calling anything.
  def self.bootstrap!
    ::AppleSDKMac.bootstrap!
  end
end

# IRB autocomplete / doc preview / auto-discover prefetch は同 repo の
# logical sub-gem `apple_sdk_mac-irb` に分離 (irb/ ディレクトリ)。
# 主 gem は IRB / Reline / repl_type_completor / foundation_model_mac の
# IRB 関連依存を一切持たない。
#
# IRB セッションで利用したい場合は明示的に:
#   require "apple_sdk_mac"
#   require "apple_sdk_mac/irb"
#   AppleSDKMac::IRB.install!
