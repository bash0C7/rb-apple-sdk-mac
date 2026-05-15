# NS-0 完了 → NS-1 (Knowledge Base completeness) 着手 引き継ぎ (2026-05-15)

> 次セッションが cold start で読むことを前提とした handoff doc。
> 前 handoff: `docs/superpowers/handoffs/2026-05-15-phase4-1-complete-to-e2e-gap-analysis.md`
> 関連 spec: `docs/superpowers/specs/2026-05-15-zero-base-redesign-design.md`
> 関連 plan (NS-0): `docs/superpowers/plans/2026-05-15-ns-0-baseline-and-compile-history.md`

---

## 1. 大命題 (北極星)

README.md L8:

> Call any public Apple framework API from Ruby with no pre-declarations.

これを **literal な runtime-verifiable claim** として実現することが gem の核心。 zero-base redesign (spec doc 2026-05-15) で 9 phase (NS-0 〜 NS-8) に分けて到達する。

### 1.1 Trade-off priority (user 明示 2026-05-15、 継続)

- gem 内部の実行 overhead (bootstrap 時間 / dispatch latency / Knowledge Base ingest 時間) は **一定許容**
- user 側の「おまじない的なコード」 や「静的設定ファイル」 を不要にすることが **優先**

Memory: `feedback_user_ergonomics_over_overhead.md`

---

## 2. 直前 session で完了した内容 (NS-0)

zero-base v2.0 redesign の Phase 0 (NS-0): baseline 計測 + compile_history 復活。 大命題への寄与は **後続 phase の改善率を機械計測可能にする anchor 作り**。

### 2.1 NS-0 commits (6 commit)

```
9ffefed docs(specs): zero-base v2.0 redesign — L8 literal claim via 9 phases
3f41e2b feat(dispatcher): record_attempt on 3 typed raise paths
6a7377e fix(dispatcher): non-fatal record_attempt + tighter test assertion
a135a2d test(integration): NS-0 baseline anchor for zero-base redesign
03354a6 fix(test/integration): shell-safe baseline e2e + tighter md assert
08007f0 fix(dispatcher): tighten safe_record_attempt rescue to StandardError
```

### 2.2 NS-0 で確立された fact bundle

| 観測 | 値 (実測 2026-05-15) | 保存先 |
|---|---|---|
| examples 11 個中、 discover ゼロで動くもの | **3/11 (27%)** | `tmp/baseline-2026-05-15.md` |
| `Apple.discover` 行残存合計 | **47 行** (spec 当初想定 58 から実 grep で drift 判明) | 同上 |
| `bootstrap!` 経由で失敗する pattern | **1 件** (`audio_device_count.rb` で `TypeError: no implicit conversion of Hash into Integer` at glue_loader.rb:19 during AudioObjectGetPropertyDataSize) | 同上 |
| Telemetry jsonl 増分 (全 example run 後) | 2 行 (`symbol_missing` CoreMIDI:Missing / `compile_failed` CoreMIDI:MIDIClientCreate) | `~/.cache/rb-apple-sdk-mac/diagnostics/2026-05-15.jsonl` |
| `compile_history` table rows | 0 → **NS-0 で 3 typed raise 経路を書き込み口に追加** | `<project>/.rb-apple-sdk-mac/26.4.1/glue.sqlite` |
| Dispatcher の SQLite raise 防御 | `safe_record_attempt` (rescue StandardError + Telemetry log + non-propagate) で typed error swallow 防止済 | `lib/apple_sdk_mac/dispatcher.rb` L93-104 |

### 2.3 Test gate

| Test file | tests / assertions / fails / omits |
|---|---|
| `test/dispatcher_test.rb` | 8 / 27 / 0 / 0 |
| `test/integration/baseline_e2e_test.rb` | 4 / 36 / 0 / 1 (env-gated `RUBY_BOX_E2E=1` 用) |

### 2.4 Spec doc drift judgement (確定)

spec doc `2026-05-15-zero-base-redesign-design.md` Section 1.2 と Appendix A の数値 (58 行 / 4/11 ゼロ) は **touch しない**。 `baseline-2026-05-15.md` が source of truth。 final reviewer 推薦 (b) に従う。 spec doc の数値は indicative。

