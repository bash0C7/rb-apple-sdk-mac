# frozen_string_literal: true
require "test_helper"
require "open3"

# CoreAudio out-param + struct-in が静的 emitter で round-trip することの
# actual-run gate。env-gated (実 SDK 必要)。
class ExamplesCoreAudioE2ETest < Test::Unit::TestCase
  EXAMPLES_DIR = File.expand_path("../../examples", __dir__)

  def test_audio_device_count_runs_and_prints_count
    omit "set APPLE_SDK_MAC_RUN_E2E=1 to run" unless ENV["APPLE_SDK_MAC_RUN_E2E"] == "1"
    script = File.join(EXAMPLES_DIR, "audio_device_count.rb")
    out, err, status = Open3.capture3(
      { "RUBY_BOX" => "1" }, "bundle", "exec", "ruby", script,
      chdir: File.expand_path("../..", __dir__)
    )
    assert status.success?, "audio_device_count.rb exited non-zero:\n#{err}"
    assert_match(/audio devices: \d+/, out,
                 "expected 'audio devices: N' line, got:\n#{out}")
  end
end
