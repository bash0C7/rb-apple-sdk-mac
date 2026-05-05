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

  def test_recompute_marks_unspecified_void_pointer_as_void_ptr_nilable
    # Policy: unspecified nullability is treated as nilable (safe default).
    raw = JSON.generate([{ name: "userData", type: "void *" }])
    parsed = JSON.parse(R.recompute_parameters(raw), symbolize_names: true)
    assert_equal "void_ptr_nilable", parsed[0][:kind]
  end

  def test_recompute_preserves_nullability_when_already_present
    raw = JSON.generate([{ name: "cb", type: "MyCb _Nonnull", nullability: "nonnull" }])
    parsed = JSON.parse(R.recompute_parameters(raw), symbolize_names: true)
    # qual_type contains no parens but type is a typedef; kind dispatch falls to
    # opaque_ref guard (no Ref) → unsupported. The point of this test is that
    # nullability='nonnull' is preserved through recompute, not overridden.
    assert_equal "nonnull", parsed[0][:nullability]
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

class TestReclassifierUnsupportedLog < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir("reclassify-unsupported-test")
    @db_path = File.join(@dir, "k.sqlite")
    store = AppleSDKKnowledge::Store.open(@db_path)
    fid = store.insert_framework(name: "MiniMIDI", swift_module: "MiniMIDI")
    store.insert_symbol(
      framework_id: fid, name: "F_unsup_a", kind: "function", abi: "c",
      content_hash: "h1",
      parameters_json: JSON.generate([{ name: "u", type: "struct Bar *" }])
    )
    store.insert_symbol(
      framework_id: fid, name: "F_unsup_b", kind: "function", abi: "c",
      content_hash: "h2",
      parameters_json: JSON.generate([{ name: "u", type: "struct Bar *" }])
    )
    store.insert_symbol(
      framework_id: fid, name: "F_ok", kind: "function", abi: "c",
      content_hash: "h3",
      parameters_json: JSON.generate([{ name: "x", type: "int" }])
    )
    store.close

    @queue = File.join(@dir, "u.jsonl")
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: StringIO.new, queue_path: @queue
    ).run
    @lines = File.readlines(@queue, chomp: true)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_jsonl_has_one_entry_per_unsupported_param_and_one_summary
    item_lines = @lines.reject { |l| l.include?('"_summary"') }
    summary_lines = @lines.select { |l| l.include?('"_summary"') }
    assert_equal 2, item_lines.length, "expected one jsonl entry per unsupported param"
    assert_equal 1, summary_lines.length, "expected exactly one _summary line"
  end

  def test_summary_contains_required_keys
    summary = JSON.parse(@lines.last)["_summary"]
    %w[ran_at total_symbols total_params by_kind unsupported_clusters classify_kind_source kind_vocabulary next_action_hint].each do |key|
      assert summary.key?(key), "summary missing key: #{key}"
    end
  end

  def test_summary_clusters_count_matches
    summary = JSON.parse(@lines.last)["_summary"]
    cluster = summary["unsupported_clusters"].find { |c| c["qual_type"] == "struct Bar *" }
    assert_not_nil cluster
    assert_equal 2, cluster["count"]
  end

  def test_summary_classify_kind_source_points_to_kind_module
    summary = JSON.parse(@lines.last)["_summary"]
    assert_match(%r{lib/rb_apple_sdk_knowledge/importer/kind\.rb:\d+},
                 summary["classify_kind_source"])
  end

  def test_summary_kind_vocabulary_lists_known_kinds
    summary = JSON.parse(@lines.last)["_summary"]
    %w[string int bool float opaque_ref callback_nilable callback_non_nil
       void_ptr_nilable struct_in struct_out variadic_args unsupported].each do |k|
      assert_includes summary["kind_vocabulary"], k
    end
  end

  def test_summary_by_kind_sums_to_total_params
    summary = JSON.parse(@lines.last)["_summary"]
    sum = summary["by_kind"].values.sum
    assert_equal summary["total_params"], sum
  end
end
