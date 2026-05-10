# HITL Emitter Improvement Tool — 設計

**Date**: 2026-05-09
**Status**: Design (awaiting implementation plan)
**Scope**: rb-apple-sdk-mac monorepo 内 maintainer 専用 HITL (Human In The Loop) 改善 tool。 静的 emitter pattern の追加 / 冗長削減を user 承認 loop で回す。

---

## 1. Thesis & Constraints

### 1.1 Thesis

`v1.2-bootstrap-principle-design.md` (2026-05-09) section 6.3 risk #5 で予告された **継続改善ループ** を具体化する。 compile_history と Claude Code の試行錯誤 log を source として、 LLM 安全網に流れがちな symbol を静的 emitter で救う / 冗長な marshaller を統合する maintenance を、 maintainer (= user) の 2-gate 承認 loop で回せる tool 群を rb-apple-sdk-mac monorepo 内に整備する。

### 1.2 Constraints

1. **HITL gate は 2 箇所のみ** — start (candidate pick) と fact-review (accept / reject)。 中間 user query は禁止、 subagent は SDK developer documentation / Knowledge Base SQLite / 既存 examples を読んで自律的に進める
2. **fact-review gate は raw artifact で構成** — git diff / test runner stdout / verification stdout / branch name の生 evidence。 LLM の自己評価サマリは gate に入れない (memory `feedback_hitl_gate_facts_only.md`)
3. **verification は test-unit assert に乗る** — example を Open3 で起動して exit code / stdout を `assert_*` で検査する test class が verification report をそのまま生む。 raise + puts 自作 report は禁止 (memory `feedback_test_unit_assert_as_report.md`)
4. **branch isolation は git worktree 必須** — speculative work は `<repo>-emitter-<id>/` 別 worktree に閉じ込める。 main session の working tree を一切触らへん
5. **maintainer-only tool** — gem の files に含めず、 rubygems.org に上がらへん。 main gem の runtime dependency を増やさへん
6. **Knowledge Base のフルスペル必須** — user 露出箇所で「KB」略称使わへん (memory `feedback_no_kb_abbreviation.md`)
7. **「Apple.discover」非依存** — Ruby から見たら動的 call に見えるシンプル経路 (= bootstrap! 主体) を保つ前提で改善 candidate を提案する

### 1.3 v1.2 phasing との関係

v1.2 の Phase 4a.2 addendum / 4a.3 / 4b / 5 / 6 / 7 とは **直交**。 別ブランチで進める。 H-1 (HITL tool の minimum viable add path) は v1.2 Phase 4a.2 完了後に着手して、 compile_history が安定して埋まっとる状態を前提とする。

---

## 2. Architecture & File Layout

### 2.1 配置

```
rb-apple-sdk-mac/
├── .claude/                                              # Claude Code project-local
│   ├── skills/
│   │   └── rb-apple-sdk-mac-improve-emitter/
│   │       └── SKILL.md                                  # /rb-apple-sdk-mac-improve-emitter
│   │                                                      #   top-level workflow definition
│   └── agents/
│       └── emitter-implementer.md                        # subagent definition
│
├── tooling/                                              # helper Ruby code (gem 同梱せえへん)
│   ├── lib/
│   │   ├── emitter_dev/
│   │   │   ├── candidate_ranker.rb
│   │   │   ├── source_compile_history.rb
│   │   │   ├── source_llm_log.rb
│   │   │   ├── source_claude_session.rb                  # 注: skill 経由で MCP dispatch する形
│   │   │   ├── redundancy_scanner.rb
│   │   │   ├── fact_bundler.rb
│   │   │   ├── branch_ops.rb
│   │   │   └── worktree_ops.rb
│   │   └── tasks/
│   │       └── emitter.rake
│   └── README.md
│
├── test/tooling/emitter_dev/                             # HITL tool 自体の test
│   ├── candidate_ranker_test.rb
│   ├── redundancy_scanner_test.rb
│   ├── branch_ops_test.rb
│   ├── worktree_ops_test.rb
│   ├── fact_bundler_test.rb
│   └── end_to_end_test.rb
│
├── test/integration/                                     # examples を wrap する e2e test (既存 + 新規)
│   ├── examples_smoke_test.rb                            # 既存 (v1.2 spec section 6.1)
│   ├── examples_avfoundation_e2e_test.rb                 # 新規 candidate ごとに追加 / 拡張
│   └── examples_<framework>_e2e_test.rb                  # 同上
│
└── Rakefile                                              # `load "tooling/lib/tasks/emitter.rake"` 追加
```

