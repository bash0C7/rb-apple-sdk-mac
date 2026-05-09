# frozen_string_literal: true
require "test_helper"
require "open3"

# v1.2 spec § 5 examples 完了条件: avspeech_synth / vision_ocr /
# discover_escape が actual SDK call で end-to-end 成功する。
# memory rule: 1 example = 1 test method, stdout を assert_match で検証。
class ExamplesV12E2ETest < Test::Unit::TestCase
  PROJECT_ROOT = File.expand_path("../..", __dir__)

  def run_example(rel_path)
    full = File.join(PROJECT_ROOT, rel_path)
    Bundler.with_unbundled_env do
      Open3.capture3(
        { "RUBY_BOX" => "1" },
        "bundle", "exec", "ruby", full,
        chdir: PROJECT_ROOT
      )
    end
  end

  def test_avspeech_synth_example_succeeds
    out, err, status = run_example("examples/avspeech_synth.rb")
    assert status.success?, "avspeech_synth.rb failed: stderr=#{err.lines.last(20).join}"
    assert_match(/(spoke|finished|done|rate)/i, out + err,
                 "avspeech_synth.rb output had no completion signal")
  end

  def test_vision_ocr_example_succeeds
    out, err, status = run_example("examples/vision_ocr.rb")
    assert status.success?, "vision_ocr.rb failed: stderr=#{err.lines.last(20).join}"
    assert_match(/(text|recognized|observation)/i, out + err,
                 "vision_ocr.rb output had no recognized-text signal")
  end

  def test_discover_escape_example_returns_box
    out, err, status = run_example("examples/discover_escape.rb")
    assert status.success?, "discover_escape.rb failed: stderr=#{err.lines.last(20).join}"
    assert_match(/discover_escape: CFStringCreateWithCString returned box=\d+/, out,
                 "discover_escape.rb did not print expected box pointer")
  end
end
