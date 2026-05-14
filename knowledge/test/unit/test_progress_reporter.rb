# frozen_string_literal: true
require "test/unit"
require "stringio"
require "rb_apple_sdk_knowledge/importer/progress_reporter"

class TestProgressReporter < Test::Unit::TestCase
  def tty_io
    io = StringIO.new
    def io.tty?; true; end
    io
  end

  def non_tty_io
    io = StringIO.new
    def io.tty?; false; end
    io
  end

  def test_tty_outputs_ansi_escape_sequence
    io = tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 2)
    reporter.framework_started("Foundation", idx: 0, total: 2)
    reporter.framework_finished("Foundation", processed: 10, skipped: 1, elapsed_ms: 1234)
    reporter.finish(processed_total: 10, skipped_total: 1, elapsed_ms: 1234)
    assert_match(/\e\[/, io.string)
  end

  def test_non_tty_one_line_per_framework_event
    io = non_tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 3)
    reporter.framework_started("Foundation", idx: 0, total: 3)
    reporter.framework_finished("Foundation", processed: 5, skipped: 0, elapsed_ms: 800)
    lines = io.string.lines
    assert_equal 2, lines.size
    assert_match(/=== Foundation \(1\/3\) ===/, lines[0])
    assert_match(/processed=5/, lines[1])
    assert_match(/skipped=0/, lines[1])
    assert_match(/0\.8s/, lines[1])
  end

  def test_non_tty_compresses_clang_error_to_single_line
    io = non_tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 1)
    long_error = "clang failed for /path/x.h: /path/x.h:11:15: error: type specifier missing\n   11 | API_AVAILABLE\n      |               ^\n      |               int\n"
    reporter.header_done(framework: "F", header: "/path/x.h", status: :error, elapsed_ms: 12, error: long_error)
    lines = io.string.lines
    assert_equal 1, lines.size
    assert_match(%r{\[importer\] skipping /path/x\.h:}, lines[0])
    refute_match(/\n.*\|/, lines[0])
  end

  def test_non_tty_silent_on_header_ok
    io = non_tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 1)
    reporter.header_done(framework: "F", header: "/path/y.h", status: :ok, elapsed_ms: 5)
    assert_equal "", io.string
  end
end
