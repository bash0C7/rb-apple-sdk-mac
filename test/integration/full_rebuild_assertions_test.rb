# frozen_string_literal: true
require "test_helper"
require "sqlite3"

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

  # IRB autocomplete needs class→member linkage. parent_id must be populated
  # for instance_method rows whose parser-side parent_name was non-nil.
  # Lifted from knowledge/test/test_importer_integration.rb (which ran a full
  # real-SDK Pipeline.run per test method, ~17 min each); the same invariant
  # is asserted against the standing Knowledge Base SQLite.
  def test_instance_methods_have_parent_id_populated
    count = @db.execute(
      "SELECT COUNT(*) FROM symbols WHERE kind = 'instance_method' AND parent_id IS NOT NULL"
    ).first.first
    assert_operator count, :>, 100,
      "expected >100 instance_methods with parent_id, got #{count}"
  end

  # parent_id must resolve back to a real type row (class/struct/protocol/
  # enum_module/actor). Orphans indicate a parser/consolidator regression.
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
