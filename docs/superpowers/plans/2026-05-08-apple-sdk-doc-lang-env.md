# APPLE_SDK_DOC_LANG Env Var Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `APPLE_SDK_DOC_LANG` as the primary env var for selecting IRB doc-translation target language, with `LANG` retained as fallback so existing usage keeps working.

**Architecture:** Priority resolution lives in the convenience layer (`rb-translation-mac/locale`) as a new class method `Translator.detect_target_lang_priority(*env_values)`, so future UI-adjacent gems can reuse the same recipe. The IRB sub-gem (`rb-apple-sdk-mac/irb`) calls it with `[ENV["APPLE_SDK_DOC_LANG"], ENV["LANG"]]`. README documents the new env var with BCP-47-only spec while still accepting POSIX `LANG` style.

**Tech Stack:** Ruby (CRuby), test-unit, Ruby gems with path-loaded logical sub-gems, t-wada style TDD with separate RED/GREEN/REFACTOR commits per CLAUDE.md.

**Why APPLE_SDK_DOC_LANG over LANG override:** `LANG` impacts irb's Reline CJK width detection, error messages, time/number formatting, and other localized libs. A dedicated env var scoped to doc translation is the conventional CLI pattern (`BUNDLE_*`, `GH_*`, `AWS_*`).

**Why no OFF escape hatch:** User decided not to add one; `detect_target_lang` already returns nil for `C`/`POSIX`/`en*`/blank, which makes the fallback chain naturally degrade. If `APPLE_SDK_DOC_LANG=C` and `LANG=ja_JP.UTF-8`, the LANG fallback wins (correct: user didn't actually pick a translation lang in primary).

**Repos touched (cross-repo, single coordinated change):**
- `~/dev/src/github.com/bash0C7/rb-translation-mac` — sub-gem `locale/`
- `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac` — sub-gem `irb/` + root README

---

## File Structure

**rb-translation-mac/locale/** (separate git repo)
- Modify: `lib/translation_mac/locale/translator.rb` — add `detect_target_lang_priority`
- Modify: `test/translator_test.rb` — add 4 specs for the new class method

**rb-apple-sdk-mac/** (current repo, branch `feature/irb-autocomplete`)
- Modify: `irb/lib/apple_sdk_mac/irb.rb` — `build_translator` uses priority resolver
- Modify: `irb/test/install_test.rb` — add 3 specs for env-var resolution behavior
- Modify: `README.md` L65-106 — document `APPLE_SDK_DOC_LANG` as primary env var

---

## Task 1: rb-translation-mac/locale — RED for detect_target_lang_priority

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-translation-mac/locale/test/translator_test.rb`

- [ ] **Step 1: Append the failing tests**

Append after `test_default_translate_proc_returns_callable` (line 115), inside the `TestTranslator` class, before its closing `end`:

```ruby
  # ---- detect_target_lang_priority (multi-source resolution) -------------

  def test_detect_target_lang_priority_picks_first_resolvable
    assert_equal "ja-JP",
      Translator.detect_target_lang_priority("ja-JP", "fr_FR")
  end

  def test_detect_target_lang_priority_falls_through_when_primary_unresolvable
    assert_equal "fr-FR",
      Translator.detect_target_lang_priority(nil, "fr_FR.UTF-8")
    assert_equal "fr-FR",
      Translator.detect_target_lang_priority("", "fr_FR")
    assert_equal "fr-FR",
      Translator.detect_target_lang_priority("C", "fr_FR")
    assert_equal "fr-FR",
      Translator.detect_target_lang_priority("en_US.UTF-8", "fr_FR")
  end

  def test_detect_target_lang_priority_returns_nil_when_all_unresolvable
    assert_nil Translator.detect_target_lang_priority(nil, "C", "")
    assert_nil Translator.detect_target_lang_priority("en", "POSIX")
  end

  def test_detect_target_lang_priority_handles_no_args
    assert_nil Translator.detect_target_lang_priority
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ~/dev/src/github.com/bash0C7/rb-translation-mac/locale && bundle exec rake test 2>&1 | tail -20
```

Expected: FAIL with `NoMethodError: undefined method 'detect_target_lang_priority'` for the four new tests.

- [ ] **Step 3: Commit RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-translation-mac
git add locale/test/translator_test.rb
git commit -m "$(cat <<'EOF'
test: add failing spec for Translator.detect_target_lang_priority

Codifies multi-source env resolution recipe: first non-nil
detect_target_lang result wins; primary that maps to nil (en/C/
POSIX/blank) falls through to next candidate. Enables UI gems to
chain their own primary env var with LANG fallback without
re-implementing the recipe.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: rb-translation-mac/locale — GREEN implement detect_target_lang_priority

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-translation-mac/locale/lib/translation_mac/locale/translator.rb`

- [ ] **Step 1: Add the method**

Insert this method right after the existing `self.detect_target_lang` (which ends at line 30, just before `# Default translate_proc adapter` comment on line 32):

```ruby
      # Resolve target lang from a priority list of env values. The first
      # value that maps to a non-nil BCP-47 tag (i.e. is not nil / blank /
      # English / C / POSIX) wins. Designed for callers that want to
      # layer their own env var (`APPLE_SDK_DOC_LANG`, `MYTOOL_LANG`, ...)
      # on top of POSIX `LANG`. Pass values in priority order.
      def self.detect_target_lang_priority(*env_values)
        env_values.each do |v|
          target = detect_target_lang(v)
          return target if target
        end
        nil
      end
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
cd ~/dev/src/github.com/bash0C7/rb-translation-mac/locale && bundle exec rake test 2>&1 | tail -20
```

Expected: PASS, all tests green (4 new + previous count).

- [ ] **Step 3: Commit GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-translation-mac
git add locale/lib/translation_mac/locale/translator.rb
git commit -m "$(cat <<'EOF'
feat: add Translator.detect_target_lang_priority for multi-source resolution

Class method takes a variadic list of env values in priority order
and returns the first that resolves to a non-nil BCP-47 tag through
detect_target_lang. Each candidate goes through the same skip rules
(nil/blank/C/POSIX/en* → fall through), so callers can layer a
gem-specific primary env var on top of POSIX LANG without writing
their own short-circuit logic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: rb-apple-sdk-mac/irb — RED for APPLE_SDK_DOC_LANG priority

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb/test/install_test.rb`

- [ ] **Step 1: Append the failing tests**

Insert these tests inside `class TestIRBInstall < Test::Unit::TestCase`, after the existing `test_install_prepends_reline_input_method_override` (line 90-94), before the class-closing `end` on line 95.

The test_helper sets up some shared cache stubs, but since these tests need to inspect `apple_translator` the simplest path is to install! with a stub knowledge_cache (covered by other tests' pattern) and read `apple_translator&.instance_variable_get(:@target_lang)`.

```ruby
  # ---- APPLE_SDK_DOC_LANG primary env var (with LANG fallback) -----------

  def with_doc_lang_env(primary, fallback)
    saved_primary = ENV["APPLE_SDK_DOC_LANG"]
    saved_lang = ENV["LANG"]
    ENV["APPLE_SDK_DOC_LANG"] = primary
    ENV["LANG"] = fallback
    yield
  ensure
    ENV["APPLE_SDK_DOC_LANG"] = saved_primary
    ENV["LANG"] = saved_lang
  end

  def install_with_stub_cache
    fake_cache = Object.new
    fake_cache.define_singleton_method(:list_frameworks) { [] }
    fake_cache.define_singleton_method(:list_framework_symbols) { |**| [] }
    fake_cache.define_singleton_method(:list_klass_methods) { |**| [] }
    fake_cache.define_singleton_method(:lookup_documentation) { |**| nil }
    AppleSDKMac::IRB.install!(knowledge_cache: fake_cache)
  end

  def resolved_target_lang
    t = AppleSDKMac::IRB.apple_translator
    t && t.instance_variable_get(:@target_lang)
  end

  def test_install_prefers_apple_sdk_doc_lang_over_lang
    with_doc_lang_env("fr-FR", "ja_JP.UTF-8") do
      install_with_stub_cache
      assert_equal "fr-FR", resolved_target_lang,
        "APPLE_SDK_DOC_LANG must take priority over LANG"
    end
  end

  def test_install_falls_back_to_lang_when_apple_sdk_doc_lang_unset
    with_doc_lang_env(nil, "ja_JP.UTF-8") do
      install_with_stub_cache
      assert_equal "ja-JP", resolved_target_lang,
        "LANG (POSIX style) must still resolve when APPLE_SDK_DOC_LANG is unset"
    end
  end

  def test_install_falls_through_apple_sdk_doc_lang_when_unresolvable
    with_doc_lang_env("C", "ja_JP.UTF-8") do
      install_with_stub_cache
      assert_equal "ja-JP", resolved_target_lang,
        "Primary env mapping to nil (C/POSIX/en*/blank) must fall through to LANG"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

