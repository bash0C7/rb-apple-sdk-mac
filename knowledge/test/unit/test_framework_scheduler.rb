# frozen_string_literal: true
require "test/unit"
require "rb_apple_sdk_knowledge/importer/framework_scheduler"

class TestFrameworkScheduler < Test::Unit::TestCase
  def test_pool_size_for_framework_caps_at_workers
    fs = AppleSDKKnowledge::Importer::FrameworkScheduler.new(
      frameworks: [], parallelism: 4, workers_per_framework: 4,
      store: nil, writer: nil, reporter: nil,
      consolidator: nil, swift_overlay: nil, sdk_path: nil
    )
    assert_equal 1, fs.send(:pool_size_for_framework, 0)
    assert_equal 1, fs.send(:pool_size_for_framework, 1)
    assert_equal 2, fs.send(:pool_size_for_framework, 2)
    assert_equal 4, fs.send(:pool_size_for_framework, 10)
    assert_equal 4, fs.send(:pool_size_for_framework, 100)
  end

  def test_run_with_empty_frameworks_returns_zero_stats
    fs = AppleSDKKnowledge::Importer::FrameworkScheduler.new(
      frameworks: [], parallelism: 2, workers_per_framework: 2,
      store: nil, writer: nil, reporter: nil,
      consolidator: nil, swift_overlay: nil, sdk_path: nil
    )
    stats = fs.run
    assert_equal({ processed: 0, skipped: 0 }, stats)
  end
end
