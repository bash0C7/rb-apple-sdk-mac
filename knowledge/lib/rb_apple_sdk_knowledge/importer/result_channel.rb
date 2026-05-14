# frozen_string_literal: true
require "thread"

module AppleSDKKnowledge
  module Importer
    class ResultChannel
      def initialize(buffer_size: 64)
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @buffer = {}
        @next_seq = 0
        @closed = false
        @buffer_size = buffer_size
      end

      def push(seq:, payload:, may_block: true)
        @mutex.synchronize do
          # When may_block: false (reader thread path), never stall: overflow the
          # buffer rather than deadlock. Without this, a slow worker delivering
          # seq=N while faster workers fill buffer with N+1, N+2... creates an
          # unresolvable cycle (each_ordered waits for N; reader waits for space).
          if may_block
            while @buffer.size >= @buffer_size && !@closed
              @cond.wait(@mutex)
            end
          end
          @buffer[seq] = { seq: seq, payload: payload }
          @cond.broadcast
        end
      end

      def close
        @mutex.synchronize do
          @closed = true
          @cond.broadcast
        end
      end

      def each_ordered
        loop do
          item = @mutex.synchronize do
            until @buffer.key?(@next_seq) || @closed
              @cond.wait(@mutex)
            end
            break nil if @closed && !@buffer.key?(@next_seq)
            @buffer.delete(@next_seq).tap { @cond.broadcast }
          end
          break if item.nil?
          @next_seq += 1
          yield item
        end
      end
    end
  end
end
