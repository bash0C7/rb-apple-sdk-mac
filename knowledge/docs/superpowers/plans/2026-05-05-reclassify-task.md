# `apple:knowledge:reclassify` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `rake apple:knowledge:reclassify` task in gem B (`rb-apple-sdk-knowledge`) that recomputes the derived per-parameter fields (`kind` / `is_out_param` / `nullability`) on every existing `symbols.parameters_json` row in-place — replacing the 4-hour `apple:knowledge:rebuild` step that Bug C originally planned with a seconds-to-minutes recompute. This plan also fulfills Bug C plan Task 9.

**Architecture:** Three coordinated parts. (1) Extract `classify_kind` / `out_param?` / `nullability_of` from `HeaderParser` into a public `AppleSDKKnowledge::Importer::Kind` module, so the importer pipeline and the new rake task share one definition. `HeaderParser` keeps calling them through the module. (2) New rake task wraps a rotating-backup → single-transaction → row-by-row recompute → post-condition verification flow, emitting a screen-pattern progress log to stdout and a Claude-readable jsonl queue of `unsupported` parameters. (3) The Bug C T9 step becomes "launch the recompute via the screen long-batch template, end the turn, verify in a later turn, run the SQL smoke."

**Tech Stack:** Ruby (test-unit), SQLite3 (single transaction, in-place UPDATE), JSON (parameters_json + unsupported.jsonl), GNU `screen` for batch detachment, `~/dev/src/CLAUDE.md` long-batch convention.

**Spec:** `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/docs/superpowers/specs/2026-05-05-longrun-pattern-design.md` (Part 2: Performance redesign).

**Replaces:** Task 9 of `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/docs/superpowers/plans/2026-05-05-bug-c-template-runtime-integration.md`. Tasks 1–8 of that plan are unchanged. Task 10 (E2E) runs after this plan completes.

---

## File Structure

### gem B (`rb-apple-sdk-knowledge`, `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge`)

- Create: `lib/rb_apple_sdk_knowledge/importer/kind.rb` — public `AppleSDKKnowledge::Importer::Kind` module exposing module functions `classify_kind(qual_type, desugared = qual_type)` / `out_param?(qual_type, name, is_last_pointer)` / `nullability_of(qual_type)`.
- Modify: `lib/rb_apple_sdk_knowledge/importer/header_parser.rb` — `require_relative "kind"`; replace the inline private methods with delegations to `Kind.classify_kind` etc. No behavior change.
- Modify: `lib/rb_apple_sdk_knowledge.rb` — add `require_relative "rb_apple_sdk_knowledge/importer/kind"` so callers (the rake task) do not need the explicit nested require.
- Create: `lib/rb_apple_sdk_knowledge/reclassifier.rb` — `AppleSDKKnowledge::Reclassifier` class with `#run(store_path:, log_io:, queue_path:)`. Holds the recompute loop, transaction, backup rotation, verification, and jsonl emission.
- Modify: `Rakefile` — add `task :reclassify` under `namespace :apple do; namespace :knowledge do`.
- Create: `test/test_kind.rb` — module-level unit tests for `Kind.classify_kind` / `Kind.out_param?` / `Kind.nullability_of` parameterised over the cases the original `HeaderParser` tests already exercised.
- Create: `test/test_reclassifier.rb` — integration test against an in-memory-style `Store` populated with a few symbol rows, asserting (a) `parameters_json` updated in place, (b) backup file produced, (c) `unsupported.jsonl` shape correct, (d) `_summary` line includes required keys, (e) idempotent re-run.

### gem C (`rb-apple-sdk-mac`)

- Modify: `docs/superpowers/plans/2026-05-05-bug-c-template-runtime-integration.md` — Task 9 body replaced by a pointer to this plan. Tasks 1–8 and Task 10 unchanged.

### Runtime artifacts (not source)

- `tmp/longrun/bug-c-reclassify.log` — screen-pattern progress log
- `tmp/longrun/bug-c-reclassify-unsupported.jsonl` — Claude-readable failure log + final `_summary` line
- `data/sdk_knowledge_26.2.sqlite.bak` — rotating single-slot backup created by the task

---

## Task 1: Extract `Kind` module (REFACTOR-only, no behavior change)

**Files:**
- Create: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/importer/kind.rb`
- Create: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/test_kind.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/importer/header_parser.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge.rb`

This is a behavior-preserving refactor; the existing `test_header_parser.rb` is the regression net. The new `test_kind.rb` pins the module's public contract directly.

- [ ] **Step 1: Write failing test for `Kind` module surface (RED)**

