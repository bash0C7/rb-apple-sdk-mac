# Phase 3 完了 → Phase 4 引き継ぎ (2026-05-14)

> 次セッションが cold start で読むことを前提とした handoff doc。
> 関連 spec: `docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md`
> 関連 plan: `docs/superpowers/plans/2026-05-14-deterministic-runtime-phase3-cleanup-and-telemetry.md`

---

## 1. North Star (Phase 全体の不変命題)

- **「gem は runtime で Swift を書かへん」** — LLM fallback path は gem 公開 path に置かない。 cloud LLM は on-device only。
- **「並列セッション影響排除」** — knowledge sub-gem の改修は main gem に依存を作らない。
- **「safe execution の継続」** — README L3「any public Apple framework API」が end-to-end 動作することを v1.0 release-quality criteria として死守。

---

## 2. Phase 3 完了サマリ

**branch**: `feature/knowledge-base-rebuild-tuning` (local、 main 未 push)

### Commit chain (Phase 3 全 11 task)

| Task | SHA | 内容 |
|---|---|---|
| Plan | `2b1bb01` | docs(plans): Phase 3 plan |
| T1 | `939b01a` | refactor(errors): retire dead `Apple::CallError` |
| T2 | `07f5c8e` / `7e5675c` | test RED + swiftc kwarg / `max_llm_retries` reject |
| T3 | `03118e7` | refactor: strip `try_llm` + add `gates:` kwarg |
| T4 | `32b6082` / `f36788e` / `2ca777c` | delete `LLMGenerator` / `LLMExamples` + test cleanup + RDoc purge |
| T5 | `6bb8b7d` / `e6350de` | drop `rb-foundation-model-mac` dep + sub-gem Gemfile clean |
| T6 | `af3fd9f` | knowledge sub-gem importer chain decouple |
| T7 | `60015f8` | Phase 2 LOAD_PATH stub 削除 |
| T8 | `cb75b15` | test(telemetry): RED for Section 6.3 |
| T9 | `8d7f327` / `d79f1be` | telemetry GREEN + `KNOWLEDGE_BASE_SCHEMA` top-level 昇格 |
| T10 | `fade71a` / `0f3bcc9` | dispatcher wiring + assertion symmetric fix |
| T11 | `f34319a` | docs(specs): Section 17 Phase 3 結果 + Phase 4 引き継ぎ |

### Test 結果

- `bundle exec rake test`: **404 tests / 1022 assertions / 2 failures**
- 2 failure は **Phase 2 commit `2573d28` (typed raise 切替) 起因の pre-existing**
  - `test_dispatch_raises_on_unknown_symbol`
  - `test_dispatch_raises_when_auto_compile_fails`
  - root cause: `test-unit` `assert_raise(klass)` は `instance_of?` で厳密 class match する。 dispatcher は `SymbolMissingError` / `GlueCompileError` を raise するようになったのに、 test 側が `assert_raise(AppleSDKMac::Error)` のまま。
  - **Phase 4 で test 側を `assert_raise(AppleSDKMac::SymbolMissingError)` 等に追従させる**だけで解消。
- `TestTelemetryWired` (integration、 Rakefile L17-21 で `test/integration/**` exclusion): 3 tests / 16 assertions / 0 failure。 `bundle exec ruby -Ilib -Itest test/integration/test_telemetry_wired.rb` で直接実行可。

---

## 3. Phase 4 引き継ぎ items (spec doc Section 17 記録済)

優先度順:

1. **`test/dispatcher_test.rb` 2 件の pre-existing failure 解消** (Phase 2 残債、 機械的 fix)
2. **`AppleSDKMac::DiscoveryError` deprecate × `Apple.discover` lazy 化** (Phase 3 で保留した paired 改修)
3. **Section 1 transparent namespace 本体** (`bootstrap!` 不要化、 `Apple::<Framework>` const_missing → Knowledge Base lookup)
4. **Section 7/8/9 MCP server 拡張** (`search_apple_api` / `lookup_documentation` / `web_fetch`)
5. **Phase 1 importer backlog**
   - Consolidator hash divergence
   - Swift IUO-of-Optional
   - nested enum case payload edge case
6. **integration test の `rake test` coverage** (`release_quality` task 整備で別 wire、 現状 Rakefile glob から外れる)

---

## 4. user judgment 委ね事項 (自律 action せん)

- **main 直 push**: memory rule「main 直 push は user handoff」 (`feedback_main_branch_push_handoff.md`)。 私から push せん、 ahead 状態 report のみ。
- **並列セッション WIP**: `knowledge/lib/rb_apple_sdk_knowledge/importer/framework_scheduler.rb` unstaged。 scope discipline で touch せず残置、 並列セッション側の判断に委ねる。
- **Final code review dispatch 要否**: Subagent-Driven Development skill の最後 step。 user 判断。
- **Phase 4 着手タイミング**: user 判断。

---

## 5. 重要 memory rules (Phase 4 でも継続)

- **「KB」 略称禁止**: user-facing は「Knowledge Base」 full spelling (`feedback_no_kb_abbreviation.md`)。 内部 short form (`@kc` / `kb_schema` column 名) は OK。
- **silent rescue 禁止**: named rescue + `APPLE_DEBUG` warn / re-raise / Result 型返却のいずれか。
- **並列セッション scope を厳守**: 触らないファイル明示 — `knowledge/lib/.../worker_pool.rb` / `framework_scheduler.rb` / knowledge gemspec 周辺。
- **open questions は命題直結のみ**: branch 分割粒度 / 起点 framework / 反映ルート等は自律で決める、 user に問うのは命題達成方向が変わる judgement だけ (`feedback_no_offtopic_open_questions.md`)。
- **ローカル git commit は自律進行**: commit 単位 / message / 順序は私が決める、 user 確認は main 直 push / merge / PR public 化等の外部影響操作だけ (`feedback_local_git_commit_autonomous.md`)。
- **HITL gate は test-unit assert で報告**: raise+puts 自作 report 禁止 (`feedback_test_unit_assert_as_report.md`)。
- **cache clear は rake task 経由 only**: `~/.cache/rb-apple-sdk-mac/...` 直 `rm -rf` 禁止 (`cache_clear_via_rake_task.md`)。

---

## 6. 環境状態 snapshot

- **OS**: Darwin 25.4.0 (macOS)
- **Ruby test**: `bundle exec rake test` (404/1022/2)
- **Knowledge Base**: schema 9、 163,541 symbols (Phase 2 rebuild 完了状態)
- **Section 6.3 telemetry**: `~/.cache/rb-apple-sdk-mac/diagnostics/<YYYY-MM-DD>.jsonl` daily append、 default-on、 `APPLE_SDK_MAC_NO_DIAGNOSTICS=1` で opt-out
- **dispatcher 3 typed raise 経路**: `symbol_missing` / `unsupported_pattern` / `compile_failed` 全て Telemetry 発火済 (`lib/apple_sdk_mac/dispatcher.rb`)

---

## 7. 次セッション最初の action 候補

1. `git status` + `git log --oneline -20 feature/knowledge-base-rebuild-tuning` で branch 状態 verify
2. user に「Phase 4 着手するか / main push 先に処理するか / 別件か」 を聞く
3. Phase 4 着手なら spec doc Section 17 を読んで優先順位再確認、 plan 化は `superpowers:writing-plans`
