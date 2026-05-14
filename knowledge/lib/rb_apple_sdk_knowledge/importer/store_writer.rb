# frozen_string_literal: true
module AppleSDKKnowledge
  module Importer
    class StoreWriter
      def initialize(store:, batch_size: 1000)
        @store = store
        @batch_size = batch_size
        @counter = 0
        @in_tx = false
      end

      def begin!
        return if @in_tx
        @store.db.execute("BEGIN")
        @in_tx = true
        @counter = 0
      end

      def insert_symbol(**kwargs)
        ret = @store.insert_symbol(**kwargs)
        bump!
        ret
      rescue SQLite3::ConstraintException
        # Caller (Pipeline#insert_one) handles duplicate-skip semantics.
        # A UNIQUE violation on a single INSERT does not invalidate the
        # surrounding transaction in SQLite, so we must NOT rollback here.
        raise
      rescue
        rollback!
        raise
      end

      def insert_framework(**kwargs)
        ret = @store.insert_framework(**kwargs)
        bump!
        ret
      rescue
        rollback!
        raise
      end

      def flush
        return unless @in_tx
        @store.db.execute("COMMIT")
        @in_tx = false
        @counter = 0
      end

      private

      def rollback!
        return unless @in_tx
        @store.db.execute("ROLLBACK")
        @in_tx = false
        @counter = 0
      end

      def bump!
        @counter += 1
        return if @counter < @batch_size
        flush
        begin!
      end
    end
  end
end
