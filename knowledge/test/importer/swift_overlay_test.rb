# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/swift_overlay"
require "tmpdir"

class SwiftOverlayImporterTest < Test::Unit::TestCase
  def test_imports_class_func_devices_for_mediatype
    Dir.mktmpdir do |dir|
      store = AppleSDKKnowledge::Store.open(File.join(dir, "test.sqlite"))
      fixture = File.expand_path("../fixtures/swift_overlay/AVFoundation.swiftinterface", __dir__)
      AppleSDKKnowledge::Importer::SwiftOverlay.new(store).import!(framework: "AVFoundation", path: fixture)

      row = store.db.execute(<<~SQL, ["AVFoundation", "AVCaptureDevice", "devicesWithMediaType:"]).first
        SELECT s.kind, s.swift_imported_name FROM symbols s
        JOIN symbols p ON s.parent_id = p.id
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ? AND p.name = ? AND s.name = ?
      SQL
      refute_nil row, "no row found for AVFoundation::AVCaptureDevice::devicesWithMediaType:"
      assert_equal "objc_method_class", row[0]
      assert_equal "devices(for:)", row[1]
      store.close
    end
  end
end
