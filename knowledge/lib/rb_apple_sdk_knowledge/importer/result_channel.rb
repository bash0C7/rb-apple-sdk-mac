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

      def push(seq:, payload:)
        @mutex.synchronize do
          while @buffer.size >= @buffer_size && !@closed
            @cond.wait(@mutex)
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
