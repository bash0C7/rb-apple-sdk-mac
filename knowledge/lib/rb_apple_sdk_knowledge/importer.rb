# frozen_string_literal: true
require "json"
require_relative "importer/sdk_resolver"
require_relative "importer/swift_interface_parser"
require_relative "importer/swift_overlay"
require_relative "importer/header_parser"
require_relative "importer/consolidator"
require_relative "importer/store_writer"
require_relative "store"

module AppleSDKKnowledge
  module Importer
    class Pipeline
      def initialize(store_path:, resolver: nil)
        @store_path = store_path
        @resolver = resolver
      end

      def run
        # Lazy-load rebuild-only dependencies so that requiring importer.rb
        # from the main gem (which lacks ruby-progressbar) does not fail at
        # load time. ProgressReporter depends on ruby-progressbar which is
        # only bundled in the knowledge sub-gem; fall back to NullReporter
        # when the gem is unavailable (e.g. root test suite context).
        require_relative "importer/result_channel"
        require_relative "importer/objc_header_worker"
        require_relative "importer/worker_pool"
        begin
          require_relative "importer/progress_reporter"
        rescue LoadError
          # ruby-progressbar unavailable; NullReporter defined below
        end

        resolver      = @resolver || SDKResolver.new
        store         = AppleSDKKnowledge::Store.open(@store_path)
        swift_parser  = SwiftInterfaceParser.new
        consolidator  = Consolidator.new
        swift_overlay = SwiftOverlay.new(store)
        writer        = StoreWriter.new(store: store, batch_size: (ENV["APPLE_SDK_MAC_KB_BATCH_SIZE"] || 1000).to_i)
        frameworks    = resolver.frameworks
        reporter_class = defined?(AppleSDKKnowledge::Importer::ProgressReporter) ?
                         AppleSDKKnowledge::Importer::ProgressReporter :
                         NullReporter
        reporter      = reporter_class.new(io: $stderr, total_frameworks: frameworks.size)
        workers       = (ENV["APPLE_SDK_MAC_KB_WORKERS"] || 2).to_i
        sdk_path      = resolver.sdk_path

        t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        total_processed = 0
        total_skipped = 0

        writer.begin!
        frameworks.each_with_index do |fw, idx|
          reporter.framework_started(fw.name, idx: idx, total: frameworks.size)
          fw_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          fw_id = store.find_framework_id_by_name(fw.name) ||
                  writer.insert_framework(name: fw.name, swift_module: fw.name)

          headers = collect_header_paths(fw)
          processed = 0
          skipped = 0
          c_syms_all = []

          if !headers.empty?
            channel = ResultChannel.new(buffer_size: workers * 8)
            pool = WorkerPool.new(
              size: workers,
              worker_factory: -> { ObjCHeaderWorker.new(sdk_path: sdk_path) },
              channel: channel
            )
            headers.each_with_index { |h, seq| pool.submit(seq: seq, payload: { framework: fw.name, header: h }) }
            pool.shutdown(wait: true)

            channel.each_ordered do |item|
              response = item[:payload]
              header_path = response[:request] && response[:request][:header]
              if response[:error]
                reporter.header_done(framework: fw.name, header: header_path,
                                     status: :error, elapsed_ms: response[:elapsed_ms], error: response[:error])
                skipped += 1
              else
                reporter.header_done(framework: fw.name, header: header_path,
                                     status: :ok, elapsed_ms: response[:elapsed_ms])
                # JSON round-trip: response[:result] is an array of symbol-keyed hashes
                c_syms_all.concat(response[:result] || [])
                processed += 1
              end
            end
          end

          swift_syms = collect_swift_symbols(fw, swift_parser)
          merged = consolidator.merge(swift_syms, c_syms_all)
          two_pass_insert(merged, writer, fw_id)

          import_swift_overlay(fw, swift_overlay)
          fw_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - fw_start) * 1000).to_i
          reporter.framework_finished(fw.name, processed: processed, skipped: skipped, elapsed_ms: fw_ms)
          total_processed += processed
          total_skipped += skipped
        end
        writer.flush

        store.rebuild_fts!
        store.db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                         ["sdk_version", resolver.sdk_version])
        store.close
        reporter.finish(processed_total: total_processed, skipped_total: total_skipped,
                        elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).to_i)
      end

      private

      PARENT_KINDS = %w[class struct protocol enum_module actor].freeze

      # Minimal reporter used when ruby-progressbar is unavailable (e.g. root
      # test suite context). Matches the ProgressReporter public interface.
      class NullReporter
        def initialize(io: $stderr, total_frameworks:); @io = io; end
        def framework_started(name, idx:, total:)
          @io.puts "=== #{name} (#{idx + 1}/#{total}) ==="
        end
        def header_done(framework:, header:, status:, elapsed_ms:, error: nil)
          return unless status == :error
          @io.puts "[importer] skipping #{header}: #{error.to_s.lines.first.to_s.strip}"
        end
        def framework_finished(name, processed:, skipped:, elapsed_ms:)
          @io.puts "-> processed=#{processed} skipped=#{skipped}"
        end
        def finish(processed_total:, skipped_total:, elapsed_ms:)
          @io.puts "done processed=#{processed_total} skipped=#{skipped_total}"
        end
      end

      # Legacy entry point kept for test compatibility.
      # Tests in test_importer_parameters_json.rb call this via +send+ with a
      # duck-typed store (SpyStore) that implements +insert_symbol+ directly.
      def process_framework(fw, store, swift_parser, header_parser, consolidator)
        fw_id = store.find_framework_id_by_name(fw.name)
        fw_id ||= store.insert_framework(name: fw.name, swift_module: fw.name)

        swift_syms = collect_swift_symbols(fw, swift_parser)
        c_syms = collect_c_symbols(fw, header_parser)

        merged = consolidator.merge(swift_syms, c_syms)
        two_pass_insert(merged, store, fw_id)
      end

      # Collect ObjC symbols using a HeaderParser directly (serial, legacy path
      # used by process_framework and tests with a fake parser).
      def collect_c_symbols(fw, parser)
        headers_dir = File.join(fw.path, "Headers")
        return [] unless File.directory?(headers_dir)
        Dir.glob(File.join(headers_dir, "*.h")).flat_map do |h|
          parser.parse_file(h)
        rescue StandardError => e
          warn "[importer] skipping header #{h}: #{e.class}: #{e.message}"
          []
        end
      end

      def collect_header_paths(fw)
        headers_dir = File.join(fw.path, "Headers")
        return [] unless File.directory?(headers_dir)
        Dir.glob(File.join(headers_dir, "*.h")).sort
      end

      def two_pass_insert(merged, writer, fw_id)
        parents, children = merged.partition do |sym|
          PARENT_KINDS.include?(sym[:kind]) && sym[:parent_name].nil?
        end

        parent_id_by_name = {}
        parents.each do |sym|
          id = insert_one(writer, fw_id, sym, nil)
          parent_id_by_name[sym[:name]] = id if id
        end

        children.each do |sym|
          parent_id = sym[:parent_name] && parent_id_by_name[sym[:parent_name]]
          insert_one(writer, fw_id, sym, parent_id)
        end
      end

      def insert_one(writer, fw_id, sym, parent_id)
        writer.insert_symbol(
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
        # symbol already exists from a prior run (content_hash UNIQUE): skip silently
        nil
      end

      # Walks the framework's .swiftinterface set and runs SwiftOverlay
      # against each. SwiftOverlay handles its own per-decl skip rules
      # (generic / async / throws); failures here are logged and swallowed
      # so one corrupt interface does not abort the whole rebuild.
      def import_swift_overlay(fw, swift_overlay)
        pattern = File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")
        Dir.glob(pattern).each do |path|
          begin
            swift_overlay.import!(framework: fw.name, path: path)
          rescue StandardError => e
            warn "[importer] swift overlay skipped #{path}: #{e.class}: #{e.message}"
          end
        end
      end

      def collect_swift_symbols(fw, parser)
        pattern = File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")
        Dir.glob(pattern).flat_map do |path|
          begin
            parser.parse_file(path)
          rescue StandardError => e
            warn "[importer] skipping swift interface #{path}: #{e.class}: #{e.message}"
            []
          end
        end
      end
    end
  end
end
