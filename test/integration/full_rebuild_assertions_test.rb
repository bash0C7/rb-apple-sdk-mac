# frozen_string_literal: true
require "test_helper"
require "sqlite3"
require "sqlite_vec"

# Asserts post-rebuild Knowledge Base invariants. Run AFTER
# `bundle exec rake apple:knowledge:clean` + `bundle exec rake apple:knowledge:rebuild`.
# Reads the project-scoped Knowledge Base at
# .rb-apple-sdk-mac/knowledge/26.2/sdk_knowledge.sqlite.
#
# memory rule: verification の output は test-unit assert に任せる。
class FullRebuildAssertionsTest < Test::Unit::TestCase
  # SDK version is detected by SDKResolver at rebuild time (xcrun --show-sdk-version),
  # so the path is `<project>/.rb-apple-sdk-mac/knowledge/<sdk_version>/sdk_knowledge.sqlite`.
  # Glob the version segment so this test stays valid as the SDK upgrades
  # (26.2 → 26.4.1 → ...).
  KB_PATH = Dir.glob(File.expand_path(
    "../../.rb-apple-sdk-mac/knowledge/*/sdk_knowledge.sqlite",
    __dir__
  )).max_by { |p| File.mtime(p) }

  def setup
    omit "Knowledge Base SQLite missing — run `bundle exec rake apple:knowledge:rebuild` first" if KB_PATH.nil? || !File.exist?(KB_PATH)
    @db = SQLite3::Database.new(KB_PATH)
    # symbols_vec is a vec0 virtual table — querying it requires the
    # sqlite-vec extension loaded on this connection, same as Store#initialize.
    @db.enable_load_extension(true)
    SqliteVec.load(@db)
    @db.enable_load_extension(false)
  end

  def teardown
    @db&.close
  end

  def test_frameworks_count_above_floor
    count = @db.execute("SELECT COUNT(*) FROM frameworks").first.first
    assert_operator count, :>=, 200, "expected >=200 frameworks, got #{count}"
  end

  def test_symbols_count_above_floor
    count = @db.execute("SELECT COUNT(*) FROM symbols").first.first
    assert_operator count, :>=, 50_000, "expected >=50k symbols, got #{count}"
  end

  def test_swift_imported_name_populated_non_trivially
    populated = @db.execute(
      "SELECT COUNT(*) FROM symbols WHERE swift_imported_name IS NOT NULL AND swift_imported_name != ''"
    ).first.first
    # Foundation alone has ~1320 extension blocks × multiple decls each.
    # Real expected populate is several thousand. Floor at 1000 to leave
    # headroom for SDK changes; if real number stays << 1000, regex still
    # under-matches and we should investigate further.
    assert_operator populated, :>=, 1000,
      "expected >=1000 rows with swift_imported_name (Foundation/AppKit overlay), got #{populated}"
  end

  def test_foundation_url_has_swift_imported_name
    rows = @db.execute(<<~SQL).flatten
      SELECT s.swift_imported_name FROM symbols s
      JOIN frameworks f ON s.framework_id = f.id
      WHERE f.name = 'Foundation'
        AND s.swift_imported_name IS NOT NULL
        AND s.swift_imported_name != ''
      LIMIT 5
    SQL
    refute_empty rows, "Foundation has zero swift_imported_name rows — overlay ingester broken"
  end

  def test_appkit_has_swift_imported_name_rows
    count = @db.execute(<<~SQL).first.first
      SELECT COUNT(*) FROM symbols s
      JOIN frameworks f ON s.framework_id = f.id
      WHERE f.name = 'AppKit'
        AND s.swift_imported_name IS NOT NULL
        AND s.swift_imported_name != ''
    SQL
    assert_operator count, :>, 0, "AppKit has zero swift_imported_name rows — overlay ingester broken on AppKit forms"
  end

  def test_schema_has_swift_imported_name_column
    cols = @db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
    assert_includes cols, "swift_imported_name"
  end

  def test_symbols_vec_table_exists_and_has_rows
    count = @db.execute("SELECT COUNT(*) FROM symbols_vec").first.first
    # embedder ON で rebuild した前提。 0 なら embedder path 全 skip された
    # (FAST=1 残存 / Embedder.available? false)。 spec は populated 期待。
    assert_operator count, :>=, 1000, "symbols_vec has #{count} rows (embedder may not have run)"
  end
end