### 2.5 Pre-existing issue (NS-0 scope 外、 NS-1 と並行 fix 可能)

`RUBY_BOX=1 bundle exec rake test` 全体 sweep が 42 tests 付近で harness crash:

- `test/runtime_test_module_gating_test.rb#test_test_submodule_absent_when_env_unset` で test-unit が nil exception message を format しようとして NoMethodError、 suite halt
- 個別 file 直 invoke (`bundle exec ruby -Ilib -Itest test/...`) では問題なし
- NS-0 final reviewer 判定: **NS-1 着手 blocker やない**、 並行 fix or 後回し OK

---

## 3. 次セッションのテーマ

**NS-1 plan drafting + 実行**: Knowledge Base completeness — 5 attribute (`is_out_param` / `cf_create_rule` / `block_lifetime` / `swift_imported_name` / `objc_kind`) を ingester で完全 ingest + schema bump。 工数見積 1-2 営業日。

詳細は `docs/superpowers/specs/2026-05-15-zero-base-redesign-design.md` Section 5 (NS-1) と Section 6 (NS-2) 周辺を参照。

### 3.1 NS-1 の中核 file (要確認)

- `knowledge/lib/rb_apple_sdk_knowledge/importer/` 配下 — 既存 ingester 群
- `knowledge/lib/rb_apple_sdk_knowledge/store.rb` (or 同等) — schema 管理
- `lib/apple_sdk_mac/knowledge_cache.rb` (239 行) — Ruby side lookup
- `test/knowledge_cache_test.rb` + `knowledge/test/` 配下

### 3.2 NS-1 verification gate (spec Section 5.5)

| Assert | 内容 |
|---|---|
| `test/unit/knowledge/importer/objc_attribute_test.rb` | clang AST から 5 attribute 全 populate (fixture `*.h` 経由) |
| `test/unit/knowledge/importer/swift_overlay_attribute_test.rb` | Foundation / AVFoundation `*.swiftinterface` 由来で attribute 完全 |
| `test/unit/knowledge_cache_schema_mismatch_test.rb` | 旧 schema cache を開くと `SchemaMismatchError` raise (RED→GREEN) |
| `test/integration/kb_attribute_coverage_test.rb` | KB 全 symbol の `objc_kind` populated 率 ≥ 95% (ObjC framework only) |

NB: 既存 test convention は **flat layout** (`test/<name>_test.rb`)。 spec の `test/unit/...` paths は naming hint、 実際は `test/knowledge_importer_objc_attribute_test.rb` 形式に倒して OK (NS-0 でも plan の `test/unit/...` を `test/dispatcher_test.rb` に統合した先例あり)。

### 3.3 想定 risk

