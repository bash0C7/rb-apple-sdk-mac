# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/swift_overlay"
require "rb_apple_sdk_knowledge/store"
require "tmpdir"

# Public-surface coverage of SwiftOverlay#import!. Replaces the prior
# decl_parse / extension_scan / selector_recon test files (which used
# .send(:private_method, ...) to drill into internal helpers). Each
# invariant here corresponds to one of those private-method assertions
# but is verified via the rows that land in the Knowledge Base SQLite
# after a public import! call.
#
# The fixture knowledge/test/fixtures/swift_overlay/comprehensive.swiftinterface
# is constructed so that one import! exercises every parsing concern
# (label-vs-internal first-param mapping, underscore label, multiple
# params, failable init, instance/class var, module-qualified extension
# names, conformance clause, where clause + generic func, nested type).
class SwiftOverlayImporterTest < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir("swift-overlay-test")
    @store = AppleSDKKnowledge::Store.open(File.join(@dir, "test.sqlite"))
    fixture = File.expand_path("../fixtures/swift_overlay/comprehensive.swiftinterface", __dir__)
    AppleSDKKnowledge::Importer::SwiftOverlay.new(@store).import!(framework: "Comprehensive", path: fixture)
  end

  def teardown
    @store&.close
    require "fileutils"
    FileUtils.rm_rf(@dir)
  end

  # -- class_func / instance_func selector reconstruction --------------------

  def test_class_func_with_for_label_emits_with_internal_selector
    row = lookup("AVCaptureDevice", "devicesWithMediaType:")
    refute_nil row, "class func devices(for mediaType:) → devicesWithMediaType: missing"
    assert_equal "class_method", row[0]
    assert_equal "devices(for:)", row[1]
  end

  def test_class_func_no_params_uses_bare_name
    row = lookup("AVCaptureDevice", "defaultDevice")
    refute_nil row, "class func defaultDevice() → defaultDevice missing"
    assert_equal "class_method", row[0]
    assert_equal "defaultDevice()", row[1]
  end

  def test_instance_func_no_params_uses_bare_name
    row = lookup("AVCaptureDevice", "lockForConfiguration")
    refute_nil row, "instance func lockForConfiguration() → lockForConfiguration missing"
    assert_equal "instance_method", row[0]
    assert_equal "lockForConfiguration()", row[1]
  end

  def test_instance_func_multiple_params_keeps_rest_label
    # When first param label == internal, produces "setFormatFormat:"; second
    # param uses its label "for" verbatim.
    row = lookup("AVCaptureSession", "setFormatFormat:for:")
    refute_nil row, "instance func setFormat(format:for:) → setFormatFormat:for: missing"
    assert_equal "instance_method", row[0]
    assert_equal "setFormat(format:for:)", row[1]
  end

  def test_underscore_label_drops_first_suffix
    # func play(_ flag: Bool) → ObjC selector "play:"
    row = lookup("AVAudioPlayer", "play:")
    refute_nil row, "instance func play(_ flag:) → play: missing"
    assert_equal "instance_method", row[0]
    assert_equal "play(_:)", row[1]
  end

  # -- init variants ---------------------------------------------------------

  def test_init_no_params_is_init
    row = lookup("AVCaptureInput", "init")
    refute_nil row, "init() → init missing"
    assert_equal "class_method", row[0]
    assert_equal "init()", row[1]
  end

  def test_init_with_single_param_is_initWithLabel
    row = lookup("AVCaptureInput", "initWithDevice:")
    refute_nil row, "init(device:) → initWithDevice: missing"
    assert_equal "class_method", row[0]
    assert_equal "init(device:)", row[1]
  end

  def test_failable_init_question_mark_is_accepted
    # public init?(string:) under module-qualified extension Foundation.URL
    row = lookup("URL", "initWithString:")
    refute_nil row, "init?(string:) → initWithString: missing"
    assert_equal "class_method", row[0]
    assert_equal "init(string:)", row[1]
  end

  # -- instance_var / class_var ---------------------------------------------

  def test_instance_var_emits_property_row
    row = lookup("AVAudioSession", "category")
    refute_nil row, "var category: String → category missing"
    assert_equal "instance_property", row[0]
    assert_equal "category", row[1]
  end

  def test_class_var_emits_property_row
    row = lookup("AVAudioSession", "shared")
    refute_nil row, "class var shared: AVAudioSession → shared missing"
    # static / class var folds into instance_property per kind_string_for
    assert_equal "instance_property", row[0]
    assert_equal "shared", row[1]
  end

  # -- module-qualified / conformance / where / nested extension headers ----

  def test_module_qualified_simple_uses_last_segment_as_klass
    # extension Foundation.URL { ... } → klass = "URL"
    row = lookup("URL", "absoluteString")
    refute_nil row, "Foundation.URL var absoluteString missing"
    assert_equal "instance_property", row[0]
  end

  def test_extension_with_conformance_clause_parsed
    # extension Foundation.TermOfAddress : Swift.Codable
    row = lookup("TermOfAddress", "encodeWithEncoder:")
    refute_nil row, "TermOfAddress.encode(to:) → encodeWithEncoder: missing"
    assert_equal "instance_method", row[0]
  end

  def test_extension_with_where_clause_and_generic_func_parsed
    # extension Foundation._KeyValueCodingAndObservingPublishing where ...
    # public func publisher<Value>(for keyPath:) → publisherWithKeyPath:
    row = lookup("_KeyValueCodingAndObservingPublishing", "publisherWithKeyPath:")
    refute_nil row, "publisher<Value>(for:) → publisherWithKeyPath: missing"
    assert_equal "instance_method", row[0]
  end

  def test_nested_type_3_segments_uses_last_segment
    # extension Foundation.URL.ParseStrategy { ... } → klass = "ParseStrategy"
    # parse(_ value:) → parse: (underscore label drops suffix)
    row = lookup("ParseStrategy", "parse:")
    refute_nil row, "ParseStrategy.parse(_:) → parse: missing"
    assert_equal "instance_method", row[0]
    assert_equal "parse(_:)", row[1]
  end

  # -- real Apple .swiftinterface fixture coverage --------------------------

  def test_real_apple_foundation_fixture_populates_swift_imported_name
    Dir.mktmpdir do |dir|
      store   = AppleSDKKnowledge::Store.open(File.join(dir, "test.sqlite"))
      fixture = File.expand_path("../fixtures/swift_overlay/foundation_real.swiftinterface", __dir__)
      AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(framework: "Foundation", path: fixture)

      count = store.db.execute(
        "SELECT COUNT(*) FROM symbols WHERE swift_imported_name IS NOT NULL AND swift_imported_name != ''"
      ).first.first
      assert_operator count, :>=, 4,
        "expected >=4 rows with swift_imported_name from 5 extension blocks (URL has 1 init + 1 var, others 1 each), got #{count}"

      # Spot-check: URL.init?(string:) — Swift initializer ingests under
      # ObjC selector "initWithString:" with swift_imported_name "init(string:)"
      row = store.db.execute(<<~SQL, ["Foundation", "URL", "initWithString:"]).first
        SELECT s.swift_imported_name FROM symbols s
        JOIN symbols p ON s.parent_id = p.id
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ? AND p.name = ? AND s.name = ?
      SQL
      refute_nil row, "URL.initWithString: row missing"
      assert_equal "init(string:)", row[0]

      store.close
    end
  end

  # -- return_type / throws / async propagation -----------------------------
  # postmortem 2026-05-14 #4 / #12 root cause work:
  # Swift overlay 経由で取り込んだ method は return_type / throws / async
  # 等の Swift 文法 marker を DB に残す必要がある。 emitter 側は KB record の
  # field を見て emit を分岐する (Apple.discover の override に頼らず)。

  # 非 throws func の return_type が DB に乗ること。
  # 既存実装は insert_symbol に return_type を渡しておらず、 SwiftOverlay 由来
  # row の return_type 列は常に nil だった。
  def test_non_throws_class_func_return_type_propagated
    row = @store.db.execute(<<~SQL, ["Comprehensive", "AVCaptureDevice", "devicesWithMediaType:"]).first
      SELECT s.return_type FROM symbols s
      JOIN symbols p ON s.parent_id = p.id
      JOIN frameworks f ON s.framework_id = f.id
      WHERE f.name = ? AND p.name = ? AND s.name = ?
    SQL
    refute_nil row, "devicesWithMediaType: row must exist"
    assert_equal "[AVCaptureDevice]", row[0],
      "non-throws class func の return_type は DB に乗る"
  end

  # `func parse(_:) throws -> URL` shape: throws と return type が共存する
  # 場合、 DECL_FUNC_RE は throws を間に挟んで `->` を探せず return_type を
  # 落としていた。 regex 拡張で throws/async modifier を skip して return_type
  # まで届くこと。
  def test_throws_func_return_type_propagated
    row = @store.db.execute(<<~SQL, ["Comprehensive", "ParseStrategy", "parse:"]).first
      SELECT s.return_type FROM symbols s
      JOIN symbols p ON s.parent_id = p.id
      JOIN frameworks f ON s.framework_id = f.id
      WHERE f.name = ? AND p.name = ? AND s.name = ?
    SQL
    refute_nil row, "ParseStrategy.parse(_:) row must exist"
    assert_equal "Foundation.URL", row[0],
      "throws func の return_type は throws を skip して capture される"
  end

  # signature 列に Swift 文法 marker `throws` が残ること。 emitter は KB
  # record の signature を見て throws 判定可能になる (Apple.discover の
  # swift_initializer 文字列に頼らず)。
  def test_throws_marker_preserved_in_signature
    row = @store.db.execute(<<~SQL, ["Comprehensive", "AVCaptureDevice", "lockForConfiguration"]).first
      SELECT s.signature FROM symbols s
      JOIN symbols p ON s.parent_id = p.id
      JOIN frameworks f ON s.framework_id = f.id
      WHERE f.name = ? AND p.name = ? AND s.name = ?
    SQL
    refute_nil row, "lockForConfiguration row must exist"
    assert_match(/\bthrows\b/, row[0],
      "throws marker は signature 文字列に残る (downstream parser が判定可能)")
  end

  # -- whole-fixture invariant ----------------------------------------------

  def test_all_extension_blocks_produce_class_rows
    # Every extension block creates / reuses a class row whose name is
    # the last dotted segment. From the comprehensive fixture: AVCaptureDevice,
    # AVCaptureSession, AVAudioPlayer, AVCaptureInput, AVAudioSession, URL,
    # TermOfAddress, _KeyValueCodingAndObservingPublishing,
    # NSKeyValueObservedChange (skipped — empty body), ParseStrategy.
    klasses = @store.db.execute(
      "SELECT DISTINCT name FROM symbols WHERE kind = 'class'"
    ).flatten
    %w[AVCaptureDevice AVCaptureSession AVAudioPlayer AVCaptureInput
       AVAudioSession URL TermOfAddress _KeyValueCodingAndObservingPublishing
       ParseStrategy].each do |k|
      assert_includes klasses, k, "expected class row for #{k}"
    end
  end

  private

  def lookup(parent_name, selector)
    @store.db.execute(<<~SQL, ["Comprehensive", parent_name, selector]).first
      SELECT s.kind, s.swift_imported_name FROM symbols s
      JOIN symbols p ON s.parent_id = p.id
      JOIN frameworks f ON s.framework_id = f.id
      WHERE f.name = ? AND p.name = ? AND s.name = ?
    SQL
  end
end