### 2.2 依存方向

- `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md` は Claude Code が load し main agent context に inject
- skill 内から `Bash` で `bundle exec rake apple:emitter:<task>` を呼ぶ。 Rake task が `tooling/lib/emitter_dev/*.rb` を require
- skill 内から `Agent` で `subagent_type: general-purpose` を dispatch、 prompt に `.claude/agents/emitter-implementer.md` の中身 + task-specific context を埋め込み
- `tooling/` は **main gem の lib/ に逆依存しない** (maintainer-only、 gem 出荷物に混ぜへん)
- gemspec への影響: 無し (gemspec の files 列に tooling/ 含めへん)
- 新規 runtime dependency: 無し (development dep に Ruby `parser` gem 追加 = redundancy_scanner 用)

### 2.3 環境前提

- `bundle exec rake apple:emitter:<task>` を repo root から実行する前提
- swiftly env (`. ~/.swiftly/env.sh`) は test 実行する Rake task でだけ要求
- `RUBY_BOX=1` は test 実行 task が ENV にセット (`Open3.capture3` 内で merge)
- chiebukuro-mcp は user の MCP wire 経由 (既設定)、 helper module は MCP tool を直叩きせえへん設計

---

## 3. Skill Workflow (`/rb-apple-sdk-mac-improve-emitter`)

`.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md` が main agent context に load されたら以下の手順を踏む。

### 3.1 起動 → candidate aggregation

```
[user] /rb-apple-sdk-mac-improve-emitter [--mode=add|trim|all] [--top=N]
```

skill が Bash で:

```bash
bundle exec rake apple:emitter:candidates -- --mode=$MODE --top=$TOP --json > tmp/emitter/candidates.json
```

Rake task は 3 source (compile_history + LLM log + redundancy_scanner) を集約 → JSON で ranked list を吐く (Section 5)。

skill が `tmp/emitter/candidates.json` を Read。 さらに **chiebukuro_query_claude_session の hit 情報を別 subagent dispatch で取得** (helper Ruby は MCP 直叩きせえへん):

```ruby
Agent({
  description: "Query Claude session log for top candidate symbols",
  subagent_type: "general-purpose",
  prompt: "Use chiebukuro_query_claude_session to find recent (last 30 days) sessions mentioning each of these symbols: <list>. Return JSON: [{symbol, session_id, date, snippet_200char}, ...]"
})
```

skill が結果を candidate JSON に merge → markdown table に整形 → user 提示。

### 3.2 [USER PICK gate]

skill が `AskUserQuestion`:

> 「どの candidate に worktree 切る? (1〜N の番号 / `cancel`)」

cancel → skill 終了。 番号 → 次へ。 v1 では複数選択非対応 (1 candidate / 1 worktree / 1 fact bundle 単位を厳格化)。

### 3.3 worktree create

skill が Bash:

```bash
bundle exec rake apple:emitter:worktree_create -- --candidate-id=$ID
```

Rake task は:
- candidate_id から branch name 生成 (例: `emitter/avfoundation-classmethod-bridge-20260509`)
- `git worktree add -b <branch> <worktree_path> <base_branch>` 実行
- `EmitterDev::WorktreeOps.populate_cache` で `.rb-apple-sdk-mac/<sdk>/` を populate (Section 7 詳細)
- `tmp/emitter/branch_<sanitized>.json` に candidate 詳細 + worktree_path 保存 (subagent dispatch 用 input)
- worktree path を stdout に書く

### 3.4 implementer subagent dispatch

skill が Agent dispatch:

```ruby
Agent({
  description: "Implement emitter improvement <candidate-summary>",
  subagent_type: "general-purpose",
  prompt: File.read(".claude/agents/emitter-implementer.md")
            .gsub("__CANDIDATE_JSON__",  File.read(branch_json_path))
            .gsub("__BRANCH_NAME__",     branch_name)
            .gsub("__BASE_BRANCH__",     base_branch)
            .gsub("__WORKTREE_PATH__",   worktree_path)
})
```

