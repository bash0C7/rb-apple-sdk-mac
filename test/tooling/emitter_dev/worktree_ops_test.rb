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
end
