# frozen_string_literal: true
require "json"
require_relative "importer/sdk_resolver"
require_relative "importer/swift_interface_parser"
require_relative "importer/swift_overlay"
require_relative "importer/header_parser"
require_relative "importer/consolidator"
require_relative "importer/embedder"
require_relative "store"

module AppleSDKKnowledge
  module Importer
    class Pipeline
      def initialize(store_path:, fast: ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] == "1",
                     offline: ENV["RB_APPLE_SDK_KNOWLEDGE_OFFLINE"] == "1",
                     resolver: nil)
        @store_path = store_path
        @fast = fast
        @offline = offline
        @resolver = resolver
      end

      def run
        resolver      = @resolver || SDKResolver.new
        store         = AppleSDKKnowledge::Store.open(@store_path)
        embedder      = @fast ? nil : Embedder.new
        swift_parser  = SwiftInterfaceParser.new
        header_parser = HeaderParser.new
        consolidator  = Consolidator.new
        swift_overlay = SwiftOverlay.new(store)

        resolver.frameworks.each do |fw|
          process_framework(fw, store, swift_parser, header_parser, consolidator, embedder)
          import_swift_overlay(fw, swift_overlay)
        end

        store.rebuild_fts!
        store.db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                         ["sdk_version", resolver.sdk_version])
        store.close
      end

      private

      PARENT_KINDS = %w[class struct protocol enum_module actor].freeze

      def process_framework(fw, store, swift_parser, header_parser, consolidator, embedder)
        fw_id = store.find_framework_id_by_name(fw.name)
        fw_id ||= store.insert_framework(name: fw.name, swift_module: fw.name)

        swift_syms = collect_swift_symbols(fw, swift_parser)
        c_syms = collect_c_symbols(fw, header_parser)

        merged = consolidator.merge(swift_syms, c_syms)

        # Two-pass insert so member rows can resolve parent_id by name.
        # Pass 1: top-level type rows (class/struct/protocol/enum_module/actor)
        # whose parser-side parent_name is nil. Build a name→id map.
        parents, children = merged.partition do |sym|
          PARENT_KINDS.include?(sym[:kind]) && sym[:parent_name].nil?
        end

        parent_id_by_name = {}
        parents.each do |sym|
          id = insert_one(store, fw_id, sym, nil, embedder)
          parent_id_by_name[sym[:name]] = id if id
        end

        # Pass 2: members + nested types. parent_name (when present) is
        # resolved against the map; unresolved names insert with parent_id nil
        # (e.g. extensions on types from another framework — out of scope for v1).
        children.each do |sym|
          parent_id = sym[:parent_name] && parent_id_by_name[sym[:parent_name]]
          insert_one(store, fw_id, sym, parent_id, embedder)
        end
      end

      def insert_one(store, fw_id, sym, parent_id, embedder)
        symbol_id = store.insert_symbol(
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
          content_hash: sym[:content_hash]
        )
        if embedder && embedder.available?
          text = "#{sym[:name]} #{sym[:signature]} #{sym[:documentation]}"
          store.vec_insert(symbol_id, embedder.embed(text))
        end
        symbol_id
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
    end
  end
end
