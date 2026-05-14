# Phase 3 — Cleanup and Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the LLM runtime fallback path entirely, retire `CallError` (dead class), wire Section 6.3 telemetry, and decouple the Knowledge Base sub-gem's importer chain from the main gem's runtime load path.

**Architecture:** Phase 2 made the emitter Knowledge-Base-driven and raised typed exceptions instead of returning `nil` on errors. Phase 3 cuts the safety-net cloud LLM path off entirely (the project's North Star: gem does not write Swift), prunes the dead class, lets the runtime persist failure events to a jsonl ring, and stops the main gem from accidentally requiring `ruby-progressbar` through the Knowledge Base sub-gem.

**Tech Stack:** Ruby (CRuby), test-unit, SQLite (existing), JSON Lines (`jsonl`), Bundler/Gemspec, `superpowers:subagent-driven-development`.

**Out of scope (Phase 4 handoff):** `Apple::DiscoveryError` deprecate is paired with `Apple.discover` lazy transparent namespace (spec Section 1) and stays in Phase 4. Importer backlog items (Consolidator hash divergence, swift IUO-of-Optional, etc.) are a separate Knowledge Base track.

---

## File Structure

### Files removed (4 files, 1 dep)

| Path | Reason |
|---|---|
| `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` | LLM fallback path全廃 |
| `lib/apple_sdk_mac/glue_compiler/llm_examples.rb` | LLMGenerator が唯一の consumer |
| `test/glue_compiler/llm_generator_test.rb` | 対象 class 廃止 |
| `rb-foundation-model-mac` dep in `rb-apple-sdk-mac.gemspec` | LLMGenerator が唯一の consumer |

### Files added (2 files)

| Path | Responsibility |
|---|---|
| `lib/apple_sdk_mac/telemetry.rb` | `~/.cache/rb-apple-sdk-mac/diagnostics/<YYYY-MM-DD>.jsonl` への opt-out append (env `APPLE_SDK_MAC_NO_DIAGNOSTICS=1` で disable)。 single-method API (`append_event`)、 atomic append、 silent on error |
| `test/test_telemetry.rb` | Telemetry の RED → GREEN |

### Files modified

| Path | 変更 |
|---|---|
| `lib/apple_sdk_mac/errors.rb` | `class CallError < Error` 削除 |
| `lib/apple_sdk_mac.rb` | `Apple::CallError` alias 削除、 `Apple::Telemetry` 追加なし (内部 module) |
| `lib/apple_sdk_mac/glue_compiler.rb` | `try_llm` method 全削除、 `compile` は `try_template` の Result をそのまま return、 `llm_generator:` / `max_llm_retries:` kwargs 削除、 require_relative の llm_generator 削除 |
| `lib/apple_sdk_mac/glue_compiler/validation_gates.rb` | LLMGenerator 言及 comment (33行) 削除 |
| `lib/apple_sdk_mac/public_api.rb` | LLMGenerator.new wire 削除、 require_relative llm_generator 削除 |
| `lib/apple_sdk_mac/dispatcher.rb` | typed raise 直前で `Telemetry.append_event` |
| `rb-apple-sdk-mac.gemspec` | `add_dependency "rb-foundation-model-mac"` 削除 |
| `Gemfile` | `gem "rb-foundation-model-mac", path: "../rb-foundation-model-mac"` 削除 |
| `knowledge/lib/rb_apple_sdk_knowledge.rb` | `require_relative "rb_apple_sdk_knowledge/importer"` 削除 (importer は rake task 経由のみ load) |
| `Rakefile` (knowledge rebuild task の置き場) | importer を明示 require |
| `test/errors_test.rb` | CallError assertions 削除 |
| `test/integration/test_emitter_phase2_smoke.rb` | LOAD_PATH stub block 削除 (ruby-progressbar 連鎖が解消したので不要) |
| `docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md` | Section 17 に Phase 3 完了結果 record |

---

## Task 1: Retire `Apple::CallError` (dead class)

**Files:**
- Modify: `lib/apple_sdk_mac/errors.rb:31`
- Modify: `lib/apple_sdk_mac.rb:26`
- Modify: `test/errors_test.rb` (CallError 言及行)

**Pre-check (verify the class is truly dead):**

```bash
grep -rn "CallError" lib ext --include="*.rb" --include="*.swift" --include="*.c" --include="*.h"
```

Expected: only `lib/apple_sdk_mac.rb:26` (alias) and `lib/apple_sdk_mac/errors.rb:31` (definition) appear. No production `raise` site. If any other site is found, **STOP** and report — the class is not dead.

- [ ] **Step 1: Re-run the dead-class verification**

Run:
```bash
grep -rn "raise.*CallError\|AppleSDKMac::CallError\|Apple::CallError" lib ext --include="*.rb" --include="*.swift" --include="*.c" --include="*.h"
```

Expected:
```
lib/apple_sdk_mac.rb:26:  CallError      = ::AppleSDKMac::CallError      unless const_defined?(:CallError, false)
lib/apple_sdk_mac/errors.rb:31:  class CallError < Error; end
```

No `raise` line. Confirmed dead.

- [ ] **Step 2: Write the failing test for "CallError const is gone"**

Modify `test/errors_test.rb` — replace the existing `test_hierarchy` assertion that includes `CallError` with one that asserts the const is **removed**.

Locate the existing block:
```ruby
def test_hierarchy
  assert_operator Apple::DiscoveryError, :<, Apple::Error
  assert_operator Apple::CompileError,   :<, Apple::Error
  assert_operator Apple::CallError,      :<, Apple::Error
end
```

Replace `Apple::CallError` line with a removal assertion, and remove the CallError alias / hierarchy assertions:

```ruby
def test_hierarchy
  assert_operator Apple::DiscoveryError, :<, Apple::Error
  assert_operator Apple::CompileError,   :<, Apple::Error
end

def test_call_error_retired
  refute Apple.const_defined?(:CallError, false),
    "Apple::CallError は Phase 3 で retire (ObjcError / SwiftError へ移行済)"
  refute AppleSDKMac.const_defined?(:CallError, false),
    "AppleSDKMac::CallError は Phase 3 で retire"
end
```

Also locate and remove the line that asserts the alias points to the same class:

```ruby
assert_equal Apple::CallError,      AppleSDKMac::CallError
```

And in the iteration list (`[Apple::Error, Apple::DiscoveryError, Apple::CompileError, Apple::CallError]`), remove the `Apple::CallError` entry.

- [ ] **Step 3: Run test to verify it fails**

Run:
```bash
bundle exec rake test TESTOPTS="-n /test_call_error_retired/"
```

Expected: FAIL with `Apple::CallError is defined`.

- [ ] **Step 4: Delete the definition + alias**

Edit `lib/apple_sdk_mac/errors.rb` — remove line 31 (`class CallError < Error; end`).

Edit `lib/apple_sdk_mac.rb` — remove line 26 (`CallError = ::AppleSDKMac::CallError ...`).

- [ ] **Step 5: Run test to verify it passes**

Run:
```bash
bundle exec rake test TESTOPTS="-n /test_call_error_retired|test_hierarchy/"
```

Expected: PASS for both methods.

- [ ] **Step 6: Run full errors_test.rb**

Run:
```bash
bundle exec rake test TESTOPTS="-n /errors_test/"
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/apple_sdk_mac/errors.rb lib/apple_sdk_mac.rb test/errors_test.rb
git commit -m "$(cat <<'EOF'
refactor(errors): retire dead Apple::CallError class

Phase 2 で do/catch + rb_raise 経由の ObjcError / SwiftError dispatch
に置換済。 production raise site が無いことを grep で verify した上で
class CallError と Apple::CallError alias を削除。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add failing test for `GlueCompiler#compile` without LLM fallback

**Files:**
- Create: `test/glue_compiler/test_compiler_no_llm_fallback.rb`

**Context:** Currently `glue_compiler.rb:35` calls `try_llm` when `try_template` returns `success?: false`. After Phase 3, `compile` must return the template's failure Result directly (no LLM attempt). This task writes the RED test first.

- [ ] **Step 1: Write the failing test**

Create `test/glue_compiler/test_compiler_no_llm_fallback.rb`:

```ruby
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require_relative "../../lib/apple_sdk_mac"
require_relative "../../lib/apple_sdk_mac/glue_compiler"

class TestGlueCompilerNoLLMFallback < Test::Unit::TestCase
  class FakeCache
    attr_reader :base_dir, :sdk_version, :attempts, :inserts
    def initialize(base_dir)
      @base_dir = base_dir
      @sdk_version = "26.0"
      @attempts = []
      @inserts = []
      FileUtils.mkdir_p(File.join(base_dir, "26.0", "sources"))
      FileUtils.mkdir_p(File.join(base_dir, "26.0", "lib"))
    end
    def record_attempt(**kwargs); @attempts << kwargs; end
    def insert(**kwargs); @inserts << kwargs; end
  end

  class FakeTemplate
    def initialize(source) ; @source = source ; end
    def generate(**_kwargs) ; @source ; end
  end

  class FakeGates
    Pass = Struct.new(:pass?, :errors)
    def initialize(pass:) ; @pass = pass ; end
    def validate(*_) ; @pass ? Pass.new(true, []) : Pass.new(false, ["forced gate fail"]) ; end
  end

  class FakeSwiftc
    def initialize(success:) ; @success = success ; end
    def compile(**_kwargs)
      @success ? [true, nil] : [false, "forced swiftc fail"]
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("glue_compiler_no_llm")
    @cache = FakeCache.new(@tmpdir)
    @symbol = { name: "fooBar", signature: "void fooBar(void)", parameters_json: "[]" }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_compile_returns_template_failure_directly_when_gate_fails
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: @cache,
      runtime_dylib_path: "/dev/null",
      template_generator: FakeTemplate.new("dummy swift"),
    )
    # Inject FakeGates via instance_variable_set since GlueCompiler currently
    # constructs its own ValidationGates. Phase 3 keeps this construction; the
    # test substitutes only for assertion purposes.
    compiler.instance_variable_set(:@gates, FakeGates.new(pass: false))
    compiler.instance_variable_set(:@swiftc, FakeSwiftc.new(success: true))

    result = compiler.compile(framework: "Foundation", symbol: @symbol)

    assert_equal false, result.success?
    assert_equal "static_check", result.error_stage
    assert_match(/forced gate fail/, result.error_detail)
    # The LLM path must NOT run: only one attempt recorded (from template).
    assert_equal 1, @cache.attempts.size,
      "compile() must not retry via LLM after template failure (Phase 3 invariant)"
    assert_equal "template", @cache.attempts.first[:generator]
  end

  def test_compile_returns_template_failure_directly_when_swiftc_fails
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: @cache,
      runtime_dylib_path: "/dev/null",
      template_generator: FakeTemplate.new("import Foundation\n"),
    )
    compiler.instance_variable_set(:@gates, FakeGates.new(pass: true))
    compiler.instance_variable_set(:@swiftc, FakeSwiftc.new(success: false))

    result = compiler.compile(framework: "Foundation", symbol: @symbol)

    assert_equal false, result.success?
    assert_equal "swiftc", result.error_stage
    assert_match(/forced swiftc fail/, result.error_detail)
    assert_equal 1, @cache.attempts.size
    assert_equal "template", @cache.attempts.first[:generator]
  end

  def test_compile_constructor_rejects_llm_kwargs
    # Phase 3 removes llm_generator: / max_llm_retries: kwargs from the public
    # constructor. Their presence in a caller's code is now an ArgumentError so
    # downstream forks get a hard signal during the migration.
    assert_raise(ArgumentError) do
      AppleSDKMac::GlueCompiler.new(
        cache: @cache,
        runtime_dylib_path: "/dev/null",
        llm_generator: :something,
      )
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails (RED)**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestGlueCompilerNoLLMFallback/"
```

Expected:
- `test_compile_returns_template_failure_directly_when_gate_fails`: FAIL because `compile` currently falls through to `try_llm` and records a 2nd `compile_history` row (generator=llm, error_stage=no_llm)
- `test_compile_returns_template_failure_directly_when_swiftc_fails`: same FAIL
- `test_compile_constructor_rejects_llm_kwargs`: FAIL — `llm_generator:` is currently accepted

- [ ] **Step 3: Commit (RED)**

```bash
git add test/glue_compiler/test_compiler_no_llm_fallback.rb
git commit -m "$(cat <<'EOF'
test(glue_compiler): RED for Phase 3 no-LLM-fallback contract

compile() must return the template path's failure Result directly,
record exactly one compile_history attempt (generator=template), and
the constructor must reject the obsolete llm_generator: / max_llm_retries:
kwargs as ArgumentError. Currently failing because try_llm still runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Strip `try_llm` from `GlueCompiler`

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler.rb` (whole file rewrite — remove try_llm path)

- [ ] **Step 1: Rewrite `lib/apple_sdk_mac/glue_compiler.rb`**

Replace the entire file with:

```ruby
# frozen_string_literal: true
require "digest"
require_relative "glue_compiler/template_generator"
require_relative "glue_compiler/validation_gates"
require_relative "glue_compiler/swiftc_invoker"

module AppleSDKMac
  class GlueCompiler
    Result = Struct.new(:success?, :glue_id, :generator, :dylib_path,
                         :exported_symbol, :error_stage, :error_detail,
                         keyword_init: true)

    def initialize(cache:, runtime_dylib_path:, runtime_modules_paths: [],
                    swiftc_invoker: nil,
                    template_generator: nil,
                    knowledge_cache: nil)
      @cache = cache
      @runtime_dylib_path = runtime_dylib_path
      @runtime_modules_paths = runtime_modules_paths
      @template = template_generator || GlueCompiler::TemplateGenerator.new(knowledge_cache: knowledge_cache)
      @gates = GlueCompiler::ValidationGates.new
      @swiftc = swiftc_invoker || GlueCompiler::SwiftcInvoker.new
    end

    def compile(framework:, symbol:)
      try_template(framework: framework, symbol: symbol)
    end

    private

    def try_template(framework:, symbol:)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      exported = "glue_#{glue_id}_#{swift_id}"

      swift_source = @template.generate(framework: framework, symbol: symbol, glue_id: glue_id)
      # UnsupportedPatternError raised inside @template.generate propagates as-is
      # (intentional — no LLM fallback, the caller must handle the typed exception).

      if swift_source.nil?
        return Result.new(success?: false, error_stage: "template_nil",
                           error_detail: "template returned nil")
      end

      gate_result = @gates.validate(swift_source, framework: framework,
                                                  glue_id: glue_id, symbol: swift_id)
      unless gate_result.pass?
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                               generator: "template",
                               error_stage: "static_check",
                               error_detail: gate_result.errors.join("; "))
        return Result.new(success?: false, error_stage: "static_check",
                           error_detail: gate_result.errors.join("; "))
      end

      File.write(src, swift_source)
      ok, err = @swiftc.compile(
        source_path: src, dylib_path: dylib,
        runtime_dylib_path: @runtime_dylib_path,
        module_search_paths: @runtime_modules_paths
      )
      unless ok
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                               generator: "template",
                               error_stage: "swiftc",
                               error_detail: err)
        return Result.new(success?: false, error_stage: "swiftc", error_detail: err)
      end

      @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                     swift_source: swift_source, dylib_path: dylib,
                     exported_symbol: exported, generator: "template")
      Result.new(success?: true, glue_id: glue_id, generator: "template",
                  dylib_path: dylib, exported_symbol: exported)
    end

    def compute_glue_id(framework, symbol)
      Digest::SHA256.hexdigest(
        "#{framework}|#{symbol[:name]}|#{symbol[:signature]}|#{symbol[:parameters_json]}"
      )[0, 16]
    end
  end
end
```

Note removed: `require_relative "glue_compiler/llm_generator"`, `DEFAULT_MAX_LLM_RETRIES`, `llm_generator:` / `max_llm_retries:` kwargs, `@llm`, `@max_llm_retries`, `try_llm` method, `begin/rescue AppleSDKMac::UnsupportedPatternError; raise; end` wrapper (no longer needed since LLM path is gone).

- [ ] **Step 2: Run Phase 3 RED test to verify it now passes**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestGlueCompilerNoLLMFallback/"
```

Expected: all 3 tests PASS.

- [ ] **Step 3: Run existing glue_compiler tests to verify no regression**

Run:
```bash
bundle exec rake test TESTOPTS="-n /GlueCompiler|glue_compiler/"
```

Expected: PASS (except llm_generator_test.rb which still references LLMGenerator — that test file is removed in Task 5). If any other test breaks (e.g., a test passing `llm_generator:` kwarg), note it and address in this task by updating the test to drop the kwarg.

- [ ] **Step 4: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler.rb
git commit -m "$(cat <<'EOF'
refactor(glue_compiler): strip try_llm, compile() returns template Result directly

Phase 3 North Star: gem は runtime で Swift を書かへん。 try_template の
Result (success / failure 問わず) をそのまま return、 LLM safety-net path は
廃止。 llm_generator: / max_llm_retries: kwargs も削除した。
UnsupportedPatternError は @template.generate からそのまま propagate。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Delete LLMGenerator + LLMExamples + LLM test

**Files:**
- Delete: `lib/apple_sdk_mac/glue_compiler/llm_generator.rb`
- Delete: `lib/apple_sdk_mac/glue_compiler/llm_examples.rb`
- Delete: `test/glue_compiler/llm_generator_test.rb`
- Modify: `lib/apple_sdk_mac/glue_compiler/validation_gates.rb` (remove LLM-referencing comment at line 33)
- Modify: `lib/apple_sdk_mac/public_api.rb` (remove llm_generator wire + require_relative)

- [ ] **Step 1: Confirm no remaining import of `llm_generator` / `llm_examples`**

Run:
```bash
grep -rn "llm_generator\|llm_examples\|LLMGenerator\|LLMExamples" lib test --include="*.rb"
```

Expected only these sites (post-Task 3):
- `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` (the file itself)
- `lib/apple_sdk_mac/glue_compiler/llm_examples.rb` (the file itself)
- `lib/apple_sdk_mac/glue_compiler/validation_gates.rb:33` (comment)
- `lib/apple_sdk_mac/public_api.rb` (require_relative + wire)
- `test/glue_compiler/llm_generator_test.rb`

If any other site appears, stop and report.

- [ ] **Step 2: Strip the LLM comment from validation_gates.rb**

Open `lib/apple_sdk_mac/glue_compiler/validation_gates.rb`. Look at the comment block around line 30-35 referring to LLMGenerator's retry loop. Delete the LLM-referencing sentence; keep any other validation-gate documentation intact. Replace the multi-line comment to a one-line summary about static-check ordering only.

For example, if the existing comment is:

```ruby
# Validation gates run on every glue source string before swiftc is invoked.
# Static violations (bad @c shape, unsupported imports, raw rb_raise from
# Ruby-side code) are rejected before swiftc invocation; LLMGenerator's retry
# loop relies on this to short-circuit unsalvageable outputs without burning
# a 5-minute swiftc run.
class ValidationGates
```

Replace with:

```ruby
# Validation gates run on every glue source string before swiftc is invoked.
# Static violations (bad @c shape, unsupported imports, raw rb_raise from
# Ruby-side code) are rejected before swiftc invocation.
class ValidationGates
```

- [ ] **Step 3: Strip LLM wire from public_api.rb**

Open `lib/apple_sdk_mac/public_api.rb`. Remove:

```ruby
require_relative "glue_compiler/llm_generator"
```

And in the GlueCompiler instantiation site, remove the line:

```ruby
llm_generator: GlueCompiler::LLMGenerator.new
```

(Keep the rest of the `GlueCompiler.new(...)` call.)

- [ ] **Step 4: Delete the three files**

```bash
git rm lib/apple_sdk_mac/glue_compiler/llm_generator.rb \
       lib/apple_sdk_mac/glue_compiler/llm_examples.rb \
       test/glue_compiler/llm_generator_test.rb
```

- [ ] **Step 5: Run the full main-gem suite to verify no regression**

Run:
```bash
bundle exec rake test
```

Expected: all PASS. If any test fails referencing `LLMGenerator` / `LLMExamples`, fix the test in this same task (drop the reference).

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/validation_gates.rb lib/apple_sdk_mac/public_api.rb
git commit -m "$(cat <<'EOF'
feat(glue_compiler): delete LLMGenerator + LLMExamples + LLM-only test

Phase 3 LLM fallback path 全廃の本体。 try_llm 経路 (Task 3) を消した
後、 残った generator class / examples module / 単体 test を削除し、
public_api.rb の wire と validation_gates.rb の LLM 言及 comment も整理。
foundation_model_mac への依存はこれで lib/ から消える (gemspec / Gemfile
は Task 5 で外す)。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Drop `rb-foundation-model-mac` dependency

**Files:**
- Modify: `rb-apple-sdk-mac.gemspec` (remove add_dependency)
- Modify: `Gemfile` (remove path entry)

**Context:** `rb-foundation-model-mac` was used only by LLMGenerator (just deleted). Removing the runtime dep aligns with `feedback_gem_internal_encapsulation` memory: cloud / on-device LLM はゲム公開 path に置かへん。

- [ ] **Step 1: Confirm no remaining import**

Run:
```bash
grep -rn "foundation_model_mac\|AppleFoundationModel\|rb-foundation-model-mac" lib test --include="*.rb"
```

Expected: zero matches in `lib/` and `test/` (post-Task 4).

If any match exists in `lib/` or `test/`, stop and clean it up first.

- [ ] **Step 2: Remove the gemspec dep**

Open `rb-apple-sdk-mac.gemspec`. Find the line:

```ruby
spec.add_dependency "rb-foundation-model-mac"
```

Delete it.

- [ ] **Step 3: Remove the Gemfile path entry**

Open `Gemfile`. Find the line:

```ruby
gem "rb-foundation-model-mac", path: "../rb-foundation-model-mac"
```

Delete it.

- [ ] **Step 4: Bundle to refresh Gemfile.lock**

Run:
```bash
bundle install
```

Expected: success. `Gemfile.lock` updates and removes `rb-foundation-model-mac` (and its transitive deps if not pulled by anything else).

- [ ] **Step 5: Run the full main-gem suite**

Run:
```bash
bundle exec rake test
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add rb-apple-sdk-mac.gemspec Gemfile Gemfile.lock
git commit -m "$(cat <<'EOF'
chore(deps): drop rb-foundation-model-mac dependency

LLMGenerator が唯一の consumer やった。 Phase 3 で LLMGenerator が消えた
ので gemspec runtime dep と Gemfile path entry の両方を外す。 これで
runtime gem は cloud / on-device LM に一切依存せず、 README L8
"any public Apple framework API" は Knowledge Base + emitter のみで成立する。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Decouple Knowledge Base importer from main gem's `require` chain

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge.rb:6` (remove `require_relative "rb_apple_sdk_knowledge/importer"`)
- Modify: `Rakefile` (entry points that invoke importer)

**Context:** Currently `knowledge/lib/rb_apple_sdk_knowledge.rb` loads `importer` at top-level. Anything that does `require "rb_apple_sdk_knowledge"` (e.g. `lib/apple_sdk_mac/knowledge_cache.rb:2`) drags in `ruby-progressbar` via `importer/progress_reporter.rb`. The main gem's `Gemfile` does not declare `ruby-progressbar` — the test environment only succeeds because the knowledge sub-gem is path-loaded with its own bundled deps. Production users hit a `LoadError` when the knowledge gem is installed without the importer's dev deps.

Fix: `rb_apple_sdk_knowledge.rb` top-level requires only `version`, `sdk`, `store`. The importer is loaded only by rake tasks (already invoked explicitly under `Rakefile` rebuild path). Production runtime never touches it.

- [ ] **Step 1: Locate the rake task that drives `Importer::Pipeline`**

Run:
```bash
grep -rn "Importer::Pipeline\|require.*rb_apple_sdk_knowledge/importer" lib knowledge Rakefile --include="*.rb" --include="Rakefile*" 2>/dev/null
```

Note all entry sites. Production rebuild path is invoked from `Rakefile` (or a rakefile under `lib/tasks/`); these are the sites that must add explicit `require "rb_apple_sdk_knowledge/importer"` after Step 4.

- [ ] **Step 2: Write the failing test**

Create `test/test_knowledge_topload_no_progressbar.rb`:

```ruby
# frozen_string_literal: true
require "test/unit"

class TestKnowledgeTopLoadHasNoProgressbar < Test::Unit::TestCase
  # The main gem's runtime path (`require "rb_apple_sdk_knowledge"`) must not
  # transitively `require "ruby-progressbar"`. The importer (only consumer)
  # is rake-task-only.
  def test_top_require_does_not_load_progressbar
    # Strip the cached load state for both gems by running a subprocess so we
    # observe a clean require chain.
    ruby = RbConfig.ruby
    repo_root = File.expand_path("..", __dir__)
    script = <<~RUBY
      $LOAD_PATH.unshift("#{repo_root}/knowledge/lib")
      $LOAD_PATH.unshift("#{repo_root}/lib")
      require "rb_apple_sdk_knowledge"
      puts $LOADED_FEATURES.grep(/ruby-progressbar|ruby_progressbar|progress_reporter/).inspect
    RUBY
    out, status = Open3.capture2(ruby, "-rbundler/setup", "-e", script,
                                  chdir: repo_root)
    assert_predicate status, :success?, out
    assert_equal "[]\n", out,
      "rb_apple_sdk_knowledge top-level require must not load progressbar / progress_reporter"
  end
end
```

Note: `Open3` import. Add `require "open3"` at the top of the file.

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
bundle exec rake test TESTOPTS="-n /test_top_require_does_not_load_progressbar/"
```

Expected: FAIL — the loaded features array contains `progress_reporter` / `ruby-progressbar` because `rb_apple_sdk_knowledge.rb:6` requires the importer chain.

- [ ] **Step 4: Decouple — strip importer from top-level require**

Open `knowledge/lib/rb_apple_sdk_knowledge.rb`. Remove line 6:

```ruby
require_relative "rb_apple_sdk_knowledge/importer"
```

Leave the other 4 requires (`version`, `sdk`, `store`, `importer/kind`) — `importer/kind` is the enum-only Kind taxonomy and does not pull progress_reporter; verify by checking that file's requires:

```bash
head -10 knowledge/lib/rb_apple_sdk_knowledge/importer/kind.rb
```

If `kind.rb` does pull progress_reporter (which it should not), also remove its require from the top-level and move it under the importer entry. Otherwise leave it.

- [ ] **Step 5: Update `Rakefile` to explicit-require importer**

Open the `Rakefile` (root of repo). Locate the namespace `apple:knowledge` (`rebuild` / `rebuild_async`) tasks. At the top of those tasks' bodies, ensure an explicit `require "rb_apple_sdk_knowledge/importer"` runs before instantiating `AppleSDKKnowledge::Importer::Pipeline`.

If the existing task looks like:

```ruby
namespace :apple do
  namespace :knowledge do
    task :rebuild do
      require "rb_apple_sdk_knowledge"
      pipeline = AppleSDKKnowledge::Importer::Pipeline.new(...)
      pipeline.run
    end
  end
end
```

Change the `require` line to:

```ruby
require "rb_apple_sdk_knowledge"
require "rb_apple_sdk_knowledge/importer"
```

Apply the same edit to `rebuild_async` and any sibling task that uses `Importer::Pipeline`.

- [ ] **Step 6: Run the decoupling test to verify it passes**

Run:
```bash
bundle exec rake test TESTOPTS="-n /test_top_require_does_not_load_progressbar/"
```

Expected: PASS.

- [ ] **Step 7: Run the knowledge sub-gem's own tests to verify nothing broke**

Run:
```bash
(cd knowledge && bundle exec rake test) 2>&1 | tail -20
```

Expected: all PASS.

- [ ] **Step 8: Run the main-gem suite**

Run:
```bash
bundle exec rake test
```

Expected: all PASS. The Phase 2 smoke test (`test_emitter_phase2_smoke.rb`) will still pass — Task 7 cleans up its now-obsolete LOAD_PATH stub workaround.

- [ ] **Step 9: Commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge.rb Rakefile test/test_knowledge_topload_no_progressbar.rb
git commit -m "$(cat <<'EOF'
fix(knowledge): decouple importer chain from main gem runtime load path

main gem の runtime (`lib/apple_sdk_mac/knowledge_cache.rb`)が
`require "rb_apple_sdk_knowledge"` した時に importer/progress_reporter
経由で ruby-progressbar まで連鎖 require されとった。 production user
の Gemfile に ruby-progressbar が無いと LoadError。 importer は
rake task 専用 entry に格下げ、 top-level require からは外して main gem
の runtime 経路から完全 decouple。 rake task 側は明示 require を追加。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Remove `test_emitter_phase2_smoke.rb` LOAD_PATH stub workaround

**Files:**
- Modify: `test/integration/test_emitter_phase2_smoke.rb` (remove LOAD_PATH stub block, keep KB-exists omit gate)

**Context:** Phase 2 added a tmpdir LOAD_PATH stub for `ruby-progressbar` because the importer was loaded transitively. After Task 6 decouples the chain, the stub is dead code.

- [ ] **Step 1: Read the existing smoke test header**

Open `test/integration/test_emitter_phase2_smoke.rb`. Inspect the LOAD_PATH stub block (the `PHASE2_SMOKE_STUB_DIR` setup, the `File.write` for `ruby-progressbar.rb`, the `at_exit` cleanup). Confirm that with Task 6's decoupling, this block is unused.

- [ ] **Step 2: Run the smoke test as-is (control)**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestEmitterPhase2Smoke/"
```

Expected: PASS (Phase 2 already green; verifying we have a clean baseline before deleting the stub).

- [ ] **Step 3: Remove the stub block**

Strip:
- The `PHASE2_SMOKE_STUB_DIR` constant
- The `Dir.mkdir_p` / `File.write` lines that write `ruby-progressbar.rb`
- The `$LOAD_PATH.unshift(PHASE2_SMOKE_STUB_DIR)` line
- The `at_exit { FileUtils.rm_rf(PHASE2_SMOKE_STUB_DIR) }` line

Keep:
- `KNOWLEDGE_DB = File.expand_path("../../.rb-apple-sdk-mac/knowledge/26.4.1/sdk_knowledge.sqlite", __dir__)` constant
- `omit unless File.exist?(KNOWLEDGE_DB)` gate in each test
- All the test methods themselves (`test_swift_init_throws_emits_do_catch`, `test_unsupported_pattern_raises`, etc.)
- Any `register_transient` fixture setup with the 9-column Hash shape

- [ ] **Step 4: Run the smoke test to verify it still passes**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestEmitterPhase2Smoke/"
```

Expected: PASS — Task 6 made ruby-progressbar unnecessary, so the stub block is no longer keeping the test green.

- [ ] **Step 5: Run the full suite**

Run:
```bash
bundle exec rake test
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add test/integration/test_emitter_phase2_smoke.rb
git commit -m "$(cat <<'EOF'
refactor(test): drop ruby-progressbar LOAD_PATH stub from Phase 2 smoke

Phase 2 で tmpdir 経由の no-op stub を入れたんは importer の連鎖 require
を遮断するためやった。 Phase 3 Task 6 で knowledge sub-gem の top-level
require から importer 自体を decouple したので stub はもう不要。
KB 存在の omit gate と test method 本体は維持。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Add failing test for `Telemetry.append_event`

**Files:**
- Create: `test/test_telemetry.rb`

**Context:** Section 6.3 specifies `~/.cache/rb-apple-sdk-mac/diagnostics/<YYYY-MM-DD>.jsonl` append. `APPLE_SDK_MAC_NO_DIAGNOSTICS=1` disables. Default-on (env unset → append). One event = one JSON line. PII-free (only error_stage / framework / symbol / detail / timestamp / gem_version / kb_schema).

- [ ] **Step 1: Write the failing test**

Create `test/test_telemetry.rb`:

```ruby
# frozen_string_literal: true
require "test/unit"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../lib/apple_sdk_mac"
require_relative "../lib/apple_sdk_mac/telemetry"

class TestTelemetry < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("apple_sdk_mac_telemetry")
    @saved_env = ENV.to_h.slice("APPLE_SDK_MAC_NO_DIAGNOSTICS", "APPLE_SDK_MAC_DIAGNOSTICS_DIR")
    ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] = @tmpdir
    ENV.delete("APPLE_SDK_MAC_NO_DIAGNOSTICS")
  end

  def teardown
    ENV.delete("APPLE_SDK_MAC_DIAGNOSTICS_DIR")
    @saved_env.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def jsonl_path
    File.join(@tmpdir, "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl")
  end

  def test_append_event_writes_one_jsonl_line_when_env_unset
    AppleSDKMac::Telemetry.append_event(
      stage: "unsupported_pattern",
      framework: "Foundation",
      symbol: "Observable.value",
      detail: "swift_macro"
    )
    assert File.exist?(jsonl_path), "jsonl file should be created at #{jsonl_path}"
    lines = File.readlines(jsonl_path)
    assert_equal 1, lines.size
    row = JSON.parse(lines.first)
    assert_equal "unsupported_pattern", row["stage"]
    assert_equal "Foundation",          row["framework"]
    assert_equal "Observable.value",    row["symbol"]
    assert_equal "swift_macro",         row["detail"]
    assert row.key?("at"),         "row must include UTC timestamp under :at"
    assert row.key?("gem_version"), "row must include gem_version for telemetry triage"
    assert row.key?("kb_schema"),   "row must include kb_schema for telemetry triage"
  end

  def test_append_event_appends_to_existing_jsonl
    AppleSDKMac::Telemetry.append_event(stage: "a", framework: "F", symbol: "S", detail: "d1")
    AppleSDKMac::Telemetry.append_event(stage: "b", framework: "F", symbol: "S", detail: "d2")
    lines = File.readlines(jsonl_path)
    assert_equal 2, lines.size
    assert_equal "d1", JSON.parse(lines[0])["detail"]
    assert_equal "d2", JSON.parse(lines[1])["detail"]
  end

  def test_append_event_skips_when_env_set
    ENV["APPLE_SDK_MAC_NO_DIAGNOSTICS"] = "1"
    AppleSDKMac::Telemetry.append_event(
      stage: "compile_failed",
      framework: "Foundation",
      symbol: "anything",
      detail: "swiftc error"
    )
    refute File.exist?(jsonl_path),
      "jsonl file must NOT be created when APPLE_SDK_MAC_NO_DIAGNOSTICS=1"
  end

  def test_append_event_swallows_io_errors_silently
    # If the diagnostics dir is unwritable, telemetry must not surface the error
    # — the gem's primary path keeps working. We force EACCES by pointing
    # APPLE_SDK_MAC_DIAGNOSTICS_DIR to a path under a read-only parent.
    ro_parent = File.join(@tmpdir, "ro")
    Dir.mkdir(ro_parent)
    File.chmod(0o500, ro_parent)
    ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] = File.join(ro_parent, "diagnostics")
    begin
      assert_nothing_raised do
        AppleSDKMac::Telemetry.append_event(
          stage: "x", framework: "F", symbol: "S", detail: "d"
        )
      end
    ensure
      File.chmod(0o700, ro_parent)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails (file does not exist yet)**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestTelemetry/"
