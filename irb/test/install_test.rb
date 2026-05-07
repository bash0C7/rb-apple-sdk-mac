# frozen_string_literal: true
require "test_helper"
require "irb"
require "apple_sdk_mac/irb"

class TestIRBInstall < Test::Unit::TestCase
  def teardown
    AppleSDKMac::IRB.uninstall!
  end

  def test_install_sets_installed_flag
    AppleSDKMac::IRB.install!
    assert AppleSDKMac::IRB.installed?
  end

  def test_install_provides_apple_provider
    fake_cache = Object.new
    fake_cache.define_singleton_method(:list_frameworks) { ["Foundation", "Vision"] }
    fake_cache.define_singleton_method(:list_framework_symbols) { |**| [] }
    fake_cache.define_singleton_method(:list_klass_methods) { |**| [] }

    AppleSDKMac::IRB.install!(knowledge_cache: fake_cache)
    provider = AppleSDKMac::IRB.apple_provider
    refute_nil provider

    completor = AppleSDKMac::IRB::Completor.new(provider: provider, base: nil)
    out = completor.completion_candidates("Apple::", "", "", bind: binding)
    assert_includes out, "Apple::Foundation"
    assert_includes out, "Apple::Vision"
  end

  def test_completor_delegates_non_apple_to_base
    fake_cache = Object.new
    fake_cache.define_singleton_method(:list_frameworks) { [] }
    fake_cache.define_singleton_method(:list_framework_symbols) { |**| [] }
    fake_cache.define_singleton_method(:list_klass_methods) { |**| [] }

    AppleSDKMac::IRB.install!(knowledge_cache: fake_cache)
    provider = AppleSDKMac::IRB.apple_provider

    base = Object.new
    base.define_singleton_method(:completion_candidates) do |preposing, target, postposing, bind:|
      ["delegated_for_#{preposing}#{target}"]
    end

    completor = AppleSDKMac::IRB::Completor.new(provider: provider, base: base)
    assert_equal ["delegated_for_String."],
      completor.completion_candidates("String.", "", "", bind: binding)
  end

  def test_completor_returns_empty_for_non_apple_when_no_base
    AppleSDKMac::IRB.install!
    provider = AppleSDKMac::IRB.apple_provider
    completor = AppleSDKMac::IRB::Completor.new(provider: provider, base: nil)

    assert_equal [], completor.completion_candidates("foo.bar", "", "", bind: binding)
  end

  def test_install_sets_irb_completor_to_type
    AppleSDKMac::IRB.install!
    assert_equal :type, IRB.conf[:COMPLETOR]
  end

  def test_uninstall_clears_provider
    AppleSDKMac::IRB.install!
    AppleSDKMac::IRB.uninstall!
    refute AppleSDKMac::IRB.installed?
    assert_nil AppleSDKMac::IRB.apple_provider
  end

  def test_install_prepends_context_override
    AppleSDKMac::IRB.install!
    assert IRB::Context.include?(AppleSDKMac::IRB::ContextOverride),
      "IRB::Context must be prepended with ContextOverride"
  end

  def test_install_prepends_reline_input_method_override
    AppleSDKMac::IRB.install!
    assert IRB::RelineInputMethod.include?(AppleSDKMac::IRB::RelineInputMethodOverride),
      "IRB::RelineInputMethod must be prepended with RelineInputMethodOverride"
  end
end
