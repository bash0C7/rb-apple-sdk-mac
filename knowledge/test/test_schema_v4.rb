# frozen_string_literal: true
require "test_helper"
require "tmpdir"

class TestSchemaV4 < Test::Unit::TestCase
  def test_schema_version_constant
    assert_equal 4, AppleSDKKnowledge::Store::SCHEMA_VERSION
  end

  def test_migrate_adds_swift_imported_name_column
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
      assert_includes cols, "swift_imported_name", "expected column swift_imported_name in symbols table; got #{cols}"
      meta = store.db.execute("SELECT value FROM schema_meta WHERE key='schema_version'").first
      assert_equal "4", meta[0]
      store.close
    end
  end
end
