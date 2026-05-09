# frozen_string_literal: true
#
# Rake tasks for the HITL emitter-improvement workflow.
#
# Thin orchestrators only — every task is load → call EmitterDev module → format.
# Module APIs live under tooling/lib/emitter_dev/. See:
#   docs/superpowers/specs/2026-05-09-hitl-emitter-improvement-design.md  (Section 7)
#   docs/superpowers/plans/2026-05-09-hitl-emitter-improvement.md         (Task 1.6)
#
# Note: CandidateRanker is a stateless module form
# (`EmitterDev::CandidateRanker.rank(rows:, mode:, top:)`), not the
# class form sketched in the spec. SQLite read is delegated to
# `EmitterDev::Sources::CompileHistory#aggregate`.

require "json"
require "fileutils"
require "open3"

_emitter_lib = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(_emitter_lib) unless $LOAD_PATH.include?(_emitter_lib)

require "emitter_dev/branch_ops"
require "emitter_dev/worktree_ops"
require "emitter_dev/candidate_ranker"
require "emitter_dev/source_compile_history"
require "emitter_dev/fact_bundler"

namespace :apple do
  namespace :emitter do
    desc "Aggregate compile_history and rank candidates (MODE=add|all TOP=N OUT=path)"
    task :candidates do
      mode         = ENV.fetch("MODE", "add")
      top          = Integer(ENV.fetch("TOP", "10"))
      out          = ENV.fetch("OUT", "tmp/emitter/candidates.json")
      project_root = Dir.pwd
      sdk_version  = ENV.fetch("SDK_VERSION") { detect_sdk_version(project_root) }
      db_path      = File.join(project_root, ".rb-apple-sdk-mac", sdk_version, "cache.sqlite")

      rows   = EmitterDev::Sources::CompileHistory.new(db_path).aggregate
      result = EmitterDev::CandidateRanker.rank(rows: rows, mode: mode, top: top)

      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, JSON.pretty_generate(result))
      puts "wrote #{result.fetch('candidates').size} candidates to #{out}"
    end

    desc "Create worktree + branch + populate cache for picked candidate (CANDIDATE_ID=N BASE=branch)"
    task :worktree_create do
      cid             = Integer(ENV.fetch("CANDIDATE_ID"))
      base            = ENV.fetch("BASE") { current_branch }
      candidates_file = ENV.fetch("CANDIDATES", "tmp/emitter/candidates.json")
      sdk_version     = ENV.fetch("SDK_VERSION") { detect_sdk_version(Dir.pwd) }

      payload = JSON.parse(File.read(candidates_file))
      cand    = payload.fetch("candidates").find { |c| c["id"] == cid }
      raise "candidate #{cid} not found in #{candidates_file}" unless cand

      branch_name   = EmitterDev::BranchOps.derive_name(cand)
      worktree_path = "../rb-apple-sdk-mac-emitter-#{cid}"

      EmitterDev::WorktreeOps.add(branch: branch_name, base: base, path: worktree_path)
      EmitterDev::WorktreeOps.populate_cache(
        worktree_path: worktree_path, main_root: Dir.pwd, sdk_version: sdk_version
      )

      branch_json = "tmp/emitter/branch_#{branch_name.tr('/', '_')}.json"
      FileUtils.mkdir_p(File.dirname(branch_json))
      File.write(branch_json, JSON.pretty_generate(cand.merge(
        "branch"        => branch_name,
        "base"          => base,
        "worktree_path" => worktree_path,
      )))

      puts worktree_path
      puts "branch=#{branch_name}"
      puts "branch_json=#{branch_json}"
    end

    desc "Compose fact bundle markdown from tmp/emitter/* (BRANCH=name BASE=branch OUT=path)"
    task :fact_bundle do
      branch = ENV.fetch("BRANCH")
      base   = ENV.fetch("BASE") { current_branch }
      slug   = branch.tr("/", "_")
      out    = ENV.fetch("OUT", "tmp/emitter/fact_#{slug}.md")

      bundler = EmitterDev::FactBundler.new(branch: branch, base: base)
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, bundler.compose)
      puts out
    end

    desc "Non-ff merge improvement branch back into base (BRANCH=name BASE=branch WORKTREE_PATH=path)"
    task :merge do
      branch = ENV.fetch("BRANCH")
      base   = ENV.fetch("BASE") { current_branch }
      wp     = ENV.fetch("WORKTREE_PATH")

      EmitterDev::BranchOps.checkout(base)
      EmitterDev::BranchOps.merge_no_ff(branch)
      EmitterDev::WorktreeOps.remove(wp)
      EmitterDev::BranchOps.delete_branch(branch)
      puts "merged #{branch} into #{base} (no-ff), worktree #{wp} removed"
    end

    def detect_sdk_version(project_root)
      candidates = Dir.glob(File.join(project_root, ".rb-apple-sdk-mac", "*"))
                      .select { |p| File.directory?(p) && File.basename(p) =~ /\A\d+\.\d+\z/ }
      raise "could not detect SDK version under #{File.join(project_root, '.rb-apple-sdk-mac')}/" if candidates.empty?
      File.basename(candidates.sort.last)
    end

    def current_branch
      out, err, status = Open3.capture3("git", "rev-parse", "--abbrev-ref", "HEAD")
      raise "git rev-parse --abbrev-ref HEAD failed: #{err}" unless status.success?
      out.strip
    end
  end
end