The sub-gem's test runner is rake-based:

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb && bundle exec rake test TEST=test/install_test.rb 2>&1 | tail -30
```

Expected: 3 new tests FAIL because `build_translator` currently reads only `ENV["LANG"]` directly. Specifically `test_install_prefers_apple_sdk_doc_lang_over_lang` fails — `resolved_target_lang` is `"ja-JP"` (from LANG), expected `"fr-FR"`.

If the suite is delegated per CLAUDE.md "Test Execution Delegation" rule, dispatch a general-purpose subagent that just runs the rake command above and reports pass/fail counts.

- [ ] **Step 3: Commit RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
git add irb/test/install_test.rb
git commit -m "$(cat <<'EOF'
test: add failing spec for APPLE_SDK_DOC_LANG primary env var

Pins the contract: APPLE_SDK_DOC_LANG is the dedicated primary env
var for IRB doc translation target locale, LANG remains as
fallback so existing usage keeps working, and a primary that maps
to nil through detect_target_lang (C/POSIX/en*/blank) falls
through to LANG. Currently fails — build_translator reads only
ENV["LANG"].

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: rb-apple-sdk-mac/irb — GREEN modify build_translator

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb/lib/apple_sdk_mac/irb.rb` (lines 329-344)

- [ ] **Step 1: Replace the build_translator method**

