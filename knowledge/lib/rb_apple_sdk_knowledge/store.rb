# frozen_string_literal: true
require "sqlite3"
require "sqlite_vec"

module AppleSDKKnowledge
  class Store
    # Phase 7 / spec §5 — bump for cf_create_rule + objc_kind + swift_kind
    # columns. ingest population of those columns is staged for v1.1; the
    # column shape is committed at v1.0 so the mac gem's schema_version
    # invalidation path doesn't have to thrash on later bumps.
    # v4 — adds swift_imported_name TEXT for Swift overlay importer (Task 4a.2).
    # The Glue Compiler emitter (Phase 4b) reads this column to bridge ObjC
    # method selectors to their resolved Swift import name.
    SCHEMA_VERSION = 4

    SCHEMA_SQL = <<~SQL.freeze
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;

      CREATE TABLE IF NOT EXISTS schema_meta (
        key TEXT PRIMARY KEY,
        value TEXT
      );

      CREATE TABLE IF NOT EXISTS frameworks (
        id           INTEGER PRIMARY KEY,
        name         TEXT NOT NULL UNIQUE,
        swift_module TEXT NOT NULL,
        category     TEXT,
        doc_url      TEXT,
        min_macos    TEXT
      );

      CREATE TABLE IF NOT EXISTS symbols (
        id              INTEGER PRIMARY KEY,
        framework_id    INTEGER REFERENCES frameworks(id),
        name            TEXT NOT NULL,
        parent_id       INTEGER REFERENCES symbols(id),
        kind            TEXT NOT NULL,
        signature       TEXT,
        abi             TEXT NOT NULL,
        documentation   TEXT,
        return_type     TEXT,
        parameters_json TEXT,
        availability    TEXT,
        deprecated      INTEGER DEFAULT 0,
        requires_main_thread INTEGER DEFAULT 0,
        content_hash    TEXT NOT NULL UNIQUE,
        fields_json     TEXT
      );

      CREATE INDEX IF NOT EXISTS idx_symbols_framework_name ON symbols(framework_id, name);
      CREATE INDEX IF NOT EXISTS idx_symbols_parent          ON symbols(parent_id);
      CREATE INDEX IF NOT EXISTS idx_symbols_kind            ON symbols(kind);

      CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(
        name, documentation, signature,
        tokenize = 'trigram',
        content = 'symbols',
        content_rowid = 'id'
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS symbols_vec USING vec0(
        symbol_id INTEGER PRIMARY KEY,
        embedding FLOAT[768]
      );
    SQL

    attr_reader :db, :path

    def self.open(path)
      new(path).tap(&:migrate!)
    end

    def initialize(path)
      @path = path
      @db = SQLite3::Database.new(path)
      @db.enable_load_extension(true)
      SqliteVec.load(@db)
      @db.enable_load_extension(false)
      @db.results_as_hash = false
    end

    def migrate!
      @db.execute_batch(SCHEMA_SQL)
      ensure_column!("symbols", "fields_json", "TEXT")
      # Phase 7 / spec §5 — Apple-API-classification columns. The mac
      # gem's TemplateGenerator already prefers symbol[:cf_create_rule]
      # for CF auto-ARC routing (falling back to the Create/Copy naming
      # heuristic when null); objc_kind / swift_kind unblock the
      # ObjC method dispatch + Swift initializer / property paths.
      ensure_column!("symbols", "cf_create_rule",      "INTEGER DEFAULT 0")
      ensure_column!("symbols", "objc_kind",            "TEXT")
      ensure_column!("symbols", "swift_kind",           "TEXT")
      # v4 — Swift overlay importer writes ObjC selector → Swift import name here.
      ensure_column!("symbols", "swift_imported_name", "TEXT")
      @db.execute(
        "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
        ["schema_version", SCHEMA_VERSION.to_s]
      )
    end

    def ensure_column!(table, col, type)
      cols = @db.execute("PRAGMA table_info(#{table})").map { |r| r[1] }
      return if cols.include?(col)
      @db.execute("ALTER TABLE #{table} ADD COLUMN #{col} #{type}")
    end

    def insert_framework(name:, swift_module:, category: nil, doc_url: nil, min_macos: nil)
      @db.execute(
        "INSERT INTO frameworks (name, swift_module, category, doc_url, min_macos) VALUES (?, ?, ?, ?, ?)",
        [name, swift_module, category, doc_url, min_macos]
      )
      @db.last_insert_row_id
    end

    def insert_symbol(framework_id:, name:, kind:, abi:, content_hash:,
                       parent_id: nil, signature: nil, documentation: nil,
                       return_type: nil, parameters_json: nil, availability: nil,
                       deprecated: 0, requires_main_thread: 0, fields_json: nil)
      # UPSERT on content_hash: a re-import (e.g. apple:knowledge:rebuild
      # under a newer classifier or schema) must overwrite the existing row
      # so updated parameters_json / fields_json land. Plain INSERT would
      # raise ConstraintException, which the importer used to swallow —
      # leaving stale rows from prior schema versions.
      @db.execute(
        <<~SQL,
          INSERT INTO symbols
          (framework_id, name, parent_id, kind, signature, abi, documentation,
           return_type, parameters_json, availability, deprecated,
           requires_main_thread, content_hash, fields_json)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(content_hash) DO UPDATE SET
            framework_id    = excluded.framework_id,
            name            = excluded.name,
            parent_id       = excluded.parent_id,
            kind            = excluded.kind,
            signature       = excluded.signature,
            abi             = excluded.abi,
            documentation   = excluded.documentation,
            return_type     = excluded.return_type,
            parameters_json = excluded.parameters_json,
            availability    = excluded.availability,
            deprecated      = excluded.deprecated,
            requires_main_thread = excluded.requires_main_thread,
            fields_json     = COALESCE(excluded.fields_json, symbols.fields_json)
        SQL
        [framework_id, name, parent_id, kind, signature, abi, documentation,
         return_type, parameters_json, availability, deprecated,
         requires_main_thread, content_hash, fields_json]
      )
      # last_insert_row_id() reports 0 on UPDATE; recover the actual rowid.
      row = @db.execute("SELECT id FROM symbols WHERE content_hash = ?", [content_hash]).first
      row && row.first
    end

    def rebuild_fts!
      @db.execute("INSERT INTO symbols_fts(symbols_fts) VALUES('rebuild')")
    end

    def fts_search(framework_name, query, limit: 5)
      sql = <<~SQL
        SELECT s.name, s.kind, s.signature, f.name AS framework
        FROM symbols_fts ft
        JOIN symbols s ON s.id = ft.rowid
        JOIN frameworks f ON s.framework_id = f.id
        WHERE symbols_fts MATCH ? AND f.name = ?
        ORDER BY rank
        LIMIT ?
      SQL
      sanitized = query.to_s.gsub(/[-+*^"()]/, " ").squeeze(" ").strip
      return [] if sanitized.empty?
      @db.execute(sql, [sanitized, framework_name, limit]).map do |row|
        { name: row[0], kind: row[1], signature: row[2], framework: row[3] }
      end
    end

    def vec_insert(symbol_id, embedding)
      blob = embedding.pack("f*")
      @db.execute(
        "INSERT OR REPLACE INTO symbols_vec(symbol_id, embedding) VALUES (?, ?)",
        [symbol_id, blob]
      )
    end

    def find_framework_id_by_name(name)
      row = @db.execute("SELECT id FROM frameworks WHERE name = ?", [name]).first
      row && row.first
    end

    def close
      @db.close
    end
  end
end
