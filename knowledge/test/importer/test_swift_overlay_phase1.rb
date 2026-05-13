# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "json"
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

  # Phase 1 T9: capture Swift's two parameter naming positions
  # (external label / internal name) per element in parameters_json.
  # Conventions:
  # - `_ raw: String` (anonymous external) → external_label = nil, internal_name = "raw"
  # - `url: URL` (single label)            → external_label = internal_name = "url"
  # - `forReading url: URL` (2 種)         → external_label = "forReading", internal_name = "url"
  def test_parameter_external_and_internal_labels_captured
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        extension TestKlass {
          public init(forReading url: URL)
          public init(_ raw: String)
          public func render(into target: Image, with options: Options)
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      begin
        AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(
          framework: "TestFW", path: interface
        )

        # init(forReading url: URL) — Apple init bridging:
        # always initWith<capitalize(internal)>: → initWithUrl:
        params1_raw = store.db.execute(<<~SQL, ["initWithUrl:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil params1_raw, "init(forReading url:) symbol が import されてへん"
        params1 = JSON.parse(params1_raw[0])
        assert_equal 1, params1.size
        assert_equal "forReading", params1[0]["external_label"]
        assert_equal "url",        params1[0]["internal_name"]

        # init(_ raw: String) — anonymous external (`_` → external_label = nil)
        # ObjC bridging still uses initWith<Internal>: → initWithRaw:
        params2_raw = store.db.execute(<<~SQL, ["initWithRaw:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil params2_raw, "init(_ raw:) symbol が import されてへん"
        params2 = JSON.parse(params2_raw[0])
        assert_nil      params2[0]["external_label"]
        assert_equal "raw", params2[0]["internal_name"]

        # render(into target: Image, with options: Options) — 2 引数 2 label
        # first_param_suffix: label "into" != internal "target" → "WithTarget"
        # rest_param_part: "with:" → selector = renderWithTarget:with:
        params3_raw = store.db.execute(<<~SQL, ["renderWithTarget:with:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil params3_raw, "render(into:with:) symbol が import されてへん"
        params3 = JSON.parse(params3_raw[0])
        assert_equal "into",    params3[0]["external_label"]
        assert_equal "target",  params3[0]["internal_name"]
        assert_equal "with",    params3[1]["external_label"]
        assert_equal "options", params3[1]["internal_name"]
      ensure
        store.close
      end
    end
  end
end