Replace the existing `build_translator` method (currently lines 329-344) with this version:

```ruby
      # Resolve translation target locale from APPLE_SDK_DOC_LANG (primary,
      # documented as BCP-47 e.g. "ja-JP") and ENV["LANG"] (fallback,
      # POSIX style e.g. "ja_JP.UTF-8" also accepted). When both resolve
      # to nil, when LANG is C / POSIX / en*, or when the translation gem
      # is not installed, returns nil so doc_transform stays identity.
      def build_translator
        begin
          require "translation_mac/locale"
        rescue LoadError => e
          warn "[apple-sdk-mac irb] translation_mac/locale unavailable: #{e.message}" if ENV["APPLE_IRB_DEBUG"]
          return nil
        end
        target = ::TranslationMac::Locale::Translator.detect_target_lang_priority(
          ENV["APPLE_SDK_DOC_LANG"], ENV["LANG"]
        )
        return nil unless target
        ::TranslationMac::Locale::Translator.new(target_lang: target)
      end
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb && bundle exec rake test TEST=test/install_test.rb 2>&1 | tail -20
```

Expected: PASS, including the 3 new tests.

- [ ] **Step 3: Run the full irb sub-gem suite to verify no regression**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb && bundle exec rake test 2>&1 | tail -10
```

Expected: PASS, all tests green. Per CLAUDE.md delegation rule, may want a subagent here.

- [ ] **Step 4: Commit GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
git add irb/lib/apple_sdk_mac/irb.rb
git commit -m "$(cat <<'EOF'
feat: prefer APPLE_SDK_DOC_LANG env var with LANG fallback

build_translator now resolves the doc-translation target through
TranslationMac::Locale::Translator.detect_target_lang_priority
with APPLE_SDK_DOC_LANG as primary and ENV["LANG"] as fallback.
The new dedicated env var avoids the LANG-override side effects
on irb itself (Reline CJK width, error messages, time/number
formatting) while keeping the existing LANG=ja_JP.UTF-8 usage
working.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: rb-apple-sdk-mac — README documentation

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/README.md` lines 87-104