```

Expected: FAIL with `LoadError: cannot load such file -- .../lib/apple_sdk_mac/telemetry` (because Task 9 has not yet created the file).

- [ ] **Step 3: Commit (RED)**

```bash
git add test/test_telemetry.rb
git commit -m "$(cat <<'EOF'
test(telemetry): RED for Section 6.3 jsonl append + env opt-out

AppleSDKMac::Telemetry.append_event(stage:, framework:, symbol:, detail:)
が default-on で ~/.cache/rb-apple-sdk-mac/diagnostics/<date>.jsonl に 1
event = 1 行 append、 APPLE_SDK_MAC_NO_DIAGNOSTICS=1 で skip、
write 失敗時は silent (gem primary path に影響させへん) の 4 試験。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Implement `Telemetry` module

**Files:**
- Create: `lib/apple_sdk_mac/telemetry.rb`
- Modify: `lib/apple_sdk_mac.rb` (require_relative "apple_sdk_mac/telemetry")

- [ ] **Step 1: Create `lib/apple_sdk_mac/telemetry.rb`**

```ruby
# frozen_string_literal: true
require "json"
require "fileutils"
require "time"

module AppleSDKMac
  # Section 6.3 internal telemetry: append failure events to a daily jsonl
  # for gem self-improvement. Default-on; disable via env
  # APPLE_SDK_MAC_NO_DIAGNOSTICS=1. Write failures are silent (must not
  # disturb the gem's primary error-reporting path).
  module Telemetry
    DEFAULT_DIR = File.expand_path("~/.cache/rb-apple-sdk-mac/diagnostics")

    def self.append_event(stage:, framework:, symbol:, detail:)
      return if disabled?
      dir = ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] || DEFAULT_DIR
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl")
      row = {
        at: Time.now.utc.iso8601,
        stage: stage,
        framework: framework,
        symbol: symbol,
        detail: detail,
        gem_version: AppleSdkMac::VERSION,
        kb_schema: AppleSDKMac::KNOWLEDGE_BASE_SCHEMA
      }
      File.open(path, "a") { |f| f.write(JSON.generate(row) + "\n") }
    rescue SystemCallError, IOError => e
      # Diagnostics must never break the primary path. Swallow filesystem
      # errors (EACCES on read-only parent, EROFS, ENOSPC, etc.).
      warn "[apple_sdk_mac] telemetry skipped: #{e.class}: #{e.message}" if ENV["APPLE_DEBUG"]
    end

    def self.disabled?
      ENV["APPLE_SDK_MAC_NO_DIAGNOSTICS"] == "1"
    end
  end
end
```

