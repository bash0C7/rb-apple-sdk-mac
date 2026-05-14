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
end
