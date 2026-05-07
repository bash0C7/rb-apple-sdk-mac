# frozen_string_literal: true
require "rb_apple_sdk_knowledge"

module AppleSDKMac
  class KnowledgeCache
    def self.open
      new(AppleSDKKnowledge.open)
    end

    def initialize(store)
      @store = store
      @db = store.db
      @transient = {}
    end

    # Phase 7 T5 — transient lookup tier. Apple.discover synthesizes
    # symbol records for the polymorphic shapes (objc / swift / etc.)
    # that aren't necessarily in the knowledge DB and registers them
    # here. lookup_symbol returns the transient record before falling
    # back to the DB, so registered overlays win.
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
               s.fields_json
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
        fields_json: row[9]
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

    # Children of a class symbol — instance methods, class methods, properties.
    # IRB completion で `Apple::Foundation::NSData.<TAB>` の候補列挙に使う。
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

    def search(framework:, query:, limit: 5)
      AppleSDKKnowledge::Search.new(@store).lexical(
        framework: framework, query: query, limit: limit
      )
    end

    def close
      @store.close
    end
  end
end
