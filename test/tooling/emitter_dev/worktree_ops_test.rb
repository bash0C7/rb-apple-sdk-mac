# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "emitter_dev/worktree_ops"

class WorktreeOpsTest < Test::Unit::TestCase
  def setup
    @main = Dir.mktmpdir("main")
    @wt   = Dir.mktmpdir("wt")
    @sdk  = "26.2"
    src = File.join(@main, ".rb-apple-sdk-mac", @sdk)
    FileUtils.mkdir_p(File.join(src, "knowledge"))
    FileUtils.mkdir_p(File.join(src, "sources"))
    FileUtils.mkdir_p(File.join(src, "lib"))
    File.write(File.join(src, "cache.sqlite"), "stub-cache-data")
  end

  def teardown
    FileUtils.rm_rf(@main)
    FileUtils.rm_rf(@wt)
  end

  def test_populate_cache_creates_symlinks_and_cache_copy
    EmitterDev::WorktreeOps.populate_cache(
      worktree_path: @wt, main_root: @main, sdk_version: @sdk
    )
    dst = File.join(@wt, ".rb-apple-sdk-mac", @sdk)
    %w[knowledge sources lib].each do |dir|
      assert File.symlink?(File.join(dst, dir)), "expected symlink #{dir}"
    end
    cache = File.join(dst, "cache.sqlite")
    assert File.file?(cache), "expected cache.sqlite copy"
    refute File.symlink?(cache), "cache.sqlite must be a copy, not symlink"
    assert_equal "stub-cache-data", File.read(cache)
  end

  def test_populate_cache_skips_symlink_when_source_subdir_missing
    src = File.join(@main, ".rb-apple-sdk-mac", @sdk)
    FileUtils.rm_rf(File.join(src, "knowledge"))

    EmitterDev::WorktreeOps.populate_cache(
      worktree_path: @wt, main_root: @main, sdk_version: @sdk
    )

    dst  = File.join(@wt, ".rb-apple-sdk-mac", @sdk)
    link = File.join(dst, "knowledge")
    refute File.symlink?(link), "must not create dangling symlink for missing source subdir"
    refute File.exist?(link), "must not create entry at all when source missing"

    %w[sources lib].each do |dir|
      assert File.symlink?(File.join(dst, dir)), "expected symlink #{dir} (source exists)"
    end
  end

  def test_stale_paths_returns_array
    assert_respond_to EmitterDev::WorktreeOps, :stale_paths
    paths = EmitterDev::WorktreeOps.stale_paths(older_than_days: 7)
    assert_kind_of Array, paths
  end

  def test_stale_paths_filters_by_mtime
    fresh = Dir.mktmpdir("fresh-wt")
    stale = Dir.mktmpdir("stale-wt")
    long_ago = Time.now - (100 * 86_400)
    File.utime(long_ago, long_ago, stale)

    candidates = [fresh, stale]
    selected   = EmitterDev::WorktreeOps.send(:filter_stale, candidates, older_than_days: 7)

    refute_includes selected, fresh, "fresh dir must not be flagged stale"
    assert_includes selected, stale, "100-day-old dir must be flagged stale"
  ensure
    FileUtils.rm_rf(fresh) if fresh
    FileUtils.rm_rf(stale) if stale
  end
end
