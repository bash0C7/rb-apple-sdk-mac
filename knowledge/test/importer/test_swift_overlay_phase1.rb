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

  # Phase 1 T10: capture Swift literal default values per parameter into
  # parameters_json element's :default_value key. Literal kinds covered:
  # numeric / string / dot-prefixed enum case / bool / nil. Complex
  # expressions (closure / function call / 等) は default_value = nil の
  # まま — Phase 2 emitter は default 値あり要素なら glue で arg 省略可、
  # nil 要素は user に explicit 渡し必須として扱う。 副次効果として T9
  # で type column に absorb されとった `= literal` 部分が default_value
  # に lift され、 type column は clean に戻る (regression net 付き)。
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

        # 3-arg init: selector form は実機確認済み (initWithValue:name:encoding:)
        # — first 引数 (label==internal) は capitalize(label) で頭 token を
        # 作り、 残りは label のまま colon 付加。
        row1 = store.db.execute(<<~SQL, ["initWithValue:name:encoding:", "TestKlass"]).first
          SELECT s.parameters_json FROM symbols s JOIN symbols p ON s.parent_id = p.id
          WHERE s.name = ? AND p.name = ?
        SQL
        assert_not_nil row1, "3-arg init symbol が import されてへん"
        params1 = JSON.parse(row1[0])
        assert_equal 3, params1.size
        # default_value: numeric / string / dot-prefixed enum 全部 capture
        assert_equal "42",          params1[0]["default_value"]
        assert_equal "\"default\"", params1[1]["default_value"]
        assert_equal ".utf8",       params1[2]["default_value"]
        # regression net: type column は default 部分を含まへんこと
        assert_equal "Int",             params1[0]["type"]
        assert_equal "String",          params1[1]["type"]
        assert_equal "String.Encoding", params1[2]["type"]

        # closure default は literal じゃない → default_value = nil。
        # closure 表現自体は DECL_INIT_RE が `()` で param body を切る都合
        # 上 type は degrade するが、 default capture policy としては
        # 「literal じゃない」 として nil を返す点が本 task の検証対象。
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

  # Phase 1 T11: refine Swift Optional / IUO outer-nullable detection so
  # the Knowledge Base parameters_json carries an accurate `nullable` flag
  # per parameter. Apple's bridging contract:
  #   `URL?`         → outer Optional      → nullable = true
  #   `URL??`        → outer Optional      → nullable = true
  #   `Array<URL?>`  → outer Array (non-optional), inner element Optional
  #                                        → nullable = false
  #   `URL!`         → IUO (outer)         → nullable = true
  # paren / bracket / angle の depth balance で外形を識別し、 内側の `?`
  # を誤検出せぇへん。 Phase 2 emitter は nullable=true なら Ruby 側で
  # nil 受容 / NULL bridging、 nullable=false なら non-null 前提で glue
  # を生成する。
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

        # selector form: underscore label (`_ x`) drops the `With<X>` suffix,
        # selector reduces to `<funcName>:` (verified empirically in Step 1).
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

  # Phase 1 T12: capture Swift `public enum X { case a; case b }` cases
  # into the `enum_cases_json` schema column on the parent enum symbol row.
  # Phase 2 namespace_builder consumes this list to install
  # `Apple::<Framework>::<Enum>::<Case>` constants without re-parsing the
  # swiftinterface. Cases are stored as a JSON array of name strings on
  # the enum row itself — individual cases do not get their own symbol
  # rows in this iteration (case-attached properties / payloads are
  # deferred to a later phase).
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

  # Phase 1 T13: distinguish Swift property readwrite (`{ get set }`) from
  # readonly (`{ get }`) and persist as is_settable schema column.
  # Phase 2 emitter consults this column to auto-emit setter glue
  # (`obj.prop = val`) only for readwrite properties; readonly properties
  # get a getter-only Ruby wrapper. Property symbol kind stays the
  # canonical "instance_property" — static / class vars fold into the
  # same kind (kind_string_for collapses :class_var → "instance_property"),
  # matching swift_interface_parser.rb's existing convention.
  def test_property_is_settable_distinguished
    Dir.mktmpdir do |dir|
      interface = File.join(dir, "TestFW.swiftinterface")
      # `extension TestKlass { ... }` is the unit SwiftOverlay scans —
      # mirrors the phase1 throws/async test convention. A plain
      # `public class TestKlass { ... }` body is NOT picked up by the
      # extension scanner, so we bundle the var decls under an extension
      # block to exercise the production import path end-to-end.
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
end