Notes:
- The `rescue` clause names the specific error classes (`SystemCallError, IOError`). This is **not** silent rescue — it captures filesystem failures only, with an `APPLE_DEBUG` opt-in stderr trace, satisfying CLAUDE.md's "No Silent Exception Swallowing" rule (rescue with logging + explanation).
- `AppleSdkMac::VERSION` (CamelCase, defined in `lib/apple_sdk_mac/version.rb`) and `AppleSDKMac::KNOWLEDGE_BASE_SCHEMA` (constant added in Phase 2 `errors.rb`) are reused.

- [ ] **Step 2: Wire the require in `lib/apple_sdk_mac.rb`**

Open `lib/apple_sdk_mac.rb`. After the existing `require_relative "apple_sdk_mac/diagnostics"` line (around line 7), add:

```ruby
require_relative "apple_sdk_mac/telemetry"
```

- [ ] **Step 3: Run the Telemetry test to verify it passes**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestTelemetry/"
```

Expected: all 4 tests PASS.

- [ ] **Step 4: Run the full suite to verify no regression**

Run:
```bash
bundle exec rake test
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/telemetry.rb lib/apple_sdk_mac.rb
git commit -m "$(cat <<'EOF'
feat(telemetry): Section 6.3 daily jsonl append (default-on, env opt-out)

