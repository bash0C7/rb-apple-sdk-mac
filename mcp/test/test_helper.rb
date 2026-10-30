# frozen_string_literal: true
require "test-unit"
require "stringio"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "apple_sdk_mac/mcp"

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
