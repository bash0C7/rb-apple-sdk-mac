# frozen_string_literal: true
require "sqlite3"

module AppleSDKKnowledge
  class Store
    # Bumped when the on-disk schema shape changes. Bumping invalidates any
    # existing Knowledge Base SQLite at the project-scoped path; the next
    # `apple:knowledge:rebuild` regenerates it.
    SCHEMA_VERSION = 9

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
        id                   INTEGER PRIMARY KEY,
        framework_id         INTEGER REFERENCES frameworks(id),
        name                 TEXT NOT NULL,
        parent_id            INTEGER REFERENCES symbols(id),
        kind                 TEXT NOT NULL,
        signature            TEXT,
        abi                  TEXT NOT NULL,
        documentation        TEXT,
        return_type          TEXT,
        parameters_json      TEXT,
        availability         TEXT,
        deprecated           INTEGER DEFAULT 0,
        requires_main_thread INTEGER DEFAULT 0,
        content_hash         TEXT NOT NULL UNIQUE,
        fields_json          TEXT,
        is_throws            INTEGER NOT NULL DEFAULT 0,
        is_async             INTEGER NOT NULL DEFAULT 0,
        is_failable          INTEGER NOT NULL DEFAULT 0,
        is_settable          INTEGER NOT NULL DEFAULT 0,
        return_ownership     TEXT,
        throws_error_type    TEXT,
        callback_signature_json TEXT,
        enum_cases_json      TEXT,
        unsupported_pattern  TEXT,
        swift_imported_name  TEXT
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
    SQL

    attr_reader :db, :path

    def self.open(path)
      new(path).tap(&:migrate!)
    end

    def initialize(path)
      @path = path
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = false
    end

    def migrate!
      @db.execute_batch(SCHEMA_SQL)
      @db.execute(
        "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
        ["schema_version", SCHEMA_VERSION.to_s]
      )
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
                       deprecated: 0, requires_main_thread: 0, fields_json: nil,
                       swift_imported_name: nil,
                       is_throws: 0, is_async: 0, is_failable: 0, is_settable: 0,
                       return_ownership: nil, throws_error_type: nil,
                       callback_signature_json: nil, enum_cases_json: nil,
                       unsupported_pattern: nil)
      # UPSERT on content_hash: a re-import (e.g. apple:knowledge:rebuild
      # under a newer classifier) must overwrite the existing row so
      # updated parameters_json / fields_json / swift_imported_name land
      # atomically in one statement. Phase 1 metadata: integer flags
      # (is_throws/is_async/is_failable/is_settable) overwrite on re-import
      # to reflect the latest classifier; nullable TEXT columns
      # (return_ownership / throws_error_type / *_json / unsupported_pattern)
      # use COALESCE so a later import that leaves them NULL preserves
      # values an earlier richer source already populated.
      @db.execute(
        <<~SQL,
          INSERT INTO symbols
          (framework_id, name, parent_id, kind, signature, abi, documentation,
           return_type, parameters_json, availability, deprecated,
           requires_main_thread, content_hash, fields_json, swift_imported_name,
           is_throws, is_async, is_failable, is_settable,
           return_ownership, throws_error_type, callback_signature_json,
           enum_cases_json, unsupported_pattern)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            fields_json     = COALESCE(excluded.fields_json, symbols.fields_json),
            swift_imported_name = COALESCE(excluded.swift_imported_name, symbols.swift_imported_name),
            is_throws       = excluded.is_throws,
            is_async        = excluded.is_async,
            is_failable     = excluded.is_failable,
            is_settable     = excluded.is_settable,
            return_ownership = COALESCE(excluded.return_ownership, symbols.return_ownership),
            throws_error_type = COALESCE(excluded.throws_error_type, symbols.throws_error_type),
            callback_signature_json = COALESCE(excluded.callback_signature_json, symbols.callback_signature_json),
            enum_cases_json = COALESCE(excluded.enum_cases_json, symbols.enum_cases_json),
            unsupported_pattern = COALESCE(excluded.unsupported_pattern, symbols.unsupported_pattern)
        SQL
        [framework_id, name, parent_id, kind, signature, abi, documentation,
         return_type, parameters_json, availability, deprecated,
         requires_main_thread, content_hash, fields_json, swift_imported_name,
         is_throws, is_async, is_failable, is_settable,
         return_ownership, throws_error_type, callback_signature_json,
         enum_cases_json, unsupported_pattern]
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

    def find_framework_id_by_name(name)
      row = @db.execute("SELECT id FROM frameworks WHERE name = ?", [name]).first
      row && row.first
    end

    def close
      @db.close
    end
  end
end
