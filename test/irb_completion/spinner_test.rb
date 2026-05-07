# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac/irb_completion"
require "stringio"

class TestIRBCompletionSpinner < Test::Unit::TestCase
  Spinner = AppleSDKMac::IRBCompletion::Spinner

  class FakeTTY < StringIO
    def tty?
      true
    end
  end

  def test_writes_alternating_frames
    io = FakeTTY.new
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("discovering Foo.bar...")
    sleep 0.05
    spinner.stop

    out = io.string
    assert_match(/\* discovering Foo\.bar\.\.\./, out)
    assert_match(/\+ discovering Foo\.bar\.\.\./, out)
  end

  def test_stop_clears_line
    io = FakeTTY.new
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("x")
    sleep 0.02
    spinner.stop

    assert_match(/\r\e\[K/, io.string)
  end

  def test_no_op_on_non_tty
    io = StringIO.new
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("x")
    sleep 0.02
    spinner.stop
    assert_equal "", io.string
  end

  def test_double_stop_safe
    io = FakeTTY.new
    spinner = Spinner.new(io: io, interval: 0.01)
    spinner.start("x")
    spinner.stop
    spinner.stop
  end
end
