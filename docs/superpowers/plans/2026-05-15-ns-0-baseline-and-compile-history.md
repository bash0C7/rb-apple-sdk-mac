# NS-0: Baseline 計測 + compile_history 復活 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dispatcher の 3 typed raise 経路 (`symbol_missing` / `unsupported_pattern` / `compile_failed`) で `CompiledGlueCache#record_attempt` を呼ぶようにし、 e2e baseline (11 examples の exit / discover 行数 / bootstrap! 有無 / latency / functional output / raise) を `tmp/baseline-2026-05-15.md` に保存して後続 NS-X phase で改善率を機械計測可能にする。

**Architecture:** 既存 `Telemetry.append_event(stage: ...)` 直前の 3 raise 経路に `@cache.record_attempt(framework:, symbol:, generator:, error_stage:, error_detail:)` を追加挿入 (telemetry は jsonl daily append、 compile_history は SQLite に persist。 二重出力で観測軸を 2 つに増やす)。 baseline は test/integration/ 配下の smoke test で 11 examples の `Apple.discover` 行数と bootstrap! 有無を grep 集計、 actual run の outcome は実 SDK が必要なため `RUBY_BOX=1` env-gate して fixture record と diff。

**Tech Stack:** Ruby 4 master + RUBY_BOX=1、 test-unit gem、 SQLite3 + jsonl、 Test::Unit::TestCase 既存 convention。

---

## Spec reference

- `docs/superpowers/specs/2026-05-15-zero-base-redesign-design.md` Section 4 (NS-0)
- Verification gates: spec Section 4.3

---

## File Structure

| File | Action | 行数目安 | 責任 |
|---|---|---|---|
| `lib/apple_sdk_mac/dispatcher.rb` | Modify (L13-61) | +6 | 3 raise 直前で `@cache.record_attempt(...)` を呼ぶ |
| `test/dispatcher_test.rb` | Modify (末尾追加) | +90 | FakeCache に `record_attempt` 記録機能追加、 3 経路 assert メソッド 3 個追加 |
| `test/integration/baseline_e2e_test.rb` | Create | +130 | 11 examples を静的 grep + (env-gate で) 実行、 baseline 表と diff |
| `tmp/baseline-2026-05-15.md` | Create | +60 | 11 examples の baseline 観測表 (exit / discover 行数 / bootstrap! / latency / functional output / raise) |

---

## Task 1: Dispatcher の 3 raise 経路で `record_attempt` を呼ぶ

### Files

- Modify: `lib/apple_sdk_mac/dispatcher.rb` (L13-61)
- Modify: `test/dispatcher_test.rb` (末尾追加)

### Background

現状 `lib/apple_sdk_mac/dispatcher.rb` の 3 raise 経路 (L22 / L42 / L52) は `Telemetry.append_event` のみで `@cache.record_attempt` を呼ばない。 `glue_compiler.rb` L50/L65 では既に `record_attempt` を呼んでるので、 同じ pattern を Dispatcher 側に揃える。 `CompiledGlueCache#record_attempt` signature (`lib/apple_sdk_mac/compiled_glue_cache.rb` L140-153):

```ruby
def record_attempt(framework:, symbol:, generator:, llm_response: nil,
                    error_stage: nil, error_detail: nil, glue_id: nil)
```

### Steps

- [ ] **Step 1: Write the failing test — extend FakeCache + 3 test methods**

`test/dispatcher_test.rb` に以下を追加 (`TestDispatcher` class の最後の `def` の後、 `end` の前に挿入。 既存 FakeCache class 自体を以下に書き換えて記録機能を加える。 既存テストはこの拡張版 FakeCache で動き続ける)。

まず class FakeCache を 以下に置き換え:

```ruby
  class FakeCache
    attr_reader :attempts
    def initialize; @hits = {}; @attempts = []; end
    def lookup(framework:, symbol:); @hits[[framework, symbol]]; end
    def fake_hit!(framework, symbol, exported, dylib)
      @hits[[framework, symbol]] = {
        glue_id: "g", dylib_path: dylib, exported_symbol: exported, generator: "template"
      }
    end
    def record_attempt(**kwargs)
      @attempts << kwargs
    end
  end
```

class の末尾 (最後の `end` の直前) に以下 3 test を追加:

