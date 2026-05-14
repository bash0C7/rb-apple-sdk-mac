# frozen_string_literal: true
require "test-unit"
require "apple_sdk_mac/errors"

class TestErrorsPhase2 < Test::Unit::TestCase
  def test_framework_missing_error_is_apple_sdk_mac_error
    e = AppleSDKMac::FrameworkMissingError.new("framework not in Knowledge Base")
    assert_kind_of AppleSDKMac::Error, e
    assert_equal "framework not in Knowledge Base", e.message
  end

  def test_symbol_missing_error_is_apple_sdk_mac_error
    e = AppleSDKMac::SymbolMissingError.new("symbol absent")
    assert_kind_of AppleSDKMac::Error, e
  end

  def test_unsupported_pattern_error_carries_pattern_metadata
    e = AppleSDKMac::UnsupportedPatternError.new(
      pattern: "swift_macro",
      framework: "Foundation",
      symbol: "Observable::someMethod"
    )
    assert_kind_of AppleSDKMac::Error, e
    assert_equal "swift_macro", e.pattern
    assert_equal "Foundation", e.framework
    assert_equal "Observable::someMethod", e.symbol
    assert_match(/swift_macro/, e.message)
    assert_match(/Foundation/, e.message)
    assert_match(/Observable::someMethod/, e.message)
  end

  def test_glue_compile_error_is_alias_of_compile_error
    assert_same AppleSDKMac::CompileError, AppleSDKMac::GlueCompileError
  end

  def test_objc_error_is_apple_sdk_mac_error
    e = AppleSDKMac::ObjcError.new("NSError: domain=NSCocoaErrorDomain code=4")
    assert_kind_of AppleSDKMac::Error, e
  end

  def test_swift_error_is_apple_sdk_mac_error
    e = AppleSDKMac::SwiftError.new("Swift threw URLError")
    assert_kind_of AppleSDKMac::Error, e
  end

  def test_unsupported_pattern_error_diagnostic_message_includes_section_6_2_fields
    e = AppleSDKMac::UnsupportedPatternError.new(
      pattern: "swift_macro",
      framework: "Foundation",
      symbol: "Observable::someMethod",
      hint: "Use Swift package wrapper."
    )
    msg = e.message
    assert_match(/Pattern: swift_macro/, msg)
    assert_match(/Framework: Foundation/, msg)
    assert_match(/Symbol: Observable::someMethod/, msg)
    assert_match(/macOS SDK:/, msg)
    assert_match(/gem version:/, msg)
    assert_match(/Knowledge Base schema:/, msg)
    assert_match(/Workaround:/, msg)
    assert_match(/Use Swift package wrapper/, msg)
    assert_match(%r{https://github.com/bash0C7/rb-apple-sdk-mac/issues}, msg)
  end

  def test_unsupported_pattern_error_diagnostic_message_default_workaround
    e = AppleSDKMac::UnsupportedPatternError.new(
      pattern: "novel_pattern",
      framework: "Foo",
      symbol: "Foo.bar"
      # hint not specified
    )
    msg = e.message
    # hint 無しでも Workaround セクションは存在する (default 文言)
    assert_match(/Workaround:/, msg)
    # default workaround 文は github URL / docs / wrapper 等の generic guidance を含む
    assert_match(%r{https?://}, msg)
  end
end
