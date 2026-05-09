# frozen_string_literal: true
require "fileutils"
require "open3"

module EmitterDev
  module WorktreeOps
    class WorktreeError < StandardError; end

    module_function

    def add(branch:, base:, path:)
      _, err, status = Open3.capture3("git", "worktree", "add", "-b", branch, path, base)
      raise WorktreeError, "worktree add failed: #{err}" unless status.success?
    end

    def populate_cache(worktree_path:, main_root:, sdk_version:)
      src = File.join(main_root, ".rb-apple-sdk-mac", sdk_version)
      dst = File.join(worktree_path, ".rb-apple-sdk-mac", sdk_version)
      FileUtils.mkdir_p(dst)
      %w[knowledge sources lib].each do |dir|
        target = File.join(src, dir)
        link   = File.join(dst, dir)
        File.symlink(target, link) unless File.exist?(link) || File.symlink?(link)
      end
      cache_src = File.join(src, "cache.sqlite")
      cache_dst = File.join(dst, "cache.sqlite")
      FileUtils.cp(cache_src, cache_dst) if File.exist?(cache_src) && !File.exist?(cache_dst)
    end

    def remove(path)
      _, err, status = Open3.capture3("git", "worktree", "remove", path)
      raise WorktreeError, "worktree remove failed: #{err}" unless status.success?
    end
  end
end