```ruby
  # NS-0 — Dispatcher が 3 typed raise 経路で compile_history.record_attempt
  # を必ず呼ぶ contract をピン止めする。 telemetry jsonl と compile_history
  # SQLite の二重観測点を維持。

  def test_record_attempt_on_symbol_missing
    cache = FakeCache.new
    loader = FakeLoader.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: loader, compiler: nil
    )
    assert_raise(AppleSDKMac::SymbolMissingError) do
      d.dispatch(framework: "CoreMIDI", symbol: "Missing")
    end
    assert_equal 1, cache.attempts.size
    rec = cache.attempts.first
    assert_equal "CoreMIDI", rec[:framework]
    assert_equal "Missing", rec[:symbol]
    assert_equal "symbol_missing", rec[:error_stage]
    assert_equal "knowledge_lookup", rec[:generator]
  end

  class FakeCompilerUnsupported
    def compile(**)
      raise AppleSDKMac::UnsupportedPatternError.new("variadic+block")
    end
  end

  def test_record_attempt_on_unsupported_pattern
    cache = FakeCache.new
    loader = FakeLoader.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: loader, compiler: FakeCompilerUnsupported.new
    )
    assert_raise(AppleSDKMac::UnsupportedPatternError) do
      d.dispatch(framework: "Foundation", symbol: "WeirdSym")
    end
    assert_equal 1, cache.attempts.size
    rec = cache.attempts.first
    assert_equal "Foundation", rec[:framework]
    assert_equal "WeirdSym", rec[:symbol]
    assert_equal "unsupported_pattern", rec[:error_stage]
    assert_match(/variadic\+block/, rec[:error_detail])
  end

  class FakeCompilerNoOp
    def compile(**); end  # no exception, but also produces no cache row
  end

  def test_record_attempt_on_compile_failed
    cache = FakeCache.new
    loader = FakeLoader.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: loader, compiler: FakeCompilerNoOp.new
    )
    assert_raise(AppleSDKMac::GlueCompileError) do
      d.dispatch(framework: "Foundation", symbol: "GhostSym")
    end
    assert_equal 1, cache.attempts.size
    rec = cache.attempts.first
    assert_equal "compile_failed", rec[:error_stage]
    assert_equal "Foundation", rec[:framework]
    assert_equal "GhostSym", rec[:symbol]
  end
```

- [ ] **Step 2: Run new tests to verify they fail**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bundle exec ruby -Ilib -Itest test/dispatcher_test.rb -n /test_record_attempt/
```

Expected: 3 tests FAIL — `Expected: 1 / Actual: 0` for `cache.attempts.size`。

- [ ] **Step 3: Modify `lib/apple_sdk_mac/dispatcher.rb` — add 3 record_attempt calls**

`lib/apple_sdk_mac/dispatcher.rb` を以下に書き換え (Telemetry append 直後、 raise の直前に `@cache.record_attempt(...)` を 3 経路で追加):

```ruby
# frozen_string_literal: true
require_relative "telemetry"

module AppleSDKMac
  class Dispatcher
    def initialize(knowledge_cache:, glue_cache:, loader:, compiler:)
      @knowledge = knowledge_cache
      @cache = glue_cache
      @loader = loader
      @compiler = compiler
    end

    def dispatch(framework:, symbol:, args: [])
      sym_meta = @knowledge.lookup_symbol(framework: framework, symbol: symbol)
      unless sym_meta
        Telemetry.append_event(
          stage: "symbol_missing",
          framework: framework.to_s,
          symbol: symbol.to_s,
          detail: "no entry in Knowledge Base"
        )
        @cache.record_attempt(
          framework: framework.to_s,
          symbol: symbol.to_s,
          generator: "knowledge_lookup",
          error_stage: "symbol_missing",
          error_detail: "no entry in Knowledge Base"
        )
        raise SymbolMissingError, "unknown symbol #{framework}::#{symbol}"
      end

      canonical = sym_meta[:name]
      cache_hit = @cache.lookup(framework: framework, symbol: canonical)
      if cache_hit.nil?
        begin
          @compiler.compile(framework: framework, symbol: sym_meta)
        rescue UnsupportedPatternError => e
          detail = e.respond_to?(:pattern) ? e.pattern.to_s : e.message.to_s
          Telemetry.append_event(
            stage: "unsupported_pattern",
            framework: framework.to_s,
            symbol: symbol.to_s,
            detail: detail
          )
          @cache.record_attempt(
            framework: framework.to_s,
            symbol: symbol.to_s,
            generator: "template",
            error_stage: "unsupported_pattern",
            error_detail: detail
          )
          raise
        end
        cache_hit = @cache.lookup(framework: framework, symbol: canonical)
        if cache_hit.nil?
          Telemetry.append_event(
            stage: "compile_failed",
            framework: framework.to_s,
            symbol: symbol.to_s,
            detail: "compile produced no cache row"
          )
          @cache.record_attempt(
            framework: framework.to_s,
            symbol: symbol.to_s,
            generator: "template",
            error_stage: "compile_failed",
            error_detail: "compile produced no cache row"
          )
          raise GlueCompileError, "compile failed for #{framework}::#{canonical}"
        end
      end

      fn_ptr = @loader.load(
        dylib_path: cache_hit[:dylib_path],
        exported_symbol: cache_hit[:exported_symbol]
      )
      @loader.invoke(fn_ptr, args)
    end
  end
