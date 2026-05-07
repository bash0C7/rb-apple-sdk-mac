# frozen_string_literal: true
require "test_helper"
require "reline"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionInstall < Test::Unit::TestCase
  def setup
    @original_proc = Reline.completion_proc
    @original_perfect = Reline.dig_perfect_match_proc
  end

  def teardown
    AppleSDKMac::IRBCompletion.uninstall!
    Reline.completion_proc = @original_proc
    Reline.dig_perfect_match_proc = @original_perfect
  end

  def test_install_replaces_completion_proc
    AppleSDKMac::IRBCompletion.install!
    refute_same @original_proc, Reline.completion_proc
  end

  def test_apple_path_uses_apple_provider
    fake_cache = Object.new
    fake_cache.define_singleton_method(:list_frameworks) { ["Foundation", "Vision"] }
    fake_cache.define_singleton_method(:list_framework_symbols) { |**| [] }
    fake_cache.define_singleton_method(:list_klass_methods) { |**| [] }

    AppleSDKMac::IRBCompletion.install!(knowledge_cache: fake_cache)
    out = Reline.completion_proc.call("Apple::")
    assert_includes out, "Foundation"
    assert_includes out, "Vision"
  end

  def test_non_apple_path_delegates_to_original
    sentinel = ["delegated_result"]
    Reline.completion_proc = ->(_) { sentinel }
    AppleSDKMac::IRBCompletion.install!
    out = Reline.completion_proc.call("String.")
    assert_equal sentinel, out
  end

  def test_uninstall_restores_original
    Reline.completion_proc = ->(_) { ["sentinel"] }
    original = Reline.completion_proc
    AppleSDKMac::IRBCompletion.install!
    AppleSDKMac::IRBCompletion.uninstall!
    assert_same original, Reline.completion_proc
  end
end
