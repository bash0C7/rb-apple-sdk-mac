# frozen_string_literal: true
require "open3"

module EmitterDev
  class FactBundler
    def initialize(branch:, base:)
      @branch = branch
      @base   = base
      @slug   = branch.tr("/", "_")
    end

    def compose
      sections = [
        section_header,
        section_branch_commits,
        section_diff_stat,
        section_design,
        section_regression,
        section_individual_verification,
        section_compile_history_delta,
      ]
      sections.join("\n\n")
    end

    private

    def section_header
      "# Fact bundle: #{@branch}\nbase: #{@base}"
    end

    def section_design
      content = read_artifact("tmp/emitter/design_#{@slug}.md")
      "## design\n#{content}"
    end

    def section_branch_commits
      out, _ = Open3.capture2("git", "log", "--oneline", "#{@base}..#{@branch}")
      "## branch & commits\n#{out.strip}"
    end

    def section_diff_stat
      out, _ = Open3.capture2("git", "diff", "--stat", "#{@base}..#{@branch}")
      "## diff stat\n#{out.strip}"
    end

    def section_regression
      content = read_artifact("tmp/emitter/regression_#{@slug}.txt")
      "## regression\n#{content}"
    end

    def section_individual_verification
      content = read_artifact("tmp/emitter/verify_#{@slug}.txt")
      "## individual verification\n#{content}"
    end

    def section_compile_history_delta
      content = read_artifact("tmp/emitter/compile_history_#{@slug}.txt")
      "## compile_history delta\n#{content}"
    end

    def read_artifact(path)
      return "<missing: #{path}>" unless File.exist?(path)
      File.read(path).strip
    end
  end
end
