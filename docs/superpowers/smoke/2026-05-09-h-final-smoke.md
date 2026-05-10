# H-2 / H-3 / H-4 final smoke transcript

Date: 2026-05-09
Branch: feature/v1.2-bootstrap-principle
SDK: 26.2

H-1 dogfood smoke (`2026-05-09-h1-smoke.md`) で add mode end-to-end が動いた
あと、 H-2 (trim mode + RedundancyScanner) / H-3 (Claude session source
fallback) / H-4 (UX polish + cleanup_stale + FactBundler design section)
を順次 land。 二度目の smoke で **trim mode + all mode + design section
+ cleanup_stale** が end-to-end で生 artifact を出すことを test-unit assert
+ rake stdout で確認した。

## 1. emitter_dev unit test 全 GREEN

```text
$ bundle exec ruby -Itest -e 'Dir["test/tooling/emitter_dev/*_test.rb"].each { |f| require_relative f }'
20 tests, 56 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions, 0 notifications
100% passed
```

H-1 ship 済の 12 test (worktree_ops 1 + branch_ops + candidate_ranker 6 +
fact_bundler 2 + source_compile_history) に対し、 +8 増設:
- worktree_ops: +3 (skip dangling symlink / stale_paths array / filter_stale by mtime)
- redundancy_scanner: +2 (twin_private_helper / class_pair_method_overlap)
- candidate_ranker: +2 (trim mode / all mode merge)
- fact_bundler: +1 (design section)

## 2. trim mode candidate 抽出

```text
$ SDK_VERSION=26.2 bundle exec rake apple:emitter:candidates MODE=trim TOP=3 OUT=tmp/smoke2/candidates.json
wrote 3 candidates to tmp/smoke2/candidates.json
```

`tmp/smoke2/candidates.json` の中身 (jq summary):

```json
{
  "mode": "trim",
  "candidates": 3,
  "first_summary": "GlueCompiler / StructInPointerMarshaller の双子 helper initialize / initialize を共通化"
}
```

RedundancyScanner が `lib/apple_sdk_mac/glue_compiler/marshallers.rb` を AST
走査して twin_private_helper を抽出 → CandidateRanker.rank_trim が score=12
の trim candidate envelope に wrap → JSON 出力。 user pick gate に提示する
形式そのまま。

## 3. all mode 動作 (compile_history table 不在 tolerate)

```text
$ SDK_VERSION=26.2 bundle exec rake apple:emitter:candidates MODE=all TOP=3 OUT=tmp/smoke2/all.json
wrote 3 candidates to tmp/smoke2/all.json
```

```text
$ jq '[.candidates[].mode] | unique' tmp/smoke2/all.json
[ "trim" ]
```

cache.sqlite に compile_history table が無い (just-bootstrapped state) でも
crash せず、 add 経路は `[]` 返却 + trim 経路で 3 candidate 出力。
`source_compile_history.rb` の `table_exists?` guard が効いとる。

## 4. fact_bundle に design section が出る

```text
$ echo "## Design ..." > tmp/emitter/design_feature_v1.2-bootstrap-principle.md
$ SDK_VERSION=26.2 bundle exec rake apple:emitter:fact_bundle \
    BRANCH=feature/v1.2-bootstrap-principle BASE=main \
    OUT=tmp/smoke2/fact.md
$ grep "^## " tmp/smoke2/fact.md
## branch & commits
## diff stat
## design        ← ★ H-4.3 で追加
## regression
## individual verification
## compile_history delta
```

design artifact を読みに行き、 fact bundle markdown の HITL gate 用 section
として正しく挿入される。 artifact 不在の section は `<missing: ...>` placeholder
で残ることも `test_compose_marks_missing_artifact` で固定済。

## 5. cleanup_stale rake task 動作

```text
$ bundle exec rake apple:emitter:cleanup_stale DAYS=7
stale worktrees (older than 7d):
  (none)
```

stale worktree 0 件。 自動削除はせえへん設計 (HITL principle: 'present, do
not destroy') どおり、 user に `git worktree remove --force <path>` を suggest
するのみ。

## 6. SKILL.md / agent definition 改訂サマリ

| change | scope |
| --- | --- |
| `## Arguments parsing` block 追加 | `--mode` / `--top` の parse + validation を明文化 (default fall-back 含む) |
| Section 1 に MCP fallback 文言追加 | chiebukuro-mcp 不在 / `[]` return / timeout の 3 ケースで workflow を止めず evidence.claude_session を空欄のまま進める |

## 7. plan ↔ impl 整合 addendum

`docs/superpowers/plans/2026-05-09-hitl-emitter-improvement.md` 冒頭に
`## Implementation status (2026-05-09 post-H-1)` を追加し、
- CandidateRanker は class form ではなく stateless module form
- Rake task env var grid (SDK_VERSION / CANDIDATES / CANDIDATE_ID / BRANCH / BASE)
- H-2 Task 2.3 Step 4 の class-form code block を `Trim mode wiring (revised)` で stateless 拡張に差し替え

を明示し、 H-2 以降の implementer dispatch が plan literal だけ読んで誤実装に
向かわんようにした。

## 結論

H-2 / H-3 / H-4 の core deliverable はすべて end-to-end で生 artifact を
出力できる。 trim mode の RedundancyScanner は noise 多めやけど、 user pick
gate でフィルタする想定どおりの minimum viable 動作。 cleanup_stale は
auto-destroy せず suggest 方式で安全。 SKILL.md の `--mode` / `--top` /
MCP fallback 文言が落ちてた箇所も埋め、 plan と impl の divergence は
addendum で固定。

H-1 から続く HITL emitter improvement tool の core 機能は完備。 次の
deliverable (compile_history delta automation や redundancy_scanner の noise
filtering) は core thesis の 「長期改善が組み込まれた状態」 を伸ばす方向の
別 phase で扱う。