end
```

- [ ] **Step 4: Run new tests to verify they pass**

```bash
bundle exec ruby -Ilib -Itest test/dispatcher_test.rb -n /test_record_attempt/
```

Expected: 3 tests PASS。 既存 `test_dispatch_uses_cache_hit` / `test_dispatch_uses_sym_meta_name_for_cache_lookup` も同 FakeCache の `record_attempt` no-op 経路 (compile 不到達) で PASS 継続。

- [ ] **Step 5: Full test sweep via subagent (verify no regression)**

`bundle exec rake test` は subagent (general-purpose) に委譲する (memory `~/dev/src/CLAUDE.md` Test Execution Delegation rule)。 main session の context を rake-compiler の make ログで汚さんため。

subagent prompt の骨子:

```
cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
. ~/.swiftly/env.sh
RUBY_BOX=1 bundle exec rake test

ただし出力は pass/fail 数と test count のみ返す。 baseline は 404/1022/0。
Failure があれば 該当 file:line だけ報告、 full diff は送らない。
```

Expected (subagent 報告): test count ≥ 1025 (元 1022 + 新 3)、 failure 0。 もし failure > 0 なら次 step に進まず subagent report の file:line を見て fix 後 re-run。

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/dispatcher.rb test/dispatcher_test.rb
git commit -m "$(cat <<'EOF'
feat(dispatcher): record_attempt on 3 typed raise paths

symbol_missing / unsupported_pattern / compile_failed all call
CompiledGlueCache#record_attempt before re-raising, matching the pattern
already used in glue_compiler.rb L50/L65. Restores SQLite-side failure
ledger that went silent after the LLMGenerator deletion (commit 32b6082).
Two observation points (jsonl + SQLite) for the NS-0 baseline gate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Baseline integration test + baseline 表保存

### Files

- Create: `test/integration/baseline_e2e_test.rb`
- Create: `tmp/baseline-2026-05-15.md`

### Background

11 examples の baseline 状態を **後続 phase の改善率測定の起点** として固定する。 examples の actual run には実 SDK が必要なので、 default では静的 grep (Apple.discover 行数 / bootstrap! 有無) のみ検査し、 `RUBY_BOX_E2E=1` env-gate で actual run も run/diff (CI 等向け)。

### Steps

- [ ] **Step 1: Write the failing test**

`test/integration/baseline_e2e_test.rb` を新規作成:

```ruby
# frozen_string_literal: true
require "test_helper"

# NS-0 baseline — 11 examples の事前宣言状態 (Apple.discover 行数 / bootstrap!
# 呼び出し有無) を pin down する。 後続 NS-1 〜 NS-6 phase で改善率を計測する
# anchor。 actual run gate は env-gated (実 SDK 必要)。

