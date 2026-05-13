# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/importer/swift_overlay"

# Phase 1 T8: persist swift_overlay's parse-time decl Hash booleans
# (:throws / :async / :failable) into the schema columns
# (is_throws / is_async / is_failable). Phase 2 emitter consults these
# columns directly to choose AndReturnError marshalling and Optional
# unwrap paths without re-parsing signature strings at codegen time.
class TestSwiftOverlayImporterPhase1 < Test::Unit::TestCase
  def test_throws_async_failable_lifted_to_schema_columns
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      # `extension TestKlass { ... }` is the unit SwiftOverlay scans;
      # the class header alone is skipped by the line parser. Bundling
      # the three decls under an extension exercises the production
      # import path end-to-end.
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        extension TestKlass {
          public init(forReading url: URL) throws
          public init?(string: String)
          public func parse(_ data: Data) async throws -> URL
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      begin
        AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(
          framework: "TestFW", path: interface
        )

        # init(forReading url:) → initWithUrl: (Apple init bridging:
        # always initWith<capitalize(internal)>:; capitalize only upcases
        # the first letter so `url` becomes `Url`, not `URL`).
        r1 = store.db.execute(<<~SQL, ["initWithUrl:", "TestKlass"]).first
          SELECT s.is_throws, s.is_async, s.is_failable
          FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil r1, "init(forReading:) throws symbol must be imported"
        assert_equal [1, 0, 0], r1, "init throws → is_throws=1"

        # init?(string:) → initWithString: failable initializer
        r2 = store.db.execute(<<~SQL, ["initWithString:", "TestKlass"]).first
          SELECT s.is_throws, s.is_async, s.is_failable
          FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil r2, "init?(string:) symbol must be imported"
        assert_equal [0, 0, 1], r2, "init?(string:) → is_failable=1"

        # func parse(_ data:) async throws → parse: (underscore label
        # drops the suffix, selector is just the func name + colon)
        r3 = store.db.execute(<<~SQL, ["parse:", "TestKlass"]).first
          SELECT s.is_throws, s.is_async, s.is_failable
          FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil r3, "parse(_:) async throws symbol must be imported"
        assert_equal [1, 1, 0], r3, "async throws → is_throws=1 / is_async=1"
      ensure
        store.close
      end
    end
  end
end