Create `test/test_kind.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/kind"

class TestKind < Test::Unit::TestCase
  K = AppleSDKKnowledge::Importer::Kind

  def test_classifies_string_for_const_char_pointer
    assert_equal "string", K.classify_kind("const char *")
  end

  def test_classifies_string_for_cfstring_ref
    assert_equal "string", K.classify_kind("CFStringRef")
  end

  def test_classifies_bool
    assert_equal "bool", K.classify_kind("_Bool")
  end

  def test_classifies_float
    assert_equal "float", K.classify_kind("double")
  end

  def test_classifies_int_for_osstatus
    assert_equal "int", K.classify_kind("OSStatus")
  end

  def test_classifies_opaque_ref_for_ref_typedef
    assert_equal "opaque_ref", K.classify_kind("MIDIClientRef")
  end

  def test_classifies_unsupported_for_void_pointer
    assert_equal "unsupported", K.classify_kind("void *")
  end

  def test_classifies_unsupported_for_function_pointer_via_desugared
    assert_equal "unsupported",
      K.classify_kind("MIDINotifyProc", "void (*)(const MIDINotification *, void *)")
  end

  def test_out_param_true_for_last_pointer
    assert_equal true, K.out_param?("MIDIClientRef *", "outClient", true)
  end

  def test_out_param_true_for_out_prefix_name
    assert_equal true, K.out_param?("Int32 *", "outNode", false)
  end

  def test_out_param_false_for_non_pointer
    assert_equal false, K.out_param?("CFStringRef", "name", false)
  end

  def test_nullability_nonnull
    assert_equal "nonnull", K.nullability_of("CFStringRef _Nonnull")
  end

  def test_nullability_nullable
    assert_equal "nullable", K.nullability_of("MIDIClientRef _Nullable")
  end

  def test_nullability_unspecified
    assert_equal "unspecified", K.nullability_of("CFStringRef")
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_kind.rb
```
Expected: `LoadError` (no such file `rb_apple_sdk_knowledge/importer/kind`).

- [ ] **Step 3: Commit RED**

```bash
git add test/test_kind.rb
git commit -m "test: add failing spec for Importer::Kind module surface"
```

- [ ] **Step 4: Create `Kind` module (GREEN)**

Create `lib/rb_apple_sdk_knowledge/importer/kind.rb`:

```ruby
# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    module Kind
      module_function

      def classify_kind(qual_type, desugared = qual_type)
        return "unsupported" if desugared.include?("(") && desugared.include?(")")
        return "string" if qual_type =~ /\b(CFStringRef|NSString\s*\*|char\s*\*|const\s+char\s*\*)/
        return "bool"   if qual_type =~ /\b(_Bool|Bool|BOOL)\b/
        return "float"  if qual_type =~ /\b(double|float|CGFloat)\b/
        if qual_type =~ /\b(?:U?Int(?:8|16|32|64)?|SInt(?:8|16|32|64)?|long|short|unsigned|signed|uint(?:8|16|32|64)_t|int(?:8|16|32|64)_t|OSStatus|kern_return_t)\b/
          return "opaque_ref" if qual_type =~ /\b\w+Ref\b/
          return "int"
        end
        return "unsupported" if qual_type =~ /\bvoid\s*\*/
        "unsupported"
      end

      def out_param?(qual_type, name, is_last_pointer)
        return false unless qual_type.include?("*")
        is_last_pointer || name.start_with?("out")
      end

      def nullability_of(qual_type)
        return "nonnull"  if qual_type.include?("_Nonnull")
        return "nullable" if qual_type.include?("_Nullable")
        "unspecified"
      end
    end
  end
end
```

Replace the corresponding private methods in `lib/rb_apple_sdk_knowledge/importer/header_parser.rb`. The top of the file gains `require_relative "kind"`. Replace the body of the three classifier methods so they delegate:

```ruby
require "open3"
require "json"
require_relative "kind"

module AppleSDKKnowledge
  module Importer
    class HeaderParser
      # ... (everything above function_parameters unchanged) ...

      def function_parameters(node)
        params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
        pointer_params = params.select { |p| (p.dig("type", "qualType") || "").include?("*") }
        last_pointer = pointer_params.last

        params.each_with_index.map do |p, i|
          qual_type = p.dig("type", "qualType") || ""
          desugared = p.dig("type", "desugaredQualType") || qual_type
          name = p["name"] || "_arg#{i}"
          {
            name: name,
            type: qual_type,
            kind: Kind.classify_kind(qual_type, desugared),
            is_out_param: Kind.out_param?(qual_type, name, p == last_pointer),
            nullability: Kind.nullability_of(qual_type)
          }
        end
      end

      # Remove the now-redundant private methods classify_kind, out_param?,
      # nullability_of from this class. The Kind module is the source of truth.
    end
  end
end
```