AppleSDKMac::Telemetry.append_event は dispatch / compile failure を
~/.cache/rb-apple-sdk-mac/diagnostics/<YYYY-MM-DD>.jsonl に 1 行ずつ
append する。 PII 含まへん (stage / framework / symbol / detail /
timestamp / gem_version / kb_schema のみ)。 env APPLE_SDK_MAC_NO_DIAGNOSTICS=1
で disable。 IO 失敗は SystemCallError / IOError を named rescue で
APPLE_DEBUG 経由の warn に流すだけ (primary path 不変)。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Wire Telemetry into `dispatcher` and `glue_compiler` failure paths

**Files:**
- Modify: `lib/apple_sdk_mac/dispatcher.rb` (Telemetry.append_event before each typed raise)
- Modify: `lib/apple_sdk_mac/glue_compiler.rb` (Telemetry.append_event on swiftc / static_check failure)
- Create: `test/integration/test_telemetry_wired.rb`

**Context:** Phase 2 placed typed raises in `dispatcher.rb` (`SymbolMissingError` / `GlueCompileError`) and propagates `UnsupportedPatternError` from the template generator. Each of these failure points emits one telemetry event.

- [ ] **Step 1: Write the failing wiring test**

Create `test/integration/test_telemetry_wired.rb`:

```ruby
# frozen_string_literal: true
require "test/unit"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/apple_sdk_mac"
require_relative "../../lib/apple_sdk_mac/dispatcher"
require_relative "../../lib/apple_sdk_mac/glue_compiler"
require_relative "../../lib/apple_sdk_mac/telemetry"

class TestTelemetryWired < Test::Unit::TestCase
  class FakeKnowledgeCache
    def initialize(symbol_data: nil); @symbol = symbol_data; end
    def lookup_symbol(framework:, symbol:)
      raise AppleSDKMac::FrameworkMissingError, "no F" if framework == "MissingFw"
      @symbol
    end
  end

  class FakeGlueCache
    attr_reader :base_dir, :sdk_version
    def initialize(dir); @base_dir = dir; @sdk_version = "26.0"; end
    def record_attempt(**_kwargs); end
    def insert(**_kwargs); end
    def find(*); nil; end
  end

  def setup
    @tmpdir = Dir.mktmpdir("telemetry_wired")
    @diag = Dir.mktmpdir("diag")
    ENV["APPLE_SDK_MAC_DIAGNOSTICS_DIR"] = @diag
    ENV.delete("APPLE_SDK_MAC_NO_DIAGNOSTICS")
  end

  def teardown
    ENV.delete("APPLE_SDK_MAC_DIAGNOSTICS_DIR")
    FileUtils.rm_rf(@tmpdir) if @tmpdir
    FileUtils.rm_rf(@diag) if @diag
  end

  def jsonl_lines
    path = File.join(@diag, "#{Time.now.utc.strftime('%Y-%m-%d')}.jsonl")
    return [] unless File.exist?(path)
    File.readlines(path).map { |l| JSON.parse(l) }
  end

  def test_symbol_missing_raise_emits_telemetry
    kc = FakeKnowledgeCache.new(symbol_data: nil)
    gc = FakeGlueCache.new(@tmpdir)
    dispatcher = AppleSDKMac::Dispatcher.new(knowledge_cache: kc, glue_cache: gc,
                                              glue_compiler: nil, loader: nil)
    assert_raise(AppleSDKMac::SymbolMissingError) do
      dispatcher.call(framework: "Foundation", symbol: "no_such")
    end
    events = jsonl_lines
    assert_equal 1, events.size
    assert_equal "symbol_missing", events[0]["stage"]
    assert_equal "Foundation",     events[0]["framework"]
    assert_equal "no_such",        events[0]["symbol"]
  end

  def test_unsupported_pattern_raise_emits_telemetry
    kc = FakeKnowledgeCache.new(symbol_data: { name: "x", kind: "swift_func",
                                                unsupported_pattern: "swift_macro" })
    gc = FakeGlueCache.new(@tmpdir)
    template = Class.new do
      def generate(framework:, symbol:, **)
        raise AppleSDKMac::UnsupportedPatternError.new(
          pattern: "swift_macro", framework: framework, symbol: symbol[:name]
        )
      end
    end.new
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: gc, runtime_dylib_path: "/dev/null",
      template_generator: template,
    )
    dispatcher = AppleSDKMac::Dispatcher.new(knowledge_cache: kc, glue_cache: gc,
                                              glue_compiler: compiler, loader: nil)
    assert_raise(AppleSDKMac::UnsupportedPatternError) do
      dispatcher.call(framework: "Foundation", symbol: "x")
    end
    events = jsonl_lines
    assert_equal 1, events.size
    assert_equal "unsupported_pattern", events[0]["stage"]
    assert_equal "swift_macro",         events[0]["detail"]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestTelemetryWired/"
```