subagent は isolated context で **`cd <worktree_path>` 後に**:
- 既存 examples scan + Knowledge Base query + WebFetch (Apple developer documentation) を駆使して該当 example を確定 / 必要なら新規作成
- design markdown を `tmp/emitter/design_<branch>.md` に書く
- TDD: RED → GREEN → REFACTOR の独立 commit (CLAUDE.md 準拠)
- 該当 `test/integration/examples_<framework>_e2e_test.rb` の test class 新規 / 拡張、 assert で SDK API 期待振る舞い検査
- `bundle exec rake test` 全 green 確認 (output を `tmp/emitter/regression_<branch>.txt` に tee)
- `bundle exec rake test TEST=<file> TESTOPTS="-n <method>"` で個別 verification (output を `tmp/emitter/verify_<branch>.txt` に tee)
- compile_history delta を SQL で query して `tmp/emitter/compile_history_<branch>.txt` に書く
- 最終 message に status code + raw artifact ファイル path 列挙

skill が subagent return 受領 → 次へ。

### 3.5 [USER FACT-REVIEW gate]

skill が Bash:

```bash
cd <worktree_path> && bundle exec rake apple:emitter:fact_bundle -- --branch=$BRANCH
```

`tmp/emitter/fact_<branch>.md` の内容を skill が Read → 全文 user に presented → AskUserQuestion:

> 「OK ならこの branch を base に non-ff merge + worktree remove、 NG ならこのまま session 内対話で修正方針決めよう。 どっち?」

### 3.6 merge or NG dialog

**OK 選択**:

```bash
# main repo の cwd で:
bundle exec rake apple:emitter:merge -- --branch=$BRANCH --worktree-path=$WP
```

Rake task が `git merge --no-ff <branch>` → `git worktree remove <wp>` → `git branch -d <branch>` を順に実行。 push しない (user judgment)。

**NG 選択**:

skill 終了せず、 同 Claude session 内で main agent と user が修正方針を対話。 worktree は維持。 必要に応じて main agent が implementer subagent を再 dispatch (`send-message` で issue 投げる)、 または直接修正。 user が完全に諦めた時のみ `git worktree remove --force <wp>` で掃除。

---

## 4. Subagent Contract (`.claude/agents/emitter-implementer.md`)

### 4.1 Inputs (skill が prompt で埋め込む)

```
__CANDIDATE_JSON__         # candidate 詳細 JSON
__BRANCH_NAME__            # 既に切られとる branch name
__BASE_BRANCH__            # 比較先 (feature/v1.2-bootstrap-principle 等)
__WORKTREE_PATH__          # 作業ディレクトリ (subagent は cd してから操作)
```

candidate JSON shape:

```json
{
  "id": 1,
  "mode": "add",
  "score": 87,
  "summary": "AVCaptureDevice.devicesWithMediaType: の static emitter 追加",
  "evidence": {
    "compile_history": {
      "framework": "AVFoundation",
      "symbol": "AVCaptureDevice.devicesWithMediaType:",
      "llm_invocations": 9,
      "template_successes": 0,
      "avg_retry": 2.1,
      "last_error_stages": ["template_nil", "template_nil"]
    },
    "llm_log": {
      "common_failure": "swift_call_for_class_method の bridge naming heuristic miss"
    },
    "claude_session": {
      "related_session_id": "abc-...",
      "date": "2026-05-08T19:42",
      "snippet": "user の試行錯誤抜粋 (200 char)"
    }
  },
  "recommended_action": "新 marshaller `class_method_swift_overlay` 追加 / SwiftBridgeName.from_kb 経路強化"
}
```

### 4.2 Mandatory steps

1. `cd __WORKTREE_PATH__` 後、 全操作はこの worktree 内で実行 (main repo を一切触らへん)
2. **example resolution** (自律):
   - `examples/*.rb` を Glob + Read で全 scan
   - candidate symbol を直接呼ぶ example あれば採用
   - 無ければ Apple developer documentation を WebFetch、 Knowledge Base SQLite query、 既存 examples の skeleton 倣って新 example を作成 → branch に commit
   - user に query しない。 確信持てない場合は最も近い既存 example fallback で進めて fact bundle に明示
3. **design markdown** を `tmp/emitter/design_<branch>.md` に書く
   - 新 marshaller class outline / REGISTRY entry / `broken?` trigger / 既存 caller 改変箇所 / 想定 test cases
   - trim mode なら統合先 + caller migration + 既存 test preservation 戦略
