# Phase 4-1 完了 → e2e gap analysis 着手 引き継ぎ (2026-05-15)

> 次セッションが cold start で読むことを前提とした handoff doc。
> 前 handoff: `docs/superpowers/handoffs/2026-05-14-phase3-complete-to-phase4.md`
> 関連 spec: `docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md`
>          `docs/superpowers/specs/2026-05-09-v1.2-bootstrap-principle-design.md`

---

## 1. 大命題 (北極星)

README.md L8:

> Call any public Apple framework API from Ruby with no pre-declarations.

これを **literal な runtime-verifiable claim** として実現することが gem の核心。 個別 phase / task / feature の正当性は最終的にここに収束する。

### 1.1 Trade-off priority (user 明示 2026-05-15)

- gem 内部の実行 overhead (bootstrap 時間 / dispatch latency / Knowledge Base ingest 時間) は **一定許容**
- user 側の「おまじない的なコード」 や「静的な設定ファイル」 を不要にすることが **優先**

具体: 「user に 1 行書かせれば解決」 vs 「gem 内部で 100 ms かかるが user 側 transparent」 → 後者を選ぶ。

Memory: `feedback_user_ergonomics_over_overhead.md`

---

## 2. 次セッションのテーマ

**End-to-end での動きを検証 → 内部構造を明確化 → 大命題との gap を列挙 → 解決順を立てる。**

これは Phase 4 引き継ぎ doc の優先 list (`DiscoveryError` deprecate / transparent namespace / MCP 拡張 / importer backlog) を「ボトムアップ」 で消すのではなく、 大命題からの「トップダウン gap analysis」 で再優先順位化する作業。

---

## 3. e2e 検証手順 (起点)

README.md と `examples/` を起点に **actual runtime 検証** を行う。 「動く」 = exit 0 + 実 functional output + DEFERRED line 無し。

### 3.1 検証対象 (README L52-110)

| Scenario | README 箇所 | 検証 file (要確認) |
|---|---|---|
| (a) bootstrap! → ObjC framework | L52-57 | `examples/coremidi_*.rb` 等 |
| (b) bootstrap! → Swift overlay | L10-17 | `examples/avspeech_synth.rb` / `examples/vision_ocr.rb` |
| (c) Apple.discover lightweight | L70-75 | `examples/discover_escape.rb` |
| (d) Apple.discover override (params/return_kind) | L92-97 | 要確認 |
| (e) Apple.discover for unknown symbol | L105-110 | 要確認 |
| (f) IRB autocomplete + doc preview | L134-143 | irb sub-gem |

### 3.2 観測指標

- **動くか動かんか** (actual functional output / DEFERRED line 検出)
- **bootstrap! latency** (README 想定 ~1 s、 実測)
- **dispatcher 初回 compile latency** (README 想定 1〜3 s swiftc、 実測)
- **2 回目以降 cache hit latency** (README 想定 sub-ms、 実測)
- **Knowledge Base lookup miss / typed raise 頻度** (telemetry jsonl: `~/.cache/rb-apple-sdk-mac/diagnostics/<YYYY-MM-DD>.jsonl`)

### 3.3 検証コマンド (草案)

```bash
# 個別 example
bundle exec ruby examples/<file>.rb

# 統合 task (要確認: rake task 名 / 現存有無)
bundle exec rake release_quality

# telemetry tail (検証中観測用)
tail -f ~/.cache/rb-apple-sdk-mac/diagnostics/$(date +%Y-%m-%d).jsonl
```

---

## 4. 内部構造 mapping starter

README L177-191 の Architecture section と spec doc が起点。 Cold start で次の 6 layer を mapping する:

1. **Glue Runtime** (`ext/apple_sdk_mac_runtime/`): static Swift dylib + 9 pillars (Ref Table / Marshal / Callback / ARC / Error / Async / Threading / RunLoop / Conformance)
2. **Ruby cache layer**: Config / CompiledGlueCache (SQLite + dylib FS) / KnowledgeCache
3. **Discovery / shape resolution**: SelectorBridge / DiscoveryShape (`synthesize_symbol_record` + `KIND_SYM_TO_TYPE`)
4. **Glue Compiler pipeline**: TemplateGenerator → ObjcMarshalling → SwiftBridgeName → LLMGenerator (safety net、 Ollama) → ValidationGates → SwiftcInvoker
5. **Ruby runtime**: GlueLoader (dlopen + pointer cache) / Dispatcher / SecurityCop / NamespaceBuilder / `Apple` Ruby::Box bootstrap
6. **Knowledge Base** (`knowledge/` sub-gem): `*.swiftinterface` ingester、 ObjC + Swift overlay 両対応、 `symbols.swift_imported_name` column

