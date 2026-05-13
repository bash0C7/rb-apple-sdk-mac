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
end
