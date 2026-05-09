# HITL Emitter Improvement Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `/rb-apple-sdk-mac-improve-emitter` slash command + Rake tasks + helper Ruby modules that lets the maintainer iterate on static emitter coverage with a 2-gate (pick + fact-review) HITL loop, isolated in a git worktree.

**Architecture:** Skill (slash command) drives the workflow in main agent context. Rake tasks (`apple:emitter:*`) handle mechanical operations: candidate aggregation, worktree create + cache populate, fact bundle compose, non-ff merge. Implementer subagent (`general-purpose`) runs autonomously inside the worktree for design + TDD + test-unit-based verification. Two reviewer subagents (`feature-dev:code-reviewer`) gate the implementer per `subagent-driven-development` skill.

**Tech Stack:** Ruby 4.0.3 / test-unit 3.x / SQLite3 (via `rb-apple-sdk-knowledge` sub-gem) / `parser` gem (H-2, AST scan) / Claude Code skill + agent definitions / git worktree.

**Spec reference:** `docs/superpowers/specs/2026-05-09-hitl-emitter-improvement-design.md` (commit `0dd7209`).

**TDD discipline (`~/dev/src/CLAUDE.md`):** RED commit と GREEN commit は別 commit。 REFACTOR は不要ならスキップ可。

---

## File Structure

### Created

```
tooling/lib/emitter_dev/branch_ops.rb               # branch derive / checkout / merge / delete
tooling/lib/emitter_dev/worktree_ops.rb             # worktree add / populate_cache / remove
tooling/lib/emitter_dev/source_compile_history.rb   # SQLite reader
tooling/lib/emitter_dev/source_llm_log.rb           # error_stage 集計 (compile_history 共有)
tooling/lib/emitter_dev/redundancy_scanner.rb       # marshallers.rb AST scan (H-2)
tooling/lib/emitter_dev/candidate_ranker.rb         # 4 source 集約 + ranking
tooling/lib/emitter_dev/fact_bundler.rb             # tmp/emitter/* 連結 → markdown
tooling/lib/tasks/emitter.rake                      # 4 Rake task 定義
tooling/README.md                                   # tooling/ 趣旨
.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md
.claude/agents/emitter-implementer.md
test/tooling/emitter_dev/branch_ops_test.rb
test/tooling/emitter_dev/worktree_ops_test.rb
test/tooling/emitter_dev/source_compile_history_test.rb
test/tooling/emitter_dev/redundancy_scanner_test.rb
test/tooling/emitter_dev/candidate_ranker_test.rb
test/tooling/emitter_dev/fact_bundler_test.rb
test/tooling/emitter_dev/end_to_end_test.rb
test/fixtures/emitter_dev/sample_marshallers.rb     # redundancy_scanner fixture
```

### Modified

```
Rakefile                                             # libs に tooling/lib 追加 + emitter.rake load
Gemfile                                              # H-2 で parser gem 追加
```

---

## Phase H-1: Minimum Viable Add Path

H-1 完了条件: 1 candidate を end-to-end で pick → worktree → implementer → fact bundle → merge できる。 trim mode と Claude session source は無し、 add mode のみ。

---

### Task 1.1: BranchOps — branch name derive + git ops

**Files:**
- Create: `tooling/lib/emitter_dev/branch_ops.rb`
- Test:   `test/tooling/emitter_dev/branch_ops_test.rb`

- [ ] **Step 1: Write the failing test for `derive_name`**

```ruby
# test/tooling/emitter_dev/branch_ops_test.rb
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "emitter_dev/branch_ops"

class BranchOpsTest < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    Dir.chdir(@tmpdir) do
      system "git init -q --initial-branch=main"
      system "git config user.email t@x"
      system "git config user.name t"
      File.write("a", "a"); system "git add a && git commit -qm init"
    end
    @prev_pwd = Dir.pwd
    Dir.chdir(@tmpdir)
  end

  def teardown
    Dir.chdir(@prev_pwd)
    FileUtils.rm_rf(@tmpdir)
  end

  def test_derive_name_basic
    cand = { "mode" => "add", "summary" => "AVCaptureDevice devicesWithMediaType static emitter" }
    name = EmitterDev::BranchOps.derive_name(cand)
    assert_match %r{\Aemitter/add-avcapturedevice-deviceswithmediatype-static-emitter-\d{8}\z}, name
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/branch_ops_test.rb`
Expected: `LoadError: cannot load such file -- emitter_dev/branch_ops` (or NameError on EmitterDev::BranchOps).

- [ ] **Step 3: Commit RED**

```bash
git add test/tooling/emitter_dev/branch_ops_test.rb
git commit -m "test: RED — BranchOps.derive_name spec"
```

- [ ] **Step 4: Implement minimal BranchOps**

```ruby
# tooling/lib/emitter_dev/branch_ops.rb
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
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/branch_ops_test.rb`
Expected: `1 tests, 1 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/branch_ops.rb
git commit -m "feat(tooling): GREEN — BranchOps.derive_name minimal impl"
```

- [ ] **Step 7: Add suffix-collision test (RED)**

Append to `test/tooling/emitter_dev/branch_ops_test.rb`:

```ruby
  def test_derive_name_collision_uses_suffix
    system "git checkout -qb emitter/add-foo-#{Time.now.strftime('%Y%m%d')} 2>/dev/null"
    system "git checkout -q main"
    cand = { "mode" => "add", "summary" => "foo" }
    name = EmitterDev::BranchOps.derive_name(cand)
    assert_match %r{-2\z}, name, "expected -2 suffix when base name exists"
  end
```

Run, verify fail (= test passes if suffix not yet implemented? actually MaxSuffix loop already handles. let me re-check — initial implementation already handles suffix. So this test will pass without code change. Move to GREEN commit if passes.)

- [ ] **Step 8: Commit suffix-collision test as combined RED+GREEN**

If test passes immediately on first run (because Step 4 implementation already supports it), commit as:
```bash
git add test/tooling/emitter_dev/branch_ops_test.rb
git commit -m "test: add collision-suffix coverage for BranchOps.derive_name"
```

If it fails, fix BranchOps and commit RED then GREEN as separate commits per CLAUDE.md.

---

### Task 1.2: WorktreeOps — git worktree add / populate_cache / remove

**Files:**
- Create: `tooling/lib/emitter_dev/worktree_ops.rb`
- Test:   `test/tooling/emitter_dev/worktree_ops_test.rb`

- [ ] **Step 1: Write the failing test for `populate_cache`**

```ruby
# test/tooling/emitter_dev/worktree_ops_test.rb
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
```

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/worktree_ops_test.rb`
Expected: LoadError on `emitter_dev/worktree_ops`.

- [ ] **Step 3: Commit RED**

```bash
git add test/tooling/emitter_dev/worktree_ops_test.rb
git commit -m "test: RED — WorktreeOps.populate_cache spec"
```

- [ ] **Step 4: Implement WorktreeOps**

```ruby
# tooling/lib/emitter_dev/worktree_ops.rb
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
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/worktree_ops_test.rb`
Expected: `1 tests, 5 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/worktree_ops.rb
git commit -m "feat(tooling): GREEN — WorktreeOps.populate_cache impl"
```

---

### Task 1.3: CompileHistory source reader

**Files:**
- Create: `tooling/lib/emitter_dev/source_compile_history.rb`
- Test:   `test/tooling/emitter_dev/source_compile_history_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/tooling/emitter_dev/source_compile_history_test.rb
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "sqlite3"
require "emitter_dev/source_compile_history"

