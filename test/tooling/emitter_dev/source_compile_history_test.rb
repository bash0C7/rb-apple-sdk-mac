# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "sqlite3"
require "emitter_dev/source_compile_history"

class SourceCompileHistoryTest < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir
    @db_path = File.join(@tmp, "cache.sqlite")
    db = SQLite3::Database.new(@db_path)
    db.execute_batch <<~SQL
      CREATE TABLE compile_history (
        framework    TEXT, symbol       TEXT,
        generator    TEXT, retry_count  INTEGER,
        error_stage  TEXT, error_detail TEXT
      );
      INSERT INTO compile_history VALUES ('AVFoundation', 'devicesWithMediaType:', 'llm', 2, 'template_nil', NULL);
      INSERT INTO compile_history VALUES ('AVFoundation', 'devicesWithMediaType:', 'llm', 3, 'template_nil', NULL);
      INSERT INTO compile_history VALUES ('CoreAudio',    'AudioObjectGetPropertyDataSize', 'template', 0, NULL, NULL);
    SQL
    db.close
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_aggregate_returns_only_llm_seen_symbols
    rows = EmitterDev::Sources::CompileHistory.new(@db_path).aggregate
    assert_equal 1, rows.size
    r = rows.first
    assert_equal "AVFoundation", r["framework"]
    assert_equal "devicesWithMediaType:", r["symbol"]
    assert_equal 2, r["llm_count"]
    assert_in_delta 2.5, r["avg_retry"], 0.001
    assert_includes r["error_stages"], "template_nil"
  end
end
