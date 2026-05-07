# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb"
require "apple_sdk_mac/irb/translator"

# Translator wraps rb-translation-mac (Apple Intelligence translation)
# so DocResolver's doc_transform can localize KB doc strings on the
# fly. The wrapper:
# - parses LANG env to BCP-47 (ja_JP.UTF-8 → ja-JP)
# - skips translation when LANG is C / POSIX / English / empty
# - caches by input text
# - silently degrades to the original text on translator errors
#   (popup hover must never crash IRB)
class TestTranslator < Test::Unit::TestCase
  Translator = AppleSDKMac::IRB::Translator

  # ---- detect_target_lang (LANG env → BCP-47) ----------------------------

  def test_detect_target_lang_strips_encoding_suffix
    assert_equal "ja-JP", Translator.detect_target_lang("ja_JP.UTF-8")
  end

  def test_detect_target_lang_converts_underscore_to_dash
    assert_equal "fr-FR", Translator.detect_target_lang("fr_FR")
  end

  def test_detect_target_lang_passes_short_form
    assert_equal "ja", Translator.detect_target_lang("ja")
  end

  def test_detect_target_lang_returns_nil_for_english
    assert_nil Translator.detect_target_lang("en_US.UTF-8")
    assert_nil Translator.detect_target_lang("en_GB")
    assert_nil Translator.detect_target_lang("en")
  end

  def test_detect_target_lang_returns_nil_for_c_or_posix
    assert_nil Translator.detect_target_lang("C")
    assert_nil Translator.detect_target_lang("POSIX")
  end

  def test_detect_target_lang_returns_nil_for_blank
    assert_nil Translator.detect_target_lang(nil)
    assert_nil Translator.detect_target_lang("")
  end

  # ---- translate (proc + cache + degrade) --------------------------------

  Result = Struct.new(:success, :text, keyword_init: true)

  def test_translate_returns_input_unchanged_when_no_target_lang
    t = Translator.new(target_lang: nil, translate_proc: ->(*) { raise "should not be called" })
    assert_equal "Adds the value.", t.translate("Adds the value.")
  end

  def test_translate_invokes_proc_with_from_and_to
    seen = nil
    proc_ = ->(text, from:, to:) {
      seen = [text, from, to]
      Result.new(success: true, text: "値を追加します。")
    }
    t = Translator.new(target_lang: "ja-JP", translate_proc: proc_)
    out = t.translate("Adds the value.")
    assert_equal ["Adds the value.", "en-US", "ja-JP"], seen
    assert_equal "値を追加します。", out
  end

  def test_translate_caches_by_input
    counter = 0
    proc_ = ->(text, **_) {
      counter += 1
      Result.new(success: true, text: "T#{counter}: #{text}")
    }
    t = Translator.new(target_lang: "ja-JP", translate_proc: proc_)
    a = t.translate("Hello")
    b = t.translate("Hello")
    c = t.translate("World")
    assert_equal a, b
    assert_not_equal a, c
    assert_equal 2, counter
  end

  def test_translate_falls_back_to_original_when_result_unsuccessful
    proc_ = ->(*) { Result.new(success: false, text: nil) }
    t = Translator.new(target_lang: "ja-JP", translate_proc: proc_)
    assert_equal "Adds the value.", t.translate("Adds the value.")
  end

  def test_translate_falls_back_to_original_when_proc_raises
    proc_ = ->(*) { raise "translator unavailable" }
    t = Translator.new(target_lang: "ja-JP", translate_proc: proc_)
    assert_nothing_raised do
      assert_equal "Adds the value.", t.translate("Adds the value.")
    end
  end

  def test_translate_returns_input_for_blank_text
    proc_ = ->(*) { raise "should not be called" }
    t = Translator.new(target_lang: "ja-JP", translate_proc: proc_)
    assert_equal "", t.translate("")
    assert_nil t.translate(nil)
  end

  def test_translate_accepts_string_result_from_proc
    proc_ = ->(*) { "直接返す訳文" }
    t = Translator.new(target_lang: "ja-JP", translate_proc: proc_)
    assert_equal "直接返す訳文", t.translate("Original")
  end

  def test_active_query
    t = Translator.new(target_lang: "ja-JP", translate_proc: ->(*) { nil })
    assert t.active?
    t = Translator.new(target_lang: nil, translate_proc: ->(*) { nil })
    refute t.active?
  end
end
