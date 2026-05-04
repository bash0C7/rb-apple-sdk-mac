# frozen_string_literal: true
require "sqlite3"
require "fileutils"

module AppleSDKMac
  class CompiledGlueCache
    SCHEMA_SQL = <<~SQL.freeze
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS compiled_glue (
        glue_id              TEXT PRIMARY KEY,
        framework_name       TEXT NOT NULL,
        symbol_name          TEXT NOT NULL,
        swift_source         BLOB NOT NULL,
        dylib_path           TEXT NOT NULL,
        exported_symbol      TEXT NOT NULL,
        generator            TEXT NOT NULL,
        llm_model_version    TEXT,
        llm_prompt_hash      TEXT,
        compile_swiftc_args  TEXT NOT NULL DEFAULT '',
        verification_status  TEXT NOT NULL DEFAULT 'pass',
        generated_at         INTEGER NOT NULL,
        last_used_at         INTEGER,
        use_count            INTEGER DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_glue_framework_symbol
        ON compiled_glue(framework_name, symbol_name);

      CREATE TABLE IF NOT EXISTS compile_history (
        id            INTEGER PRIMARY KEY,
        framework     TEXT NOT NULL,
        symbol        TEXT NOT NULL,
        attempt_at    INTEGER NOT NULL,
        generator     TEXT NOT NULL,
        llm_response  BLOB,
        error_stage   TEXT,
        error_detail  TEXT,
        glue_id       TEXT
      );

      CREATE TABLE IF NOT EXISTS conformance_shims (
        shim_id              TEXT PRIMARY KEY,
        protocol_or_class    TEXT NOT NULL,
        framework_name       TEXT NOT NULL,
        swift_source         BLOB NOT NULL,
        dylib_path           TEXT NOT NULL,
        shim_class_name      TEXT NOT NULL,
        required_methods     TEXT NOT NULL,
        generated_at         INTEGER NOT NULL
      );
    SQL

    attr_reader :db, :base_dir, :sdk_version

    def self.open(base_dir, sdk_version:)
      new(base_dir, sdk_version: sdk_version).tap(&:migrate!)
    end

    def initialize(base_dir, sdk_version:)
      @base_dir = base_dir
      @sdk_version = sdk_version
      FileUtils.mkdir_p(File.join(@base_dir, sdk_version, "lib"))
      FileUtils.mkdir_p(File.join(@base_dir, sdk_version, "sources"))
      @db = SQLite3::Database.new(File.join(@base_dir, sdk_version, "glue.sqlite"))
    end

    def migrate!
      @db.execute_batch(SCHEMA_SQL)
    end

    def lookup(framework:, symbol:)
      row = @db.execute(<<~SQL, [framework, symbol]).first
        SELECT glue_id, framework_name, symbol_name, dylib_path,
               exported_symbol, generator, verification_status
        FROM compiled_glue
        WHERE framework_name = ? AND symbol_name = ?
        LIMIT 1
      SQL
      return nil unless row
      {
        glue_id: row[0], framework: row[1], symbol: row[2],
        dylib_path: row[3], exported_symbol: row[4],
        generator: row[5], verification_status: row[6]
      }
    end

    def insert(glue_id:, framework:, symbol:, swift_source:, dylib_path:,
               exported_symbol:, generator:, llm_model_version: nil, llm_prompt_hash: nil)
      @db.execute(
        <<~SQL,
          INSERT INTO compiled_glue
          (glue_id, framework_name, symbol_name, swift_source, dylib_path,
           exported_symbol, generator, llm_model_version, llm_prompt_hash,
           generated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [glue_id, framework, symbol, SQLite3::Blob.new(swift_source), dylib_path,
         exported_symbol, generator, llm_model_version, llm_prompt_hash, Time.now.to_i]
      )
    end

    def record_attempt(framework:, symbol:, generator:, llm_response: nil,
                        error_stage: nil, error_detail: nil, glue_id: nil)
      @db.execute(
        <<~SQL,
          INSERT INTO compile_history
          (framework, symbol, attempt_at, generator, llm_response,
           error_stage, error_detail, glue_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [framework, symbol, Time.now.to_i, generator,
         llm_response ? SQLite3::Blob.new(llm_response) : nil,
         error_stage, error_detail, glue_id]
      )
    end

    def close
      @db.close
    end
  end
end
