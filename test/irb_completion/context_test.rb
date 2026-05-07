# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"

class TestIRBCompletionContext < Test::Unit::TestCase
  Context = AppleSDKMac::IRBCompletion::Context

  def test_apple_root_empty
    c = Context.parse("Apple::")
    assert_equal :apple_root, c.receiver_kind
    assert_nil c.framework
    assert_nil c.klass
    assert_equal "", c.prefix
  end

  def test_apple_root_with_prefix
    c = Context.parse("Apple::Fou")
    assert_equal :apple_root, c.receiver_kind
    assert_equal "Fou", c.prefix
  end

  def test_module_empty_prefix
    c = Context.parse("Apple::Foundation::")
    assert_equal :module, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_nil c.klass
    assert_equal "", c.prefix
  end

  def test_module_with_prefix
    c = Context.parse("Apple::Foundation::NSDa")
    assert_equal :module, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_equal "NSDa", c.prefix
  end

  def test_class_empty_prefix
    c = Context.parse("Apple::Foundation::NSData.")
    assert_equal :class, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_equal "NSData", c.klass
    assert_equal "", c.prefix
  end

  def test_class_with_prefix
    c = Context.parse("Apple::Foundation::NSData.dataW")
    assert_equal :class, c.receiver_kind
    assert_equal "Foundation", c.framework
    assert_equal "NSData", c.klass
    assert_equal "dataW", c.prefix
  end

  def test_non_apple_returns_nil
    assert_nil Context.parse("String.")
    assert_nil Context.parse("foo.bar")
    assert_nil Context.parse("")
    assert_nil Context.parse(nil)
  end
end
