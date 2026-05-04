# frozen_string_literal: true
require_relative "importer/sdk_resolver"
require_relative "importer/swift_interface_parser"
require_relative "importer/header_parser"
require_relative "importer/docc_parser"
require_relative "importer/consolidator"
require_relative "importer/embedder"
require_relative "store"

module AppleSDKKnowledge
  module Importer
    class Pipeline
      def initialize(store_path:, fast: ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] == "1",
                     offline: ENV["RB_APPLE_SDK_KNOWLEDGE_OFFLINE"] == "1")
        @store_path = store_path
        @fast = fast
        @offline = offline
      end

      def run
        resolver = SDKResolver.new
        store = AppleSDKKnowledge::Store.open(@store_path)
        embedder = @fast ? nil : Embedder.new
        swift_parser = SwiftInterfaceParser.new
        header_parser = HeaderParser.new
        docc_parser = DoccParser.new
        consolidator = Consolidator.new

        resolver.frameworks.each do |fw|
          process_framework(fw, store, swift_parser, header_parser, docc_parser, consolidator, embedder)
        end

        store.rebuild_fts!
        store.db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                         ["sdk_version", resolver.sdk_version])
        store.close
      end

      private

      def process_framework(fw, store, swift_parser, header_parser, docc_parser, consolidator, embedder)
        # Reuse existing framework id on re-runs to avoid UNIQUE constraint on name
        fw_id = store.find_framework_id_by_name(fw.name)
        fw_id ||= store.insert_framework(name: fw.name, swift_module: fw.name)

        swift_syms = collect_swift_symbols(fw, swift_parser)
        c_syms = collect_c_symbols(fw, header_parser)
        docc_syms = [] # doc enrichment optional in v1

        merged = consolidator.merge(swift_syms, c_syms, docc_syms)

        merged.each do |sym|
          begin
            symbol_id = store.insert_symbol(
              framework_id: fw_id,
              name: sym[:name],
              kind: sym[:kind],
              abi: sym[:abi],
              signature: sym[:signature],
              documentation: sym[:documentation],
              content_hash: sym[:content_hash]
            )
            if embedder && embedder.available?
              text = "#{sym[:name]} #{sym[:signature]} #{sym[:documentation]}"
              store.vec_insert(symbol_id, embedder.embed(text))
            end
          rescue SQLite3::ConstraintException
            # symbol already exists from a prior run (content_hash UNIQUE): skip silently
            next
          end
        end
      end

      def collect_swift_symbols(fw, parser)
        pattern = File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")
        Dir.glob(pattern).flat_map { |path| parser.parse_file(path) }
      rescue
        []
      end

      def collect_c_symbols(fw, parser)
        headers_dir = File.join(fw.path, "Headers")
        return [] unless File.directory?(headers_dir)
        Dir.glob(File.join(headers_dir, "*.h")).flat_map do |h|
          parser.parse_file(h)
        rescue
          []
        end
      end
    end
  end
end