class SourceCompileHistoryTest < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir
    @db_path = File.join(@tmp, "cache.sqlite")
    db = SQLite3::Database.new(@db_path)
    db.execute_batch <<~SQL
      CREATE TABLE compile_history (
        framework    TEXT, symbol       TEXT,
        generator    TEXT, retry_count  INTEGER,
        error_stage  TEXT, error_detail TEXT
      );
      INSERT INTO compile_history VALUES ('AVFoundation', 'devicesWithMediaType:', 'llm', 2, 'template_nil', NULL);
      INSERT INTO compile_history VALUES ('AVFoundation', 'devicesWithMediaType:', 'llm', 3, 'template_nil', NULL);
      INSERT INTO compile_history VALUES ('CoreAudio',    'AudioObjectGetPropertyDataSize', 'template', 0, NULL, NULL);
    SQL
    db.close
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_aggregate_returns_only_llm_seen_symbols
    rows = EmitterDev::Sources::CompileHistory.new(@db_path).aggregate
    assert_equal 1, rows.size
    r = rows.first
    assert_equal "AVFoundation", r["framework"]
    assert_equal "devicesWithMediaType:", r["symbol"]
    assert_equal 2, r["llm_count"]
    assert_in_delta 2.5, r["avg_retry"], 0.001
    assert_includes r["error_stages"], "template_nil"
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/source_compile_history_test.rb`
Expected: LoadError.

- [ ] **Step 3: Commit RED**

```bash
git add test/tooling/emitter_dev/source_compile_history_test.rb
git commit -m "test: RED — Sources::CompileHistory#aggregate spec"
```

- [ ] **Step 4: Implement CompileHistory reader**

```ruby
# tooling/lib/emitter_dev/source_compile_history.rb
# frozen_string_literal: true
require "sqlite3"

module EmitterDev
  module Sources
    class CompileHistory
      class CacheNotFoundError < StandardError; end

      def initialize(sqlite_path)
        @sqlite_path = sqlite_path
      end

      def aggregate
        unless File.exist?(@sqlite_path)
          raise CacheNotFoundError,
            "compile_history db not found: #{@sqlite_path}\n" \
            "run `bundle exec rake apple:knowledge:rebuild` first."
        end
        db = SQLite3::Database.new(@sqlite_path)
        db.results_as_hash = true
        rows = db.execute(<<~SQL)
          SELECT framework, symbol,
                 SUM(CASE WHEN generator = 'llm'      THEN 1 ELSE 0 END) AS llm_count,
                 SUM(CASE WHEN generator = 'template' THEN 1 ELSE 0 END) AS tpl_count,
                 AVG(CASE WHEN generator = 'llm' THEN retry_count END)   AS avg_retry,
                 group_concat(DISTINCT error_stage)                       AS error_stages
          FROM compile_history
          GROUP BY framework, symbol
          HAVING llm_count > 0
          ORDER BY llm_count DESC, avg_retry DESC
        SQL
        rows.map do |r|
          {
            "framework"    => r["framework"],
            "symbol"       => r["symbol"],
            "llm_count"    => r["llm_count"].to_i,
            "tpl_count"    => r["tpl_count"].to_i,
            "avg_retry"    => (r["avg_retry"] || 0.0).to_f,
            "error_stages" => (r["error_stages"] || "").split(",").map(&:strip).reject(&:empty?).uniq,
          }
        end
      ensure
        db&.close
      end
    end
  end
end
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/source_compile_history_test.rb`
Expected: `1 tests, 5 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/source_compile_history.rb
git commit -m "feat(tooling): GREEN — Sources::CompileHistory#aggregate impl"
```

---

### Task 1.4: CandidateRanker (add mode)

**Files:**
- Create: `tooling/lib/emitter_dev/candidate_ranker.rb`
- Test:   `test/tooling/emitter_dev/candidate_ranker_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/tooling/emitter_dev/candidate_ranker_test.rb
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "sqlite3"
require "emitter_dev/candidate_ranker"

class CandidateRankerTest < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir
    @sdk = "26.2"
    project_dir = File.join(@tmp, ".rb-apple-sdk-mac", @sdk)
    FileUtils.mkdir_p(project_dir)
    db = SQLite3::Database.new(File.join(project_dir, "cache.sqlite"))
    db.execute_batch <<~SQL
      CREATE TABLE compile_history (
        framework TEXT, symbol TEXT, generator TEXT,
        retry_count INTEGER, error_stage TEXT, error_detail TEXT
      );
      INSERT INTO compile_history VALUES ('A', 'sym1', 'llm', 3, 'template_nil', NULL);
      INSERT INTO compile_history VALUES ('A', 'sym1', 'llm', 2, 'template_nil', NULL);
      INSERT INTO compile_history VALUES ('B', 'sym2', 'llm', 1, 'swiftc', NULL);
      INSERT INTO compile_history VALUES ('C', 'sym3', 'template', 0, NULL, NULL);
    SQL
    db.close
    @project_root = @tmp
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_rank_add_mode_sorts_by_score_descending
    ranker = EmitterDev::CandidateRanker.new(project_root: @project_root, sdk_version: @sdk)
    out = ranker.rank(mode: "add", top: 5)
    cs = out.fetch("candidates")
    assert_equal 2, cs.size
    assert_equal "sym1", cs[0].fetch("evidence").fetch("compile_history").fetch("symbol")
    assert_equal "add", cs[0].fetch("mode")
    assert cs[0].fetch("score") > cs[1].fetch("score"), "sym1 should outrank sym2"
    assert_equal "all", out.fetch("mode") == "add" ? "add" : "all"  # mode echoed
  end

  def test_rank_excludes_template_only_symbols
    ranker = EmitterDev::CandidateRanker.new(project_root: @project_root, sdk_version: @sdk)
    out = ranker.rank(mode: "add", top: 5)
    syms = out.fetch("candidates").map { |c| c.fetch("evidence").fetch("compile_history").fetch("symbol") }
    refute_includes syms, "sym3"
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/candidate_ranker_test.rb`
Expected: LoadError.

- [ ] **Step 3: Commit RED**

```bash
git add test/tooling/emitter_dev/candidate_ranker_test.rb
git commit -m "test: RED — CandidateRanker#rank add-mode spec"
```

- [ ] **Step 4: Implement CandidateRanker (add mode only)**

```ruby
# tooling/lib/emitter_dev/candidate_ranker.rb
# frozen_string_literal: true
require "json"
require "time"
require "emitter_dev/source_compile_history"

module EmitterDev
  class CandidateRanker
    def initialize(project_root:, sdk_version:)
      @project_root = project_root
      @sdk_version  = sdk_version
    end

    def rank(mode:, top:)
      candidates = []
      candidates += rank_add  if %w[add all].include?(mode)
      candidates.sort_by! { |c| -c["score"] }
      candidates = candidates.first(top)
      candidates.each_with_index { |c, i| c["id"] = i + 1 }
      {
        "generated_at" => Time.now.utc.iso8601,
        "mode"         => mode,
        "top"          => top,
        "candidates"   => candidates,
      }
    end

    private

    def rank_add
      db_path = File.join(@project_root, ".rb-apple-sdk-mac", @sdk_version, "cache.sqlite")
      Sources::CompileHistory.new(db_path).aggregate.map do |row|
        score = (row["llm_count"] * 10) +
                (row["avg_retry"] * 3) +
                (row["error_stages"].include?("template_nil") ? 5 : 0) -
                (row["tpl_count"] * 1)
        {
          "mode"               => "add",
          "score"              => score.round(1),
          "summary"             => "#{row['framework']} / #{row['symbol']} の static emitter 追加",
          "evidence"           => {
            "compile_history" => row,
          },
          "recommended_action" => "compile_history で LLM 経路に流れとる #{row['symbol']} を template path に乗せる",
        }
      end
    end
  end