Add the eager require so the rake task can use the module without an explicit nested require. In `lib/rb_apple_sdk_knowledge.rb`, add near the other requires:

```ruby
require_relative "rb_apple_sdk_knowledge/importer/kind"
```

- [ ] **Step 5: Run `test_kind.rb` and the existing `test_header_parser.rb` to confirm GREEN + no regression**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_kind.rb
bundle exec ruby -Ilib -Itest test/test_header_parser.rb
```
Expected: 0 failures, 0 errors in both.

- [ ] **Step 6: Run full suite via subagent**

Per the "Delegate rake test to subagent" memory rule, dispatch a general-purpose subagent. Prompt:

> Run `cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge && bundle exec rake test`. Report only: total tests, assertions, failures, errors, omits. Do NOT include the verbose per-test log. If failures > 0 or errors > 0, also paste the lines containing the assertion message for each failing test.

Expected: 0 failures, 0 errors.

- [ ] **Step 7: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge.rb lib/rb_apple_sdk_knowledge/importer/kind.rb lib/rb_apple_sdk_knowledge/importer/header_parser.rb
git commit -m "refactor: extract Importer::Kind module from HeaderParser"
```

---

## Task 2: `Reclassifier` core — recompute one parameters_json row in memory

**Files:**
- Create: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/reclassifier.rb`
- Create: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/test_reclassifier.rb`

This task introduces the class and its pure recompute helper before any DB I/O. The DB integration lands in Task 3.

- [ ] **Step 1: Write failing test for `Reclassifier.recompute_parameters` (RED)**

Create `test/test_reclassifier.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"
require "json"
require "rb_apple_sdk_knowledge/reclassifier"

class TestReclassifier < Test::Unit::TestCase
  R = AppleSDKKnowledge::Reclassifier

  def test_recompute_fills_kind_and_is_out_param_from_type_only
    raw = JSON.generate([
      { name: "name",      type: "const char *" },
      { name: "outClient", type: "MIDIClientRef *" }
    ])
    out = R.recompute_parameters(raw)
    parsed = JSON.parse(out, symbolize_names: true)

    assert_equal "string",     parsed[0][:kind]
    assert_equal false,        parsed[0][:is_out_param]
    assert_equal "unspecified", parsed[0][:nullability]

    assert_equal "opaque_ref", parsed[1][:kind]
    assert_equal true,         parsed[1][:is_out_param]
  end

  def test_recompute_marks_void_pointer_unsupported
    raw = JSON.generate([{ name: "userData", type: "void *" }])
    parsed = JSON.parse(R.recompute_parameters(raw), symbolize_names: true)
    assert_equal "unsupported", parsed[0][:kind]
  end

  def test_recompute_is_idempotent
    raw = JSON.generate([{ name: "x", type: "int" }])
    once  = R.recompute_parameters(raw)
    twice = R.recompute_parameters(once)
    assert_equal once, twice
  end

  def test_recompute_handles_nil_or_empty_input
    assert_nil R.recompute_parameters(nil)
    assert_nil R.recompute_parameters("")
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_reclassifier.rb
```
Expected: `LoadError` (no `reclassifier`).

- [ ] **Step 3: Commit RED**

```bash
git add test/test_reclassifier.rb
git commit -m "test: add failing spec for Reclassifier.recompute_parameters"
```

- [ ] **Step 4: Implement `Reclassifier.recompute_parameters` (GREEN)**

Create `lib/rb_apple_sdk_knowledge/reclassifier.rb`:

```ruby
# frozen_string_literal: true
require "json"
require_relative "importer/kind"

module AppleSDKKnowledge
  class Reclassifier
    K = AppleSDKKnowledge::Importer::Kind

    def self.recompute_parameters(json)
      return nil if json.nil? || json.empty?
      params = JSON.parse(json, symbolize_names: true)
      pointer_params = params.select { |p| (p[:type] || "").include?("*") }
      last_pointer = pointer_params.last

      params.each_with_index.map do |p, i|
        qual_type = p[:type] || ""
        name = p[:name] || "_arg#{i}"
        p.merge(
          kind: K.classify_kind(qual_type),
          is_out_param: K.out_param?(qual_type, name, p.equal?(last_pointer)),
          nullability: K.nullability_of(qual_type)
        )
      end.then { |xs| JSON.generate(xs) }
    end
  end
end
```

- [ ] **Step 5: Run, verify GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_reclassifier.rb
```
Expected: 0 failures, 0 errors.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/reclassifier.rb
git commit -m "feat: add Reclassifier.recompute_parameters pure helper"
```

---

