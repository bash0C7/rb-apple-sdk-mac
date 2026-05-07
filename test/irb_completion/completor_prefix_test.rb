# frozen_string_literal: true
require "test_helper"
require "irb"
require "apple_sdk_mac/irb_completion"

# Reline は target (= preposing+target) を candidate の prefix に対して match する。
# IRB の BASIC_WORD_BREAK_CHARACTERS には `:` も `.` も入らんので、
# `Apple::Foundation::U<TAB>` のとき target = "Apple::Foundation::U" 全部、
# preposing = "" になる。 candidates が単に ["URL"] やと target と prefix が
# 噛み合わず Reline は確定できへん。 full-prefix で返す必要あり。
class TestCompletorPrefixMatch < Test::Unit::TestCase
  Provider = Struct.new(:result) do
    def call(_context); result; end
  end

  def make_completor(provider)
    AppleSDKMac::IRBCompletion::Completor.new(provider: provider, base: nil)
  end

  def test_apple_root_candidates_carry_apple_prefix
    provider = Provider.new(["Foundation", "Vision"])
    comp = make_completor(provider)
    out = comp.completion_candidates("", "Apple::F", "", bind: binding)
    assert_includes out, "Apple::Foundation"
    assert_includes out, "Apple::Vision"
  end

  def test_module_candidates_carry_full_apple_framework_prefix
    provider = Provider.new(["URL", "URLComponents"])
    comp = make_completor(provider)
    out = comp.completion_candidates("", "Apple::Foundation::U", "", bind: binding)
    assert_includes out, "Apple::Foundation::URL"
    assert_includes out, "Apple::Foundation::URLComponents"
  end

  def test_class_method_candidates_carry_full_receiver_prefix
    provider = Provider.new(["appendingPathComponent", "appendingPathExtension"])
    comp = make_completor(provider)
    out = comp.completion_candidates("", "Apple::Foundation::URL.appendingP", "", bind: binding)
    assert_includes out, "Apple::Foundation::URL.appendingPathComponent"
    assert_includes out, "Apple::Foundation::URL.appendingPathExtension"
  end
end
