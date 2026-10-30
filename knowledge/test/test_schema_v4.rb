# frozen_string_literal: true
require "test_helper"
require "tmpdir"

class TestSchema < Test::Unit::TestCase
  def test_swift_imported_name_column_present
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
      assert_includes cols, "swift_imported_name", "expected swift_imported_name column; got #{cols}"
      store.close
    end
  end

  def test_dead_reservation_columns_absent
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      cols = store.db.execute("PRAGMA table_info(symbols)").map { |r| r[1] }
      %w[cf_create_rule objc_kind swift_kind].each do |c|
        refute_includes cols, c,
          "column #{c} must not exist — never populated by any code path"
      end
      store.close
    end
  end
end