Expected: FAIL — `events.size` is 0 because the dispatcher does not yet call `Telemetry.append_event`.

- [ ] **Step 3: Wire Telemetry calls in `dispatcher.rb`**

Open `lib/apple_sdk_mac/dispatcher.rb`. Find the locations where `SymbolMissingError`, `UnsupportedPatternError`, and `GlueCompileError` are raised. Add a `Telemetry.append_event` call **immediately before** each raise. Use the following stages: `symbol_missing` / `unsupported_pattern` / `compile_failed`.

For the `SymbolMissingError` raise site:

```ruby
AppleSDKMac::Telemetry.append_event(
  stage: "symbol_missing",
  framework: framework.to_s,
  symbol: symbol.to_s,
  detail: "no entry in Knowledge Base"
)
raise AppleSDKMac::SymbolMissingError, ...
```

For `UnsupportedPatternError`, the exception is raised inside `@template.generate` (called by `glue_compiler.compile`). The dispatcher catches it and re-raises. Wrap the compile call so that we observe + emit + re-raise:

```ruby
result = @glue_compiler.compile(framework: framework, symbol: symbol_record)
rescue AppleSDKMac::UnsupportedPatternError => e
  AppleSDKMac::Telemetry.append_event(
    stage: "unsupported_pattern",
    framework: framework.to_s,
    symbol: symbol.to_s,
    detail: e.respond_to?(:pattern) ? e.pattern.to_s : "unknown"
  )
  raise
```