## Task 3: `Reclassifier#run` — backup, transaction, recompute every row, verification

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/reclassifier.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/test_reclassifier.rb`

- [ ] **Step 1: Write failing test for `#run` against a real on-disk Store (RED)**

Append to `test/test_reclassifier.rb`:

```ruby
require "tmpdir"
require "fileutils"
require "stringio"
require "rb_apple_sdk_knowledge/store"

class TestReclassifierRun < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir("reclassify-test")
    @db_path = File.join(@dir, "k.sqlite")
    store = AppleSDKKnowledge::Store.open(@db_path)
    fid = store.insert_framework(name: "MiniMIDI", swift_module: "MiniMIDI")
    store.insert_symbol(
      framework_id: fid, name: "MiniCreate", kind: "function", abi: "c",
      content_hash: "h1",
      parameters_json: JSON.generate([
        { name: "name",      type: "const char *" },
        { name: "outClient", type: "MiniClientRef *" }
      ])
    )
    store.insert_symbol(
      framework_id: fid, name: "MiniNoParams", kind: "function", abi: "c",
      content_hash: "h2",
      parameters_json: nil
    )
    store.close
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_run_updates_every_parameters_json_row_in_place
    log = StringIO.new
    queue = File.join(@dir, "unsupported.jsonl")
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: log, queue_path: queue
    ).run

    db = SQLite3::Database.new(@db_path)
    row = db.execute(
      "SELECT parameters_json FROM symbols WHERE name = ?", ["MiniCreate"]
    ).first
    db.close

    parsed = JSON.parse(row[0], symbolize_names: true)
    assert_equal "string",     parsed[0][:kind]
    assert_equal "opaque_ref", parsed[1][:kind]
    assert_equal true,         parsed[1][:is_out_param]
  end

  def test_run_creates_rotating_backup
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path,
      log_io: StringIO.new,
      queue_path: File.join(@dir, "u.jsonl")
    ).run
    assert File.exist?("#{@db_path}.bak"), "expected rotating backup at <db>.bak"
  end

  def test_run_skips_rows_with_null_parameters_json_without_error
    queue = File.join(@dir, "u.jsonl")
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: StringIO.new, queue_path: queue
    ).run

    db = SQLite3::Database.new(@db_path)
    row = db.execute(
      "SELECT parameters_json FROM symbols WHERE name = ?", ["MiniNoParams"]
    ).first
    db.close
    assert_nil row[0]
  end

  def test_run_is_idempotent
    log1 = StringIO.new
    log2 = StringIO.new
    queue1 = File.join(@dir, "u1.jsonl")
    queue2 = File.join(@dir, "u2.jsonl")

    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: log1, queue_path: queue1
    ).run

    db = SQLite3::Database.new(@db_path)
    snapshot1 = db.execute(
      "SELECT name, parameters_json FROM symbols ORDER BY name"
    )
    db.close

    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: log2, queue_path: queue2
    ).run

    db = SQLite3::Database.new(@db_path)
    snapshot2 = db.execute(
      "SELECT name, parameters_json FROM symbols ORDER BY name"
    )
    db.close

    assert_equal snapshot1, snapshot2
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_reclassifier.rb
```
Expected: 4 failures/errors (`Reclassifier#new` / `#run` not implemented).

- [ ] **Step 3: Commit RED**

```bash
git add test/test_reclassifier.rb
git commit -m "test: add failing spec for Reclassifier#run (in-place + backup + idempotent)"
```

- [ ] **Step 4: Implement `Reclassifier#run` (GREEN)**

Replace `lib/rb_apple_sdk_knowledge/reclassifier.rb` with:

```ruby
# frozen_string_literal: true
require "json"
require "fileutils"
require "sqlite3"
require_relative "importer/kind"

module AppleSDKKnowledge
  class Reclassifier
    K = AppleSDKKnowledge::Importer::Kind

    def self.recompute_parameters(json)
      return nil if json.nil? || json.empty?
      params = JSON.parse(json, symbolize_names: true)
      pointer_params = params.select { |p| (p[:type] || "").include?("*") }
      last_pointer = pointer_params.last

      params.each_with_index.map do |p, i|
        qual_type = p[:type] || ""
        name = p[:name] || "_arg#{i}"
        p.merge(
          kind: K.classify_kind(qual_type),
          is_out_param: K.out_param?(qual_type, name, p.equal?(last_pointer)),
          nullability: K.nullability_of(qual_type)
        )
      end.then { |xs| JSON.generate(xs) }
    end

    def initialize(store_path:, log_io:, queue_path:)
      @store_path = store_path
      @log = log_io
      @queue_path = queue_path
    end

    def run
      backup!
      File.open(@queue_path, "w") do |queue|
        @queue = queue
        recompute_all!
      end
      verify!
      log "DONE: total_symbols=#{@total_symbols} total_params=#{@total_params}"
    end

    private

    def backup!
      bak = "#{@store_path}.bak"
      FileUtils.cp(@store_path, bak)
      log "backup: #{bak}"
    end

    def recompute_all!
      db = SQLite3::Database.new(@store_path)
      db.results_as_hash = false
      @total_symbols = 0
      @total_params = 0
      db.execute("BEGIN")
      begin
        db.execute(
          "SELECT s.id, s.name, s.signature, f.name, s.parameters_json
           FROM symbols s LEFT JOIN frameworks f ON s.framework_id = f.id
           WHERE s.parameters_json IS NOT NULL"
        ) do |row|
          symbol_id, sym_name, signature, framework, json = row
          recomputed = self.class.recompute_parameters(json)
          db.execute(
            "UPDATE symbols SET parameters_json = ? WHERE id = ?",
            [recomputed, symbol_id]
          )
          @total_symbols += 1
          enqueue_unsupported(framework, sym_name, signature, recomputed)
        end
        db.execute("COMMIT")
      rescue => e
        db.execute("ROLLBACK")
        raise
      ensure
        db.close
      end
    end

    def enqueue_unsupported(framework, sym_name, signature, json)
      params = JSON.parse(json, symbolize_names: true)
      params.each_with_index do |p, i|
        @total_params += 1
        next unless p[:kind] == "unsupported"
        @queue.puts JSON.generate(
          qual_type: p[:type],
          framework: framework,
          symbol: sym_name,
          signature: signature,
          param_index: i,
          param_name: p[:name],
          heuristics: {
            looks_like_void_pointer: p[:type].to_s =~ /\bvoid\s*\*/ ? true : false,
            looks_like_function_pointer: p[:type].to_s.include?("(") && p[:type].to_s.include?(")")
          }
        )
      end
    end

    def verify!
      db = SQLite3::Database.new(@store_path)
      bad = db.execute(
        "SELECT id, parameters_json FROM symbols WHERE parameters_json IS NOT NULL"
      ).reject do |_id, json|
        JSON.parse(json).all? { |p| p.key?("kind") }
      end
      db.close
      raise "verification failed: #{bad.length} rows lack :kind" unless bad.empty?
    end

    def log(msg)
      @log.puts msg
    end
  end
end
```

- [ ] **Step 5: Run, verify GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_reclassifier.rb
```
Expected: 0 failures, 0 errors.

- [ ] **Step 6: Run full suite via subagent**

Same prompt format as Task 1 Step 6. Expected: still 0 failures, 0 errors.

- [ ] **Step 7: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/reclassifier.rb
git commit -m "feat: implement Reclassifier#run with backup, transaction, idempotent recompute"
```

---

## Task 4: Unsupported jsonl + final `_summary` line

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/lib/rb_apple_sdk_knowledge/reclassifier.rb`
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/test/test_reclassifier.rb`

The summary must include `unsupported_clusters` (top-N by qual_type), `classify_kind_source` (file:line), `kind_vocabulary`, and `next_action_hint`. This makes the log Claude-readable for the recovery loop.

- [ ] **Step 1: Write failing test for jsonl shape + summary (RED)**

Append to `test/test_reclassifier.rb`:

```ruby
class TestReclassifierUnsupportedLog < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir("reclassify-unsupported-test")
    @db_path = File.join(@dir, "k.sqlite")
    store = AppleSDKKnowledge::Store.open(@db_path)
    fid = store.insert_framework(name: "MiniMIDI", swift_module: "MiniMIDI")
    # 3 rows total: 2 introduce the same unsupported qual_type, 1 is fully supported.
    store.insert_symbol(
      framework_id: fid, name: "F_unsup_a", kind: "function", abi: "c",
      content_hash: "h1",
      parameters_json: JSON.generate([{ name: "u", type: "void *" }])
    )
    store.insert_symbol(
      framework_id: fid, name: "F_unsup_b", kind: "function", abi: "c",
      content_hash: "h2",
      parameters_json: JSON.generate([{ name: "u", type: "void *" }])
    )
    store.insert_symbol(
      framework_id: fid, name: "F_ok", kind: "function", abi: "c",
      content_hash: "h3",
      parameters_json: JSON.generate([{ name: "x", type: "int" }])
    )
    store.close

    @queue = File.join(@dir, "u.jsonl")
    AppleSDKKnowledge::Reclassifier.new(
      store_path: @db_path, log_io: StringIO.new, queue_path: @queue
    ).run
    @lines = File.readlines(@queue, chomp: true)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_jsonl_has_one_entry_per_unsupported_param_and_one_summary
    item_lines = @lines.reject { |l| l.start_with?('{"_summary"') || l.include?('"_summary"') }
    summary_lines = @lines.select { |l| l.include?('"_summary"') }
    assert_equal 2, item_lines.length, "expected one jsonl entry per unsupported param"
    assert_equal 1, summary_lines.length, "expected exactly one _summary line"
  end

  def test_summary_contains_required_keys
    summary = JSON.parse(@lines.last)["_summary"]
    %w[ran_at total_symbols total_params by_kind unsupported_clusters classify_kind_source kind_vocabulary next_action_hint].each do |key|
      assert summary.key?(key), "summary missing key: #{key}"
    end
  end

  def test_summary_clusters_count_matches
    summary = JSON.parse(@lines.last)["_summary"]
    cluster = summary["unsupported_clusters"].find { |c| c["qual_type"] == "void *" }
    assert_not_nil cluster
    assert_equal 2, cluster["count"]
  end

  def test_summary_classify_kind_source_points_to_kind_module
    summary = JSON.parse(@lines.last)["_summary"]
    assert_match(%r{lib/rb_apple_sdk_knowledge/importer/kind\.rb:\d+},
                 summary["classify_kind_source"])
  end

  def test_summary_kind_vocabulary_lists_known_kinds
    summary = JSON.parse(@lines.last)["_summary"]
    %w[string int bool float opaque_ref unsupported].each do |k|
      assert_includes summary["kind_vocabulary"], k
    end
  end

  def test_summary_by_kind_sums_to_total_params
    summary = JSON.parse(@lines.last)["_summary"]
    sum = summary["by_kind"].values.sum
    assert_equal summary["total_params"], sum
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_reclassifier.rb
```
Expected: failures (no `_summary` line emitted yet).

- [ ] **Step 3: Commit RED**

```bash
git add test/test_reclassifier.rb
git commit -m "test: add failing spec for unsupported.jsonl + _summary line"
```

- [ ] **Step 4: Extend `Reclassifier#run` to emit summary (GREEN)**

In `lib/rb_apple_sdk_knowledge/reclassifier.rb` replace the contents of the class with the following (the additions are: `KIND_VOCABULARY` constant, `@by_kind` / `@unsupported_clusters` accumulators, `emit_summary!` invoked at the end of `run`, and `classify_kind_source_location`):