end
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/candidate_ranker_test.rb`
Expected: `2 tests, 5 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/candidate_ranker.rb
git commit -m "feat(tooling): GREEN — CandidateRanker add-mode impl"
```

---

### Task 1.5: FactBundler

**Files:**
- Create: `tooling/lib/emitter_dev/fact_bundler.rb`
- Test:   `test/tooling/emitter_dev/fact_bundler_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/tooling/emitter_dev/fact_bundler_test.rb
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "emitter_dev/fact_bundler"

class FactBundlerTest < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir
    Dir.chdir(@tmp) do
      system "git init -q --initial-branch=main"
      system "git config user.email t@x; git config user.name t"
      File.write("a", "1"); system "git add a && git commit -qm base"
      system "git checkout -qb emitter/test-fix"
      File.write("b", "2"); system "git add b && git commit -qm fix"
    end
    @prev = Dir.pwd; Dir.chdir(@tmp)
    FileUtils.mkdir_p("tmp/emitter")
    File.write("tmp/emitter/regression_emitter_test-fix.txt", "489 tests, 2105 assertions, 0 failures, 0 errors\n")
    File.write("tmp/emitter/verify_emitter_test-fix.txt",     "1 tests, 2 assertions, 0 failures, 0 errors\n")
    File.write("tmp/emitter/compile_history_emitter_test-fix.txt", "new template row: A/sym1\n")
  end

  def teardown
    Dir.chdir(@prev); FileUtils.rm_rf(@tmp)
  end

  def test_compose_includes_all_sections
    md = EmitterDev::FactBundler.new(branch: "emitter/test-fix", base: "main").compose
    assert_match(/## branch & commits/, md)
    assert_match(/## diff stat/, md)
    assert_match(/## regression/, md)
    assert_match(/489 tests/, md)
    assert_match(/## individual verification/, md)
    assert_match(/## compile_history delta/, md)
    assert_match(/new template row/, md)
  end

  def test_compose_marks_missing_artifact
    File.delete("tmp/emitter/verify_emitter_test-fix.txt")
    md = EmitterDev::FactBundler.new(branch: "emitter/test-fix", base: "main").compose
    assert_match(/<missing: tmp\/emitter\/verify_emitter_test-fix\.txt>/, md)
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/fact_bundler_test.rb`
Expected: LoadError.

- [ ] **Step 3: Commit RED**

```bash
git add test/tooling/emitter_dev/fact_bundler_test.rb
git commit -m "test: RED — FactBundler#compose spec"
```

- [ ] **Step 4: Implement FactBundler**

```ruby
# tooling/lib/emitter_dev/fact_bundler.rb
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
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/fact_bundler_test.rb`
Expected: `2 tests, 8 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/fact_bundler.rb
git commit -m "feat(tooling): GREEN — FactBundler#compose impl"
```

---

### Task 1.6: Rake tasks (4) — emitter.rake

**Files:**
- Create: `tooling/lib/tasks/emitter.rake`
- Test:   `test/tooling/emitter_dev/end_to_end_test.rb` (later, Task 1.11)

- [ ] **Step 1: Write the rake file (no TDD test for rake glue, integration test in Task 1.11 covers chaining)**

```ruby
# tooling/lib/tasks/emitter.rake
# frozen_string_literal: true
require "json"
require "fileutils"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "emitter_dev/branch_ops"
require "emitter_dev/worktree_ops"
require "emitter_dev/candidate_ranker"
require "emitter_dev/fact_bundler"

namespace :apple do
  namespace :emitter do
    desc "Aggregate sources and rank emitter improvement candidates (MODE=add|trim|all TOP=N OUT=path)"
    task :candidates do
      mode = ENV.fetch("MODE", "all")
      top  = Integer(ENV.fetch("TOP", "10"))
      out  = ENV.fetch("OUT", "tmp/emitter/candidates.json")
      project_root = Dir.pwd
      sdk_version  = ENV.fetch("SDK_VERSION") { detect_sdk_version(project_root) }

      ranker = EmitterDev::CandidateRanker.new(project_root: project_root, sdk_version: sdk_version)
      json   = ranker.rank(mode: mode, top: top)
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, JSON.pretty_generate(json))
      puts "wrote #{json.fetch('candidates').size} candidates to #{out}"
    end

    desc "Create worktree + branch + populate cache for picked candidate (CANDIDATE_ID=N BASE=branch)"
    task :worktree_create do
      cid    = Integer(ENV.fetch("CANDIDATE_ID"))
      base   = ENV.fetch("BASE", current_branch)
      candidates_file = ENV.fetch("CANDIDATES", "tmp/emitter/candidates.json")
      payload = JSON.parse(File.read(candidates_file))
      cand    = payload.fetch("candidates").find { |c| c["id"] == cid }
      raise "candidate #{cid} not found in #{candidates_file}" unless cand

      branch_name   = EmitterDev::BranchOps.derive_name(cand)
      worktree_path = "../rb-apple-sdk-mac-emitter-#{cid}"
      sdk_version   = ENV.fetch("SDK_VERSION") { detect_sdk_version(Dir.pwd) }

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
      base   = ENV.fetch("BASE", current_branch)
      slug   = branch.tr("/", "_")
      out    = ENV.fetch("OUT", "tmp/emitter/fact_#{slug}.md")
      bundler = EmitterDev::FactBundler.new(branch: branch, base: base)
      File.write(out, bundler.compose)
      puts out
    end

    desc "Non-ff merge improvement branch back into base (BRANCH=name BASE=branch WORKTREE_PATH=path)"
    task :merge do
      branch = ENV.fetch("BRANCH")
      base   = ENV.fetch("BASE", current_branch)
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
      raise "could not detect SDK version under .rb-apple-sdk-mac/" if candidates.empty?
      File.basename(candidates.sort.last)
    end

    def current_branch
      out, = Open3.capture2("git", "rev-parse", "--abbrev-ref", "HEAD")
      out.strip
    end
  end
end
```

- [ ] **Step 2: Smoke verify task names registered**

Run: `bundle exec rake -T apple:emitter:`
Expected stdout (4 task lines):
```
rake apple:emitter:candidates       # Aggregate sources...
rake apple:emitter:fact_bundle      # Compose fact bundle...
rake apple:emitter:merge            # Non-ff merge...
rake apple:emitter:worktree_create  # Create worktree...
```

(rake -T won't list yet because Rakefile hasn't loaded emitter.rake — that's Task 1.7.)

- [ ] **Step 3: Commit Rake file**

```bash
git add tooling/lib/tasks/emitter.rake
git commit -m "feat(tooling): add 4 Rake tasks under apple:emitter namespace"
```

---

### Task 1.7: Rakefile load + libs update

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Add tooling/lib to TestTask libs and load emitter.rake**

Edit `Rakefile`. Locate the existing `Rake::TestTask.new(:test)` block and add `t.libs << "tooling/lib"`. At end of file, append `load "tooling/lib/tasks/emitter.rake"`.

After:

```ruby
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.libs << "tooling/lib"
  t.test_files = FileList["test/**/*_test.rb", "knowledge/test/test_*.rb"]
end

# ... existing namespaces ...

load "tooling/lib/tasks/emitter.rake"
```

- [ ] **Step 2: Verify rake -T sees new tasks**

Run: `bundle exec rake -T apple:emitter:`
Expected: 4 task lines visible.

- [ ] **Step 3: Verify all unit tests still pass via subagent dispatch**

Per CLAUDE.md "Test Execution Delegation": dispatch `general-purpose` subagent to run `bundle exec rake test`, return only count + pass/fail. Expected: prior count + 4 new tests added by Tasks 1.1-1.5 = +4 cases, 0 failures.

- [ ] **Step 4: Commit Rakefile change**

```bash
git add Rakefile
git commit -m "chore(rakefile): load tooling/lib/tasks/emitter.rake and add tooling/lib to test load path"
```

---

### Task 1.8: Subagent definition (`.claude/agents/emitter-implementer.md`)

**Files:**
- Create: `.claude/agents/emitter-implementer.md`

- [ ] **Step 1: Write the agent definition markdown**

Create `.claude/agents/emitter-implementer.md` with this exact content:

````markdown
---
name: emitter-implementer
description: rb-apple-sdk-mac の HITL emitter improvement workflow で dispatched される implementer subagent。 git worktree 内で 1 candidate の static emitter 追加 / 冗長削減を TDD で完成させ、 verification を test-unit assert に乗せ、 fact bundle 用 raw artifact を生成する。
---

# Emitter Implementer Agent

## Inputs (controller が prompt 内で埋め込む)

```
__CANDIDATE_JSON__   # candidate 詳細 JSON (mode/score/summary/evidence/recommended_action)
__BRANCH_NAME__      # 既に作られとる branch name
__BASE_BRANCH__      # 比較先 branch (例: feature/v1.2-bootstrap-principle)
__WORKTREE_PATH__    # 作業ディレクトリ (= worktree)。 全操作はこの中で
```

## Mandatory steps

1. **`cd __WORKTREE_PATH__`** を最初に実行。 全 Bash / Edit / Write はここから。 main repo を一切触らへん。

2. **Example resolution (自律)**:
   - `examples/*.rb` を Glob + Read で全 scan
   - `__CANDIDATE_JSON__` の `evidence.compile_history.symbol` を直接呼ぶ example 探す
   - 該当あれば採用。 無ければ Apple developer documentation を WebFetch (`https://developer.apple.com/documentation/<framework>/<symbol>` 形)、 Knowledge Base SQLite を query して signature 把握、 既存 examples の skeleton (`require "apple_sdk_mac"; AppleSDKMac.bootstrap!; ...`) に倣って **新規 example を作って commit** する
   - user に質問せえへん。 確信持てない場合は最も近い既存 example fallback で進めて fact bundle に明示

3. **Design markdown** を `tmp/emitter/design_<branch>.md` に書く:
   - 新 marshaller class outline / REGISTRY entry / `broken?` trigger / 既存 caller の改変箇所 / 想定 test cases
   - trim mode なら統合先 + caller migration + 既存 test preservation 戦略

4. **TDD cycle** (CLAUDE.md 準拠):
   - **RED commit**: 失敗 test のみ — `test: RED — <feature>`
   - **GREEN commit**: 最小実装 — `feat: GREEN — <feature>`
   - **REFACTOR commit** (任意): 振る舞い変化ゼロ — `refactor: <what>`
   - 各 commit 末尾に `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`

5. **Examples e2e wrapper** を整備:
   - `test/integration/examples_<framework>_e2e_test.rb` の test class を新規 / 拡張
   - 該当 example 起動 → exit code + stdout を `assert_*` で検査
   - test method 名を fact bundle に書ける形 (`test_<example_name>`)

6. **Regression** 確認:
   - `bundle exec rake test 2>&1 | tee tmp/emitter/regression_<sanitized_branch>.txt`
   - 0 failures / 0 errors / 0 pendings 必須。 失敗あれば fix し直して再実行

7. **Individual verification**:
   - `bundle exec rake test TEST=<file> TESTOPTS="-n <method>" 2>&1 | tee tmp/emitter/verify_<sanitized_branch>.txt`

8. **compile_history delta**:
   - `sqlite3 .rb-apple-sdk-mac/<sdk>/cache.sqlite "SELECT framework, symbol, generator, COUNT(*) FROM compile_history WHERE symbol = '<sym>' GROUP BY generator" > tmp/emitter/compile_history_<sanitized_branch>.txt`

9. **Final message**:
   - 1 行目: status code (`DONE` / `DONE_WITH_CONCERNS` / `BLOCKED`)
   - 続けて raw artifact path 一覧 (regression / verify / compile_history / design)
   - 「うまくいきました」 系の自己評価サマリは書かない

## 禁止事項

- main / __BASE_BRANCH__ への直 commit (worktree 内 branch のみ)
- `--no-verify` / `--amend` (hook fail 時は新 commit 作る)
- `__CANDIDATE_JSON__` 範囲外への scope creep
- 「KB」略称使用 — user 露出箇所は常に「Knowledge Base」
- `rescue nil` / `rescue ... => _` で silent swallow
- `omit "reason"` (test-unit 3.7.7 omit bug)、 pending 不要なら test method を commit-out
- `rm -rf` 直叩き (cache 操作は rake task 経由)
- 推測で kind 値書く — `sqlite3 ... "SELECT DISTINCT kind FROM symbols"` で verify してから書く
- raise + puts の自作 verification report — 必ず test-unit `assert_*` 経由

## Status codes

- `DONE`: 1〜9 全成功
- `DONE_WITH_CONCERNS`: 動いとるが懸念あり (例: fallback example 採用、 indirect coverage)
- `BLOCKED`: 自律探索しても進まへん real blocker (rake test green にならへん / WebFetch 全 fail / SQLite corrupt 等)
````

- [ ] **Step 2: Verify file exists and is readable**

Run: `head -5 .claude/agents/emitter-implementer.md`
Expected: frontmatter `---` + name + description fields visible.

- [ ] **Step 3: Commit agent definition**

```bash
git add .claude/agents/emitter-implementer.md
git commit -m "feat(claude): add emitter-implementer subagent definition"
```

---

### Task 1.9: Skill definition (`.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`)

**Files:**
- Create: `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`

- [ ] **Step 1: Write the SKILL.md**

Create `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`:

````markdown
---
name: rb-apple-sdk-mac-improve-emitter
description: rb-apple-sdk-mac の static emitter coverage を継続改善する HITL workflow。 candidate を compile_history / LLM log / Claude session log / static redundancy scan から ranking 提示 → user pick → git worktree 切って implementer subagent dispatch → fact bundle で 「実行された事実 (test stdout / git diff / e2e log)」 を user に提示 → OK で non-ff merge / NG で session 内対話継続。
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent, AskUserQuestion
---

# Improve Emitter (HITL Loop)

## Workflow

### 1. Candidate aggregation

```bash
bundle exec rake apple:emitter:candidates MODE=$MODE TOP=$TOP OUT=tmp/emitter/candidates.json
```

mode は `add` / `trim` / `all` (default `all`)。 top 件数は `--top=N` (default 10)。

ranker output (`tmp/emitter/candidates.json`) を Read。 さらに **chiebukuro_query_claude_session の hit を別 subagent で取得** (helper Ruby は MCP 直叩きしない):

```ruby
Agent({
  description: "Query Claude session log for top candidate symbols",
  subagent_type: "general-purpose",
  prompt: "Use chiebukuro_query_claude_session to find sessions in the last 30 days mentioning each of these symbols: <list from candidates.json>. Return JSON array: [{symbol, session_id, date, snippet (200 char max)}, ...]. Return empty array if no hits."
})
```

結果を candidate JSON の各 entry の `evidence.claude_session` field に merge。

その後 markdown table に整形して user に提示:

```
# Emitter improvement candidates (mode=<mode>, top=<top>)

| # | mode | symbol / pattern | LLM 比率 | 関連 Claude session | recommended_action |
|---|------|---|---|---|---|
| 1 | add  | ... | ... | ... | ... |
```

### 2. USER PICK gate

`AskUserQuestion`:
- 質問: 「どの candidate に worktree 切る? (1〜N の番号 / `cancel`)」
- options: candidates の summary を 1 つずつ + cancel

cancel → workflow 終了。 番号 → 次へ。

### 3. Worktree create

```bash
bundle exec rake apple:emitter:worktree_create CANDIDATE_ID=$ID BASE=$CURRENT_BRANCH
```

stdout に worktree_path / branch / branch_json path が出る。

### 4. Implementer subagent dispatch

`Agent` で:

```ruby
agent_def = File.read(".claude/agents/emitter-implementer.md")
candidate_json = File.read(branch_json_path)
prompt = agent_def
           .gsub("__CANDIDATE_JSON__", candidate_json)
           .gsub("__BRANCH_NAME__",    branch_name)
           .gsub("__BASE_BRANCH__",    base_branch)
           .gsub("__WORKTREE_PATH__",  worktree_path)

Agent({
  description: "Implement emitter improvement candidate ##{cid}",
  subagent_type: "general-purpose",
  prompt: prompt,
})
```

return 受領。 status code 確認:
- `DONE` / `DONE_WITH_CONCERNS` → 次 Step 5 へ
- `BLOCKED` → user に diagnostic 提示、 同 session で対話継続

### 5. Reviewer cycle (subagent-driven-development pattern)

5a. Spec compliance review:

```ruby
Agent({
  description: "Spec compliance review for emitter improvement",
  subagent_type: "feature-dev:code-reviewer",
  prompt: "Review changes on branch <branch> against this spec: <recommended_action>. Report only spec gaps (missing or extra). Worktree: <worktree_path>."
})
```

5b. Code quality review:

```ruby
Agent({
  description: "Code quality review for emitter improvement",
  subagent_type: "feature-dev:code-reviewer",
  prompt: "Review code quality of changes on branch <branch>. Worktree: <worktree_path>. Check: TDD discipline (RED/GREEN/REFACTOR commits), naming, scope (no creep), test_unit-based verification (no raise+puts self-report)."
})
```

両 reviewer fail → implementer に `send-message` で issue 投げて再 dispatch、 再 review。 両 pass で次。

### 6. Fact bundle

```bash
cd <worktree_path>
bundle exec rake apple:emitter:fact_bundle BRANCH=<branch> BASE=<base>
```

`tmp/emitter/fact_<sanitized>.md` の中身を Read、 全文を user に提示。

### 7. USER FACT-REVIEW gate

`AskUserQuestion`:
- 質問: 「OK ならこの branch を base に non-ff merge + worktree remove、 NG なら session 内対話で修正方針を決めよう。 どっち?」
- options: `OK / merge` / `NG / iterate`

### 8. Merge or NG dialog

OK 選択 → main repo の cwd で:

```bash
bundle exec rake apple:emitter:merge BRANCH=<branch> BASE=<base> WORKTREE_PATH=<worktree_path>
```

push しない。

NG 選択 → workflow 終了せず、 同 session 内で main agent と user が修正方針を対話。 worktree 維持。 必要に応じて main agent が implementer を再 dispatch (`send-message` で具体 issue を投げる) または直接 Edit で修正。 user が完全に諦めた時のみ:

```bash
git worktree remove --force <worktree_path>
git branch -D <branch>
```

## 禁止事項

- 中間で user に質問しない (USER PICK と USER FACT-REVIEW の 2 gate のみ)
- candidate JSON 範囲外への scope creep
- 「KB」略称使用
- `rake test` の生 verbose log を main agent context に貼らない (CLAUDE.md "Test Execution Delegation"、 subagent 経由で count + pass/fail のみ取る or `tee` でファイル経由で渡す)
````

- [ ] **Step 2: Commit skill definition**

```bash
git add .claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md
git commit -m "feat(claude): add /rb-apple-sdk-mac-improve-emitter skill definition"
```

---

### Task 1.10: tooling/README.md

**Files:**
- Create: `tooling/README.md`

- [ ] **Step 1: Write README**

```markdown
# tooling/

rb-apple-sdk-mac の **maintainer-only** 開発支援 tool。 gem 出荷物には含まれない (gemspec の files 列に含めへん)。

## 構成

- `lib/emitter_dev/` — HITL emitter improvement helper Ruby modules
- `lib/tasks/emitter.rake` — `apple:emitter:*` Rake task 定義

## 使い方

slash command 経由が標準:

```
/rb-apple-sdk-mac-improve-emitter [--mode=add|trim|all] [--top=N]
```

skill が `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md` に定義されとる。

直接 Rake task を叩くこともできる:

```bash
bundle exec rake apple:emitter:candidates MODE=add TOP=5
bundle exec rake apple:emitter:worktree_create CANDIDATE_ID=1 BASE=feature/v1.2-bootstrap-principle
bundle exec rake apple:emitter:fact_bundle BRANCH=emitter/... BASE=...
bundle exec rake apple:emitter:merge BRANCH=... BASE=... WORKTREE_PATH=...
```

## 設計 spec

`docs/superpowers/specs/2026-05-09-hitl-emitter-improvement-design.md`
```

- [ ] **Step 2: Commit README**

```bash
git add tooling/README.md
git commit -m "docs(tooling): add tooling/ README"
```

---

### Task 1.11: H-1 dogfood — end-to-end smoke

**Files:**
- Create: `test/tooling/emitter_dev/end_to_end_test.rb`

- [ ] **Step 1: Write integration test that exercises candidates + fact_bundle in tmpdir**

```ruby
# test/tooling/emitter_dev/end_to_end_test.rb
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "fileutils"
require "tmpdir"
require "json"
require "sqlite3"
require "emitter_dev/candidate_ranker"
require "emitter_dev/fact_bundler"

class EmitterEndToEndTest < Test::Unit::TestCase
  def setup
    @tmp = Dir.mktmpdir
    @sdk = "26.2"
    project = File.join(@tmp, ".rb-apple-sdk-mac", @sdk)
    FileUtils.mkdir_p(project)
    db = SQLite3::Database.new(File.join(project, "cache.sqlite"))
    db.execute_batch <<~SQL
      CREATE TABLE compile_history (
        framework TEXT, symbol TEXT, generator TEXT,
        retry_count INTEGER, error_stage TEXT, error_detail TEXT
      );
      INSERT INTO compile_history VALUES ('AVF', 'devicesWithMediaType:', 'llm', 2, 'template_nil', NULL);
      INSERT INTO compile_history VALUES ('AVF', 'devicesWithMediaType:', 'llm', 3, 'template_nil', NULL);
    SQL
    db.close

    Dir.chdir(@tmp) do
      system "git init -q --initial-branch=main"
      system "git config user.email t@x; git config user.name t"
      File.write("a", "1"); system "git add a && git commit -qm base"
      system "git checkout -qb emitter/test"
      File.write("b", "2"); system "git add b && git commit -qm fix"
    end
    @prev = Dir.pwd; Dir.chdir(@tmp)
  end

  def teardown
    Dir.chdir(@prev); FileUtils.rm_rf(@tmp)
  end

  def test_full_chain_candidates_to_fact_bundle
    # candidates
    out = EmitterDev::CandidateRanker.new(project_root: @tmp, sdk_version: @sdk).rank(mode: "add", top: 5)
    FileUtils.mkdir_p("tmp/emitter")
    File.write("tmp/emitter/candidates.json", JSON.pretty_generate(out))
    assert_equal 1, out.fetch("candidates").size

    # simulate implementer artifacts
    File.write("tmp/emitter/regression_emitter_test.txt", "12 tests, 50 assertions, 0 failures, 0 errors\n")
    File.write("tmp/emitter/verify_emitter_test.txt",     "1 tests, 2 assertions, 0 failures, 0 errors\n")
    File.write("tmp/emitter/compile_history_emitter_test.txt", "AVF/devicesWithMediaType: llm=2 template=0\n")

    md = EmitterDev::FactBundler.new(branch: "emitter/test", base: "main").compose
    assert_match(/12 tests/, md)
    assert_match(/AVF\/devicesWithMediaType:/, md)
    assert_match(/## branch & commits/, md)
  end
end
```

- [ ] **Step 2: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/end_to_end_test.rb`
Expected: `1 tests, 4 assertions, 0 failures, 0 errors`.

- [ ] **Step 3: Commit**

```bash
git add test/tooling/emitter_dev/end_to_end_test.rb
git commit -m "test(tooling): end-to-end smoke for HITL emitter helper chain"
```

- [ ] **Step 4: Run full test suite via subagent dispatch**

Per CLAUDE.md "Test Execution Delegation": dispatch general-purpose subagent to run `bundle exec rake test`, return only count + pass/fail summary. Expected: prior count + 6 new test methods (Tasks 1.1-1.5 + 1.11) = +6, all green.

H-1 完了。 自己ドッグフード可能 = HITL tool 自身が compile_history を読んで Phase 4a.2 後の swift_overlay marshaller の改善 candidate を提案できる状態。

---

## Phase H-2: Trim Mode

H-2 完了条件: `--mode=trim` で marshallers.rb の redundancy candidate が ranking に出る。

---

### Task 2.1: Add `parser` gem dependency

**Files:**
- Modify: `Gemfile`

- [ ] **Step 1: Add to development group**

Edit `Gemfile`. Locate the `group :development do ... end` block and add `gem "parser"`.

After:

```ruby
group :development do
  gem "apple_sdk_mac-irb", path: "irb"
  gem "parser"
end
```

- [ ] **Step 2: Run `bundle install`**

Run: `bundle install`
Expected: parser gem installed (and its dep `ast`).

- [ ] **Step 3: Commit Gemfile + Gemfile.lock**

```bash
git add Gemfile Gemfile.lock
git commit -m "chore(deps): add parser gem (development) for redundancy_scanner AST parse"
```

---

### Task 2.2: RedundancyScanner module

**Files:**
- Create: `tooling/lib/emitter_dev/redundancy_scanner.rb`
- Create: `test/fixtures/emitter_dev/sample_marshallers.rb`
- Test:   `test/tooling/emitter_dev/redundancy_scanner_test.rb`

- [ ] **Step 1: Write fixture marshallers file**

```ruby
# test/fixtures/emitter_dev/sample_marshallers.rb
# This is a fixture for redundancy_scanner_test, NOT real production code.
module Sample
  class IntMarshaller
    def in_load; "x"; end
    private
    def scalar_type_token(raw)
      raw.gsub(/const|nullable/, "").strip.split("*").first.strip
    end
  end

  class FloatMarshaller
    def in_load; "y"; end
    private
    def scalar_float_type(raw)
      raw.gsub(/const|nullable/, "").strip.split("*").first.strip
    end
  end

  class BlockA
    def in_load; "a"; end
    def call_arg; "a"; end
  end

  class BlockAVoid
    def in_load; "a"; end
    def call_arg; "a"; end
  end
end
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/tooling/emitter_dev/redundancy_scanner_test.rb
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../../../tooling/lib", __dir__)
require "test/unit"
require "emitter_dev/redundancy_scanner"

class RedundancyScannerTest < Test::Unit::TestCase
  def fixture_path
    File.expand_path("../../fixtures/emitter_dev/sample_marshallers.rb", __dir__)
  end

  def test_scan_detects_twin_private_helpers
    cands = EmitterDev::RedundancyScanner.new(fixture_path).scan
    twins = cands.select { |c| c[:heuristic] == :twin_private_helper }
    assert_operator twins.size, :>=, 1, "expected at least 1 twin helper detection"
    methods = twins.first[:methods]
    assert_includes methods, "scalar_type_token"
    assert_includes methods, "scalar_float_type"
  end

  def test_scan_detects_class_pair_with_overlapping_methods
    cands = EmitterDev::RedundancyScanner.new(fixture_path).scan
    pairs = cands.select { |c| c[:heuristic] == :class_pair_method_overlap }
    assert_operator pairs.size, :>=, 1
    pair = pairs.first[:classes]
    assert_includes pair, "BlockA"
    assert_includes pair, "BlockAVoid"
  end
end
```

- [ ] **Step 3: Commit RED**

```bash
git add test/fixtures/emitter_dev/sample_marshallers.rb test/tooling/emitter_dev/redundancy_scanner_test.rb
git commit -m "test: RED — RedundancyScanner detects twin helpers and class-pair overlap"
```

- [ ] **Step 4: Implement RedundancyScanner**

```ruby
# tooling/lib/emitter_dev/redundancy_scanner.rb
# frozen_string_literal: true
require "parser/current"

module EmitterDev
  class RedundancyScanner
    def initialize(file_path)
      @file_path = file_path
    end

    def scan
      source = File.read(@file_path)
      ast = Parser::CurrentRuby.parse(source)
      classes = collect_classes(ast)
      cands = []
      cands += scan_twin_private_helpers(classes)
      cands += scan_class_pair_method_overlap(classes)
      cands
    end

    private

    def collect_classes(node, acc = [])
      return acc unless node.is_a?(Parser::AST::Node)
      if node.type == :class
        name_node = node.children[0]
        cls_name  = name_node.children.last.to_s
        methods   = collect_methods(node)
        acc << { name: cls_name, methods: methods }
      end
      node.children.each { |c| collect_classes(c, acc) }
      acc
    end

    def collect_methods(class_node)
      methods = {}
      walk(class_node) do |n|
        if n.type == :def
          mname = n.children[0].to_s
          body  = n.children[2]
          methods[mname] = body ? body.loc.expression.source : ""
        end
      end
      methods
    end

    def walk(node, &block)
      return unless node.is_a?(Parser::AST::Node)
      block.call(node)
      node.children.each { |c| walk(c, &block) }
    end

    def scan_twin_private_helpers(classes)
      bodies = []
      classes.each do |c|
        c[:methods].each { |mname, body| bodies << { class: c[:name], method: mname, body: body.gsub(/\s+/, " ") } }
      end
      twins = []
      bodies.combination(2).each do |a, b|
        next if a[:class] == b[:class]
        next unless similar?(a[:body], b[:body])
        twins << {
          heuristic: :twin_private_helper,
          classes:   [a[:class], b[:class]],
          methods:   [a[:method], b[:method]],
          score:     12,
        }
      end
      twins
    end

    def scan_class_pair_method_overlap(classes)
      pairs = []
      classes.combination(2).each do |a, b|
        common = a[:methods].keys & b[:methods].keys
        next if common.size < 2
        pairs << {
          heuristic: :class_pair_method_overlap,
          classes:   [a[:name], b[:name]],
          common_methods: common,
          score:     10,
        }
      end
      pairs
    end

    def similar?(a, b)
      return false if a.length < 10 || b.length < 10
      shorter, longer = [a, b].sort_by(&:length)
      common = shorter.length - levenshtein(a, b)
      common.to_f / longer.length > 0.7
    end

    def levenshtein(a, b)
      m = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
      (0..a.length).each { |i| m[i][0] = i }
      (0..b.length).each { |j| m[0][j] = j }
      (1..a.length).each do |i|
        (1..b.length).each do |j|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          m[i][j] = [m[i - 1][j] + 1, m[i][j - 1] + 1, m[i - 1][j - 1] + cost].min
        end
      end
      m[a.length][b.length]
    end
  end
end
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/redundancy_scanner_test.rb`
Expected: `2 tests, 4 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/redundancy_scanner.rb
git commit -m "feat(tooling): GREEN — RedundancyScanner with 2 heuristics"
```

---

### Task 2.3: Wire trim mode into CandidateRanker

**Files:**
- Modify: `tooling/lib/emitter_dev/candidate_ranker.rb`
- Modify: `test/tooling/emitter_dev/candidate_ranker_test.rb`

- [ ] **Step 1: Add a failing test for trim mode**

Append to `test/tooling/emitter_dev/candidate_ranker_test.rb`:

```ruby
  def test_rank_trim_mode_returns_redundancy_candidates
    fixture = File.expand_path("../../fixtures/emitter_dev/sample_marshallers.rb", __dir__)
    ranker = EmitterDev::CandidateRanker.new(
      project_root: @project_root, sdk_version: @sdk,
      marshallers_path: fixture
    )
    out = ranker.rank(mode: "trim", top: 5)
    cs = out.fetch("candidates")
    assert_operator cs.size, :>=, 1, "expected at least 1 trim candidate"
    assert_equal "trim", cs.first.fetch("mode")
    assert cs.first.fetch("evidence").key?("redundancy_scanner")
  end
```

- [ ] **Step 2: Run, verify fail**

Expected: ArgumentError on `marshallers_path` kwarg, or NoMethodError on rank_trim.

- [ ] **Step 3: Commit RED**

```bash
git add test/tooling/emitter_dev/candidate_ranker_test.rb
git commit -m "test: RED — CandidateRanker trim mode spec"
```

- [ ] **Step 4: Extend CandidateRanker**

Replace `tooling/lib/emitter_dev/candidate_ranker.rb` initializer + rank with:

```ruby
require "json"
require "time"
require "emitter_dev/source_compile_history"
require "emitter_dev/redundancy_scanner"

module EmitterDev
  class CandidateRanker
    DEFAULT_MARSHALLERS = "lib/apple_sdk_mac/glue_compiler/marshallers.rb"

    def initialize(project_root:, sdk_version:, marshallers_path: nil)
      @project_root      = project_root
      @sdk_version       = sdk_version
      @marshallers_path  = marshallers_path || File.join(project_root, DEFAULT_MARSHALLERS)
    end

    def rank(mode:, top:)
      candidates = []
      candidates += rank_add  if %w[add all].include?(mode)
      candidates += rank_trim if %w[trim all].include?(mode) && File.exist?(@marshallers_path)
      candidates.sort_by! { |c| -c["score"] }
      candidates = candidates.first(top)
      candidates.each_with_index { |c, i| c["id"] = i + 1 }
      {
        "generated_at" => Time.now.utc.iso8601,
        "mode"         => mode,
        "top"          => top,
        "candidates"   => candidates,
      }
    end

    private

    def rank_add
      db_path = File.join(@project_root, ".rb-apple-sdk-mac", @sdk_version, "cache.sqlite")
      return [] unless File.exist?(db_path)
      Sources::CompileHistory.new(db_path).aggregate.map do |row|
        score = (row["llm_count"] * 10) +
                (row["avg_retry"] * 3) +
                (row["error_stages"].include?("template_nil") ? 5 : 0) -
                (row["tpl_count"] * 1)
        {
          "mode"               => "add",
          "score"              => score.round(1),
          "summary"            => "#{row['framework']} / #{row['symbol']} の static emitter 追加",
          "evidence"           => { "compile_history" => row },
          "recommended_action" => "compile_history で LLM 経路に流れとる #{row['symbol']} を template path に乗せる",
        }
      end
    end

    def rank_trim
      RedundancyScanner.new(@marshallers_path).scan.map do |finding|
        {
          "mode"               => "trim",
          "score"              => finding[:score].to_f,
          "summary"            => trim_summary(finding),
          "evidence"           => { "redundancy_scanner" => finding },
          "recommended_action" => trim_action(finding),
        }
      end
    end

    def trim_summary(f)
      case f[:heuristic]
      when :twin_private_helper
        "#{f[:classes].join(' / ')} の双子 helper #{f[:methods].join(' / ')} を共通化"
      when :class_pair_method_overlap
        "Marshaller pair #{f[:classes].join(' / ')} の重複 method #{f[:common_methods].join(',')} を整理"
      else
        "redundancy: #{f[:heuristic]}"
      end
    end

    def trim_action(f)
      case f[:heuristic]
      when :twin_private_helper
        "#{f[:methods].join(' と ')} を Marshaller base の単一 helper にまとめて両 class から呼ぶ"
      when :class_pair_method_overlap
        "#{f[:classes].join(' と ')} の overlap (#{f[:common_methods].join(',')}) を片方に統合 + 残る側を delegator に"
      else
        "redundancy 解消"
      end
    end
  end
end
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/candidate_ranker_test.rb`
Expected: `3 tests, 8 assertions, 0 failures, 0 errors`.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/candidate_ranker.rb
git commit -m "feat(tooling): GREEN — CandidateRanker trim mode wiring"
```

---

### Task 2.4: H-2 verification

- [ ] **Step 1: Run full test suite via subagent**

Dispatch general-purpose subagent: `bundle exec rake test`. Expected count = H-1 count + 1 (Task 2.3 added 1 trim test) + 2 (RedundancyScanner tests in Task 2.2) = +3. All green.

- [ ] **Step 2: Smoke-run candidates with mode=trim**

Run from main repo (with marshallers.rb present at `lib/apple_sdk_mac/glue_compiler/marshallers.rb`):

```bash
bundle exec rake apple:emitter:candidates MODE=trim TOP=5
cat tmp/emitter/candidates.json | jq '.candidates[].mode'
```

Expected: stdout shows `"trim"` for each entry.

H-2 完了。

---

## Phase H-3: Claude Session Source

H-3 完了条件: skill が Claude session log の hit 情報を candidate JSON に merge できる。

### Task 3.1: Document the dispatch wiring inside SKILL.md

**Files:**
- Modify: `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`

Step 5 of skill workflow (1.9) already references chiebukuro_query_claude_session subagent dispatch. H-3 is about verifying the wording is operationally correct and adding a guard for "MCP 無し時は section skip" fallback.

- [ ] **Step 1: Edit SKILL.md to clarify MCP-unavailable fallback**

In `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`, in section 1 ("Candidate aggregation"), after the Agent dispatch snippet, add:

```markdown
chiebukuro-mcp が wire されてない / subagent return が `[]` / dispatch が timeout した場合: candidate JSON の `evidence.claude_session` field を空欄のまま進める。 workflow 全体は止めない。
```

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md
git commit -m "docs(skill): clarify Claude session source MCP-unavailable fallback"
```

### Task 3.2: H-3 verification

- [ ] **Step 1: Manual session test**

Invoke `/rb-apple-sdk-mac-improve-emitter --mode=add --top=3` interactively. Verify the skill:
1. Runs `apple:emitter:candidates`
2. Dispatches chiebukuro session subagent
3. Merges results (or fails gracefully with empty evidence)
4. Presents combined markdown table

Expected: candidate table with `claude_session` column populated for at least 1 row, or empty column if no hits.

This is a manual verification gate; no test code commit needed.

H-3 完了。

---

## Phase H-4: Polish

### Task 4.1: `--top` and `--mode` UX in skill

**Files:**
- Modify: `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`

- [ ] **Step 1: Add argument parsing block**

In SKILL.md, before "Workflow" section, add:

```markdown
## Arguments parsing

Slash command receives optional flags:
- `--mode=add|trim|all` (default `all`)
- `--top=N` (default 10)

Parse from `$ARGUMENTS` env var (set by Claude Code when slash command invoked):

```ruby
mode = "all"
top  = 10
ARGUMENTS.scan(/--mode=(\S+)/) { |m| mode = m.first }
ARGUMENTS.scan(/--top=(\d+)/)  { |m| top  = m.first.to_i }
```

Pass mode / top to `apple:emitter:candidates` Rake task via ENV.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md
git commit -m "docs(skill): document --mode and --top argument parsing"
```

### Task 4.2: cleanup_stale Rake task

**Files:**
- Modify: `tooling/lib/tasks/emitter.rake`
- Test:   `test/tooling/emitter_dev/end_to_end_test.rb` (extend)

- [ ] **Step 1: Add failing test for cleanup_stale logic**

Append to `test/tooling/emitter_dev/end_to_end_test.rb`:

```ruby
  def test_cleanup_stale_returns_old_worktree_paths
    require "emitter_dev/branch_ops"
    require "emitter_dev/worktree_ops"

    # In a real env, would scan `git worktree list` and filter by mtime.
    # Here we just check the helper exists and has correct signature.
    assert_respond_to EmitterDev::WorktreeOps, :stale_paths
    paths = EmitterDev::WorktreeOps.stale_paths(older_than_days: 7)
    assert_kind_of Array, paths
  end
```

- [ ] **Step 2: Commit RED**

```bash
git add test/tooling/emitter_dev/end_to_end_test.rb
git commit -m "test: RED — WorktreeOps.stale_paths spec"
```

- [ ] **Step 3: Implement stale_paths**

Append to `tooling/lib/emitter_dev/worktree_ops.rb`:

```ruby
    def stale_paths(older_than_days:)
      out, _, status = Open3.capture3("git", "worktree", "list", "--porcelain")
      return [] unless status.success?
      cutoff  = Time.now - (older_than_days * 86_400)
      paths   = out.scan(/^worktree (.+)$/).flatten
      paths.select do |p|
        next false unless File.directory?(p)
        File.mtime(p) < cutoff
      end
    end
```

- [ ] **Step 4: Add cleanup_stale Rake task**

Append to `tooling/lib/tasks/emitter.rake` inside `namespace :emitter`:

```ruby
    desc "List stale emitter worktrees older than DAYS days (default 7)"
    task :cleanup_stale do
      days = Integer(ENV.fetch("DAYS", "7"))
      paths = EmitterDev::WorktreeOps.stale_paths(older_than_days: days)
      puts "stale worktrees (older than #{days}d):"
      puts paths.empty? ? "  (none)" : paths.map { |p| "  #{p}" }
      puts "remove with: git worktree remove --force <path>"
    end
```

- [ ] **Step 5: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/end_to_end_test.rb`
Expected: 2 tests, all green.

- [ ] **Step 6: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/worktree_ops.rb tooling/lib/tasks/emitter.rake
git commit -m "feat(tooling): GREEN — WorktreeOps.stale_paths + cleanup_stale Rake task"
```

### Task 4.3: FactBundler section expansion (compile_history before/after diff)

**Files:**
- Modify: `tooling/lib/emitter_dev/fact_bundler.rb`
- Modify: `test/tooling/emitter_dev/fact_bundler_test.rb`

- [ ] **Step 1: Add failing test**

Append to `test/tooling/emitter_dev/fact_bundler_test.rb`:

```ruby
  def test_compose_includes_design_section_when_artifact_present
    File.write("tmp/emitter/design_emitter_test-fix.md", "## Design\nnew marshaller class_method_overlay\n")
    md = EmitterDev::FactBundler.new(branch: "emitter/test-fix", base: "main").compose
    assert_match(/## design/, md)
    assert_match(/new marshaller class_method_overlay/, md)
  end
```

- [ ] **Step 2: Commit RED**

```bash
git add test/tooling/emitter_dev/fact_bundler_test.rb
git commit -m "test: RED — FactBundler design section"
```

- [ ] **Step 3: Add design section to FactBundler**

In `tooling/lib/emitter_dev/fact_bundler.rb`, modify `compose`:

```ruby
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

    def section_design
      content = read_artifact("tmp/emitter/design_#{@slug}.md")
      "## design\n#{content}"
    end
```

- [ ] **Step 4: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/fact_bundler_test.rb`
Expected: 3 tests, all green.

- [ ] **Step 5: Commit GREEN**

```bash
git add tooling/lib/emitter_dev/fact_bundler.rb
git commit -m "feat(tooling): GREEN — FactBundler design section"
```

### Task 4.4: Self-coverage scripted check

**Files:**
- Create: `test/tooling/emitter_dev/skill_smoke_test.rb`

- [ ] **Step 1: Write failing smoke test**

```ruby
# test/tooling/emitter_dev/skill_smoke_test.rb
# frozen_string_literal: true
require "test/unit"

class SkillSmokeTest < Test::Unit::TestCase
  ROOT = File.expand_path("../../..", __dir__)

  def test_skill_md_exists_and_has_frontmatter
    path = File.join(ROOT, ".claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md")
    assert File.exist?(path), "skill file missing"
    content = File.read(path)
    assert_match(/\Aname: rb-apple-sdk-mac-improve-emitter/m, content.lines[1])
    assert_match(/^description:/, content)
  end

  def test_agent_md_exists_with_required_placeholders
    path = File.join(ROOT, ".claude/agents/emitter-implementer.md")
    assert File.exist?(path), "agent file missing"
    content = File.read(path)
    %w[__CANDIDATE_JSON__ __BRANCH_NAME__ __BASE_BRANCH__ __WORKTREE_PATH__].each do |ph|
      assert_match(/#{Regexp.escape(ph)}/, content, "placeholder #{ph} missing")
    end
  end

  def test_rake_tasks_registered
    out = `bundle exec rake -T apple:emitter: 2>&1`
    %w[candidates worktree_create fact_bundle merge cleanup_stale].each do |t|
      assert_match(/apple:emitter:#{t}/, out, "rake task apple:emitter:#{t} not found")
    end
  end
end
```

- [ ] **Step 2: Run, verify pass**

Run: `bundle exec rake test TEST=test/tooling/emitter_dev/skill_smoke_test.rb`
Expected: 3 tests, 8 assertions, all green.

- [ ] **Step 3: Commit**

```bash
git add test/tooling/emitter_dev/skill_smoke_test.rb
git commit -m "test(tooling): smoke test for skill / agent md / rake task registration"
```

### Task 4.5: H-4 final verification

- [ ] **Step 1: Full regression via subagent**

Dispatch general-purpose subagent: `bundle exec rake test`. Expected: H-2 count + 1 (Task 4.2) + 1 (Task 4.3) + 3 (Task 4.4) = +5, all green.

- [ ] **Step 2: Final dogfood — full HITL loop on a real candidate**

Run interactively: `/rb-apple-sdk-mac-improve-emitter --mode=add --top=3`
- USER PICK gate fires
- Worktree gets created
- Implementer subagent runs to DONE / DONE_WITH_CONCERNS
- Fact bundle presented
- USER FACT-REVIEW gate fires
- Choose NG (don't merge), session-internal dialog confirms iteration path works
- After acceptance, choose OK, merge happens

Expected: full loop works without manual intervention beyond 2 user gates.

H-4 完了 = HITL emitter improvement tool 全機能完成。

---

## Final review checklist

Before declaring the project complete, verify:

- [ ] All Tasks 1.1〜4.5 commits exist in git history
- [ ] `bundle exec rake test` runs full regression with 0 failures / 0 errors
- [ ] `bundle exec rake -T apple:emitter:` lists 5 tasks
- [ ] `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md` invokable as `/rb-apple-sdk-mac-improve-emitter`
- [ ] At least 1 real candidate has been merged via the loop (= self-dogfood proof)
- [ ] Spec `docs/superpowers/specs/2026-05-09-hitl-emitter-improvement-design.md` Section 11.1 (含む) all items implemented; Section 11.2 (含まない) items confirmed not started