4. **TDD cycle** (CLAUDE.md 準拠):
   - RED commit: 失敗 test のみ (`test: RED — <feature>`)
   - GREEN commit: 最小実装 (`feat: GREEN — <feature>`)
   - REFACTOR commit: 不要ならスキップ可
   - 各 commit に `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
5. **examples e2e wrapper** を整備 (Section 6 詳細):
   - `test/integration/examples_<framework>_e2e_test.rb` の test class を新規 / 拡張
   - 該当 example 起動 → exit code + stdout を `assert_*` で検査
6. **regression** 確認:
   - `bundle exec rake test 2>&1 | tee tmp/emitter/regression_<branch>.txt`
   - 0 failures / 0 errors / 0 pendings 必須
7. **individual verification**:
   - `bundle exec rake test TEST=<file> TESTOPTS="-n <method>" 2>&1 | tee tmp/emitter/verify_<branch>.txt`
8. **compile_history delta** を SQL で query:
   - `sqlite3 .rb-apple-sdk-mac/<sdk>/cache.sqlite "SELECT ..." > tmp/emitter/compile_history_<branch>.txt`
9. 最終 message に status code + raw artifact 一覧

### 4.3 Status codes

- `DONE`: 1〜9 全成功 → fact-review gate へ
- `DONE_WITH_CONCERNS`: 動いとるが懸念あり (例: e2e は通ったが fallback example 採用、 indirect coverage) → fact bundle に concerns 記載 + 通常 gate
- `BLOCKED`: 自律探索しても進まへん real blocker のみ (例: WebFetch 一切 fail / SQLite corrupt / branch 切れない / rake test green にならへん) → skill が user に diagnostic + worktree path 提示、 同 session で対話継続

`NEEDS_CONTEXT` は廃止 (中間 user query 禁止)。

### 4.4 禁止事項

- main / base branch に直 commit (worktree 内 branch のみ)
- `--no-verify` / `--amend` (CLAUDE.md 準拠、 hook fail 時は新 commit)
- candidate JSON 範囲外への scope creep (memory `feedback_session_scope_creep.md`)
- 「KB」略称使用 (memory `feedback_no_kb_abbreviation.md`)
- silent rescue / `omit "reason"` (test-unit 3.7.7 omit bug、 pending 不要なら commit-out で代替)
- `rm -rf` 直叩き (cache 操作は rake task 経由、 memory `cache_clear_via_rake_task.md`)
- 推測で kind 値書く (memory `feedback_importer_kind_canonical.md`、 SQLite verify 必須)
- raise + puts の自作 verification report (memory `feedback_test_unit_assert_as_report.md`、 必ず test-unit assert)

### 4.5 Reviewer cycles

skill が implementer subagent の DONE 受領後:

1. **spec compliance review** dispatch (`subagent_type: feature-dev:code-reviewer`): candidate JSON の `recommended_action` と実装が一致するか
2. spec 通れば **code quality review** dispatch: TDD discipline / scope / 命名 / 既存 pattern 踏襲を check
3. どちらも fail → implementer 再 dispatch (`send-message` で issue 投げる) → fix → 再 review

両 review pass 後に fact-review gate (Section 3.5)。

---

## 5. Source Aggregation & Candidate Ranker

### 5.1 Source 1: compile_history SQLite

**Path**: `<project_root>/.rb-apple-sdk-mac/<sdk_version>/cache.sqlite`
**Reader**: `tooling/lib/emitter_dev/source_compile_history.rb`

**Query 概念形** (実 column は `.schema compile_history` で確認):

```sql
SELECT framework, symbol,
       SUM(CASE WHEN generator = 'llm'      THEN 1 ELSE 0 END) AS llm_count,
       SUM(CASE WHEN generator = 'template' THEN 1 ELSE 0 END) AS tpl_count,
       AVG(retry_count) FILTER (WHERE generator = 'llm')         AS avg_retry,
       group_concat(DISTINCT error_stage)                         AS error_stages
FROM compile_history
GROUP BY framework, symbol
HAVING llm_count > 0
ORDER BY llm_count DESC, avg_retry DESC;
```

**Score (add mode 用)**:

```
add_score(symbol) = llm_count * 10
                  + avg_retry * 3
                  + (template_nil ∈ error_stages ? 5 : 0)
                  - tpl_count * 1
