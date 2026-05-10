# tooling/

`tooling/` は rb-apple-sdk-mac の **maintainer-only** な開発支援コードを置く場所。 HITL (human-in-the-loop) emitter improvement workflow を構成する Ruby module 群と Rake task からなる。 ランタイム gem (`knowledge/`, `irb/`, `mcp/`) からは完全に decouple されとる: gemspec の `files` 列にも入らへんし、 出荷物には一切含まれへん。 v1.2 以降の継続的な emitter coverage 改善 (新 API の追加 / 不要 entry の trim) をテストと事実 artifact 中心の手順で回すための足場。

## ディレクトリ構成

```
tooling/
├── README.md            (this file)
├── lib/
│   ├── emitter_dev/     # HITL helper Ruby modules
│   │   ├── branch_ops.rb
│   │   ├── worktree_ops.rb
│   │   ├── source_compile_history.rb
│   │   ├── redundancy_scanner.rb
│   │   ├── candidate_ranker.rb
│   │   └── fact_bundler.rb
│   └── tasks/
│       └── emitter.rake # apple:emitter:* Rake task 定義
└── (test は repo top の test/tooling/ 配下)
```

## Module map

| Module | 役割 |
| --- | --- |
| `EmitterDev::BranchOps` | candidate 情報から branch 名 (例 `emitter/add-NSString-stringWithUTF8String`) を導出。 mode / API / timestamp を組み合わせて衝突しない名前を返す純関数。 |
| `EmitterDev::WorktreeOps` | `git worktree add` で隔離 workspace を作り、 `~/.cache/rb-apple-sdk-mac` 配下の read-only artifact (sdkdb_index 等) は symlink、 mutable な `cache.sqlite` は copy で populate。 並列 session が cache を壊さんための分離層。 |
| `EmitterDev::Sources::CompileHistory` | Knowledge Base の `cache.sqlite::compile_history` table を読み、 API ごとの compile 失敗回数 / 直近呼び出し時刻を集計。 candidate 評価の入力 fact を提供。 table 未作成な空 cache は `[]` を返して trim/all mode 経路を阻害せえへん。 |
| `EmitterDev::RedundancyScanner` | `marshallers.rb` を `parser` gem で AST 走査し、 `twin_private_helper` (Levenshtein 類似 helper の双子) と `class_pair_method_overlap` (>= 2 method 重複の class pair) の 2 heuristic で trim 候補を抽出。 H-2 で追加。 |
| `EmitterDev::CandidateRanker` | `Sources::*` / `RedundancyScanner` の出力を受け取り、 add mode (まだ emitter に無い高頻度 API) / trim mode (冗長な marshaller を統合できる pair) / all mode (両方マージ) ごとに ranking。 stateless module (`module_function`)、 `rank(rows:, findings:, mode:, top:)` 単一 entry。 |
| `EmitterDev::FactBundler` | HITL gate に提示する生 artifact (`git diff`, `rake test` stdout, e2e log, branch / base / worktree path metadata) を markdown bundle に composition。 LLM 自己評価 summary は混ぜへん。 |

`EmitterDev::*` は全て module_function ベースの薄い helper。 状態は持たず、 副作用 (git, sqlite) は引数で受け取った path に閉じる。

## Rake task

namespace `apple:emitter:` に 4 task。 定義は `tooling/lib/tasks/emitter.rake`、 repo top の `Rakefile` から `import` される。

| Task | 用途 |
| --- | --- |
| `apple:emitter:candidates` | `MODE=add\|trim TOP=N` で candidate 一覧を JSON で stdout 出力。 `CandidateRanker` を呼ぶ薄い entry point。 |
| `apple:emitter:worktree_create` | `CANDIDATE_ID=i BASE=<branch>` で worktree を作成し、 cache を populate して branch 名と worktree path を返す。 |
| `apple:emitter:fact_bundle` | `BRANCH=... BASE=...` で diff / test / e2e log を集めて fact bundle を出力。 HITL fact-review gate の入力になる。 |
| `apple:emitter:merge` | `BRANCH=... BASE=... WORKTREE_PATH=...` で承認済 branch を base に merge し、 worktree を片付ける。 |

直接呼ぶ例:

```bash
bundle exec rake apple:emitter:candidates MODE=add TOP=5
bundle exec rake apple:emitter:worktree_create CANDIDATE_ID=1 BASE=feature/v1.2-bootstrap-principle
bundle exec rake apple:emitter:fact_bundle BRANCH=emitter/add-... BASE=feature/v1.2-bootstrap-principle
bundle exec rake apple:emitter:merge BRANCH=emitter/add-... BASE=feature/v1.2-bootstrap-principle WORKTREE_PATH=...
```