For `GlueCompileError` (raised when `result.success?` is false after compile returns):

```ruby
unless result.success?
  AppleSDKMac::Telemetry.append_event(
    stage: "compile_failed",
    framework: framework.to_s,
    symbol: symbol.to_s,
    detail: "#{result.error_stage}: #{(result.error_detail || '')[0..200]}"
  )
  raise AppleSDKMac::GlueCompileError, ...
end
```

(Adapt to the actual existing structure of dispatcher.rb at the raise sites; do not refactor the surrounding logic.)

Also add `require_relative "telemetry"` at the top of `dispatcher.rb` if not already present.

- [ ] **Step 4: Run the wiring test to verify it passes**

Run:
```bash
bundle exec rake test TESTOPTS="-n /TestTelemetryWired/"
```

Expected: both tests PASS.

- [ ] **Step 5: Run the full suite to verify no regression**

Run:
```bash
bundle exec rake test
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/dispatcher.rb test/integration/test_telemetry_wired.rb
git commit -m "$(cat <<'EOF'
feat(dispatcher): emit Telemetry events before each typed raise

SymbolMissingError / UnsupportedPatternError / GlueCompileError の 3
typed raise を発する直前で AppleSDKMac::Telemetry.append_event を呼ぶ。
stage は symbol_missing / unsupported_pattern / compile_failed の 3 値。
event 発火後に raise (失敗 path はそのまま user に届く)。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Mark Phase 3 complete in spec doc

**Files:**
- Modify: `docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md` (Section 17 末尾に Phase 3 結果 record を append)

- [ ] **Step 1: Read the current Section 17 tail**

Read the lines from `### Phase 2 結果 (2026-05-14 完了)` to the end of the file. Find the `Phase 3 引き継ぎ:` block that lists the 5 items.

