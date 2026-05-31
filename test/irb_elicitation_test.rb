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

  # irb が(直接 or transitive に)require されているだけで対話 session が無い
  # プロセスでは available? は false を返さねばならない。IRB.CurrentContext は
  # session が無いと raise せず nil を返すため、戻り値を消費して判定する必要がある。
  #
  # require "irb" はプロセス全体で IRB を定義してしまい、同一プロセス内の
  # test_available_returns_false_when_irb_not_defined (IRB 未定義前提) を実行順序に
  # よっては壊す。独立性を保つため subprocess で検証する。
  def test_available_returns_false_when_irb_loaded_but_no_session
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{lib.inspect})
      require "irb"
      require "apple_sdk_mac/irb_elicitation"
      # irb は load されているが対話 session(CurrentContext)は無い
      print AppleSDKMac::IrbElicitation.available?.inspect
    RUBY
    out = IO.popen([RbConfig.ruby, "-e", script], &:read)
    status = $?
    assert_true status.success?, "subprocess failed: #{out}"
    assert_equal "false", out
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
