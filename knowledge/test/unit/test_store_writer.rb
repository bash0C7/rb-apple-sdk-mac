# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "sqlite3"
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

  def test_insert_symbol_non_constraint_raise_rolls_back_partial_transaction
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      # Wrap store with a spy that raises a non-SQLite3::ConstraintException
      # error on the second insert_symbol call, simulating e.g. an I/O error.
      call_count = 0
      store.define_singleton_method(:insert_symbol) do |**kwargs|
        call_count += 1
        raise RuntimeError, "simulated I/O error" if call_count == 2
        super(**kwargs)
      end
      writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: 100)
      writer.begin!
      fw_id = writer.insert_framework(name: "F", swift_module: "F")
      writer.insert_symbol(framework_id: fw_id, name: "Good", kind: "function", abi: "c", content_hash: "h1")
      # Non-ConstraintException → StoreWriter must rollback the transaction
      assert_raises(RuntimeError) do
        writer.insert_symbol(framework_id: fw_id, name: "Bad", kind: "function", abi: "c", content_hash: "h2")
      end
      # rollback should have fired; flush must be a no-op (in_tx=false)
      writer.flush
      rows = store.db.execute("SELECT name FROM symbols").flatten
      assert_equal [], rows, "rollback されてれば Good 行も persist してへんはず"
      store.close
    end
  end

  def test_concurrent_inserts_from_multiple_threads_serialized
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: 100)
      writer.begin!
      fw_id = writer.insert_framework(name: "F", swift_module: "F")

      threads = 4.times.map do |t|
        Thread.new do
          25.times do |i|
            writer.insert_symbol(framework_id: fw_id,
                                 name: "T#{t}_S#{i.to_s.rjust(3, '0')}",
                                 kind: "function", abi: "c",
                                 content_hash: "h_t#{t}_s#{i}")
          end
        end
      end
      threads.each(&:join)
      writer.flush
      count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      assert_equal 100, count
      store.close
    end
  end

  # SQLite3::ConstraintException (e.g. raised by a spy store) must be
  # re-raised by StoreWriter WITHOUT rolling back the surrounding transaction.
  # This allows Pipeline#insert_one to rescue that specific exception and skip
  # a duplicate symbol while leaving all other rows in the current batch intact.
  #
  # Note: Store#insert_symbol uses ON CONFLICT UPSERT so content_hash duplicates
  # never raise in practice. The test uses a spy store to simulate any
  # caller that surfaces a SQLite3::ConstraintException.
  def test_constraint_exception_does_not_rollback_transaction
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      # Spy store that raises SQLite3::ConstraintException on the 2nd insert
      call_count = 0
      store.define_singleton_method(:insert_symbol) do |**kwargs|
        call_count += 1
        raise SQLite3::ConstraintException, "simulated UNIQUE violation" if call_count == 2
        super(**kwargs)
      end
      writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: 100)
      writer.begin!
      fw_id = writer.insert_framework(name: "F", swift_module: "F")
      writer.insert_symbol(framework_id: fw_id, name: "Before", kind: "function", abi: "c", content_hash: "h1")
      # Second call → spy raises ConstraintException; StoreWriter must re-raise
      # without rolling back (transaction stays open)
      assert_raises(SQLite3::ConstraintException) do
        writer.insert_symbol(framework_id: fw_id, name: "Skip", kind: "function", abi: "c", content_hash: "dup")
      end
      # Transaction must still be open; this insert should succeed
      writer.insert_symbol(framework_id: fw_id, name: "After", kind: "function", abi: "c", content_hash: "h3")
      writer.flush
      rows = store.db.execute("SELECT name FROM symbols ORDER BY id").flatten
      assert_equal %w[Before After], rows,
        "ConstraintException must not rollback the transaction; Before and After must persist"
      store.close
    end
  end
end
