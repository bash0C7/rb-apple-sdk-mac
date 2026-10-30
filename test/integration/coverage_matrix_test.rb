# frozen_string_literal: true
require "test_helper"

class CoverageMatrixTest < Test::Unit::TestCase
  def setup
    omit "set APPLE_SDK_MAC_RUN_E2E=1 to run" unless ENV["APPLE_SDK_MAC_RUN_E2E"] == "1"
    require "apple_sdk_mac"
    AppleSDKMac.bootstrap!
  end

  def test_function_c_kind_round_trips
    n = Apple::CoreMIDI.MIDIGetNumberOfDestinations
    assert_kind_of Integer, n
    assert_operator n, :>=, 0
  end

  def test_objc_method_class_kind_round_trips
    Apple.discover(framework: :Foundation, klass: :NSData,
                   class_method: "dataWithContentsOfFile:",
                   params: [:string], return_kind: :opaque_ref)
    data = Apple::Foundation::NSData.dataWithContentsOfFile(__FILE__)
    refute_nil data, "dataWithContentsOfFile: should return a non-nil NSData ref"
  end

  def test_objc_method_instance_kind_round_trips
    Apple.discover(framework: :Foundation, klass: :NSData,
                   class_method: "dataWithContentsOfFile:",
                   params: [:string], return_kind: :opaque_ref)
    Apple.discover(framework: :Foundation, klass: :NSData,
                   selector: "length", params: [], return_kind: :int)
    data = Apple::Foundation::NSData.dataWithContentsOfFile(__FILE__)
    refute_nil data
    len = data.length
    assert_kind_of Integer, len
    assert_operator len, :>, 0, "this test file has non-zero bytes"
  end

  def test_swift_init_kind_round_trips
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    utterance = Apple::AVFoundation::AVSpeechUtterance.init_string("hello world")
    refute_nil utterance, "AVSpeechUtterance.init(string:) should return a non-nil proxy"
  end

  def test_swift_property_kind_round_trips
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_property: :speechString, instance: true,
                   return_kind: :string)
    utterance = Apple::AVFoundation::AVSpeechUtterance.init_string("matrix probe")
    refute_nil utterance
    str = utterance.speechString
    assert_equal "matrix probe", str,
      "speechString getter must round-trip the init(string:) value"
  end

  def test_swift_property_setter_kind_round_trips
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_initializer: "init(string:)",
                   params: [:string], return_kind: :opaque_ref)
    Apple.discover(framework: :AVFoundation, klass: :AVSpeechUtterance,
                   swift_property: :rate, instance: true, return_kind: :float)
    utterance = Apple::AVFoundation::AVSpeechUtterance.init_string("rate probe")
    refute_nil utterance
    utterance.rate = 0.75
    read_back = utterance.rate
    assert_kind_of Float, read_back
    assert_operator read_back, :>, 0.0,
      "rate setter must take effect (read-back > 0)"
  end

  def test_swift_func_kind_round_trips
    Apple.discover(framework: :Foundation, swift_func: "NSHomeDirectory",
                   params: [], return_kind: :string)
    home = Apple::Foundation.NSHomeDirectory
    assert_kind_of String, home
    assert home.start_with?("/"), "NSHomeDirectory() must return an absolute path"
  end

  def test_global_constant_kind_round_trips
    v = Apple::CoreFoundation.kCFCoreFoundationVersionNumber
    assert_kind_of Numeric, v
    assert_operator v, :>, 0
  end
end
