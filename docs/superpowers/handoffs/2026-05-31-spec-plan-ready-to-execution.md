# Handoff: ルールベース被覆契約 + claude -p 推論 PoC — spec/plan 完成 → 実行へ

- 日付: 2026-05-31
- ブランチ: feature/knowledge-base-rebuild-tuning
- 状態: **brainstorming + plan 完了。実装は次セッションで Subagent-Driven 実行。**

## このセッションでやったこと

ユーザ命題（このブランチは LLM 推論がうまくいかず、ルールベースも漏れが多い）に対し、二本立ての spec と実装計画を確定した。

- **Spec**: `docs/superpowers/specs/2026-05-31-rulebase-coverage-contract-and-claude-p-inference-poc-design.md` (commit bcc3409)
- **Plan**: `docs/superpowers/plans/2026-05-31-rulebase-coverage-and-claude-p-inference.md` (commit b33fdd1)

## 確定した設計判断（brainstorming で user 承認済み）

1. **ルールベース「万全」の done-state = 境界明示 + 穴塞ぎ両方**。カバー済み 8 emitter kind が end-to-end round-trip することを機械可読契約 + test matrix で実証し、`audio_device_count`(struct-in + int-out) 等の壊れた穴を塞ぎ、範囲外は loud fail させる。
2. **claude -p PoC = 抽象 + 実装 + 実証の全部**。`InferenceBackend` 抽象 + `ClaudePBackend` を第一級 backend として実装。「切り替え点が在るだけ」では不合格 — **実 failing example が推論生成 glue で e2e に正値を返すまで実証**する。
3. **過去 memory の「cloud LLM は gem 公開 path 不可」制約は user 現指示で上書き**。claude_p は第一級 backend として実装する（ただし既定 `inference_backend: :none`、cloud 発火は明示 opt-in）。→ **次セッション以降で当該 memory entry (`feedback_gem_internal_encapsulation` 等) を見直すこと**。

## アーキテクチャの核心

`glue_compiler.compile` を**唯一の合流点**にする。template 失敗時に `CoverageContract.covered?` で判定:
- 範囲内失敗 → 「穴」= バグ。`Result(success?:false)` を返し Track 1 で修正。
- 範囲外 → `inference_backend == :none` なら `OutOfCoverageError`、有効なら `try_inference` へ。
- 推論が出した Swift は**ルールと同一の ValidationGates + SwiftcInvoker + cache.insert** に通す（推論だけ別経路にしない）。

## 次セッションの入口（そのまま実行）

1. `superpowers:subagent-driven-development` を発動し、plan を Task 0 から実行。
2. **最初に Task 0 (KB rebuild) を tmux detached で起動**して走らせておく（数十分）。plan の Task 0 Step 2 に起動コマンドあり。完了は後続ターンで `grep "^DONE:" tmp/longrun/kb-rebuild-20260531.log`。
3. KB green 後、Phase 1 (Task 1-4) を逐次。**Phase 1 完了後、Track 1 (Task 5) と Track 2 (Task 6-10) は touched files disjoint で並列 dispatch 可**（user は並列を是とする方針）。
4. final code-review (Task 11) は skip 厳禁。

## 実行時の要注意（plan に書いたが重要なので再掲）

- **Task 5 (audio 穴塞ぎ) は仮定を焼かない**。root cause は marshallers.rb / template_generator.rb を行単位 read + 実験出力で確定してから直す。production code の workaround/disable で緑にしない。
- **CoverageContract の param matcher は marshallers.rb の実体に 1:1 合わせる**（plan の雛形は要調整）。乖離すると境界が嘘になる。
- e2e は `APPLE_SDK_MAC_RUN_E2E=1`、PoC は `APPLE_SDK_MAC_RUN_INFERENCE_POC=1` で env-gate。
- 検証 output は test-unit assert に乗せる（自作 raise+puts report 禁止）。PoC の事実 (test stdout / git diff / 生成 glue / branch 名) を HITL gate に出す。
- main 直 push は hook deny（handoff 案件）。merge は `--ff-only` local default、可否は user 判断。

## 現在の git 状態

- ブランチ feature/knowledge-base-rebuild-tuning、HEAD = b33fdd1 (plan commit)。
- working tree clean。spec/plan/handoff の 3 commit を追加。
- test suite は KB missing で 30 errors（Task 0 で解消する前提）。
