# frozen_string_literal: true
require "test/unit"
require "json"
require "tmpdir"
require "fileutils"
require "apple_sdk_mac"
require "apple_sdk_mac/telemetry"

class TestTelemetry < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("apple_sdk_mac_telemetry")
    @saved_env = ENV.to_h.slice("APPLE_SDK_MAC_NO_DIAGNOSTICS", "APPLE_SDK_MAC_DIAGNOSTICS_DIR")
    ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] = @tmpdir
    ENV.delete("APPLE_SDK_MAC_NO_DIAGNOSTICS")
  end

  def teardown
    ENV.delete("APPLE_SDK_MAC_DIAGNOSTICS_DIR")
    @saved_env.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def jsonl_path
    File.join(@tmpdir, "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl")
  end

  def test_append_event_writes_one_jsonl_line_when_env_unset
    AppleSDKMac::Telemetry.append_event(
      stage: "unsupported_pattern",
      framework: "Foundation",
      symbol: "Observable.value",
      detail: "swift_macro"
    )
    assert File.exist?(jsonl_path), "jsonl file should be created at #{jsonl_path}"
    lines = File.readlines(jsonl_path)
    assert_equal 1, lines.size
    row = JSON.parse(lines.first)
    assert_equal "unsupported_pattern", row["stage"]
    assert_equal "Foundation",          row["framework"]
    assert_equal "Observable.value",    row["symbol"]
    assert_equal "swift_macro",         row["detail"]
    assert row.key?("at"),          "row must include UTC timestamp under :at"
    assert row.key?("gem_version"), "row must include gem_version for triage"
    assert row.key?("kb_schema"),   "row must include kb_schema for triage"
  end

  def test_append_event_appends_to_existing_jsonl
    AppleSDKMac::Telemetry.append_event(stage: "a", framework: "F", symbol: "S", detail: "d1")
    AppleSDKMac::Telemetry.append_event(stage: "b", framework: "F", symbol: "S", detail: "d2")
    lines = File.readlines(jsonl_path)
    assert_equal 2, lines.size
    assert_equal "d1", JSON.parse(lines[0])["detail"]
    assert_equal "d2", JSON.parse(lines[1])["detail"]
  end

  def test_append_event_skips_when_env_set
    ENV["APPLE_SDK_MAC_NO_DIAGNOSTICS"] = "1"
    AppleSDKMac::Telemetry.append_event(
      stage: "compile_failed",
      framework: "Foundation",
      symbol: "anything",
      detail: "swiftc error"
    )
    refute File.exist?(jsonl_path),
      "jsonl file must NOT be created when APPLE_SDK_MAC_NO_DIAGNOSTICS=1"
  end

  def test_append_event_swallows_io_errors_silently
    ro_parent = File.join(@tmpdir, "ro")
    Dir.mkdir(ro_parent)
    File.chmod(0o500, ro_parent)
    ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] = File.join(ro_parent, "diagnostics")
    begin
      assert_nothing_raised do
        AppleSDKMac::Telemetry.append_event(
          stage: "x", framework: "F", symbol: "S", detail: "d"
        )
      end
    ensure
      File.chmod(0o700, ro_parent)
    end
  end
end
