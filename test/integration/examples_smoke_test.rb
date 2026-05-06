# frozen_string_literal: true
require "test_helper"
require "open3"

# Integration smoke for examples/. Each example is run as a subprocess so
# the gem load + dispatcher init paths exercised under RUBY_BOX=1 are the
# same code path a user invokes from the command line.
class TestExamplesSmoke < Test::Unit::TestCase
  GEM_ROOT = File.expand_path("../..", __dir__)

  def run_example(name, timeout: 30)
    path = File.join(GEM_ROOT, "examples", name)
    skip "example missing: #{name}" unless File.exist?(path)
    out, err, status = Open3.capture3({ "RUBY_BOX" => "1" },
      "bundle", "exec", "ruby", path,
      chdir: GEM_ROOT)
    { stdout: out, stderr: err, exitstatus: status.exitstatus }
  end

  def test_vision_ocr_lists_namespace_constants
    res = run_example("vision_ocr.rb")
    assert_equal 0, res[:exitstatus],
      "vision_ocr.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    # bootstrap! populates Apple::Vision; the example prints first 10 constants
    # as an Array literal. We don't pin the contents — Apple ships new types —
    # only the shape (an Array printed via #inspect).
    assert_match(/^\[:[A-Z]/, res[:stdout].lines.last.to_s,
      "expected Array of symbols on last line, got:\n#{res[:stdout]}")
  end

  # Phase 7 T11 — CFStringCreateWithCString round-trip via auto-ARC box.
  # Acceptance: example exits 0, prints "auto-ARC OK" line. Source code
  # contains zero CFRelease references (spec §3.5 requires no manual
  # release in user code).
  def test_cf_string_create_runs_under_autoarc
    res = run_example("cf_string_create.rb")
    assert_equal 0, res[:exitstatus],
      "cf_string_create.rb exited #{res[:exitstatus]}; stderr:\n#{res[:stderr]}"
    assert_match(/auto-ARC OK/, res[:stdout],
      "expected 'auto-ARC OK' message; got:\n#{res[:stdout]}")
    src = File.read(File.join(GEM_ROOT, "examples", "cf_string_create.rb"))
    refute_match(/CFRelease/i, src.gsub(/^#.*$/, ""),
      "spec §3.5 forbids manual CFRelease in user code (comments excluded)")
  end
end
