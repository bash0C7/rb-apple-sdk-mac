# frozen_string_literal: true
require "test_helper"
require "tmpdir"

class TestSchemaV4 < Test::Unit::TestCase
  def test_schema_version_constant
    assert_equal 4, AppleSDKKnowledge::Store::SCHEMA_VERSION
  end

  def test_migrate_adds_v3_and_v4_columns
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
      %w[cf_create_rule objc_kind swift_kind swift_imported_name].each do |c|
        assert_includes cols, c, "expected column #{c} in symbols table; got #{cols}"
      end
      meta = store.db.execute("SELECT value FROM schema_meta WHERE key='schema_version'").first
      assert_equal "4", meta[0]
      store.close
    end
  end
end
