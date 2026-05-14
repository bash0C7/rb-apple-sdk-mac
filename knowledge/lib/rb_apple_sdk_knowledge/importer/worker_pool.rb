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
        @next_worker = 0
        spawn_workers
        @reader = start_reader
      end

      def submit(seq:, payload:)
        msg = JSON.dump(seq: seq, payload: payload)
        @to_worker[@next_worker].puts(msg)
        @next_worker = (@next_worker + 1) % @size
      end

      def shutdown(wait: true)
        @to_worker.each(&:close)
        @pids.each { |pid| Process.waitpid(pid) }
        @reader.join if wait
        @channel.close
      end

      private

      def spawn_workers
        @size.times do
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
              res_w.puts JSON.dump(
                seq: data[:seq],
                result: res[:result],
                error: res[:error],
                elapsed_ms: res[:elapsed_ms],
                payload: payload
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
                readers.delete(r)
                next
              end
              data = JSON.parse(line, symbolize_names: true)
              @channel.push(seq: data[:seq], payload: data)
            end
          end
        end
      end
    end
  end
end