class BaselineE2ETest < Test::Unit::TestCase
  EXAMPLES_DIR = File.expand_path("../../examples", __dir__)
  BASELINE_MD  = File.expand_path("../../tmp/baseline-2026-05-15.md", __dir__)

  # 2026-05-15 観測値。 各 example の (discover_lines, has_bootstrap) を pin。
  # NS-6 後にこの hash は「全 example discover_lines=0」 に書き換わる契機。
  BASELINE = {
    "async_taskgroup.rb"         => { discover_lines: 7,  has_bootstrap: false },
    "audio_device_count.rb"      => { discover_lines: 0,  has_bootstrap: true },
    "avspeech_synth.rb"          => { discover_lines: 4,  has_bootstrap: false },
    "cf_string_create.rb"        => { discover_lines: 3,  has_bootstrap: false },
    "coremidi_endpoint_count.rb" => { discover_lines: 1,  has_bootstrap: true },
    "coremidi_receive.rb"        => { discover_lines: 1,  has_bootstrap: false },
    "discover_escape.rb"         => { discover_lines: 6,  has_bootstrap: true },
    "irb_completion_demo.rb"     => { discover_lines: 0,  has_bootstrap: false },
    "piano_keyboard.rb"          => { discover_lines: 20, has_bootstrap: true },
    "urlsession_download.rb"     => { discover_lines: 6,  has_bootstrap: false },
    "vision_ocr.rb"              => { discover_lines: 10, has_bootstrap: false }
  }.freeze

  def test_baseline_md_exists
    assert File.exist?(BASELINE_MD),
           "tmp/baseline-2026-05-15.md must exist (NS-0 anchor)"
  end

  def test_discover_line_count_matches_baseline
    BASELINE.each do |fname, expected|
      path = File.join(EXAMPLES_DIR, fname)
      assert File.exist?(path), "missing example: #{fname}"
      src = File.read(path)
      # match "Apple.discover" at start-of-line or after whitespace
      count = src.scan(/^\s*Apple\.discover\b/).size
      assert_equal expected[:discover_lines], count,
                   "#{fname}: discover_lines drift"
    end
  end

  def test_bootstrap_call_matches_baseline
    BASELINE.each do |fname, expected|
      path = File.join(EXAMPLES_DIR, fname)
      src = File.read(path)
      has = src.match?(/AppleSDKMac\.bootstrap!/)
      assert_equal expected[:has_bootstrap], has,
                   "#{fname}: bootstrap! presence drift"
    end
  end

  # Actual run is env-gated — requires real SDK + RUBY_BOX. CI / nightly
  # only; default `rake test` skips this body via the omit gate.
  def test_actual_run_smoke_under_ruby_box
    omit "set RUBY_BOX_E2E=1 to run actual example smoke" unless ENV["RUBY_BOX_E2E"] == "1"

    # interactive examples — skip (manual smoke only)
    interactive = %w[coremidi_receive.rb piano_keyboard.rb irb_completion_demo.rb]

    BASELINE.each do |fname, _expected|
      next if interactive.include?(fname)
      path = File.join(EXAMPLES_DIR, fname)
      out  = `. ~/.swiftly/env.sh && RUBY_BOX=1 bundle exec ruby #{path} 2>&1`
      status = $?.exitstatus
      assert_equal 0, status, "#{fname} exited non-zero:\n#{out.lines.last(10).join}"
      refute_match(/^DEFERRED\b/, out, "#{fname} emitted DEFERRED line")
    end
  end
end
```

- [ ] **Step 2: Run new test to verify it fails (baseline.md missing)**

`test/integration/` は default `rake test` から除外されてるので、 直接 ruby で実行する:

```bash
cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bundle exec ruby -Ilib -Itest test/integration/baseline_e2e_test.rb
```

Expected: `test_baseline_md_exists` FAIL ("must exist (NS-0 anchor)")、 残り 2 test (discover_line / bootstrap) は PASS (現状の値で BASELINE を書いてる)、 `test_actual_run_smoke_under_ruby_box` は omit。

- [ ] **Step 3: Create baseline 表 `tmp/baseline-2026-05-15.md`**

`tmp/baseline-2026-05-15.md` を新規作成 (e2e 観測 agent の事実をそのまま貼る形式):

```markdown
# NS-0 baseline (2026-05-15)

Snapshot taken before zero-base v2.0 redesign. 後続 NS-X phase の改善率を測る anchor。

| Example | exit | discover lines | bootstrap! | wall latency | DEFERRED in stdout | functional output | raise |
|---|---|---|---|---|---|---|---|
| async_taskgroup.rb | 0 | 7 | no | 6.745s | no | `inputs=[10,20,30] results=[20,40,60] elapsed_ms=73 parallel=true OperationQueue OK` | none |
| audio_device_count.rb | non-0 | 0 | yes | 1.921s | no | (no output before raise) | `TypeError: no implicit conversion of Hash into Integer` at glue_loader.rb:19 during `AudioObjectGetPropertyDataSize` (bootstrap! eager-define path) |
| avspeech_synth.rb | 0 | 4 | no | 8.669s | no | `speak issued ... speak completed OK` | none |
| cf_string_create.rb | 0 | 3 | no | 3.575s | no | `boxed_cfstring=... length=5 read_back=hello` + ARC OK | none |
| coremidi_endpoint_count.rb | 0 | 1 | yes | 3.511s | no | `MIDI input/output endpoints: 0` | none |
| coremidi_receive.rb | killed @5s | 1 | no | 5.020s | no | `client=... in_port=... src=0` then blocks on receive loop | none (interactive kill) |
| discover_escape.rb | 0 | 6 | yes | 2.631s | no | `CFStringCreateWithCString returned box=... / NSString.stringWithUTF8String returned ptr=...` | none |
| irb_completion_demo.rb | killed @8s | 0 | no | 8.010s | no | 3 phases of TAB completion + `irb_completion_demo OK` (functional output appears before kill) | none |
| piano_keyboard.rb | killed @30s | 20 | yes | 30.010s | no | only `Output devices:` device list, then blocks on stdin/MIDI input | none (interactive) |
| urlsession_download.rb | 0 | 6 | no | 5.597s | no | `scheme=https bytes=68 sha256=... urlsession download OK` | none |
| vision_ocr.rb | 0 | 10 | no | 7.205s | no | `observations=1 confidence=1.00 ocr=HELLO RUBY vision_ocr OK` | none |

