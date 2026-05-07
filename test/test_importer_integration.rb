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
      AppleSDKKnowledge::Importer::Pipeline.new(store_path: path).run
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

  def test_parent_id_populated_for_class_members
    omit "Xcode SDK not present" unless system("xcrun --show-sdk-path > /dev/null 2>&1")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] = "1"
      AppleSDKKnowledge::Importer::Pipeline.new(store_path: path).run
      ENV.delete("RB_APPLE_SDK_KNOWLEDGE_FAST")

      store = AppleSDKKnowledge::Store.open(path)

      # IRB autocomplete needs class→member linkage. parent_id must be
      # populated for instance_method / instance_property / enum_case
      # rows whose parser-side parent_name was non-nil.
      methods_with_parent = store.db.execute(
        "SELECT COUNT(*) FROM symbols WHERE kind = 'instance_method' AND parent_id IS NOT NULL"
      ).flatten.first
      assert methods_with_parent > 100,
        "expected >100 instance_methods with parent_id, got #{methods_with_parent}"

      # And the parent must resolve back to a class/struct/protocol/enum_module/actor row.
      orphans = store.db.execute(<<~SQL).flatten.first
        SELECT COUNT(*) FROM symbols c
        WHERE c.kind = 'instance_method'
          AND c.parent_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM symbols p
            WHERE p.id = c.parent_id
              AND p.kind IN ('class', 'struct', 'protocol', 'enum_module', 'actor')
          )
      SQL
      assert_equal 0, orphans, "instance_method.parent_id must reference a real type row"

      store.close
    end
  end

  def test_rerun_on_existing_store_does_not_raise
    omit "Xcode SDK not present" unless system("xcrun --show-sdk-path > /dev/null 2>&1")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] = "1"
      AppleSDKKnowledge::Importer::Pipeline.new(store_path: path).run

      store = AppleSDKKnowledge::Store.open(path)
      first_count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      store.close

      assert_nothing_raised do
        AppleSDKKnowledge::Importer::Pipeline.new(store_path: path).run
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