主要 entry point file:
- `lib/apple_sdk_mac.rb`
- `lib/apple_sdk_mac/dispatcher.rb` (Phase 2 で typed raise 化、 Phase 3 で Telemetry wiring 済)
- `lib/apple_sdk_mac/namespace_builder.rb`
- `lib/apple_sdk_mac/knowledge_cache.rb`
- `knowledge/lib/rb_apple_sdk_knowledge/importer/framework_scheduler.rb` (今 session で swift inline / objc WorkerPool 分離 refactor 済)

---

## 5. 現時点で見えてる gap 候補 (大命題距離で再分類)

| Gap | 大命題への影響 | 優先 |
|---|---|---|
| **transparent namespace 未完** (`bootstrap!` が user 側必要) | L8「no pre-declarations」 violation の最大要因。 `bootstrap!` 自体が「おまじない」 | **最高** |
| **`Apple.discover` 使用が override case で必要** | L8 violation。 ただし escape hatch として残す合意あり (README L82-114) | 高 |
| **`DiscoveryError` deprecate × `Apple.discover` lazy 化** | dispatch path の一貫性、 ergonomics 改善 | 中 |
| **Swift overlay framework の doc が空** (compiler が `///` strip) | IRB doc preview の literal claim 損なう、 user 側体験 | 中 |
| **examples が release_quality task に未統合** | DEFERRED line 検出機構未配線、 release-quality verification 抜け | 中 |
| **Phase 1 importer backlog** (Consolidator hash divergence / Swift IUO-of-Optional / nested enum case payload) | Knowledge Base 完全性、 L8「any public API」 violation | 中 |
| **Knowledge Base ingest 50+ 分** | trade-off 許容範囲、 long-term improvement 軸 | 低〜中 |
| **MCP server 拡張** (`search_apple_api` / `lookup_documentation` / `web_fetch`) | 大命題と直交、 別軸 | 後回し |

---

## 6. branch / test 状態 snapshot

- **branch**: `feature/knowledge-base-rebuild-tuning` (origin/main から **105 commits ahead**)
- **main 直 push**: user handoff 据え置き (memory rule)
- **main gem test**: 404 / 1022 / **0 failure** (Phase 4-1 で 2 failure 解消済)
- **knowledge sub-gem test**: 134 / 273 / 0 failure / 2 omission (env-gated integration)
- **working tree**: clean

直近 commit (top 4):
- `67444e4` refactor(knowledge/importer): swift inline / objc WorkerPool 分離
- `e97d0b3` docs(handoff): Phase 3 → Phase 4 entry
- `a15b931` fix(test): dispatcher assert_raise typed error 追従
- `f34319a` docs(specs): mark phase 3 (cleanup + telemetry) complete

---

## 7. 次セッション最初の action

1. README.md L8 / L52-110 を再読、 spec doc Section 1 (transparent namespace) を読む
2. `examples/` 配下を `ls` で列挙、 検証対象 file を Section 3.1 表に埋める
3. (a)(b)(c) を 1 個ずつ実行、 actual output 観測 (DEFERRED line / functional output / latency)
4. telemetry jsonl tail で typed raise / unsupported_pattern 経路の発火状況確認
5. 観測結果から gap 列挙、 Section 5 表を更新し大命題距離で再優先順位化
6. plan 化は `superpowers:writing-plans` で 1 spec doc にまとめる (e2e gap analysis spec)

---

## 8. 重要 memory rules (継続)

- **「Knowledge Base」 full spelling** (user-facing で「KB」 略禁止)
- **silent rescue 禁止** (named rescue + APPLE_DEBUG warn / re-raise / Result 型)
- **main 直 push は user handoff**
- **ローカル commit 自律進行** (commit 単位 / message / 順序は私が決める)
- **open questions は命題直結のみ** (細部 judgment は自律)
- **cache clear は rake task 経由 only**
- **trade-off priority: user ergonomics > gem internal overhead** (今 session 追加: `feedback_user_ergonomics_over_overhead.md`)
- **未知 unstaged 変更の責任 take プロセス**: author 履歴 verify → diff 読み解き → test green 確認 → 単独 commit (今 session 確立)

---

## 9. 環境状態 snapshot

- **OS**: Darwin 25.4.0 (macOS)
- **Ruby test**: `bundle exec rake test` (404/1022/0)
- **Knowledge Base**: schema 9、 163,541 symbols (Phase 2 rebuild 完了状態のまま)
- **Section 6.3 telemetry**: daily jsonl append default-on、 `APPLE_SDK_MAC_NO_DIAGNOSTICS=1` で opt-out
- **dispatcher typed raise**: `symbol_missing` / `unsupported_pattern` / `compile_failed` 全て Telemetry 発火済
