# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
require "rb_apple_sdk_knowledge/importer"
require "rb_apple_sdk_knowledge/store"

# Verifies Pipeline wires SwiftOverlay into the rebuild flow:
# given a framework dir whose .swiftinterface contains a Swift overlay
# extension block (Apple's Swift native API surface, e.g. AVCaptureDevice's
# `class func devices(for:)`), the resulting SQLite must hold rows with
# swift_imported_name populated. This is the integration point that bridges
# Phase 4a.2 (SwiftOverlay class) and Phase 5 (examples needing Swift bridge).
class TestSwiftOverlayPipeline < Test::Unit::TestCase
  Framework = AppleSDKKnowledge::Importer::SDKResolver::Framework

  class FakeResolver
    def initialize(frameworks:)
      @frameworks = frameworks
    end
    def sdk_version = "26.2-fixture"
    def sdk_path = "/dev/null/fixture"
    attr_reader :frameworks
  end

  def setup
    @tmp = Dir.mktmpdir("kb-swift-overlay-pipeline")
    fw_root = File.join(@tmp, "FakeFW.framework", "Modules", "FakeFW.swiftmodule")
    FileUtils.mkdir_p(fw_root)
    File.write(File.join(fw_root, "arm64-apple-macos.swiftinterface"), <<~SWIFT)
      // synthetic Swift overlay surface
      extension FakeCamera {
        @objc public class func devices(for mediaType: AVMediaType) -> [AVCaptureDevice]
        @objc public class func authorizationStatus(for mediaType: AVMediaType) -> Int
      }
    SWIFT
    @fw = Framework.new(name: "FakeFW", path: File.join(@tmp, "FakeFW.framework"))
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_pipeline_writes_swift_imported_name_for_overlay_decls
    db_path = File.join(@tmp, "kb.sqlite")
    ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] = "1"
    pipeline = AppleSDKKnowledge::Importer::Pipeline.new(
      store_path: db_path,
      resolver:   FakeResolver.new(frameworks: [@fw]),
    )
    pipeline.run
    ENV.delete("RB_APPLE_SDK_KNOWLEDGE_FAST")

    store = AppleSDKKnowledge::Store.open(db_path)
    rows = store.db.execute(<<~SQL)
      SELECT name, swift_imported_name, kind
      FROM symbols
      WHERE swift_imported_name IS NOT NULL
    SQL
    store.close

    assert_operator rows.size, :>=, 1,
      "Pipeline must populate at least 1 swift_imported_name when a framework " \
      "has Swift overlay declarations (got #{rows.size} rows)"
    selectors = rows.map(&:first)
    assert_includes selectors, "devicesWithMediaType:",
      "ObjC selector for `class func devices(for mediaType:)` must be reconstructed"
  end
end
