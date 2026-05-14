# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/importer/store_writer"

class TestStoreWriter < Test::Unit::TestCase
  N_SYMBOLS = 2500

  def insert_with(batch_size)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: batch_size)
      writer.begin!
      fw_id = writer.insert_framework(name: "F", swift_module: "F")
      N_SYMBOLS.times do |i|
        writer.insert_symbol(
          framework_id: fw_id,
          name: "Sym#{i.to_s.rjust(5, '0')}",
          kind: "function",
          abi: "c",
          content_hash: "h#{i}"
        )
      end
      writer.flush
      rows = store.db.execute("SELECT name FROM symbols ORDER BY id").flatten
      store.close
      rows
    end
  end

  def test_batch_size_1_and_1000_yield_identical_row_order
    rows1 = insert_with(1)
    rows1000 = insert_with(1000)
    assert_equal N_SYMBOLS, rows1.size
    assert_equal rows1, rows1000
  end

  def test_flush_without_begin_is_noop
    Dir.mktmpdir do |dir|
      store = AppleSDKKnowledge::Store.open(File.join(dir, "kb.sqlite"))
      writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: 10)
      assert_nothing_raised { writer.flush }
      store.close
    end
  end
end