```ruby
# frozen_string_literal: true
require "json"
require "fileutils"
require "sqlite3"
require "time"
require_relative "importer/kind"

module AppleSDKKnowledge
  class Reclassifier
    K = AppleSDKKnowledge::Importer::Kind

    KIND_VOCABULARY = %w[string int bool float opaque_ref unsupported].freeze

    def self.recompute_parameters(json)
      return nil if json.nil? || json.empty?
      params = JSON.parse(json, symbolize_names: true)
      pointer_params = params.select { |p| (p[:type] || "").include?("*") }
      last_pointer = pointer_params.last

      params.each_with_index.map do |p, i|
        qual_type = p[:type] || ""
        name = p[:name] || "_arg#{i}"
        p.merge(
          kind: K.classify_kind(qual_type),
          is_out_param: K.out_param?(qual_type, name, p.equal?(last_pointer)),
          nullability: K.nullability_of(qual_type)
        )
      end.then { |xs| JSON.generate(xs) }
    end

    def initialize(store_path:, log_io:, queue_path:)
      @store_path = store_path
      @log = log_io
      @queue_path = queue_path
    end

    def run
      backup!
      @by_kind = Hash.new(0)
      @clusters = Hash.new { |h, k| h[k] = { count: 0, frameworks: [], example_symbols: [] } }
      File.open(@queue_path, "w") do |queue|
        @queue = queue
        recompute_all!
        verify!
        emit_summary!
      end
      log "DONE: total_symbols=#{@total_symbols} total_params=#{@total_params}"
    end

    private

    def backup!
      bak = "#{@store_path}.bak"
      FileUtils.cp(@store_path, bak)
      log "backup: #{bak}"
    end

    def recompute_all!
      db = SQLite3::Database.new(@store_path)
      db.results_as_hash = false
      @total_symbols = 0
      @total_params = 0
      db.execute("BEGIN")
      begin
        db.execute(
          "SELECT s.id, s.name, s.signature, f.name, s.parameters_json
           FROM symbols s LEFT JOIN frameworks f ON s.framework_id = f.id
           WHERE s.parameters_json IS NOT NULL"
        ) do |row|
          symbol_id, sym_name, signature, framework, json = row
          recomputed = self.class.recompute_parameters(json)
          db.execute(
            "UPDATE symbols SET parameters_json = ? WHERE id = ?",
            [recomputed, symbol_id]
          )
          @total_symbols += 1
          tally_and_enqueue(framework, sym_name, signature, recomputed)
        end
        db.execute("COMMIT")
      rescue => e
        db.execute("ROLLBACK")
        raise
      ensure
        db.close
      end
    end

    def tally_and_enqueue(framework, sym_name, signature, json)
      params = JSON.parse(json, symbolize_names: true)
      params.each_with_index do |p, i|
        @total_params += 1
        @by_kind[p[:kind]] += 1
        next unless p[:kind] == "unsupported"
        @queue.puts JSON.generate(
          qual_type: p[:type],
          framework: framework,
          symbol: sym_name,
          signature: signature,
          param_index: i,
          param_name: p[:name],
          heuristics: {
            looks_like_void_pointer: !!(p[:type].to_s =~ /\bvoid\s*\*/),
            looks_like_function_pointer: p[:type].to_s.include?("(") && p[:type].to_s.include?(")")
          }
        )
        c = @clusters[p[:type]]
        c[:count] += 1
        c[:frameworks] << framework unless c[:frameworks].include?(framework)
        c[:example_symbols] << sym_name if c[:example_symbols].length < 3
      end
    end

    def verify!
      db = SQLite3::Database.new(@store_path)
      bad = db.execute(
        "SELECT id, parameters_json FROM symbols WHERE parameters_json IS NOT NULL"
      ).reject do |_id, json|
        JSON.parse(json).all? { |p| p.key?("kind") }
      end
      db.close
      raise "verification failed: #{bad.length} rows lack :kind" unless bad.empty?
    end

    def emit_summary!
      top_clusters = @clusters
        .sort_by { |_, v| -v[:count] }
        .first(10)
        .map { |qt, v| { qual_type: qt, count: v[:count], frameworks: v[:frameworks], example_symbols: v[:example_symbols] } }

      @queue.puts JSON.generate(
        _summary: {
          ran_at: Time.now.utc.iso8601,
          total_symbols: @total_symbols,
          total_params: @total_params,
          by_kind: @by_kind,
          unsupported_clusters: top_clusters,
          classify_kind_source: classify_kind_source_location,
          kind_vocabulary: KIND_VOCABULARY,
          next_action_hint: "extend AppleSDKKnowledge::Importer::Kind.classify_kind to handle the top cluster (or explicitly accept it as unsupported), then re-run rake apple:knowledge:reclassify"
        }
      )
    end

    def classify_kind_source_location
      method = K.method(:classify_kind)
      file, line = method.source_location
      "#{file.sub("#{Dir.pwd}/", "")}:#{line}"
    end

    def log(msg)
      @log.puts msg
    end
  end
end
```

- [ ] **Step 5: Run, verify GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec ruby -Ilib -Itest test/test_reclassifier.rb
```
Expected: 0 failures, 0 errors.

- [ ] **Step 6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/reclassifier.rb
git commit -m "feat: emit unsupported.jsonl with _summary line for Claude recovery loop"
```

---

## Task 5: Wire `apple:knowledge:reclassify` rake task

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/Rakefile`

- [ ] **Step 1: Add the rake task**

Insert under the existing `namespace :apple do; namespace :knowledge do` block (alongside `:rebuild` and `:info`):

```ruby
desc "Recompute kind / is_out_param / nullability on existing parameters_json (in place)"
task :reclassify do
  require "rb_apple_sdk_knowledge"
  require "rb_apple_sdk_knowledge/reclassifier"

  sdk_version = AppleSDKKnowledge::SDK.version
  store_path = AppleSDKKnowledge.knowledge_path(sdk_version: sdk_version)
  unless File.exist?(store_path)
    abort "no knowledge DB at #{store_path}; run apple:knowledge:rebuild first"
  end

  FileUtils.mkdir_p("tmp/longrun")
  queue_path = "tmp/longrun/reclassify-unsupported.jsonl"

  puts "store_path: #{store_path}"
  puts "queue_path: #{queue_path}"
  puts "WARNING: do not run gem C glue compilation while this is in progress."

  AppleSDKKnowledge::Reclassifier.new(
    store_path: store_path,
    log_io: $stdout,
    queue_path: queue_path
  ).run
end
```

- [ ] **Step 2: Smoke-run the task against the real DB (idempotent recompute on existing data)**

This is a small, idempotent run; it does not need the screen pattern. It should complete in seconds.

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
bundle exec rake apple:knowledge:reclassify
```
Expected: terminates with `DONE: total_symbols=<N> total_params=<M>`. Backup file `data/sdk_knowledge_26.2.sqlite.bak` is created. `tmp/longrun/reclassify-unsupported.jsonl` is non-empty (Apple SDK has many `void *` / callback typedefs).