## Slash command + Agent

通常は slash command 経由で workflow を起動する。

- Slash command (skill): `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`
  起動: `/rb-apple-sdk-mac-improve-emitter [--mode=add|trim|all] [--top=N]`
  candidate 提示 → user 選択 → worktree 用意 → subagent dispatch → fact bundle 提示 → user 承認 gate → merge を順に進める orchestrator。
- Subagent: `.claude/agents/emitter-implementer.md`
  worktree 内で TDD (RED → GREEN → REFACTOR) で emitter 変更を実装する専用 agent。 scope は単一 candidate に限定、 fact (test 結果 / diff) を生で返す。

## HITL workflow (ASCII)

```
                slash command: /rb-apple-sdk-mac-improve-emitter
                                    │
                                    ▼
                  ┌─────────────────────────────────┐
                  │ apple:emitter:candidates        │
                  │   (CandidateRanker + Sources)   │
                  └─────────────────────────────────┘
                                    │
                                    ▼
                          [ user pick gate ]
                                    │
                                    ▼
                  ┌─────────────────────────────────┐
                  │ apple:emitter:worktree_create   │
                  │   (WorktreeOps + BranchOps)     │
                  └─────────────────────────────────┘
                                    │
                                    ▼
                  ┌─────────────────────────────────┐
                  │ subagent: emitter-implementer   │
                  │   TDD: RED → GREEN → REFACTOR   │
                  └─────────────────────────────────┘
                                    │
                                    ▼
                  ┌─────────────────────────────────┐
                  │ apple:emitter:fact_bundle       │
                  │   (FactBundler: diff/test/e2e)  │
                  └─────────────────────────────────┘
                                    │
                                    ▼
                       [ HITL fact-review gate ]
                          (user reads raw facts)
                                    │
                          approve   │   reject
                          ┌─────────┴─────────┐
                          ▼                   ▼
            ┌──────────────────────┐   discard worktree
            │ apple:emitter:merge  │   (no merge)
            └──────────────────────┘
                          │
                          ▼
                       base branch
```

各 step が独立した Rake task / agent invocation になっとるんで、 失敗時はその step だけ retry できる。 fact-review gate には LLM の自己評価 summary を出さず、 生 diff / 生 test stdout / 生 e2e log だけを提示するんが design の核心 (memory: HITL gate は事実を見せる場所)。

## FactBundler の設計

HITL fact-review gate で user が読む markdown を構成する。 設計の核心は **生 artifact だけ並べる**: LLM 自己評価 / summary / 安心させる文言は一切混ぜへん。 user は事実を見て承認 / 却下を判断する (memory `feedback_hitl_gate_facts_only.md`)。

bundle は次の section から成る (`compose` の順):

| Section | source | 役割 |
| --- | --- | --- |
| header | branch + base 名 | 何の fact bundle かの identity |
| branch & commits | `git log --oneline base..branch` | 候補 branch の commit 列 |
| diff stat | `git diff --stat base..branch` | 差分の規模 (file 数 / line 増減) |
| design | `tmp/emitter/design_<slug>.md` | implementer subagent が作った設計メモ (任意 artifact) |
| regression | `tmp/emitter/regression_<slug>.txt` | `rake test` の生 stdout (test-unit summary 行) |
| individual verification | `tmp/emitter/verify_<slug>.txt` | 個別 example の e2e 結果 (test-unit assert) |
| compile_history delta | `tmp/emitter/compile_history_<slug>.txt` | `cache.sqlite` の before/after row 差分 |

artifact が無い section は `<missing: <path>>` placeholder を残す。 「なんで無いん」 を user が判断できるよう、 黙って section を消したりしない。

bundle path の slug は `branch.tr("/", "_")` で変換 (例 `emitter/add-foo` → `emitter_add-foo`)。 implementer subagent は同じ slug で artifact を出力する規約。

## 設計 spec

詳細な動機・代替案検討・data flow は次を参照。

- `docs/superpowers/specs/2026-05-09-hitl-emitter-improvement-design.md`
- `docs/superpowers/plans/2026-05-09-hitl-emitter-improvement.md`

## Test

`tooling/` のテストは repo top の `test/tooling/` 配下に置き、 `rake test` で他のテストと一緒に走る。 module 単体テストは `test/tooling/emitter_dev/<module>_test.rb`、 end-to-end smoke は `test/tooling/emitter_dev/end_to_end_test.rb`。
