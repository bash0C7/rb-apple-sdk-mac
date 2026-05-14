# frozen_string_literal: true
module AppleSDKKnowledge
  module Importer
    class StoreWriter
      def initialize(store:, batch_size: 1000)
        @store = store
        @batch_size = batch_size
        @counter = 0
        @in_tx = false
        @mutex = Mutex.new
      end

      def begin!
        @mutex.synchronize do
          return if @in_tx
          @store.db.execute("BEGIN")
          @in_tx = true
          @counter = 0
        end
      end

      def insert_symbol(**kwargs)
        ret = nil
        @mutex.synchronize do
          ret = @store.insert_symbol(**kwargs)
          bump!
        end
        ret
      rescue SQLite3::ConstraintException
        # Caller (Pipeline#insert_one) handles duplicate-skip semantics.
        # A UNIQUE violation on a single INSERT does not invalidate the
        # surrounding transaction in SQLite, so we must NOT rollback here.
        raise
      rescue
        @mutex.synchronize do
          next unless @in_tx
          @store.db.execute("ROLLBACK")
          @in_tx = false
          @counter = 0
        end
        raise
      end

      def insert_framework(**kwargs)
        ret = nil
        @mutex.synchronize do
          ret = @store.insert_framework(**kwargs)
          bump!
        end
        ret
      rescue
        @mutex.synchronize do
          next unless @in_tx
          @store.db.execute("ROLLBACK")
          @in_tx = false
          @counter = 0
        end
        raise
      end

      def flush
        @mutex.synchronize do
          return unless @in_tx
          @store.db.execute("COMMIT")
          @in_tx = false
          @counter = 0
        end
      end

      private

      def bump!
        @counter += 1
        return if @counter < @batch_size
        @store.db.execute("COMMIT")
        @in_tx = false
        @counter = 0
        @store.db.execute("BEGIN")
        @in_tx = true
      end
    end
  end
end
