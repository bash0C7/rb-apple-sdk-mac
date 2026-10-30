# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "json"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/importer/swift_overlay"

class TestSwiftOverlayImporterPhase1 < Test::Unit::TestCase
  def test_throws_async_failable_lifted_to_schema_columns
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
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

        r1 = store.db.execute(<<~SQL, ["initWithUrl:", "TestKlass"]).first
          SELECT s.is_throws, s.is_async, s.is_failable
          FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil r1, "init(forReading:) throws symbol must be imported"
        assert_equal [1, 0, 0], r1, "init throws → is_throws=1"

        r2 = store.db.execute(<<~SQL, ["initWithString:", "TestKlass"]).first
          SELECT s.is_throws, s.is_async, s.is_failable
          FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil r2, "init?(string:) symbol must be imported"
        assert_equal [0, 0, 1], r2, "init?(string:) → is_failable=1"

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

        params1_raw = store.db.execute(<<~SQL, ["initWithUrl:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil params1_raw, "init(forReading url:) symbol が import されてへん"
        params1 = JSON.parse(params1_raw[0])
        assert_equal 1, params1.size
        assert_equal "forReading", params1[0]["external_label"]
        assert_equal "url",        params1[0]["internal_name"]

        params2_raw = store.db.execute(<<~SQL, ["initWithRaw:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil params2_raw, "init(_ raw:) symbol が import されてへん"
        params2 = JSON.parse(params2_raw[0])
        assert_nil      params2[0]["external_label"]
        assert_equal "raw", params2[0]["internal_name"]

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

  def test_default_value_literal_captured
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        extension TestKlass {
          public init(value: Int = 42, name: String = "default", encoding: String.Encoding = .utf8)
          public init(callback: () -> Void = { })
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      begin
        AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(
          framework: "TestFW", path: interface
        )

        row1 = store.db.execute(<<~SQL, ["initWithValue:name:encoding:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil row1, "3-arg init symbol が import されてへん"
        params1 = JSON.parse(row1[0])
        assert_equal 3, params1.size
        assert_equal "42",          params1[0]["default_value"]
        assert_equal "\"default\"", params1[1]["default_value"]
        assert_equal ".utf8",       params1[2]["default_value"]
        assert_equal "Int",             params1[0]["type"]
        assert_equal "String",          params1[1]["type"]
        assert_equal "String.Encoding", params1[2]["type"]

        row2 = store.db.execute(<<~SQL, ["initWithCallback:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil row2, "callback init symbol が import されてへん"
        params2 = JSON.parse(row2[0])
        assert_nil params2[0]["default_value"],
          "closure default は literal じゃないから NULL"
      ensure
        store.close
      end
    end
  end

  def test_optional_layer_captured_as_nullable
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        import Foundation
        extension TestKlass {
          public func one(_ x: URL?)
          public func two(_ x: URL??)
          public func three(_ x: Array<URL?>)
          public func four(_ x: URL!)
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      begin
        AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(
          framework: "TestFW", path: interface
        )

        one = store.db.execute(<<~SQL, ["one:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil one, "one symbol が import されてへん"
        assert_equal true, JSON.parse(one[0])[0]["nullable"],
          "URL? は外形 Optional → nullable=true"

        two = store.db.execute(<<~SQL, ["two:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil two, "two symbol が import されてへん"
        assert_equal true, JSON.parse(two[0])[0]["nullable"],
          "URL?? の外形末尾 ? も nullable=true"

        three = store.db.execute(<<~SQL, ["three:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil three, "three symbol が import されてへん"
        assert_equal false, JSON.parse(three[0])[0]["nullable"],
          "Array<URL?> は外形が非 Optional"

        four = store.db.execute(<<~SQL, ["four:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil four, "four symbol が import されてへん"
        assert_equal true, JSON.parse(four[0])[0]["nullable"],
          "URL! (IUO) も nullable=true"
      ensure
        store.close
      end
    end
  end

  def test_enum_cases_captured_to_enum_cases_json
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        public enum WriteMode {
          case create
          case createAndPrepend
          case truncate
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      begin
        AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(
          framework: "TestFW", path: interface
        )
        row = store.db.execute(
          "SELECT enum_cases_json FROM symbols WHERE name = ?", ["WriteMode"]
        ).first
        assert_not_nil row, "WriteMode が import されてへん"
        assert_not_nil row[0], "enum_cases_json が NULL"
        cases = JSON.parse(row[0])
        assert_equal %w[create createAndPrepend truncate], cases
      ensure
        store.close
      end
    end
  end

  def test_property_is_settable_distinguished
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        extension TestKlass {
          public var writable: Int { get set }
          public var readonly: Int { get }
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      begin
        AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(
          framework: "TestFW", path: interface
        )
        r1 = store.db.execute(<<~SQL, ["writable", "TestKlass"]).first
          SELECT s.is_settable FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        r2 = store.db.execute(<<~SQL, ["readonly", "TestKlass"]).first
          SELECT s.is_settable FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil r1, "writable property が import されてへん"
        assert_not_nil r2, "readonly property が import されてへん"
        assert_equal 1, r1[0], "{ get set } → is_settable=1"
        assert_equal 0, r2[0], "{ get } のみ → is_settable=0"
      ensure
        store.close
      end
    end
  end

  def test_swift_macro_attribute_marked_unsupported
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      File.write(interface, <<~SWIFT)
        // swift-interface-format-version: 1.0
        @Observable public class WatchedThing {
          public var value: Int { get set }
        }
        public class PlainThing {
          @ViewBuilder public var body: AnyView { get }
        }
      SWIFT
      db_path = File.join(dir, "k.sqlite")
      store = AppleSDKKnowledge::Store.open(db_path)
      begin
        AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(
          framework: "TestFW", path: interface
        )
        r1 = store.db.execute("SELECT unsupported_pattern FROM symbols WHERE name = ?", ["WatchedThing"]).first
        assert_not_nil r1, "WatchedThing が import されてへん"
        assert_equal "swift_macro", r1[0],
          "@Observable class は macro marker"

        r2 = store.db.execute(<<~SQL, ["body", "PlainThing"]).first
          SELECT s.unsupported_pattern FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil r2, "body property が import されてへん"
        assert_equal "result_builder", r2[0],
          "@ViewBuilder property は result_builder marker"
      ensure
        store.close
      end
    end
  end

  def test_framework_discovery_includes_main_overlays
    sdk_root = `xcrun --show-sdk-path 2>/dev/null`.strip
    omit "macOS SDK not found (xcrun missing)" if sdk_root.empty?
    omit "macOS SDK path does not exist" unless File.directory?(sdk_root)

    paths = AppleSDKKnowledge::Importer::SwiftOverlay.framework_swiftinterface_paths(sdk_root)
    framework_names = paths.map { |p| File.basename(p, ".swiftinterface") }.uniq

    %w[Foundation AppKit SwiftUI].each do |fw|
      assert paths.any? { |p| p.include?("/#{fw}.framework/") },
        "expected overlay #{fw}.framework swiftinterface to be discovered (実機 sample: #{framework_names.take(20).inspect})"
    end
  end
end