```

### 5.2 Source 2: LLM safety net log

`compile_history.error_detail` / `error_stage` 列の集計を score 補正に使う。 `swiftc fail` 多い → bridge naming / Swift overlay 系 candidate、 `llm_empty` 多い → prompt 改善 (= emitter 改善ではないので score 下げ)。

**Reader**: `tooling/lib/emitter_dev/source_llm_log.rb`

### 5.3 Source 3: chiebukuro_query_claude_session

**用途**: Claude Code session jsonl の試行錯誤を candidate に紐付ける。 user が手動で同じ symbol を試した形跡を hint として取る。

**実装**: helper Ruby は MCP 直叩きせえへん。 skill が candidate ranker の出力 (上位 N seed) を受け取り、 次に **専用 subagent dispatch** で chiebukuro_query_claude_session を query させ、 結果を candidate JSON に merge する形 (Section 3.1)。

**Score 影響 (add mode 用)**:

```
add_score += claude_session_hit_count * 2
add_score += recent_session_within_7days ? 8 : 0
```

### 5.4 Source 4: redundancy scanner (trim mode)

**Reader**: `tooling/lib/emitter_dev/redundancy_scanner.rb`

**入力**: `lib/apple_sdk_mac/glue_compiler/marshallers.rb` のソース (Ruby `parser` gem で AST 取得)
**出力**: redundancy candidate の配列

**v1 検出 heuristic**:

| heuristic | 例 | trim_score |
|---|---|---|
| 同名 private method 2 箇所 (引数 arity 同一、 body overlap > 70%) | `IntMarshaller#scalar_type_token` vs `FloatMarshaller#scalar_float_type` | 12 |
| Marshaller 2 class が同 method set + 同 REGISTRY key prefix | `BlockPersistentMarshaller` vs `BlockPersistentVoidMarshaller` | 10 |
| Marshaller 2 class が overlapping input domain (kind key の prefix 共通) | `OpaqueRefMarshaller` vs `CFTypeRefMarshaller` | 8 |
| Marshaller class 内の重複した Knowledge Base lookup (3 回以上同じ field 取得) | `StructInMarshaller` vs `StructInPointerMarshaller` field load | 6 |

```
trim_score(candidate) = heuristic_score
                       - test_coverage(involved_classes) * 0.5
                       + duplication_loc_count * 0.3
```

### 5.5 Unified ranking

| --mode | 含める source |
|---|---|
| add | source 1+2+3 のみ、 score = add_score |
| trim | source 4 のみ、 score = trim_score |
| all (default) | 全部、 score = mode 別 score を 0〜100 に正規化、 mode 列で区別 |

top N (default 10、 `--top=N` で上書き)。 同 score の場合 add 優先。

### 5.6 Output JSON shape

`tmp/emitter/candidates.json`:

```json
{
  "generated_at": "2026-05-09T20:15:00Z",
  "mode": "all",
  "top": 10,
  "candidates": [
    {
      "id": 1,
      "mode": "add",
      "score": 87,
      "summary": "AVCaptureDevice.devicesWithMediaType: の static emitter 追加",
      "evidence": { "compile_history": {...}, "llm_log": {...}, "claude_session": {...} },
      "recommended_action": "新 marshaller `class_method_swift_overlay` 追加"
    }
  ]
}
```

`verification_example` field は含めない (subagent が worktree 内で自律解決、 Section 4.2 step 2)。

---

## 6. Verification (test-unit + rake test)

### 6.1 Examples wrapper

各 example file に対応する test class を `test/integration/` に置く:

```ruby
# test/integration/examples_avfoundation_e2e_test.rb
require "test_helper"
require "open3"

class ExamplesAVFoundationE2ETest < Test::Unit::TestCase
  def test_avspeech_synth
    out, err, status = Open3.capture3(
      ENV.to_h.merge("RUBY_BOX" => "1"),
      "bundle", "exec", "ruby", "-Ilib", "-Iext",
      "examples/avspeech_synth.rb"
    )
    assert_equal 0, status.exitstatus, "stderr=#{err}"
    assert_match(/OK: spoke utterance/, out)
  end
end
```

example 自体は普通の Ruby script (`AppleSDKMac.bootstrap!` + 期待振る舞いの SDK call + 簡素 puts)。 「想定通りか」 assertion は test class 側の `assert_*`。

### 6.2 全体 regression suite

`bundle exec rake test` が:

- 既存 unit test (`test/glue_compiler/marshallers/*_test.rb` 等)
- integration test (`test/integration/examples_*_e2e_test.rb` — 1 example = 1 test method)
- HITL tool 自体の test (`test/tooling/emitter_dev/*_test.rb`)

を全部回す。 candidate 改修 worktree 内で **0 failures / 0 errors / 0 pendings** が必須。

### 6.3 個別 candidate verification (subset)

```bash
bundle exec rake test \
  TEST=test/integration/examples_avfoundation_e2e_test.rb \
  TESTOPTS="-n test_avspeech_synth"
```

