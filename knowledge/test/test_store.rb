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

  def test_open_creates_fts_virtual_table
    store = AppleSDKKnowledge::Store.open(@db_path)
    tables = store.db.execute(<<~SQL).flatten
      SELECT name FROM sqlite_master ORDER BY name
    SQL
    assert_includes tables, "symbols_fts"
    store.close
  end

  # Embedder is gone; the symbols_vec virtual table and Store#vec_insert
  # were placeholder scaffolding for a Foundation Models embedder that
  # only ever wrote zero-vectors. They're removed so the schema reflects
  # the current state.
  def test_symbols_vec_table_absent_after_migrate
    store = AppleSDKKnowledge::Store.open(@db_path)
    tables = store.db.execute(
      "SELECT name FROM sqlite_master ORDER BY name"
    ).flatten
    refute_includes tables, "symbols_vec"
    store.close
  end

  def test_vec_insert_method_undefined
    refute AppleSDKKnowledge::Store.instance_methods.include?(:vec_insert),
      "Store#vec_insert must be removed alongside the symbols_vec table"
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

  def test_schema_version_persisted_matches_constant
    store = AppleSDKKnowledge::Store.open(@db_path)
    v = store.db.execute("SELECT value FROM schema_meta WHERE key = 'schema_version'").first.first
    assert_equal AppleSDKKnowledge::Store::SCHEMA_VERSION.to_s, v
    store.close
  end

  # The schema is created entirely by SCHEMA_SQL's CREATE TABLE statement;
  # there is no ALTER TABLE / ensure_column! migration step. Verifying via
  # the absence of Store#ensure_column! ensures no hidden migration path
  # creeps back in.
  def test_schema_columns_created_inline_no_ensure_column_helper
    refute AppleSDKKnowledge::Store.instance_methods(false).include?(:ensure_column!),
      "Store#ensure_column! must be removed — schema is created inline by SCHEMA_SQL"
  end

  def test_fields_json_column_present_on_fresh_db
    store = AppleSDKKnowledge::Store.open(@db_path)
    cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
    assert_includes cols, "fields_json"
    store.close
  end

  def test_swift_imported_name_column_present_on_fresh_db
    store = AppleSDKKnowledge::Store.open(@db_path)
    cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
    assert_includes cols, "swift_imported_name"
    store.close
  end

  def test_reopen_does_not_raise
    AppleSDKKnowledge::Store.open(@db_path).close
    # Second open is a no-op migration; should not raise even when columns exist.
    AppleSDKKnowledge::Store.open(@db_path).close
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

  # An existing row written under an older importer (fields_json = NULL) must
  # be UPDATED when the same content_hash is re-inserted with a populated
  # fields_json. Without this, `apple:knowledge:rebuild` is a no-op for any
  # symbol that already exists — the case actually observed in the wild
  # where 4931 struct rows have fields_json IS NULL after a full rebuild.
  def test_insert_symbol_upserts_on_content_hash_conflict
    store = AppleSDKKnowledge::Store.open(@db_path)
    fw_id = store.insert_framework(name: "Acme", swift_module: "Acme")
    # First insert — pre-fix style, no fields.
    store.insert_symbol(framework_id: fw_id, name: "Foo", kind: "struct", abi: "c",
                        content_hash: "h_upsert", fields_json: nil,
                        signature: "struct Foo")
    # Second insert with same content_hash but updated fields. Expect the
    # row to be updated, not a ConstraintException.
    new_fields = JSON.dump([{ name: "x", type: "int", kind: "int" }])
    store.insert_symbol(framework_id: fw_id, name: "Foo", kind: "struct", abi: "c",
                        content_hash: "h_upsert", fields_json: new_fields,
                        signature: "struct Foo")
    rows = store.db.execute("SELECT fields_json FROM symbols WHERE content_hash = ?", ["h_upsert"])
    assert_equal 1, rows.length
    assert_equal new_fields, rows.first.first
    store.close
  end

  # insert_symbol must accept and atomically persist swift_imported_name as
  # part of the INSERT ... ON CONFLICT DO UPDATE statement. Previously the
  # Swift overlay importer wrote this column via a separate UPDATE following
  # the insert — observable partial state, and the UPDATE was skipped on the
  # ON CONFLICT path, leaving stale swift_imported_name on re-import.
  def test_insert_symbol_persists_swift_imported_name
    store = AppleSDKKnowledge::Store.open(@db_path)
    fw_id = store.insert_framework(name: "AVFoundation", swift_module: "AVFoundation")
    store.insert_symbol(
      framework_id: fw_id, name: "devicesWithMediaType:", kind: "class_method",
      abi: "swift", content_hash: "h_swift_name",
      signature: "class func devices(for: AVMediaType)",
      swift_imported_name: "devices(for:)"
    )
    row = store.db.execute(
      "SELECT swift_imported_name FROM symbols WHERE content_hash = ?",
      ["h_swift_name"]
    ).first
    assert_equal "devices(for:)", row.first
    store.close
  end

  # Re-inserting under the same content_hash with a NEW swift_imported_name
  # must atomically update the column. The pre-fix two-statement pattern
  # left a window where the row had stale swift_imported_name and required
  # a separate UPDATE that the importer could (and did) skip on conflict.
  def test_insert_symbol_updates_swift_imported_name_on_conflict
    store = AppleSDKKnowledge::Store.open(@db_path)
    fw_id = store.insert_framework(name: "AVFoundation", swift_module: "AVFoundation")
    store.insert_symbol(
      framework_id: fw_id, name: "devicesWithMediaType:", kind: "class_method",
      abi: "swift", content_hash: "h_swift_conflict",
      signature: "class func devices(for: AVMediaType)",
      swift_imported_name: "devices(for:)"
    )
    # Second insert under the same content_hash with a DIFFERENT
    # swift_imported_name. The row must reflect the new value.
    store.insert_symbol(
      framework_id: fw_id, name: "devicesWithMediaType:", kind: "class_method",
      abi: "swift", content_hash: "h_swift_conflict",
      signature: "class func devices(for: AVMediaType)",
      swift_imported_name: "devices(forMediaType:)"
    )
    rows = store.db.execute(
      "SELECT swift_imported_name FROM symbols WHERE content_hash = ?",
      ["h_swift_conflict"]
    )
    assert_equal 1, rows.length
    assert_equal "devices(forMediaType:)", rows.first.first
    store.close
  end

end
