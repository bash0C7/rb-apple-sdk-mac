# frozen_string_literal: true
require "json"

module AppleSDKKnowledge
  module Importer
    class WorkerPool
      def initialize(size:, worker_factory:, channel:)
        @size = size
        @worker_factory = worker_factory
        @channel = channel
        @pids = []
        @to_worker = []     # parent → worker (request)
        @from_worker = []   # worker → parent (response)
        @worker_idx_by_reader = {}
        @pending_seqs = Array.new(size) { [] }
        @pending_mutex = Mutex.new
        @next_worker = 0
        spawn_workers
        @reader = start_reader
      end

      def submit(seq:, payload:)
        msg = JSON.dump(seq: seq, payload: payload)
        @to_worker[@next_worker].puts(msg)
        @pending_mutex.synchronize { @pending_seqs[@next_worker] << seq }
        @next_worker = (@next_worker + 1) % @size
      end

      # Fix C2: join reader before waitpid to drain pipes and avoid deadlock
      def shutdown(wait: true)
        @to_worker.each(&:close)
        @reader.join if wait
        @pids.each { |pid| Process.waitpid(pid) }
        @channel.close
      end

      private

      def spawn_workers
        @size.times do |worker_idx|
          req_r, req_w = IO.pipe
          res_r, res_w = IO.pipe
          pid = Process.fork do
            req_w.close
            res_r.close
            worker = @worker_factory.call
            req_r.each_line do |line|
              data = JSON.parse(line, symbolize_names: true)
              payload = data[:payload]
              res = worker.call(framework: payload[:framework], header: payload[:header])
              # Fix I4: rename inner :payload → :request to eliminate double-nesting
              res_w.puts JSON.dump(
                seq: data[:seq],
                result: res[:result],
                error: res[:error],
                elapsed_ms: res[:elapsed_ms],
                request: payload
              )
            end
            res_w.close
            exit 0
          end
          req_r.close
          res_w.close
          @pids << pid
          @to_worker << req_w
          @from_worker << res_r
          @worker_idx_by_reader[res_r] = worker_idx
        end
      end

      def start_reader
        Thread.new do
          readers = @from_worker.dup
          until readers.empty?
            ready, = IO.select(readers)
            ready.each do |r|
              line = r.gets
              if line.nil?
                # Fix C1: synthesize error payloads for any pending seqs on crashed worker
                idx = @worker_idx_by_reader[r]
                crashed = nil
                @pending_mutex.synchronize do
                  crashed = @pending_seqs[idx]
                  @pending_seqs[idx] = []
                end
                crashed.each do |seq|
                  @channel.push(seq: seq, payload: {
                    seq: seq,
                    result: nil,
                    error: "worker crashed: pid=#{@pids[idx]} idx=#{idx}",
                    elapsed_ms: 0,
                    request: nil
                  })
                end
                readers.delete(r)
                next
              end
              data = JSON.parse(line, symbolize_names: true)
              seq = data[:seq]
              idx = @worker_idx_by_reader[r]
              @pending_mutex.synchronize { @pending_seqs[idx].delete(seq) }
              @channel.push(seq: seq, payload: data)
            end
          end
        end
      end
    end
  end
end
