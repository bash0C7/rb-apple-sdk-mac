# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/importer"

class TestImporterIntegration < Test::Unit::TestCase
  def test_runs_against_real_sdk_and_stores_foundation_symbols
    omit "Xcode SDK not present" unless system("xcrun --show-sdk-path > /dev/null 2>&1")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] = "1"
      AppleSDKKnowledge::Importer.new(store_path: path).run
      ENV.delete("RB_APPLE_SDK_KNOWLEDGE_FAST")

      store = AppleSDKKnowledge::Store.open(path)
      fw_count = store.db.execute("SELECT COUNT(*) FROM frameworks").flatten.first
      sym_count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      assert fw_count > 50, "expected >50 frameworks, got #{fw_count}"
      assert sym_count > 1000, "expected >1000 symbols, got #{sym_count}"

      foundation = store.db.execute(
        "SELECT name FROM symbols WHERE framework_id = (SELECT id FROM frameworks WHERE name = 'Foundation') LIMIT 5"
      ).flatten
      assert foundation.length > 0, "no Foundation symbols found"
      store.close
    end
  end

  def test_rerun_on_existing_store_does_not_raise
    omit "Xcode SDK not present" unless system("xcrun --show-sdk-path > /dev/null 2>&1")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] = "1"
      AppleSDKKnowledge::Importer.new(store_path: path).run

      store = AppleSDKKnowledge::Store.open(path)
      first_count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      store.close

      assert_nothing_raised do
        AppleSDKKnowledge::Importer.new(store_path: path).run
      end

      store = AppleSDKKnowledge::Store.open(path)
      second_count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      store.close

      assert_equal first_count, second_count,
        "expected re-run to be idempotent: same symbol count both times"

      ENV.delete("RB_APPLE_SDK_KNOWLEDGE_FAST")
    end
  end
end