- [ ] **Step 1: Replace the LANG paragraph and example block**

Replace the existing paragraph + code block at L87-104 with:

```markdown
If `ENV["APPLE_SDK_DOC_LANG"]` is set to a non-English BCP-47 tag
(e.g. `ja-JP`, `fr-FR`) and the
[`rb-translation-mac`](https://github.com/bash0C7/rb-translation-mac)
gem (specifically the `translation_mac-locale` sub-gem) is
available, the doc text is translated by Apple Intelligence on the
fly via a `doc_transform` lambda hook on `DocResolver`.
`APPLE_SDK_DOC_LANG` is the documented primary input and expects
**BCP-47 only** (no charset suffix). When it is unset, `ENV["LANG"]`
is consulted as fallback and POSIX-style values like
`ja_JP.UTF-8` are accepted there too. English /
`C` / `POSIX` / unset locales pass through unchanged. The
translation gem is an optional runtime dep — sub-gem degrades
silently if absent. Per-input cache keeps the popup snappy across
re-hovers.

```
$ APPLE_SDK_DOC_LANG=ja-JP irb -r apple_sdk_mac -r apple_sdk_mac/irb
> AppleSDKMac::IRB.install!
> Apple::CoreFoundation::CFArrayAppendValue<TAB-hover>
  ┌─ candidates ─┐ ┌─ doc (ja-JP) ─────────────────────────┐
  │ ...          │ │ 配列に値を追加し、新しい最大インデック   │
  │              │ │ スを付与します。 値を追加する配列。      │
  └──────────────┘ └────────────────────────────────────────┘

# Or, fall back to LANG (POSIX style accepted here):
$ LANG=ja_JP.UTF-8 irb -r apple_sdk_mac -r apple_sdk_mac/irb
```

```

(Note the closing fence after the LANG example — markdown code block.)

- [ ] **Step 2: Verify README renders correctly**

Inspect the modified region:

```bash
sed -n '83,110p' ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/README.md
```

Expected: Paragraph reads naturally, code block fence pairs balanced, link to `rb-translation-mac` parent gem retained.

- [ ] **Step 3: Commit DOCS**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): document APPLE_SDK_DOC_LANG primary env var

Document the dedicated primary env var with BCP-47 spec
(no charset suffix), keep LANG as fallback with POSIX style
acceptance noted, and add the new APPLE_SDK_DOC_LANG=ja-JP irb
invocation example alongside the original LANG-based one for
backwards continuity.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Checklist (run after writing the plan)

- [x] **Spec coverage:**
  - APPLE_SDK_DOC_LANG primary → Tasks 3 + 4 (test + impl)
  - LANG fallback retained → Task 3 test_install_falls_back_to_lang_when_apple_sdk_doc_lang_unset, Task 5 README
  - No translation OFF escape hatch → confirmed not added
  - BCP-47 only documented → Task 5 README "**BCP-47 only** (no charset suffix)"
  - LANG style still accepted → Task 5 README "POSIX-style values like `ja_JP.UTF-8` are accepted there too", Task 1/3 tests use `ja_JP.UTF-8` for LANG fallback path
  - Cross-repo coordination → Tasks 1-2 in rb-translation-mac, Tasks 3-5 in rb-apple-sdk-mac, ordered so the locale sub-gem ships the new method before the irb sub-gem calls it
- [x] **Placeholder scan:** no TBDs, all code shown literally
- [x] **Type consistency:** `detect_target_lang_priority` signature matches between Tasks 1 (test) and 2 (impl) and 4 (caller). `apple_translator.instance_variable_get(:@target_lang)` matches existing Translator field name (line 46 of translator.rb).

---

## Execution Order Note

Tasks must execute in numeric order: Task 2 must commit (and ideally have its test running) before Task 4 runs, because Task 4's GREEN depends on `detect_target_lang_priority` existing in the path-loaded `translation_mac-locale` sub-gem. Both repos use Gemfile path-load so no version bump is required.
