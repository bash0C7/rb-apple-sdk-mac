# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "digest"
require "rb_apple_sdk_knowledge/importer"

class TestPipelineParallelBitIdentical < Test::Unit::TestCase
  FRAMEWORK_SUBSET = %w[CoreGraphics CoreFoundation].freeze

  def rebuild_with(workers:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: FRAMEWORK_SUBSET)
      ENV["APPLE_SDK_MAC_KB_WORKERS"] = workers.to_s
      AppleSDKKnowledge::Importer::Pipeline.new(store_path: path, resolver: resolver).run
      store = AppleSDKKnowledge::Store.open(path)
      rows = store.db.execute(<<~SQL)
        SELECT framework_id, name, kind, COALESCE(content_hash, '')
        FROM symbols
        ORDER BY framework_id, name, kind, content_hash
      SQL
      store.close
      Digest::SHA256.hexdigest(rows.map { |r| r.join("|") }.join("\n"))
    end
  end

  def test_n1_n2_n4_produce_bit_identical_symbols
    omit "set APPLE_SDK_MAC_KB_INTEGRATION=1 to run" unless ENV["APPLE_SDK_MAC_KB_INTEGRATION"]
    n1 = rebuild_with(workers: 1)
    n2 = rebuild_with(workers: 2)
    n4 = rebuild_with(workers: 4)
    assert_equal n1, n2, "N=1 と N=2 で symbols が一致しない"
    assert_equal n1, n4, "N=1 と N=4 で symbols が一致しない"
  end
end
