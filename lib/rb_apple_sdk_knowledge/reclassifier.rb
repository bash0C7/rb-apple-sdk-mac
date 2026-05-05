# frozen_string_literal: true
require "json"
require "fileutils"
require "sqlite3"
require "time"
require_relative "importer/kind"

module AppleSDKKnowledge
  class Reclassifier
    K = AppleSDKKnowledge::Importer::Kind

    KIND_VOCABULARY = %w[
      string int bool float opaque_ref
      callback_nilable callback_non_nil void_ptr_nilable
      struct_in struct_out struct_in_pointer variadic_args
      unsupported
    ].freeze

    def self.recompute_parameters(json)
      return nil if json.nil? || json.empty?
      params = JSON.parse(json, symbolize_names: true)
      pointer_params = params.select { |p| (p[:type] || "").include?("*") }
      last_pointer = pointer_params.last

      params.each_with_index.map do |p, i|
        qual_type = p[:type] || ""
        name = p[:name] || "_arg#{i}"
        # Preserve existing nullability if the parameters_json was written by
        # the importer pipeline (which has access to clang's annotated qual_type
        # and forwards nullability). Otherwise derive from qual_type.
        nullability = p[:nullability] || K.nullability_of(qual_type)
        # Run classifier with current information. If it returns "unsupported"
        # but a specific kind was already set, preserve it — this happens for
        # function-pointer typedefs whose name alone (without desugared) is
        # opaque to the classifier.
        recomputed_kind = K.classify_kind(qual_type, qual_type, nullability)
        kind = if recomputed_kind == "unsupported" && p[:kind] && p[:kind] != "unsupported"
                 p[:kind]
               else
                 recomputed_kind
               end
        p.merge(
          kind: kind,
          is_out_param: K.out_param?(qual_type, name, p.equal?(last_pointer)),
          nullability: nullability
        )
      end.then { |xs| JSON.generate(xs) }
    end

    def initialize(store_path:, log_io:, queue_path:)
      @store_path = store_path
      @log = log_io
      @queue_path = queue_path
    end

    def run
      backup!
      @by_kind = Hash.new(0)
      @clusters = Hash.new { |h, k| h[k] = { count: 0, frameworks: [], example_symbols: [] } }
      File.open(@queue_path, "w") do |queue|
        @queue = queue
        recompute_all!
        verify!
        emit_summary!
      end
      log "DONE: total_symbols=#{@total_symbols} total_params=#{@total_params}"
    end

    private

    def backup!
      bak = "#{@store_path}.bak"
      FileUtils.cp(@store_path, bak)
      log "backup: #{bak}"
    end

    def recompute_all!
      db = SQLite3::Database.new(@store_path)
      db.results_as_hash = false
      @total_symbols = 0
      @total_params = 0
      db.execute("BEGIN")
      begin
        rows = db.execute(
          "SELECT s.id, s.name, s.signature, f.name, s.parameters_json
           FROM symbols s LEFT JOIN frameworks f ON s.framework_id = f.id
           WHERE s.parameters_json IS NOT NULL"
        )
        rows.each do |row|
          symbol_id, sym_name, signature, framework, json = row
          recomputed = self.class.recompute_parameters(json)
          db.execute(
            "UPDATE symbols SET parameters_json = ? WHERE id = ?",
            [recomputed, symbol_id]
          )
          @total_symbols += 1
          tally_and_enqueue(framework, sym_name, signature, recomputed)
        end
        db.execute("COMMIT")
      rescue => _e
        db.execute("ROLLBACK")
        raise
      ensure
        db.close
      end
    end

    def tally_and_enqueue(framework, sym_name, signature, json)
      params = JSON.parse(json, symbolize_names: true)
      params.each_with_index do |p, i|
        @total_params += 1
        @by_kind[p[:kind]] += 1
        next unless p[:kind] == "unsupported"
        @queue.puts JSON.generate(
          qual_type: p[:type],
          framework: framework,
          symbol: sym_name,
          signature: signature,
          param_index: i,
          param_name: p[:name],
          heuristics: {
            looks_like_void_pointer: !!(p[:type].to_s =~ /\bvoid\s*\*/),
            looks_like_function_pointer: p[:type].to_s.include?("(") && p[:type].to_s.include?(")")
          }
        )
        c = @clusters[p[:type]]
        c[:count] += 1
        c[:frameworks] << framework unless c[:frameworks].include?(framework)
        c[:example_symbols] << sym_name if c[:example_symbols].length < 3
      end
    end

    def verify!
      db = SQLite3::Database.new(@store_path)
      bad = db.execute(
        "SELECT id, parameters_json FROM symbols WHERE parameters_json IS NOT NULL"
      ).reject do |_id, json|
        JSON.parse(json).all? { |p| p.key?("kind") }
      end
      db.close
      raise "verification failed: #{bad.length} rows lack :kind" unless bad.empty?
    end

    def emit_summary!
      top_clusters = @clusters
        .sort_by { |_, v| -v[:count] }
        .first(10)
        .map { |qt, v| { qual_type: qt, count: v[:count], frameworks: v[:frameworks], example_symbols: v[:example_symbols] } }

      @queue.puts JSON.generate(
        _summary: {
          ran_at: Time.now.utc.iso8601,
          total_symbols: @total_symbols,
          total_params: @total_params,
          by_kind: @by_kind,
          unsupported_clusters: top_clusters,
          classify_kind_source: classify_kind_source_location,
          kind_vocabulary: KIND_VOCABULARY,
          next_action_hint: "extend AppleSDKKnowledge::Importer::Kind.classify_kind to handle the top cluster (or explicitly accept it as unsupported), then re-run rake apple:knowledge:reclassify"
        }
      )
    end

    def classify_kind_source_location
      method = K.method(:classify_kind)
      file, line = method.source_location
      "#{file.sub("#{Dir.pwd}/", "")}:#{line}"
    end

    def log(msg)
      @log.puts msg
    end
  end
end
