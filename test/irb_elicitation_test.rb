# frozen_string_literal: true
require "test/unit"
require "stringio"
require_relative "../lib/apple_sdk_mac/irb_elicitation"

class IrbElicitationTest < Test::Unit::TestCase
  # test-unit 3.x はメソッド差し替えの stub を同梱しないため、依存追加せず
  # plain Ruby で singleton method を一時的に差し替える (ensure で復元)。
  def with_stub(mod, name, value)
    original = mod.method(name)
    mod.define_singleton_method(name) { |*_args, **_kw| value }
    yield
  ensure
    mod.singleton_class.send(:remove_method, name)
    mod.define_singleton_method(name, original)
  end

  def test_available_returns_false_when_irb_not_defined
    assert_false AppleSDKMac::IrbElicitation.available?
  end

  def test_elicit_returns_nil_when_not_available
    result = AppleSDKMac::IrbElicitation.elicit(
      framework: "CoreAudio", symbol_name: "AudioObjectGetPropertyDataSize",
      stdin: StringIO.new("some input\n"),
      stdout: StringIO.new
    )
    assert_nil result
  end

  def test_elicit_reads_from_stdin_when_available
    elicitation = AppleSDKMac::IrbElicitation
    with_stub(elicitation, :available?, true) do
      out = StringIO.new
      result = elicitation.elicit(
        framework: "F", symbol_name: "Sym",
        stdin: StringIO.new("Return type is UInt32\n"),
        stdout: out
      )
      assert_equal "Return type is UInt32", result
      assert_match(/F::Sym/, out.string)
    end
  end

  def test_elicit_returns_nil_for_empty_input
    elicitation = AppleSDKMac::IrbElicitation
    with_stub(elicitation, :available?, true) do
      result = elicitation.elicit(
        framework: "F", symbol_name: "Sym",
        stdin: StringIO.new("\n"),
        stdout: StringIO.new
      )
      assert_nil result
    end
  end
end
