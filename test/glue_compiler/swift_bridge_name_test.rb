# frozen_string_literal: true
require "test/unit"
require "apple_sdk_mac/glue_compiler/swift_bridge_name"

class SwiftBridgeNameTest < Test::Unit::TestCase
  # Stub implementing the relevant slice of KnowledgeCache for unit testing.
  class StubKC
    def initialize(table)
      @table = table
    end
    def lookup_swift_imported_name(framework:, klass:, selector:)
      @table[[framework, klass, selector]]
    end
  end

  def test_resolve_uses_kb_swift_imported_name_when_available
    kc = StubKC.new(
      ["AVFoundation", "AVCaptureDevice", "devicesWithMediaType:"] => "devices(for:)",
    )
    out = AppleSDKMac::GlueCompiler::SwiftBridgeName.resolve(
      framework: "AVFoundation", klass: "AVCaptureDevice",
      selector: "devicesWithMediaType:", params: [:opaque_ref], kc: kc,
    )
    assert_equal "AVCaptureDevice.devices(for: arg0)", out
  end

  def test_resolve_kb_init_form_emits_constructor_call
    kc = StubKC.new(
      ["Foundation", "URL", "URLWithString:"] => "init(string:)",
    )
    out = AppleSDKMac::GlueCompiler::SwiftBridgeName.resolve(
      framework: "Foundation", klass: "URL",
      selector: "URLWithString:", params: [:string], kc: kc,
    )
    assert_equal "URL(string: arg0)", out
  end

  def test_resolve_kb_underscore_label_emits_positional_arg
    kc = StubKC.new(
      ["Foundation", "URL", "URL:"] => "url(_:)",
    )
    out = AppleSDKMac::GlueCompiler::SwiftBridgeName.resolve(
      framework: "Foundation", klass: "URL",
      selector: "URL:", params: [:string], kc: kc,
    )
    assert_equal "URL.url(arg0)", out
  end

  def test_resolve_zero_arg_kb_form
    kc = StubKC.new(
      ["Foundation", "Process", "shared"] => "shared()",
    )
    out = AppleSDKMac::GlueCompiler::SwiftBridgeName.resolve(
      framework: "Foundation", klass: "Process",
      selector: "shared", params: [], kc: kc,
    )
    assert_equal "Process.shared()", out
  end

  def test_resolve_returns_nil_when_kb_miss_and_no_override
    kc = StubKC.new({})
    out = AppleSDKMac::GlueCompiler::SwiftBridgeName.resolve(
      framework: "AVFoundation", klass: "AVCaptureDevice",
      selector: "devicesWithMediaType:", params: [:opaque_ref], kc: kc,
    )
    assert_nil out
  end

  def test_resolve_returns_nil_when_kc_unavailable
    out = AppleSDKMac::GlueCompiler::SwiftBridgeName.resolve(
      framework: "Foundation", klass: "URL",
      selector: "URLWithString:", params: [:string], kc: nil,
    )
    assert_nil out
  end

  def test_resolve_falls_through_to_overrides_when_kb_misses
    AppleSDKMac::GlueCompiler.send(:remove_const, :SWIFT_BRIDGE_OVERRIDES) if AppleSDKMac::GlueCompiler.const_defined?(:SWIFT_BRIDGE_OVERRIDES)
    AppleSDKMac::GlueCompiler.const_set(:SWIFT_BRIDGE_OVERRIDES, {
      ["FakeFW", "FakeKlass", "fakeSelector:"] => "FakeKlass.special(thing: %s)",
    }.freeze)

    kc = StubKC.new({})
    out = AppleSDKMac::GlueCompiler::SwiftBridgeName.resolve(
      framework: "FakeFW", klass: "FakeKlass",
      selector: "fakeSelector:", params: [:string], kc: kc,
    )
    assert_equal "FakeKlass.special(thing: arg0)", out
  ensure
    AppleSDKMac::GlueCompiler.send(:remove_const, :SWIFT_BRIDGE_OVERRIDES)
    AppleSDKMac::GlueCompiler.const_set(:SWIFT_BRIDGE_OVERRIDES, {}.freeze)
  end
end
