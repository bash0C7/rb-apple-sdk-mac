# frozen_string_literal: true
require "json"
require "fileutils"
require "sqlite3"
require_relative "importer/kind"

module AppleSDKKnowledge
  class Reclassifier
    K = AppleSDKKnowledge::Importer::Kind

    def self.recompute_parameters(json)
      return nil if json.nil? || json.empty?
      params = JSON.parse(json, symbolize_names: true)
      pointer_params = params.select { |p| (p[:type] || "").include?("*") }
      last_pointer = pointer_params.last

      params.each_with_index.map do |p, i|
        qual_type = p[:type] || ""
        name = p[:name] || "_arg#{i}"
        p.merge(
          kind: K.classify_kind(qual_type),
          is_out_param: K.out_param?(qual_type, name, p.equal?(last_pointer)),
          nullability: K.nullability_of(qual_type)
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
      File.open(@queue_path, "w") do |queue|
        @queue = queue
        recompute_all!
      end
      verify!
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
          enqueue_unsupported(framework, sym_name, signature, recomputed)
        end
        db.execute("COMMIT")
      rescue => _e
        db.execute("ROLLBACK")
        raise
      ensure
        db.close
      end
    end

    def enqueue_unsupported(framework, sym_name, signature, json)
      params = JSON.parse(json, symbolize_names: true)
      params.each_with_index do |p, i|
        @total_params += 1
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

    def log(msg)
      @log.puts msg
    end
  end
end
