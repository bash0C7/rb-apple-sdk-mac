# frozen_string_literal: true
require "test_helper"
require "sqlite3"

class FullRebuildAssertionsTest < Test::Unit::TestCase
  KB_PATH = Dir.glob(File.expand_path(
    "../../.rb-apple-sdk-mac/knowledge/*/sdk_knowledge.sqlite",
    __dir__
  )).max_by { |p| File.mtime(p) }

  def setup
    omit "Knowledge Base SQLite missing — run `bundle exec rake apple:knowledge:rebuild` first" if KB_PATH.nil? || !File.exist?(KB_PATH)
    @db = SQLite3::Database.new(KB_PATH)
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

  def test_instance_methods_have_parent_id_populated
    count = @db.execute(
      "SELECT COUNT(*) FROM symbols WHERE kind = 'instance_method' AND parent_id IS NOT NULL"
    ).first.first
    assert_operator count, :>, 100,
      "expected >100 instance_methods with parent_id, got #{count}"
  end

  def test_instance_method_parent_id_resolves_to_a_type_row
    orphans = @db.execute(<<~SQL).first.first
      SELECT COUNT(*) FROM symbols c
      WHERE c.kind = 'instance_method'
        AND c.parent_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM symbols p
          WHERE p.id = c.parent_id
            AND p.kind IN ('class', 'struct', 'protocol', 'enum_module', 'actor')
        )
    SQL
    assert_equal 0, orphans, "instance_method.parent_id must reference a real type row"
  end
end
