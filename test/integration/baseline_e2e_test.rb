# frozen_string_literal: true
require "test_helper"
require "open3"

class BaselineE2ETest < Test::Unit::TestCase
  EXAMPLES_DIR = File.expand_path("../../examples", __dir__)
  BASELINE_MD  = File.expand_path("../../tmp/baseline-2026-05-15.md", __dir__)

  BASELINE = {
    "async_taskgroup.rb"         => { discover_lines: 4,  has_bootstrap: false },
    "audio_device_count.rb"      => { discover_lines: 0,  has_bootstrap: true },
    "avspeech_synth.rb"          => { discover_lines: 4,  has_bootstrap: false },
    "cf_string_create.rb"        => { discover_lines: 3,  has_bootstrap: false },
    "coremidi_endpoint_count.rb" => { discover_lines: 0,  has_bootstrap: true },
    "coremidi_receive.rb"        => { discover_lines: 1,  has_bootstrap: false },
    "discover_escape.rb"         => { discover_lines: 2,  has_bootstrap: true },
    "irb_completion_demo.rb"     => { discover_lines: 0,  has_bootstrap: false },
    "piano_keyboard.rb"          => { discover_lines: 19, has_bootstrap: true },
    "urlsession_download.rb"     => { discover_lines: 6,  has_bootstrap: false },
    "vision_ocr.rb"              => { discover_lines: 8,  has_bootstrap: false }
  }.freeze

  def test_baseline_md_exists
    assert File.exist?(BASELINE_MD),
           "tmp/baseline-2026-05-15.md must exist (NS-0 anchor)"
    content = File.read(BASELINE_MD)
    assert_match(/NS-0 baseline/, content, "baseline.md header missing")
    row_count = content.scan(/^\| [a-z_]+\.rb /).size
    assert_equal 11, row_count, "baseline.md example row count drift"
  end

  def test_discover_line_count_matches_baseline
    BASELINE.each do |fname, expected|
      path = File.join(EXAMPLES_DIR, fname)
      assert File.exist?(path), "missing example: #{fname}"
      src = File.read(path)
      count = src.scan(/^\s*Apple\.discover\b/).size
      assert_equal expected[:discover_lines], count,
                   "#{fname}: discover_lines drift"
    end
  end

  def test_bootstrap_call_matches_baseline
    BASELINE.each do |fname, expected|
      path = File.join(EXAMPLES_DIR, fname)
      src = File.read(path)
      has = src.match?(/AppleSDKMac\.bootstrap!/)
      assert_equal expected[:has_bootstrap], has,
                   "#{fname}: bootstrap! presence drift"
    end
  end

  def test_actual_run_smoke_under_ruby_box
    omit "set RUBY_BOX_E2E=1 to run actual example smoke" unless ENV["RUBY_BOX_E2E"] == "1"

    interactive = %w[coremidi_receive.rb piano_keyboard.rb irb_completion_demo.rb]

    BASELINE.each do |fname, _expected|
      next if interactive.include?(fname)
      path = File.join(EXAMPLES_DIR, fname)
      out, status = Open3.capture2e({ "RUBY_BOX" => "1" }, "bundle", "exec", "ruby", path)
      exitcode = status.exitstatus
      assert_equal 0, exitcode, "#{fname} exited non-zero:\n#{out.lines.last(10).join}"
      refute_match(/^DEFERRED\b/, out, "#{fname} emitted DEFERRED line")
    end
  end
end
