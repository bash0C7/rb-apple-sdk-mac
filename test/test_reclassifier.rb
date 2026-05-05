# frozen_string_literal: true
require "test_helper"
require "json"
require "rb_apple_sdk_knowledge/reclassifier"

class TestReclassifierRecompute < Test::Unit::TestCase
  R = AppleSDKKnowledge::Reclassifier

  def test_recompute_fills_kind_and_is_out_param_from_type_only
    raw = JSON.generate([
      { name: "name",      type: "const char *" },
      { name: "outClient", type: "MIDIClientRef *" }
    ])
    out = R.recompute_parameters(raw)
    parsed = JSON.parse(out, symbolize_names: true)

    assert_equal "string",     parsed[0][:kind]
    assert_equal false,        parsed[0][:is_out_param]
    assert_equal "unspecified", parsed[0][:nullability]

    assert_equal "opaque_ref", parsed[1][:kind]
    assert_equal true,         parsed[1][:is_out_param]
  end

  def test_recompute_marks_void_pointer_unsupported
    raw = JSON.generate([{ name: "userData", type: "void *" }])
    parsed = JSON.parse(R.recompute_parameters(raw), symbolize_names: true)
    assert_equal "unsupported", parsed[0][:kind]
  end

  def test_recompute_is_idempotent
    raw = JSON.generate([{ name: "x", type: "int" }])
    once  = R.recompute_parameters(raw)
    twice = R.recompute_parameters(once)
    assert_equal once, twice
  end

  def test_recompute_handles_nil_or_empty_input
    assert_nil R.recompute_parameters(nil)
    assert_nil R.recompute_parameters("")
  end
end

require "tmpdir"
require "fileutils"
require "stringio"
require "rb_apple_sdk_knowledge/store"

class TestReclassifierRun < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir("reclassify-test")
    @db_path = File.join(@dir, "k.sqlite")
    store = AppleSDKKnowledge::Store.open(@db_path)
    fid = store.insert_framework(name: "MiniMIDI", swift_module: "MiniMIDI")
    store.insert_symbol(
      framework_id: fid, name: "MiniCreate", kind: "function", abi: "c",
      content_hash: "h1",
      parameters_json: JSON.generate([
        { name: "name",      type: "const char *" },
        { name: "outClient", type: "MiniClientRef *" }
      ])
    )
    store.insert_symbol(
      framework_id: fid, name: "MiniNoParams", kind: "function", abi: "c",
      content_hash: "h2",
      parameters_json: nil
    )
    store.close
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_run_updates_every_parameters_json_row_in_place
    log = StringIO.new
    queue = File.join(@dir, "unsupported.jsonl")
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: log, queue_path: queue
    ).run

    db = SQLite3::Database.new(@db_path)
    row = db.execute(
      "SELECT parameters_json FROM symbols WHERE name = ?", ["MiniCreate"]
    ).first
    db.close

    parsed = JSON.parse(row[0], symbolize_names: true)
    assert_equal "string",     parsed[0][:kind]
    assert_equal "opaque_ref", parsed[1][:kind]
    assert_equal true,         parsed[1][:is_out_param]
  end

  def test_run_creates_rotating_backup
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path,
      log_io: StringIO.new,
      queue_path: File.join(@dir, "u.jsonl")
    ).run
    assert File.exist?("#{@db_path}.bak"), "expected rotating backup at <db>.bak"
  end

  def test_run_skips_rows_with_null_parameters_json_without_error
    queue = File.join(@dir, "u.jsonl")
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: StringIO.new, queue_path: queue
    ).run

    db = SQLite3::Database.new(@db_path)
    row = db.execute(
      "SELECT parameters_json FROM symbols WHERE name = ?", ["MiniNoParams"]
    ).first
    db.close
    assert_nil row[0]
  end

  def test_run_is_idempotent
    log1 = StringIO.new
    log2 = StringIO.new
    queue1 = File.join(@dir, "u1.jsonl")
    queue2 = File.join(@dir, "u2.jsonl")

    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: log1, queue_path: queue1
    ).run

    db = SQLite3::Database.new(@db_path)
    snapshot1 = db.execute(
      "SELECT name, parameters_json FROM symbols ORDER BY name"
    )
    db.close

    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: log2, queue_path: queue2
    ).run

    db = SQLite3::Database.new(@db_path)
    snapshot2 = db.execute(
      "SELECT name, parameters_json FROM symbols ORDER BY name"
    )
    db.close

    assert_equal snapshot1, snapshot2
  end
end
