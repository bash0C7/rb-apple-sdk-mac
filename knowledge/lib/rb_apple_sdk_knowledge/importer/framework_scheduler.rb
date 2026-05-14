# frozen_string_literal: true
require "json"
require_relative "result_channel"
require_relative "worker_pool"
require_relative "objc_header_worker"
require_relative "swift_interface_worker"

module AppleSDKKnowledge
  module Importer
    class FrameworkScheduler
      PARENT_KINDS = %w[class struct protocol enum_module actor].freeze

      def initialize(frameworks:, parallelism:, workers_per_framework:,
                     store:, writer:, reporter:,
                     consolidator:, swift_overlay:, sdk_path:)
        @frameworks = frameworks
        @parallelism = [parallelism, 1].max
        @workers_per_framework = [workers_per_framework, 1].max
        @store = store
        @writer = writer
        @reporter = reporter
        @consolidator = consolidator
        @swift_overlay = swift_overlay
        @sdk_path = sdk_path
        @stats_mutex = Mutex.new
        @stats = { processed: 0, skipped: 0 }
      end

      def run
        return @stats if @frameworks.empty?

        queue = Queue.new
        @frameworks.each_with_index { |fw, idx| queue << [fw, idx] }

        threads = @parallelism.times.map do
          Thread.new do
            loop do
              pair = (queue.pop(true) rescue nil)
              break if pair.nil?
              fw, idx = pair
              process_one(fw, idx)
            end
          end
        end
        threads.each(&:join)
        @stats
      end

      private

      def pool_size_for_framework(item_count)
        return 1 if item_count < 1
        [item_count, @workers_per_framework].min
      end

      def process_one(fw, idx)
        @reporter.framework_started(fw.name, idx: idx, total: @frameworks.size)
        fw_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        fw_id = @store.find_framework_id_by_name(fw.name) ||
                @writer.insert_framework(name: fw.name, swift_module: fw.name)

        headers = collect_header_paths(fw)
        swift_paths = collect_swift_paths(fw)

        items = []
        headers.each { |h| items << { kind: "objc_header", framework: fw.name, header: h } }
        swift_paths.each { |p| items << { kind: "swift_interface", framework: fw.name, path: p } }

        processed = 0
        skipped = 0
        c_syms = []
        swift_syms = []

        unless items.empty?
          size = pool_size_for_framework(items.size)
          channel = ResultChannel.new(buffer_size: items.size + size + 4)
          sdk = @sdk_path
          pool = WorkerPool.new(
            size: size,
            worker_factory: -> do
              objc = ObjCHeaderWorker.new(sdk_path: sdk)
              swift = SwiftInterfaceWorker.new
              ->(payload) do
                case payload[:kind]
                when "objc_header" then objc.call(framework: payload[:framework], header: payload[:header])
                when "swift_interface" then swift.call(framework: payload[:framework], path: payload[:path])
                end
              end
            end,
            channel: channel
          )

          items.each_with_index { |it, seq| pool.submit(seq: seq, payload: it) }
          shutdown_thread = Thread.new { pool.shutdown(wait: true) }

          channel.each_ordered do |item|
            response = item[:payload]
            request = response[:request]
            target_path = request && (request[:header] || request[:path])
            if response[:error]
              @reporter.header_done(framework: fw.name, header: target_path,
                                    status: :error, elapsed_ms: response[:elapsed_ms],
                                    error: response[:error])
              skipped += 1
              next
            end
            @reporter.header_done(framework: fw.name, header: target_path,
                                  status: :ok, elapsed_ms: response[:elapsed_ms])
            processed += 1
            case request[:kind]
            when "objc_header" then c_syms.concat(response[:result] || [])
            when "swift_interface" then swift_syms.concat(response[:result] || [])
            end
          end
          shutdown_thread.join
        end

        merged = @consolidator.merge(swift_syms, c_syms)
        two_pass_insert(merged, fw_id)

        # SwiftOverlay (separate path from SwiftInterfaceParser) — still serial
        # because SwiftOverlay#import! mutates @store directly (Phase 1 behavior).
        import_swift_overlay(fw)

        fw_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - fw_start) * 1000).to_i
        @reporter.framework_finished(fw.name, processed: processed, skipped: skipped, elapsed_ms: fw_ms)
        @stats_mutex.synchronize do
          @stats[:processed] += processed
          @stats[:skipped] += skipped
        end
      end

      def collect_header_paths(fw)
        d = File.join(fw.path, "Headers")
        return [] unless File.directory?(d)
        Dir.glob(File.join(d, "*.h")).sort
      end

      def collect_swift_paths(fw)
        Dir.glob(File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")).sort
      end

      def two_pass_insert(merged, fw_id)
        parents, children = merged.partition do |sym|
          PARENT_KINDS.include?(sym[:kind]) && sym[:parent_name].nil?
        end
        parent_id_by_name = {}
        parents.each do |sym|
          id = insert_one(fw_id, sym, nil)
          parent_id_by_name[sym[:name]] = id if id
        end
        children.each do |sym|
          parent_id = sym[:parent_name] && parent_id_by_name[sym[:parent_name]]
          insert_one(fw_id, sym, parent_id)
        end
      end

      def insert_one(fw_id, sym, parent_id)
        @writer.insert_symbol(
          framework_id: fw_id,
          name: sym[:name],
          kind: sym[:kind],
          abi: sym[:abi],
          parent_id: parent_id,
          signature: sym[:signature],
          documentation: sym[:documentation],
          return_type: sym[:return_type],
          parameters_json: sym[:parameters] && JSON.generate(sym[:parameters]),
          fields_json: sym[:fields] && JSON.generate(sym[:fields]),
          content_hash: sym[:content_hash],
          is_throws: sym[:is_throws] ? 1 : 0,
          is_async: sym[:is_async] ? 1 : 0,
          is_failable: sym[:is_failable] ? 1 : 0,
          is_settable: sym[:is_settable] ? 1 : 0,
          return_ownership: sym[:return_ownership],
          throws_error_type: sym[:throws_error_type],
          callback_signature_json: sym[:callback_signature_json],
          enum_cases_json: sym[:enum_cases_json],
          unsupported_pattern: sym[:unsupported_pattern]
        )
      rescue SQLite3::ConstraintException
        nil
      end

      def import_swift_overlay(fw)
        pattern = File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")
        Dir.glob(pattern).each do |path|
          @swift_overlay.import!(framework: fw.name, path: path)
        rescue StandardError => e
          warn "[importer] swift overlay skipped #{path}: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
