---
name: rb-apple-sdk-mac-improve-emitter
description: rb-apple-sdk-mac の static emitter coverage を継続改善する HITL workflow。 candidate を compile_history / LLM safety net log / Claude session log / static redundancy scan から ranking 提示 → user pick → git worktree 切って implementer subagent dispatch → fact bundle で「実行された事実 (test stdout / git diff / e2e log / branch name)」 を user に提示 → OK で non-ff merge / NG なら session 内対話で修正方針を決定。
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Agent, AskUserQuestion
---

# Improve Emitter (HITL Loop)

## When to invoke

User typed `/rb-apple-sdk-mac-improve-emitter [--mode=add|trim|all] [--top=N]` in the rb-apple-sdk-mac repo. Optional flags:

- `--mode` : `add` (新規 emitter 追加 candidate) / `trim` (冗長 marshaller 統合 candidate) / `all` (default)
- `--top`  : ranking 上位件数 (default 10)

## Core principles

1. **HITL gate は 2 箇所のみ** — start (USER PICK) と fact-review (USER FACT-REVIEW)。 中間で user に確認質問せん。
2. **Gate には RAW artifact を出す** — `git diff`, `bundle exec rake test` の stdout, `tmp/emitter/verify_<branch>.txt` の生 log, branch name。 LLM の自己評価サマリは gate に入れへん (memory `feedback_hitl_gate_facts_only.md`)。
3. **Verification は test-unit assert に乗る** — `assert_*` の失敗 message がそのまま fact bundle の verification セクション。 raise + puts の自作 report 禁止 (memory `feedback_test_unit_assert_as_report.md`)。
4. **Worktree isolation MANDATORY** — main checkout で speculative work を一切やらへん。 全 implementer 操作は `<repo>-emitter-<id>/` 別 worktree 内。
5. **Non-ff merge** — OK 後の merge は `--no-ff` で、 候補単位の commit cluster を残して revert-friendly にする。 push しない (memory `feedback_main_branch_push_handoff.md`)。
6. **「Knowledge Base」 はフルスペル** — user 露出文字列で「KB」略称禁止 (memory `feedback_no_kb_abbreviation.md`)。

## Workflow

```
[user invokes /rb-apple-sdk-mac-improve-emitter]
        |
        v
   [1. candidate aggregation]
        |
        v
   [2. USER PICK gate] -- cancel --> end
        |
        v
   [3. worktree create]
        |
        v
   [4. implementer subagent dispatch]
        |
        v
   [5. reviewer cycle (spec compliance + code quality)]
        |
        v
   [6. fact bundle]
        |
        v
   [7. USER FACT-REVIEW gate]
        |
   +----+----+
   | OK      | NG
   v         v
[8a. merge] [8b. session dialog]
```

### 1. Candidate aggregation

```bash
bundle exec rake apple:emitter:candidates MODE=$MODE TOP=$TOP OUT=tmp/emitter/candidates.json
```

ranker output (`tmp/emitter/candidates.json`) を Read。 さらに **chiebukuro_query_claude_session の hit を別 subagent で取得** (helper Ruby は MCP 直叩きせえへん):

```ruby
Agent({
  description: "Query Claude session log for top candidate symbols",
  subagent_type: "general-purpose",
  prompt: "Use chiebukuro_query_claude_session to find sessions in the last 30 days mentioning each of these symbols: <list from candidates.json>. Return JSON array: [{symbol, session_id, date, snippet (200 char max)}, ...]. Return empty array if no hits."
})
```

結果を candidate JSON の各 entry の `evidence.claude_session` field に merge。

**MCP fallback**: chiebukuro-mcp が wire されてない / subagent return が `[]` / dispatch が timeout した場合は、 candidate JSON の `evidence.claude_session` field を空欄のまま進めて workflow 全体は止めへん。 user に「session source 取れんかった」 を 1 行 note して fact-bundle に注記する。

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

v1 では複数選択非対応 (1 candidate / 1 worktree / 1 fact bundle 単位を厳格化)。

### 3. Worktree create

```bash
bundle exec rake apple:emitter:worktree_create CANDIDATE_ID=$ID BASE=$CURRENT_BRANCH
```

stdout に worktree_path / branch / branch_json path が出る。

Rake task が:
- candidate_id から branch name 派生 (例: `emitter/avfoundation-classmethod-bridge-20260509`)
- `git worktree add -b <branch> <worktree_path> <base_branch>`
- `.rb-apple-sdk-mac/<sdk>/{knowledge,sources,lib}` を symlink、 `cache.sqlite` のみ copy (worktree 内の試行 row が main に漏れんよう物理分離)
- `tmp/emitter/branch_<sanitized>.json` に candidate 詳細 + `worktree_path` / `branch` / `base` を保存

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

subagent 契約は `.claude/agents/emitter-implementer.md` 参照 (TDD RED/GREEN/REFACTOR 独立 commit、 `cd <worktree_path>` 後に全操作、 examples e2e wrapper 整備、 `bundle exec rake test` 全 green、 raw artifact を `tmp/emitter/{regression,verify,compile_history,design}_<branch>.{txt,md}` に tee)。