test-unit の出力 (assert 失敗時は assert detail 含む) がそのまま fact bundle の verification セクション。

### 6.4 単独 e2e Rake task は廃止

`apple:emitter:e2e` task は作らへん。 上記 `rake test TESTOPTS="-n ..."` で代替。

---

## 7. Rake Tasks API + Worktree

### 7.1 Task 一覧

```
apple:emitter:candidates       # 4 source aggregate → tmp/emitter/candidates.json
apple:emitter:worktree_create  # git worktree + branch + cache populate
apple:emitter:fact_bundle      # tmp/emitter/* を読んで fact_<branch>.md 組み立て
apple:emitter:merge            # git merge --no-ff、 worktree remove、 branch delete (local only)
```

### 7.2 `apple:emitter:candidates`

```ruby
namespace :apple do
  namespace :emitter do
    desc "Aggregate sources and rank emitter improvement candidates"
    task :candidates do
      mode = ENV.fetch("MODE", "all")
      top  = Integer(ENV.fetch("TOP", "10"))
      out  = ENV.fetch("OUT", "tmp/emitter/candidates.json")

      ranker = EmitterDev::CandidateRanker.new(
        project_root: AppleSDKMac.cache_dir.then { |d| File.dirname(d) },
        sdk_version:  AppleSDKKnowledge::SDK.current_version,
      )
      candidates = ranker.rank(mode: mode, top: top)
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, JSON.pretty_generate(candidates))
      puts "wrote #{candidates.fetch('candidates').size} candidates to #{out}"
    end
  end
end
```

副作用: compile_history SQLite read-only、 redundancy_scanner は marshallers.rb を AST parse。 chiebukuro session source は skill 側で別 subagent 経由 merge。

### 7.3 `apple:emitter:worktree_create`

```ruby
desc "Create worktree + branch + populate cache for picked candidate"
task :worktree_create do
  candidate_id = Integer(ENV.fetch("CANDIDATE_ID"))
  base_branch  = ENV.fetch("BASE", "feature/v1.2-bootstrap-principle")
  candidates   = JSON.parse(File.read("tmp/emitter/candidates.json"))
  cand         = candidates.fetch("candidates").find { |c| c["id"] == candidate_id }
  raise "candidate #{candidate_id} not found" unless cand

  branch_name   = EmitterDev::BranchOps.derive_name(cand)
  worktree_path = "../rb-apple-sdk-mac-emitter-#{candidate_id}"
  sdk_version   = AppleSDKKnowledge::SDK.current_version

  sh "git worktree add -b #{branch_name} #{worktree_path} #{base_branch}"
  EmitterDev::WorktreeOps.populate_cache(
    worktree_path: worktree_path,
    main_root:     Dir.pwd,
    sdk_version:   sdk_version
  )
  File.write("tmp/emitter/branch_#{branch_name.tr('/', '_')}.json",
             JSON.pretty_generate(cand.merge(
               "branch"        => branch_name,
               "base"          => base_branch,
               "worktree_path" => worktree_path
             )))
  puts worktree_path
end
```

### 7.4 Worktree cache populate 戦略

`git worktree` は **tracked file のみ** copy する。 `.rb-apple-sdk-mac/` は gitignore されとるから worktree では空で出発する。 `apple:knowledge:rebuild` は 2.5h、 prohibitive。

`EmitterDev::WorktreeOps.populate_cache` で hybrid:

| Path | 戦略 | 理由 |
|---|---|---|
| `.rb-apple-sdk-mac/<sdk>/knowledge/` | symlink | 53MB read-only、 copy 無駄、 改修 target でもない |
| `.rb-apple-sdk-mac/<sdk>/sources/`, `lib/` | symlink | dylib は content_hash key で衝突しない、 共有 OK |
| `.rb-apple-sdk-mac/<sdk>/cache.sqlite` (compile_history) | copy | mutable、 worktree 内の試行 row が main に漏れんよう物理分離。 NG discard で copy ごと消える |

```ruby
# tooling/lib/emitter_dev/worktree_ops.rb 抜粋
def self.populate_cache(worktree_path:, main_root:, sdk_version:)
  src = File.join(main_root, ".rb-apple-sdk-mac", sdk_version)
  dst = File.join(worktree_path, ".rb-apple-sdk-mac", sdk_version)
  FileUtils.mkdir_p(dst)
  FileUtils.ln_s(File.join(src, "knowledge"), File.join(dst, "knowledge"))
  FileUtils.ln_s(File.join(src, "sources"),   File.join(dst, "sources"))
  FileUtils.ln_s(File.join(src, "lib"),       File.join(dst, "lib"))
  FileUtils.cp(File.join(src, "cache.sqlite"), File.join(dst, "cache.sqlite"))
end
```