- KB rebuild が 50 分 (Phase 2 実測) — schema bump → 全件 re-ingest が走る。 detached `screen -dmS` pattern (memory `~/dev/src/CLAUDE.md` ロングバッチ規律) 必須
- swift-syntax 完全 parse は段階 B として後回し、 NS-1 では regex 版を段階 A として暫定維持 (spec Section 15 risk #6)
- clang AST 走査で attribute 取れへん symbol が残る → NS-3 LLM safety net 復活で 100% 網羅 (NS-1 で 100% 達成不要、 95% で gate)

---

## 4. 最初の action (NS-1 plan drafting)

1. **このファイル + spec doc Section 5 を読む**
2. NS-1 で触る既存 file を read:
   - `knowledge/lib/rb_apple_sdk_knowledge/importer/framework_scheduler.rb` (今 session で WorkerPool 経路分離済)
   - `knowledge/lib/rb_apple_sdk_knowledge/` 配下の sdk.rb / store.rb / importers/
   - `lib/apple_sdk_mac/knowledge_cache.rb` (CACHE_SCHEMA bump 経路確認)
3. `superpowers:writing-plans` skill を起動して `docs/superpowers/plans/2026-05-15-ns-1-knowledge-base-completeness.md` を書き下す
4. plan task 分解の目安 (sub-project 化判定):
   - 5 attribute × ingester 経路 (ObjC + Swift overlay の 2 経路) で **5-10 sub-task** 想定
   - schema bump + SchemaMismatchError raise + Rakefile rebuild trigger は 1 sub-task (前段)
   - attribute 別 sub-task (1 attribute = 1 RED→GREEN→REFACTOR の TDD cycle、 ingester + KnowledgeCache lookup test 含む)
   - KB attribute coverage integration test は最後の sub-task
5. plan user 承認後、 `superpowers:subagent-driven-development` skill で順次実行

---

## 5. 実行 mode 選択 (継続)

User 明示 (前 session): **順次 plan + Subagent-Driven 実行**。

- NS-1 plan を書く → user review → 実行 (`superpowers:subagent-driven-development`)
- 各 task: implementer → spec reviewer → code quality reviewer → mark complete
- NS-1 完了 → next handoff doc → NS-2 plan へ

---

## 6. 重要 memory rules (継続)

- **「Knowledge Base」 full spelling** (user-facing で 略禁止)
- **silent rescue 禁止** (named rescue + Telemetry log / re-raise / Result 型)
- **main 直 push は user handoff** (memory `feedback_main_branch_push_handoff.md`)
- **ローカル commit 自律進行** (commit 単位 / message / 順序は私が決める)
- **open questions は命題直結のみ** (細部 judgment は自律)
- **cache clear は rake task 経由** only (memory `cache_clear_via_rake_task.md`)
- **trade-off priority: user ergonomics > gem internal overhead** (memory `feedback_user_ergonomics_over_overhead.md`)
- **未知 unstaged 変更の責任 take プロセス**: author 履歴 verify → diff 読み解き → test green 確認 → 単独 commit
- **git 操作は subagent 委譲** (status / diff / log / add / commit / push) — Bash 直叩き禁止 (memory `~/.claude/CLAUDE.md`)
- **2 分超え batch は detached screen** pattern (`~/dev/src/CLAUDE.md` ロングバッチ規律)。 KB rebuild は対象
- **Test Execution Delegation**: `bundle exec rake test` は subagent (general-purpose) 委譲、 pass/fail と test count のみ返す
- **並列セッション scope 厳守** (memory `feedback_session_scope_creep.md`)

---

## 7. 環境状態 snapshot

- **OS**: Darwin 25.4.0 (macOS)
- **Branch**: `feature/knowledge-base-rebuild-tuning` (origin/main から **112 commits ahead**)
- **Working tree**: clean (commit `08007f0` 時点)
- **Ruby test**: `bundle exec ruby -Ilib -Itest test/dispatcher_test.rb` (8/27/0)、 `test/integration/baseline_e2e_test.rb` (4/36/0/1omit)
- **Knowledge Base**: schema 9、 163,541 symbols (Phase 2 rebuild 完了状態のまま)
- **diagnostics jsonl**: `~/.cache/rb-apple-sdk-mac/diagnostics/2026-05-15.jsonl`
- **compile glue cache**: `<project>/.rb-apple-sdk-mac/26.4.1/glue.sqlite` (CACHE_SCHEMA 1.5)

---

## 8. spec doc + plan doc 一覧 (相互参照用)

| File | 役割 |
|---|---|
| `docs/superpowers/specs/2026-05-15-zero-base-redesign-design.md` | v2.0 redesign 設計 (NS-0 〜 NS-8 全体) |
| `docs/superpowers/specs/2026-05-09-v1.2-bootstrap-principle-design.md` | v1.2 design (Phase 4 以降は v2.0 spec で superseded) |
| `docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md` | Phase 7 design (v1.0 release-quality criteria の出処) |
| `docs/superpowers/plans/2026-05-15-ns-0-baseline-and-compile-history.md` | NS-0 plan (実装済) |
| `docs/superpowers/plans/2026-05-15-ns-1-knowledge-base-completeness.md` | NS-1 plan (**次セッションで書く**) |
| `tmp/baseline-2026-05-15.md` | NS-0 で確立した baseline 観測値 (NS-X 改善率の anchor) |
