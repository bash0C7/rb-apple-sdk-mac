# frozen_string_literal: true
require "open3"

module EmitterDev
  module BranchOps
    DateFormat    = "%Y%m%d"
    MaxSuffix     = 5

    class BranchError < StandardError; end

    module_function

    def derive_name(candidate)
      mode = candidate.fetch("mode")
      slug = candidate.fetch("summary").downcase
                       .gsub(/[^a-z0-9]+/, "-")
                       .gsub(/^-+|-+$/, "")[0, 60]
      date = Time.now.strftime(DateFormat)
      base = "emitter/#{mode}-#{slug}-#{date}"
      MaxSuffix.times do |i|
        name = i.zero? ? base : "#{base}-#{i + 1}"
        return name unless branch_exists?(name)
      end
      raise BranchError, "could not derive unique branch name from base: #{base}"
    end

    def branch_exists?(name)
      _, _, status = Open3.capture3("git", "rev-parse", "--verify", "--quiet", name)
      status.success?
    end

    def checkout(branch)
      _, err, status = Open3.capture3("git", "checkout", branch)
      raise BranchError, "checkout failed: #{err}" unless status.success?
    end

    def merge_no_ff(branch)
      _, err, status = Open3.capture3("git", "merge", "--no-ff", "--no-edit", branch)
      raise BranchError, "merge --no-ff failed: #{err}" unless status.success?
    end

    def delete_branch(branch)
      _, err, status = Open3.capture3("git", "branch", "-d", branch)
      raise BranchError, "branch -d failed: #{err}" unless status.success?
    end
  end
end
