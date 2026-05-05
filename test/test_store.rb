# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "rb_apple_sdk_knowledge/store"

class TestStore < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @db_path = File.join(@tmpdir, "knowledge.sqlite")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_open_creates_required_tables
    store = AppleSDKKnowledge::Store.open(@db_path)
    tables = store.db.execute(<<~SQL).flatten
      SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
    SQL
    assert_includes tables, "frameworks"
    assert_includes tables, "symbols"
    store.close
  end

  def test_open_creates_fts_and_vec_virtual_tables
    store = AppleSDKKnowledge::Store.open(@db_path)
    tables = store.db.execute(<<~SQL).flatten
      SELECT name FROM sqlite_master ORDER BY name
    SQL
    assert_includes tables, "symbols_fts"
    assert_includes tables, "symbols_vec"
    store.close
  end

  def test_insert_framework_and_select
    store = AppleSDKKnowledge::Store.open(@db_path)
    fw_id = store.insert_framework(
      name: "CoreMIDI",
      swift_module: "CoreMIDI",
      category: "media",
      doc_url: "https://developer.apple.com/documentation/coremidi",
      min_macos: "10.0"
    )
    assert_kind_of Integer, fw_id
    rows = store.db.execute("SELECT name FROM frameworks WHERE id = ?", [fw_id])
    assert_equal "CoreMIDI", rows.first.first
    store.close
  end

  def test_schema_version_bumped_to_2
    store = AppleSDKKnowledge::Store.open(@db_path)
    v = store.db.execute("SELECT value FROM schema_meta WHERE key = 'schema_version'").first.first
    assert_equal "2", v
    store.close
  end

  def test_migrate_adds_fields_json_column_idempotently
    # First open: schema is created with fields_json present.
    store = AppleSDKKnowledge::Store.open(@db_path)
    cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
    assert_includes cols, "fields_json"
    store.close

    # Second open is a no-op migration; should not raise even when column exists.
    store2 = AppleSDKKnowledge::Store.open(@db_path)
    cols2 = store2.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
    assert_includes cols2, "fields_json"
    store2.close
  end

  def test_insert_symbol_persists_fields_json
    store = AppleSDKKnowledge::Store.open(@db_path)
    fw_id = store.insert_framework(name: "Acme", swift_module: "Acme")
    fields = JSON.dump([{ name: "x", type: "int", kind: "int" }])
    store.insert_symbol(framework_id: fw_id, name: "Foo", kind: "struct", abi: "c",
                        content_hash: "h1", fields_json: fields)
    row = store.db.execute("SELECT fields_json FROM symbols WHERE name = ?", ["Foo"]).first
    assert_equal fields, row.first
    store.close
  end
end
