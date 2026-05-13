# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/store"

class TestStoreSchemaPhase1 < Test::Unit::TestCase
  def test_schema_version_is_at_least_9
    assert_operator AppleSDKKnowledge::Store::SCHEMA_VERSION, :>=, 9,
      "Phase 1 で SCHEMA_VERSION 9 に bump 必須"
  end

  def test_symbols_table_has_new_phase1_columns
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
      %w[
        is_throws is_async is_failable is_settable
        return_ownership throws_error_type callback_signature_json
        enum_cases_json unsupported_pattern
      ].each do |col|
        assert_includes cols, col, "symbols table に #{col} column が必要"
      end
      store.close
    end
  end

  def test_insert_symbol_accepts_phase1_keywords_and_round_trips
    Dir.mktmpdir do |dir|
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      fid = store.insert_framework(name: "Test", swift_module: "Test")
      sid = store.insert_symbol(
        framework_id: fid, name: "doStuff", kind: "function", abi: "c",
        content_hash: "h-dostuff",
        is_throws: 1, is_async: 1, is_failable: 0, is_settable: 1,
        return_ownership: "retained",
        throws_error_type: "NSError",
        callback_signature_json: '{"params":[{"type":"URL"}],"return_type":"Void"}',
        enum_cases_json: '["create","createAndPrepend"]',
        unsupported_pattern: nil,
      )
      assert_kind_of Integer, sid

      row = store.db.execute(<<~SQL, [sid]).first
        SELECT is_throws, is_async, is_failable, is_settable,
               return_ownership, throws_error_type, callback_signature_json,
               enum_cases_json, unsupported_pattern
        FROM symbols WHERE id = ?
      SQL
      assert_equal 1, row[0]
      assert_equal 1, row[1]
      assert_equal 0, row[2]
      assert_equal 1, row[3]
      assert_equal "retained", row[4]
      assert_equal "NSError", row[5]
      assert_equal '{"params":[{"type":"URL"}],"return_type":"Void"}', row[6]
      assert_equal '["create","createAndPrepend"]', row[7]
      assert_nil row[8]
      store.close
    end
  end
end