return 受領。 status code 確認:
- `DONE` / `DONE_WITH_CONCERNS` → 次 Step 5 へ
- `BLOCKED` → user に diagnostic + worktree path 提示、 同 session で対話継続

### 5. Reviewer cycle (subagent-driven-development pattern)

5a. **Spec compliance review**:

```ruby
Agent({
  description: "Spec compliance review for emitter improvement",
  subagent_type: "feature-dev:code-reviewer",
  prompt: "Review changes on branch <branch> against this spec: <recommended_action from candidate JSON>. Report only spec gaps (missing or extra). Worktree: <worktree_path>."
})
```

5b. **Code quality review**:

```ruby
Agent({
  description: "Code quality review for emitter improvement",
  subagent_type: "feature-dev:code-reviewer",
  prompt: "Review code quality of changes on branch <branch>. Worktree: <worktree_path>. Check: TDD discipline (RED/GREEN/REFACTOR commits), naming, scope (no creep), test-unit-based verification (no raise+puts self-report)."
})
```

両 reviewer fail → implementer に `send-message` で issue 投げて再 dispatch → 再 review。 両 pass で次。

### 6. Fact bundle

```bash
cd <worktree_path>
bundle exec rake apple:emitter:fact_bundle BRANCH=<branch> BASE=<base>
```

`tmp/emitter/fact_<sanitized>.md` の中身を Read、 **全文を user に提示**。

fact bundle は実行された事実 (raw artifact) のみ。 LLM 自己評価サマリは含まない:
- branch name + base
- `git log --oneline <base>..<branch>` の commit list
- `git diff --stat <base>..<branch>`
- `bundle exec rake test` の末尾 5 行 (regression summary)
- `bundle exec rake test TEST=... TESTOPTS="-n ..."` の全文 (test-unit assert message が verification report)
- compile_history delta SQL query 結果

### 7. USER FACT-REVIEW gate

`AskUserQuestion`:
- 質問: 「OK ならこの branch を base に non-ff merge + worktree remove、 NG なら session 内対話で修正方針を決めよう。 どっち?」
- options: `OK / merge` / `NG / iterate`

### 8. Merge or NG dialog

#### 8a. OK 選択 — non-ff merge

main repo の cwd で:

```bash
bundle exec rake apple:emitter:merge BRANCH=<branch> BASE=<base> WORKTREE_PATH=<worktree_path>
```

Rake task が `git checkout <base>` → `git merge --no-ff <branch>` → `git worktree remove <worktree_path>` → `git branch -d <branch>` を順に実行。 **push しない** (user の judgment、 memory `feedback_main_branch_push_handoff.md`)。

`--no-ff` 必須: candidate 単位の commit cluster を残して、 後で revert したいときに `git revert -m 1 <merge_commit>` で 1 発で戻せる history を保つ。

#### 8b. NG 選択 — session 内対話

workflow 終了せず、 同 Claude session 内で main agent と user が修正方針を対話。 worktree は維持。 必要に応じて main agent が implementer を再 dispatch (`send-message` で具体 issue を投げる) または直接 Edit で修正。 user が完全に諦めた時のみ:

```bash
git worktree remove --force <worktree_path>
git branch -D <branch>
```

## 禁止事項

- 中間で user に確認質問しない (USER PICK と USER FACT-REVIEW の 2 gate のみ)
- candidate JSON 範囲外への scope creep (memory `feedback_session_scope_creep.md`)
- 「KB」略称使用 (memory `feedback_no_kb_abbreviation.md`、 「Knowledge Base」 とフルスペル)
- LLM 自己評価サマリを gate に入れる (memory `feedback_hitl_gate_facts_only.md`、 raw artifact only)
- raise + puts の自作 verification report (memory `feedback_test_unit_assert_as_report.md`、 test-unit `assert_*` を使う)
- main checkout 内で speculative work (worktree isolation MANDATORY)
- main / base branch に直 commit (worktree 内 branch のみ)
- `--no-verify` / `--amend` (CLAUDE.md 準拠、 hook fail 時は新 commit)
- `rake test` の生 verbose log を main agent context に貼る (CLAUDE.md "Test Execution Delegation" 準拠、 subagent 経由で pass/fail + count のみ取る or `tee` で file 経由)
- merge 後の `git push` (local merge 止まり、 push は user 判断)

## Reference

- 設計詳細: `docs/superpowers/specs/2026-05-09-hitl-emitter-improvement-design.md` (Section 3 Skill Workflow / Section 4 Subagent Contract / Section 7 Rake Tasks API)
- 実装計画: `docs/superpowers/plans/2026-05-09-hitl-emitter-improvement.md` (Task 1.9)
- subagent 契約: `.claude/agents/emitter-implementer.md`
- helper Ruby: `tooling/lib/emitter_dev/*.rb`
- Rake task 定義: `tooling/lib/tasks/emitter.rake`
