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
        next unless File.directory?(target)

        link = File.join(dst, dir)
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

    # Returns paths of git worktrees whose directory mtime is older than
    # `older_than_days` days ago. Caller is responsible for invoking
    # `git worktree remove` (we never auto-delete; HITL gate principle —
    # only present, do not destroy).
    def stale_paths(older_than_days:)
      out, _, status = Open3.capture3("git", "worktree", "list", "--porcelain")
      return [] unless status.success?

      paths = out.scan(/^worktree (.+)$/).flatten
      filter_stale(paths, older_than_days: older_than_days)
    end

    def filter_stale(paths, older_than_days:)
      cutoff = Time.now - (older_than_days * 86_400)
      paths.select do |p|
        next false unless File.directory?(p)
        File.mtime(p) < cutoff
      end
    end
  end
end