If the task takes longer than ~60 seconds, abort it (`Ctrl-C`) and re-launch via the screen long-batch template instead — but on the current DB shape it should be far below that.

- [ ] **Step 3: Inspect the summary**

```bash
tail -1 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/reclassify-unsupported.jsonl | jq ._summary
```
Confirm it contains `total_symbols`, `total_params`, `by_kind`, `unsupported_clusters` (top-N), `classify_kind_source` ending in `kind.rb:<line>`, `kind_vocabulary` listing all 6 kinds, and `next_action_hint`.

- [ ] **Step 4: Commit**

```bash
git add Rakefile
git commit -m "feat: add apple:knowledge:reclassify rake task wiring Reclassifier"
```

---

## Task 6: Bug C plan T9 — point at this plan; document the screen-launched path for production-scale data

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/docs/superpowers/plans/2026-05-05-bug-c-template-runtime-integration.md`

This task replaces the "DB rebuild ~4hr" body of Bug C plan Task 9 with a pointer to this plan plus the screen-pattern launch and cross-turn verification steps. After this commit, Bug C T9 is satisfied by completing Tasks 1–5 above plus the verification described here.

- [ ] **Step 1: Replace Task 9 body**

In `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/docs/superpowers/plans/2026-05-05-bug-c-template-runtime-integration.md`, replace the entire body of `## Task 9: DB rebuild and SQL verification` (steps 1–3, file list included) with:

```markdown
## Task 9: In-place reclassify + SQL verification

> **Replaces the original "4hr rebuild" approach.** The new fields (`kind`, `is_out_param`, `nullability`) are pure functions of `parameters_json` already in the DB — recompute in place via the dedicated rake task instead of re-fetching the SDK headers.
>
> Implementation plan: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/docs/superpowers/plans/2026-05-05-reclassify-task.md` (Tasks 1–5 build the rake task + module + tests; Task 6 is this pointer; the steps below complete T9 of Bug C).

**Files:**
- Read-then-mutate: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite`
- Backup written by the task: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite.bak`
- Logs: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-reclassify.log` and `...-unsupported.jsonl`

- [ ] **Step 1: Pre-run safety check.** Confirm no other writer is active and the DB exists.

```bash
ls -la ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite*
pgrep -fl 'rake apple:knowledge'   # must be empty
```

- [ ] **Step 2: Launch reclassify under the long-batch screen pattern.** (Per `~/dev/src/CLAUDE.md` "ロングバッチ実行パターン".)

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
mkdir -p tmp/longrun
screen -dmS bug-c-reclassify bash -c '
  cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
  bundle exec rake apple:knowledge:reclassify > tmp/longrun/bug-c-reclassify.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/bug-c-reclassify.log
'
```

End the Claude turn here.

- [ ] **Step 3: In a later turn, verify completion.**

```bash
grep "^DONE:" ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-reclassify.log
```
Must show `DONE: exit=0`. If absent the job is still running (or has crashed); inspect the log.

- [ ] **Step 4: Read the unsupported summary; enter recovery loop only if needed.**

```bash
tail -1 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-reclassify-unsupported.jsonl | jq ._summary
```
For Bug C smoke acceptance, the only required outcome is that `MIDIClientCreate`'s `name` and `outClient` parameters classify correctly (next step). `notifyProc` and `notifyRefCon` MAY remain `unsupported` — that is acceptable. If you want to extend `Kind.classify_kind` to absorb a high-count cluster, do it now and re-run from Step 2; otherwise proceed.

- [ ] **Step 5: SQL verification (the original Task 9 acceptance check).**

```bash
sqlite3 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite \
  "SELECT s.parameters_json FROM symbols s JOIN frameworks f ON s.framework_id=f.id WHERE s.name='MIDIClientCreate' AND f.name='CoreMIDI';"
```
Expected: the JSON contains `"kind":"string"` for `name`, `"kind":"opaque_ref"` for `outClient`, and `"is_out_param":true` for `outClient`. (`notifyProc` / `notifyRefCon` may be `unsupported`.)
```

(Replace the entire existing Task 9 block with the above. Step numbering inside Task 9 is restarted at 1; this does not affect Tasks 1–8 or Task 10.)

- [ ] **Step 2: Commit**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
git add docs/superpowers/plans/2026-05-05-bug-c-template-runtime-integration.md
git commit -m "docs(plan): redirect Bug C T9 to reclassify-task plan"
```
