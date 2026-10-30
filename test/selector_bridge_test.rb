# frozen_string_literal: true
require "test_helper"

class TestSelectorBridge < Test::Unit::TestCase
  def test_canonical_method_name_single_segment_strips_trailing_colon
    assert_equal "stringWithUTF8String",
      AppleSDKMac::SelectorBridge.canonical_method_name("stringWithUTF8String:")
  end

  def test_canonical_method_name_no_colon_returns_as_is
    assert_equal "length",
      AppleSDKMac::SelectorBridge.canonical_method_name("length")
  end

  def test_canonical_method_name_init_multi_segment_swift_form
    assert_equal "init(cgImage:options:)",
      AppleSDKMac::SelectorBridge.canonical_method_name("initWithCGImage:options:")
  end

  def test_canonical_method_name_init_with_url_acronym
    assert_equal "init(url:resolvingAgainstBaseURL:)",
      AppleSDKMac::SelectorBridge.canonical_method_name(
        "initWithURL:resolvingAgainstBaseURL:"
      )
  end

  def test_canonical_method_name_non_init_multi_segment_keeps_first_form
    assert_equal "requestWithURL(cachePolicy:)",
      AppleSDKMac::SelectorBridge.canonical_method_name("requestWithURL:cachePolicy:")
  end

  def test_canonical_method_name_accepts_symbol
    assert_equal "length",
      AppleSDKMac::SelectorBridge.canonical_method_name(:length)
  end

  def test_lower_first_camel_empty_string
    assert_equal "", AppleSDKMac::SelectorBridge.lower_first_camel("")
  end

  def test_lower_first_camel_single_letter
    assert_equal "h", AppleSDKMac::SelectorBridge.lower_first_camel("H")
  end

  def test_lower_first_camel_simple_camel_case
    assert_equal "image", AppleSDKMac::SelectorBridge.lower_first_camel("Image")
  end

  def test_lower_first_camel_three_letter_acronym_alone
    assert_equal "url", AppleSDKMac::SelectorBridge.lower_first_camel("URL")
  end

  def test_lower_first_camel_three_letter_acronym_followed_by_word
    assert_equal "urlString",
      AppleSDKMac::SelectorBridge.lower_first_camel("URLString")
  end

  def test_lower_first_camel_xml_doc
    assert_equal "xmlDoc",
      AppleSDKMac::SelectorBridge.lower_first_camel("XMLDoc")
  end

  def test_lower_first_camel_irb_all_upper
    assert_equal "irb", AppleSDKMac::SelectorBridge.lower_first_camel("IRB")
  end

  def test_lower_first_camel_acronym_followed_by_digit
    assert_equal "utf8String",
      AppleSDKMac::SelectorBridge.lower_first_camel("UTF8String")
  end

  def test_lower_first_camel_cg_image_two_letter_acronym
    assert_equal "cgImage",
      AppleSDKMac::SelectorBridge.lower_first_camel("CGImage")
  end
end
