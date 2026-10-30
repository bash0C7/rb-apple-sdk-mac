# frozen_string_literal: true
require "rb_apple_sdk_knowledge"
require_relative "cache_dir"

module AppleSDKMac
  class KnowledgeCache
    def self.open
      new(AppleSDKKnowledge.open(base_dir: File.join(AppleSDKMac.cache_dir, "knowledge")))
    end

    def initialize(store)
      @store = store
      @db = store.db
      @transient = {}
    end

    def register_transient(framework:, symbol:, record:)
      @transient[[framework.to_s, symbol.to_s]] = record
    end

    def clear_transient!
      @transient.clear
    end

    def lookup_symbol(framework:, symbol:)
      key = [framework.to_s, symbol.to_s]
      return @transient[key] if @transient.key?(key)
      row = @db.execute(<<~SQL, [framework, symbol]).first
        SELECT s.id, s.name, s.kind, s.signature, s.abi, s.documentation,
               s.parameters_json, s.requires_main_thread, s.content_hash,
               s.fields_json, s.return_type,
               s.is_throws, s.is_async, s.is_failable, s.is_settable,
               s.return_ownership, s.throws_error_type,
               s.callback_signature_json, s.enum_cases_json,
               s.unsupported_pattern
        FROM symbols s
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ? AND s.name = ?
        LIMIT 1
      SQL
      return nil unless row
      {
        id: row[0], name: row[1], kind: row[2], signature: row[3],
        abi: row[4], documentation: row[5], parameters_json: row[6],
        requires_main_thread: row[7] == 1, content_hash: row[8],
        fields_json: row[9], return_type: row[10],
        is_throws:    row[11] == 1,
        is_async:     row[12] == 1,
        is_failable:  row[13] == 1,
        is_settable:  row[14] == 1,
        return_ownership: row[15],
        throws_error_type: row[16],
        callback_signature_json: row[17],
        enum_cases_json: row[18],
        unsupported_pattern: row[19],
      }
    end

    def lookup_swift_imported_name(framework:, klass:, selector:)
      row = @db.execute(<<~SQL, [framework, klass, selector]).first
        SELECT s.swift_imported_name
        FROM symbols s
        JOIN symbols p     ON s.parent_id = p.id
        JOIN frameworks f  ON s.framework_id = f.id
        WHERE f.name = ? AND p.name = ? AND s.name = ?
        LIMIT 1
      SQL
      row && row[0]
    rescue SQLite3::SQLException => e
      raise unless e.message.include?("no such column")
      nil
    end

    def lookup_klass_method(framework:, klass:, method:)
      row = @db.execute(<<~SQL, [framework, klass, method]).first
        SELECT s.id, s.name, s.kind, s.signature, s.abi, s.documentation,
               s.parameters_json, s.requires_main_thread, s.content_hash,
               s.fields_json, s.return_type,
               s.is_throws, s.is_async, s.is_failable, s.is_settable,
               s.return_ownership, s.throws_error_type,
               s.callback_signature_json, s.enum_cases_json,
               s.unsupported_pattern
        FROM symbols s
        JOIN symbols p     ON s.parent_id = p.id
        JOIN frameworks f  ON s.framework_id = f.id
        WHERE f.name = ? AND p.name = ? AND s.name = ?
        LIMIT 1
      SQL
      return nil unless row
      {
        id: row[0], name: row[1], kind: row[2], signature: row[3],
        abi: row[4], documentation: row[5], parameters_json: row[6],
        requires_main_thread: row[7] == 1, content_hash: row[8],
        fields_json: row[9], return_type: row[10],
        is_throws:    row[11] == 1,
        is_async:     row[12] == 1,
        is_failable:  row[13] == 1,
        is_settable:  row[14] == 1,
        return_ownership: row[15],
        throws_error_type: row[16],
        callback_signature_json: row[17],
        enum_cases_json: row[18],
        unsupported_pattern: row[19],
      }
    end

    def list_framework_symbols(framework:, kinds: nil)
      sql = <<~SQL
        SELECT s.name, s.kind, s.signature, s.abi
        FROM symbols s
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ?
      SQL
      args = [framework]
      if kinds
        sql += " AND s.kind IN (#{Array(kinds).map { "?" }.join(",")})"
        args.concat(kinds)
      end
      @db.execute(sql, args).map do |r|
        { name: r[0], kind: r[1], signature: r[2], abi: r[3] }
      end
    end

    def list_klass_methods(framework:, klass:)
      sql = <<~SQL
        SELECT s.name, s.kind, s.signature
        FROM symbols s
        JOIN symbols p ON s.parent_id = p.id
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ? AND p.name = ?
      SQL
      @db.execute(sql, [framework, klass]).map do |r|
        { name: r[0], kind: r[1], signature: r[2] }
      end
    end

    def list_frameworks
      @db.execute("SELECT name FROM frameworks ORDER BY name").flatten
    end

    def lookup_framework_documentation(name:)
      row = @db.execute(<<~SQL, [name]).first
        SELECT name, swift_module, category, doc_url, min_macos
        FROM frameworks WHERE name = ? LIMIT 1
      SQL
      return nil unless row

      parts = ["#{row[0]} framework"]
      parts << "Swift module: #{row[1]}" if row[1] && !row[1].empty?
      parts << "Category: #{row[2]}" if row[2] && !row[2].empty?
      parts << "macOS: #{row[4]}+" if row[4] && !row[4].empty?
      parts << "Documentation: #{row[3]}" if row[3] && !row[3].empty?
      parts.join(". ") + "."
    end

    def lookup_documentation(framework:, name:, klass: nil)
      row = if klass
              @db.execute(<<~SQL, [framework, klass, name])
                SELECT s.documentation FROM symbols s
                JOIN symbols p     ON s.parent_id = p.id
                JOIN frameworks f  ON s.framework_id = f.id
                WHERE f.name = ? AND p.name = ? AND s.name = ?
                LIMIT 1
              SQL
            else
              @db.execute(<<~SQL, [framework, name])
                SELECT s.documentation FROM symbols s
                JOIN frameworks f  ON s.framework_id = f.id
                WHERE f.name = ? AND s.parent_id IS NULL AND s.name = ?
                LIMIT 1
              SQL
            end.first
      doc = row && row[0]
      doc.is_a?(String) && !doc.empty? ? doc : nil
    end

    def search(framework:, query:, limit: 5)
      @store.fts_search(framework, query, limit: limit)
    end

    def stats
      fw_count = @db.execute("SELECT COUNT(*) FROM frameworks").first.first
      sym_count = @db.execute("SELECT COUNT(*) FROM symbols").first.first
      kinds = @db.execute(
        "SELECT kind, COUNT(*) FROM symbols GROUP BY kind ORDER BY COUNT(*) DESC"
      ).map { |r| [r[0], r[1]] }
      { framework_count: fw_count, symbol_count: sym_count, kind_breakdown: kinds }
    end

    def search_all_frameworks(query:, per_fw: 3, total: 5)
      list_frameworks.flat_map do |fw|
        search(framework: fw, query: query, limit: per_fw).map { |r| r.merge(framework: fw) }
      rescue StandardError
        []
      end.first(total)
    end

    def close
      @store.close
    end
  end
end
