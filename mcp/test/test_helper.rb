# frozen_string_literal: true
require "test-unit"
require "stringio"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__) # parent gem

require "apple_sdk_mac/mcp"

# Phase D — wrap_with_log の structured log を assert するために stderr を
# StringIO に差し替えて capture する helper。 test 終了時に元の $stderr に戻す。
module CaptureStderr
  def capture_stderr
    original = $stderr
    $stderr  = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end

Test::Unit::TestCase.include(CaptureStderr)