### 7.5 `apple:emitter:fact_bundle`

```ruby
desc "Assemble fact bundle markdown from artifacts under tmp/emitter/"
task :fact_bundle do
  branch = ENV.fetch("BRANCH")
  base   = ENV.fetch("BASE", "feature/v1.2-bootstrap-principle")
  out    = ENV.fetch("OUT", "tmp/emitter/fact_#{branch.tr('/', '_')}.md")

  bundler = EmitterDev::FactBundler.new(branch: branch, base: base)
  File.write(out, bundler.compose)
  puts out
end
```

`FactBundler#compose` は **既存ファイル連結のみ**、 自分では rake / SQL を実行せえへん:

| Section | source | 加工 |
|---|---|---|
| branch & commits | `git log --oneline #{base}..#{branch}` | そのまま |
| diff stat | `git diff --stat #{base}..#{branch}` | そのまま |
| regression | `tmp/emitter/regression_<branch>.txt` 末尾 5 行 | summary 行抽出 |
| individual verification | `tmp/emitter/verify_<branch>.txt` | 全文 |
| compile_history delta | `tmp/emitter/compile_history_<branch>.txt` | そのまま |

### 7.6 `apple:emitter:merge`

```ruby
desc "Non-ff merge improvement branch back into base"
task :merge do
  branch = ENV.fetch("BRANCH")
  base   = ENV.fetch("BASE", "feature/v1.2-bootstrap-principle")
  wp     = ENV.fetch("WORKTREE_PATH")

  EmitterDev::BranchOps.checkout(base)
  EmitterDev::BranchOps.merge_no_ff(branch)
  EmitterDev::WorktreeOps.remove(wp)
  EmitterDev::BranchOps.delete_branch(branch)
  puts "merged #{branch} into #{base} (no-ff), worktree #{wp} removed"
end
```

push しない (memory `feedback_main_branch_push_handoff.md` 準拠)。

### 7.7 Rakefile への取り込み

repo root の `Rakefile` 末尾:

```ruby
load "tooling/lib/tasks/emitter.rake"
```

development task なので gem インストール時には影響なし (gemspec の files に tooling/ 含めへん)。

---

## 8. Error Handling

CLAUDE.md "No Silent Exception Swallowing" 厳守。 全 raise は descriptive。

| 経路 | 失敗 mode | 挙動 |
|---|---|---|
| `apple:emitter:candidates` | compile_history SQLite 不在 | `EmitterDev::CacheNotFoundError` 「`<path>` 無し、 `rake apple:knowledge:rebuild` を案内」 |
| 同上 | redundancy_scanner の AST parse fail | warn + その heuristic skip、 他 source は続行 |
| 同上 | chiebukuro session subagent dispatch timeout | warn + claude_session evidence 空欄、 candidates 出続ける |
| `apple:emitter:worktree_create` | branch 名衝突 | `BranchOps.derive_name` が `-<n>` suffix で再採番 (最大 5 回)、 それでも衝突なら raise |
| 同上 | `git worktree add` fail | git stderr を raise message に含めて即 raise |
| 同上 | populate_cache の symlink fail | raise、 worktree 手動 cleanup 案内 |
| implementer subagent | rake test green にならへん | `BLOCKED` で return、 skill が user に diagnostic + worktree path 提示、 同 session 対話継続 |
| 同上 | subagent context 上限 | skill が `send-message` で sub-section 細分指示 (RED 1個ずつ separate dispatch)、 worktree 維持 |
| `apple:emitter:fact_bundle` | tmp/emitter/ の expected file 不在 | 各 section に `<missing: <filename>>` placeholder、 user が即気付く |
| `apple:emitter:merge` | non-ff merge conflict | git stderr を raise、 worktree 残置、 user に session 内対話案内 |
| 同上 | `git worktree remove` fail | warn + path 提示、 user 手動 cleanup |

---

## 9. Testing Strategy (HITL tool 自体)

### 9.1 Unit test (helper module ごと)

