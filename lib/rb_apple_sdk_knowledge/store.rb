# frozen_string_literal: true
require "sqlite3"
require "sqlite_vec"

module AppleSDKKnowledge
  class Store
    SCHEMA_VERSION = 1

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
        content_hash    TEXT NOT NULL UNIQUE
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
                       deprecated: 0, requires_main_thread: 0)
      @db.execute(
        <<~SQL,
          INSERT INTO symbols
          (framework_id, name, parent_id, kind, signature, abi, documentation,
           return_type, parameters_json, availability, deprecated,
           requires_main_thread, content_hash)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [framework_id, name, parent_id, kind, signature, abi, documentation,
         return_type, parameters_json, availability, deprecated,
         requires_main_thread, content_hash]
      )
      @db.last_insert_row_id
    end

    def close
      @db.close
    end
  end
end