- [ ] **Step 2: Append Phase 3 results after the Phase 3 引き継ぎ block**

Add a new subsection after the `Phase 3 引き継ぎ:` block:

```markdown

### Phase 3 結果 (2026-05-14 完了)

- [x] `Apple::CallError` dead class 削除 (production raise site 無し、 ObjcError / SwiftError 階層に統合済) — T1
- [x] `GlueCompiler#compile` から `try_llm` 経路全廃、 `try_template` Result そのまま return — T2-T3
- [x] `LLMGenerator` / `LLMExamples` / 単体 test 削除、 `validation_gates.rb` の LLM comment / `public_api.rb` の wire 整理 — T4
- [x] `rb-apple-sdk-mac.gemspec` から `rb-foundation-model-mac` runtime dep 削除、 `Gemfile` path entry も削除 — T5
- [x] `knowledge/lib/rb_apple_sdk_knowledge.rb` top-level require から importer 分離、 production runtime path から ruby-progressbar 連鎖排除、 Rakefile 側 で明示 require — T6
- [x] Phase 2 で入れた `test_emitter_phase2_smoke.rb` の LOAD_PATH stub 削除 (Task 6 で連鎖が解消したため不要に) — T7
- [x] `AppleSDKMac::Telemetry.append_event` (`~/.cache/rb-apple-sdk-mac/diagnostics/<date>.jsonl` daily append、 `APPLE_SDK_MAC_NO_DIAGNOSTICS=1` opt-out、 SystemCallError / IOError named rescue で primary path 不変) — T8-T9
- [x] `dispatcher.rb` 内 3 typed raise (SymbolMissingError / UnsupportedPatternError / GlueCompileError) の直前で Telemetry.append_event 発火 — T10

Phase 4 引き継ぎ:

- `AppleSDKMac::DiscoveryError` の deprecate は `Apple.discover` lazy 化 (Section 1 transparent namespace) とペアで Phase 4 に持ち越し
- Section 1 lazy transparent namespace 本体 (`bootstrap!` 不要化、 `Apple::<F>` const_missing → Knowledge Base lookup)
- Section 7 / 8 / 9 MCP server 拡張 (search_apple_api / lookup_documentation / web_fetch)
- Phase 1 importer backlog (Consolidator hash divergence、 swift IUO-of-Optional、 nested enum case payload edge case)
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md
git commit -m "$(cat <<'EOF'
docs(specs): mark phase 3 (cleanup + telemetry) complete

Phase 3 北極星: gem は runtime で Swift を書かへん。 LLM fallback 経路
全廃 + CallError 死 class 撤去 + ruby-progressbar 連鎖排除 + Section 6.3
telemetry wiring の 11 task を完了 record。 Phase 4 引き継ぎ items
(DiscoveryError deprecate ペア / Section 1 lazy namespace / MCP 拡張 /
importer backlog) を明記。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

After writing all 11 tasks I re-read the spec items:

**Spec coverage:**

| Phase 3 引き継ぎ item | Task | OK |
|---|---|---|
| CallError → ObjcError/SwiftError 統合 | T1 (dead-class retire) | ✅ (production raise なし → 削除選択) |
| LLM fallback path 全廃 (try_llm removal) | T2-T5 | ✅ |
| Section 6.3 internal telemetry wiring | T8-T10 | ✅ |
| ruby-progressbar LoadError 根本 fix | T6-T7 | ✅ |
| DiscoveryError deprecate (Apple.discover lazy 化と同時) | — | Phase 4 へ意図的に保留 (本 plan 冒頭 "Out of scope" で宣言) |

**Placeholder scan:** no TBD / TODO / "implement later" / "add appropriate error handling" appearances. Every step shows code or commands.

**Type consistency:**
- `Telemetry.append_event(stage:, framework:, symbol:, detail:)` keyword API used identically in T8 test, T9 implementation, T10 wiring test, and T10 dispatcher wires. ✅
- `AppleSdkMac::VERSION` (CamelCase, matches Phase 2 `errors.rb`'s `UnsupportedPatternError#format_message` usage) and `AppleSDKMac::KNOWLEDGE_BASE_SCHEMA` (existing constant from Phase 2). ✅
- `result.error_stage` / `result.error_detail` accessor names in T10 dispatcher snippet match `GlueCompiler::Result` Struct from T3 rewrite. ✅

**One follow-up adjustment:** T1's removal of `Apple::CallError` will, if any out-of-repo user gem subclassed it, break that user. Acknowledge in commit but do not soften — the gem is pre-1.0 and `CallError` was never raised by production code, so consumers cannot rely on it.
