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

    # Transient lookup tier. Apple.discover synthesizes symbol records for
    # the polymorphic shapes (objc / swift / etc.) that aren't necessarily
    # in the knowledge DB and registers them here. lookup_symbol returns
    # the transient record before falling back to the DB, so registered
    # overlays win.
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

    # Swift overlay bridge naming lookup. Returns the `swift_imported_name`
    # column for a given (framework, klass, selector), populated by the
    # Swift overlay importer. nil when miss (no row, no swift_imported_name
    # on row, or no Swift overlay column at all on a stale schema).
    # Caller (SwiftBridgeName.resolve) treats nil as 'fall through to next
    # resolution tier'.
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

    # Klass を介した子 method/property の lookup。 lookup_symbol は flat name
    # 検索なので "URL.appendingPathComponent" のような形式は parent_id 階層で
    # 索引された KB に対して必ず miss する。 こちらは parent_id JOIN で正確に
    # klass 配下の symbol を引く (mcp の validate_call が direct call 検証で利用)。
    def lookup_klass_method(framework:, klass:, method:)
      row = @db.execute(<<~SQL, [framework, klass, method]).first
        SELECT s.id, s.name, s.kind, s.signature, s.abi, s.documentation,
               s.parameters_json, s.requires_main_thread, s.content_hash,
               s.fields_json
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

    # Synthesizes a framework-level description from the frameworks
    # table. Used by the irb sub-gem when the user hovers `Apple::<Framework>`
    # (apple_root). When the row is absent altogether (unknown framework)
    # returns nil. Symbol counts and other gem-internal metadata are
    # intentionally omitted — only user-facing description fields appear.
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

    # Apple SDK doc-comment text for a single symbol, or nil when none.
    # `klass:` is optional — pass it for instance/class methods (parent_id
    # JOIN), omit for top-level functions/structs/constants. Empty stored
    # documentation is normalized to nil so callers can short-circuit on
    # "no doc available" without an extra empty-string check.
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

    def close
      @store.close
    end
  end
end