| test file | 対象 | fixture / mock |
|---|---|---|
| `candidate_ranker_test.rb` | `CandidateRanker#rank` | tmpdir に minimal SQLite (`compile_history` 5〜10 行手挿し)、 mode/top assertion |
| `redundancy_scanner_test.rb` | `RedundancyScanner#scan` | `test/fixtures/emitter_dev/sample_marshallers.rb` (3〜5 marshaller、 既知双子含む)、 検出件数 assertion |
| `branch_ops_test.rb` | `BranchOps.derive_name / create_from / etc.` | `Dir.mktmpdir` で fresh git repo、 init + commit + branch 操作 assertion |
| `worktree_ops_test.rb` | `WorktreeOps.populate_cache` / `WorktreeOps.remove` | tmpdir に main + worktree 模擬、 symlink 3 個 + cache.sqlite copy 後の存在 assertion / remove 後の dir 不在 assertion |
| `fact_bundler_test.rb` | `FactBundler#compose` | tmp/emitter/ 模擬 file 5 個、 markdown output の section 数 + 順序 + content assertion |

### 9.2 Integration test

| test file | 対象 | scope |
|---|---|---|
| `tooling/emitter_dev/end_to_end_test.rb` | 全 Rake task 連鎖 | tmpdir に full repo 模擬、 candidates → worktree_create → (subagent dispatch は stub) → fact_bundle → merge → cleanup の各 step 出力 assertion |

### 9.3 Skill / agent definition smoke

- `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md` 存在 + frontmatter 妥当 (description / tool list)
- `.claude/agents/emitter-implementer.md` 存在 + 必須 placeholder (`__CANDIDATE_JSON__`, `__BRANCH_NAME__`, `__BASE_BRANCH__`, `__WORKTREE_PATH__`) 含有
- `bundle exec rake -T apple:emitter:` が 4 task 全部出る scripted check

全部 `bundle exec rake test` の対象。

---

## 10. Phasing (HITL tool 実装順序)

v1.2 の Phase 4a.2 addendum / 4a.3 / 4b / 5 / 6 / 7 とは **直交**、 別ブランチで進める。

| Phase | 内容 | 工数目安 | depends |
|---|---|---|---|
| **H-1 minimum viable add path** | candidate_ranker (compile_history source のみ) + worktree_ops + branch_ops + 4 Rake task + skill md + agent md。 trim mode / Claude session source 無し。 1 candidate end-to-end pass を実 symbol で確認 | 1d | v1.2 Phase 4a.2 完了 |
| **H-2 trim mode** | redundancy_scanner + mode flag + 4 種 heuristic + trim path の e2e | 0.5d | H-1 |
| **H-3 Claude session source** | source_claude_session の subagent dispatch wiring + skill 内 merge logic | 0.5d | H-1 (chiebukuro-mcp 既設) |
| **H-4 polish** | --top / --mode UX / `apple:emitter:cleanup_stale` / fact_bundler section 拡張 / 自分自身の test カバレッジ底上げ | 0.5d | H-1〜3 |
| **合計** | | **2.5d** | v1.2 Phase 4a.2 完了後 |

H-1 完了時点で **自己ドッグフード可能**: HITL tool 自身が compile_history を読んで「Phase 4a.2 で追加した swift_overlay marshaller の改善 candidate」 「4b で追加する SwiftBridgeName の補強」 を提案できる状態。

skill / agent definition の作成自体は **`skill-creator` skill** を使って組む (user 指定)。

---

## 11. Boundary

### 11.1 含む

- 4 source aggregation (compile_history / LLM log / Claude session log / 静的 redundancy)
- 4 Rake task + skill + agent definition + worktree 必須 flow
- examples の test-unit wrapper 自律拡張 (implementer subagent 責務)
- non-ff merge with revert-friendly history
- HITL tool 自体の unit + integration test

### 11.2 含まない (out-of-scope, v2 以降)

- gem 公開 (rubygems.org publish): tooling/ は maintainer-only
- example device dependency mock (MIDI / Camera): partial verify は subagent 自由裁量で OK 扱い
- candidate 複数 batch 処理: v1 は 1 cycle 1 candidate
- worktree の自動 GC (古い worktree 一括掃除): v2 で `apple:emitter:cleanup_stale` 検討
- main branch への push: 全段階で local merge 止まり (memory `feedback_main_branch_push_handoff.md`)
- LLM prompt template の自動改善: LLM safety net 側の改善は別系
- SKILL.md / agent definition の自動更新 loop: v1 は手書き (skill-creator 経由)、 v2 で考える
