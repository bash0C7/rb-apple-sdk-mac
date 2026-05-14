# frozen_string_literal: true
require "json"
require "etc"
require_relative "importer/sdk_resolver"
require_relative "importer/swift_interface_parser"
require_relative "importer/swift_overlay"
require_relative "importer/header_parser"
require_relative "importer/consolidator"
require_relative "importer/result_channel"
require_relative "importer/store_writer"
require_relative "importer/progress_reporter"
require_relative "importer/objc_header_worker"
require_relative "importer/worker_pool"
require_relative "importer/framework_scheduler"
require_relative "store"

module AppleSDKKnowledge
  module Importer
    class Pipeline
      def initialize(store_path:, resolver: nil)
        @store_path = store_path
        @resolver = resolver
      end

      def run
        resolver      = @resolver || SDKResolver.new
        store         = AppleSDKKnowledge::Store.open(@store_path)
        consolidator  = Consolidator.new
        swift_overlay = SwiftOverlay.new(store)
        writer        = StoreWriter.new(store: store, batch_size: (ENV["APPLE_SDK_MAC_KB_BATCH_SIZE"] || 1000).to_i)
        frameworks    = resolver.frameworks
        reporter      = ProgressReporter.new(io: $stderr, total_frameworks: frameworks.size)
        workers       = [(ENV["APPLE_SDK_MAC_KB_WORKERS"] || Etc.nprocessors).to_i, 1].max
        parallelism   = [(ENV["APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM"] || 4).to_i, 1].max
        sdk_path      = resolver.sdk_path

        t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          writer.begin!
          scheduler = FrameworkScheduler.new(
            frameworks: frameworks,
            parallelism: parallelism,
            workers_per_framework: workers,
            store: store, writer: writer, reporter: reporter,
            consolidator: consolidator, swift_overlay: swift_overlay,
            sdk_path: sdk_path
          )
          stats = scheduler.run
          writer.flush
          store.rebuild_fts!
          store.db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                           ["sdk_version", resolver.sdk_version])
        ensure
          store.close
        end
        reporter.finish(processed_total: stats[:processed], skipped_total: stats[:skipped],
                        elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).to_i)
      end

      private

      PARENT_KINDS = %w[class struct protocol enum_module actor].freeze

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
    end
  end
end