## Telemetry baseline

`~/.cache/rb-apple-sdk-mac/diagnostics/2026-05-15.jsonl` — 0 行スタートで 全 example run 後 2 行追加:

| Event type | framework | symbol |
|---|---|---|
| symbol_missing | CoreMIDI | Missing |
| compile_failed | CoreMIDI | MIDIClientCreate |

## compile_history baseline

`<project>/.rb-apple-sdk-mac/26.4.1/glue.sqlite` `compile_history` table: **0 rows** (NS-0 Task 1 で Dispatcher の 3 raise 経路を書き込み口に追加し、 失敗 ledger を SQLite 側にも復活)。

| generator | success (compiled_glue) | fail (compile_history) |
|---|---|---|
| template | 49 | 0 |
| LLM | 0 | 0 |

## Lighthouse score for L8

- `Apple.discover` ゼロで動く example: 4/11 (37%)
- `Apple.discover` 行残存合計: 7 + 4 + 3 + 1 + 1 + 6 + 20 + 6 + 10 = **58 行**
- bootstrap! 経由で失敗する pattern: 1 (audio_device_count.rb)
- DEFERRED / TODO / FIXME line in stdout: 0

NS-8 完了時に同 観測手順で計測し直し、 上記指標が以下に収束することを assert:

- `Apple.discover` ゼロで動く example: 10/11 (`discover_escape.rb` のみ escape demo として残す)
- `Apple.discover` 行残存合計: **6** (`discover_escape.rb` の 6 行のみ)
- bootstrap! 経由失敗 pattern: 0
- DEFERRED line: 0
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
bundle exec ruby -Ilib -Itest test/integration/baseline_e2e_test.rb
```

Expected: 3 tests PASS、 1 test omit (`set RUBY_BOX_E2E=1 to run actual example smoke`)。

- [ ] **Step 5: Commit**

```bash
git add test/integration/baseline_e2e_test.rb tmp/baseline-2026-05-15.md
git commit -m "$(cat <<'EOF'
test(integration): NS-0 baseline anchor for zero-base redesign

11 examples の Apple.discover 行数 / bootstrap! 呼び出し有無 / e2e
outcome を 2026-05-15 時点で pin、 NS-1..NS-8 phase 後の改善率を機械
計測可能に。 Actual run は RUBY_BOX_E2E=1 env-gated (実 SDK 必要)。

Lighthouse: discover-free examples 4/11 (37%), discover lines total 58,
bootstrap-failure pattern 1 (audio_device_count.rb TypeError).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review summary

**Spec coverage:**
- spec §4.1 (目的: baseline 作る) — Task 2 で実装
- spec §4.2 (3 typed raise で record_attempt 呼ぶ) — Task 1 で実装
- spec §4.2 (apple:release_quality task skeleton) — **NS-8 で fill** に倒した。 NS-0 で placeholder 入れると writing-plans skill の「No Placeholders」 違反、 NS-8 plan で一括実装する
- spec §4.3 verification gates 両方 (`test/integration/baseline_e2e_test.rb` 新規 + `test/unit/compile_history_record_attempt_test.rb` 拡張) → 実 file 配置は flat convention に合わせ `test/dispatcher_test.rb` 拡張 + `test/integration/baseline_e2e_test.rb` 新規。 spec の `test/unit/` 配置は推奨に格下げ、 既存 convention 優先

**Placeholder scan:** TODO / TBD / "implement later" 等の placeholder なし。 全 step に exact code / exact command / expected output あり。

**Type consistency:** `record_attempt(framework:, symbol:, generator:, error_stage:, error_detail:)` の 5 引数 keys が dispatcher.rb / dispatcher_test.rb / 既存 glue_compiler.rb で一貫。 FakeCache の `attempts` accessor も test 内一貫。

**Verification gate per task:**
- Task 1 → Step 4 で 3 unit test PASS + Step 5 で全 suite ≥ 1025 / 0 fail
- Task 2 → Step 4 で 3 grep test PASS + 1 env-gated omit

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-15-ns-0-baseline-and-compile-history.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
