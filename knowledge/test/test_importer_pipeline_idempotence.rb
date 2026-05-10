# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
require "rb_apple_sdk_knowledge/importer"
require "rb_apple_sdk_knowledge/store"

# Asserts Pipeline.run is idempotent: running it twice against the same
# store yields the same row count. Uses a fixture-based FakeResolver
# instead of the real Apple SDK so the test runs in seconds rather than
# the ~17 min Pipeline.run takes against the full SDK. The end-to-end
# real-SDK invariants live in test/integration/full_rebuild_assertions_test.rb
# (post-rebuild assertions reading the standing Knowledge Base).
class TestImporterPipelineIdempotence < Test::Unit::TestCase
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
    @tmp = Dir.mktmpdir("kb-pipeline-idempotence")
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

  def test_rerun_on_existing_store_is_idempotent
    db_path = File.join(@tmp, "kb.sqlite")
    ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] = "1"

    AppleSDKKnowledge::Importer::Pipeline.new(
      store_path: db_path,
      resolver:   FakeResolver.new(frameworks: [@fw]),
    ).run

    store = AppleSDKKnowledge::Store.open(db_path)
    first_count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
    store.close

    assert_nothing_raised do
      AppleSDKKnowledge::Importer::Pipeline.new(
        store_path: db_path,
        resolver:   FakeResolver.new(frameworks: [@fw]),
      ).run
    end

    store = AppleSDKKnowledge::Store.open(db_path)
    second_count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
    store.close

    assert_equal first_count, second_count,
      "expected re-run to be idempotent: same symbol count both times"
  ensure
    ENV.delete("RB_APPLE_SDK_KNOWLEDGE_FAST")
  end
end
