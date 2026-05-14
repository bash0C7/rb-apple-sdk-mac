# Knowledge Base Rebuild Tuning — Design Spec

- Date: 2026-05-14
- Branch: `feature/knowledge-base-rebuild-tuning`
- Author: bash0C7 + Claude (brainstorming session)
- Status: Draft, pending user review

## 1. Motivation

`apple:knowledge:rebuild` rake task の完了時間は現状 70〜80 分 (2026-05-14 計測: 75 min の `DONE: exit=0` 例) で、 SDK 更新時 / phase 1 metadata 拡張時 / HITL emitter improvement での Knowledge Base 再生成のたびに長時間ブロックされる。 さらに `tmp/longrun/knowledge-rebuild-*.log` には 1 header skip ごとに数十行の clang error stack が垂れ流され、 14000 行の log のうち本当に観測価値があるのは framework 単位 elapsed / skipped 件数のみで、 大半は noise である。

本 spec は Knowledge Base rebuild の 「Core thesis: 長期改善 + README 通り安全確実な継続実行」 (`MEMORY.md` 参照) を満たすため、 以下を最小スコープで実現する。

- **速度**: 75 min → 35〜40 min (Phase 1 で半減)
- **観測性**: stderr へ 1 行 ANSI progress bar を出し、 非 tty (longrun pattern) では framework 単位 summary 1 行に圧縮

カバレッジ拡大 (現状 skip されてる AS_EXTERN / forward decl header 救出) は本 spec のスコープ外。 別 spec / 別 plan で扱う。

## 2. Non-goals

- SQLite schema の変更 (SCHEMA_VERSION bump しない)
- 既存 `Importer::Pipeline#run` の public API 変更
- swift overlay parser の構造変更 (Phase 1 では既存 serial を温存、 並列 abstraction だけ利用可能にしておく)
- libclang FFI 経由の in-process parse (Phase 3 evolution path として spec に記す のみ)
- 並列実行による Knowledge Base 内容の差分 (= bit-identical を維持する)

## 3. Success criteria

| ID | 条件 | 検証手段 |
|----|------|----------|
| S1 | full rebuild が 40 min 以内で完了する (M2 Pro / SDK 26.4.1) | `time bundle exec rake apple:knowledge:rebuild` を 3 回計測、 中央値 |
| S2 | 並列度 N=1 / N=2 / N=4 で `symbols` テーブル content が bit-identical | 全行を `framework_id, name, kind, content_hash` で order by → SHA256 が一致 |
| S3 | tty=true で stderr に 1 行 progress bar が表示される | integration test で `StringIO` + `tty=true` simulate、 ANSI escape `\e[` の存在を assert |
| S4 | tty=false (longrun) で log size が 過去 run の 1/5 以下 | 過去 1.47 MB / 14000 行 → 目標 < 300 KB / < 3000 行 |
| S5 | 既存 `rake test` (knowledge 配下) が green を維持 | `bundle exec rake test` |

## 4. Architecture

```
Pipeline#run
  ├── SDKResolver           [既存] framework / header 列挙
  ├── ProgressReporter      [新規] 開始 / framework / header / 終了 イベント受信
  ├── WorkerPool            [新規] per-header clang invoke を N 並列化 (default N=2)
  │     └── ObjCHeaderWorker (子 process / thread を Phase 1 では選択可能に)
  ├── ResultChannel         [新規] worker → main の ordered delivery (SizedQueue)
  └── StoreWriter           [新規] SQLite 単一 writer + transaction batching (1000 行 / commit)
```

### 4.1 抽象境界

Phase 2 / 3 の evolution は **WorkerPool の内部実装** を差し替えるだけで成立するように設計する。 Pipeline / ResultChannel / StoreWriter / ProgressReporter の interface は不変。

| Layer | Phase 1 | Phase 2 (1/3 target) | Phase 3 (1/10 target) |
|-------|---------|---------------------|----------------------|
| WorkerPool 実装 | `Process.fork` × N=2〜4、 framework 内 header 並列 | N=nproc、 framework 間も並列 | libclang FFI in-process、 process 起動廃止 |
| StoreWriter | transaction batching 1000 行 | 同 | 同 |
| ResultChannel | SizedQueue (framework serial) | per-framework queue + main aggregator | 同 |
| ProgressReporter | stderr ANSI bar / non-tty summary | 同 (粒度のみ調整) | 同 |

### 4.2 Determinism

並列化を入れても Knowledge Base content は serial run と bit-identical を維持する。 担保手段:

1. `resolver.frameworks` の iteration 順は serial を維持 (framework は集約 unit のまま)
2. framework 内の header 並列処理は **submit 順** に紐づく **sequence number** を付与
3. ResultChannel は sequence number 順に main へ deliver
4. StoreWriter は deliver 順そのままで `insert_one` を呼ぶ
5. `content_hash` 計算は header path / symbol name 等の入力に対し純粋関数 → 並列化と無関係

S2 の bit-identical テストでこれを毎回検証する。

## 5. Components

### 5.1 `Importer::WorkerPool`

```ruby
class WorkerPool
  # @param size [Integer] 同時並列度 (default ENV["APPLE_SDK_MAC_KB_WORKERS"] || 2)
  # @param worker_class [Class] ObjCHeaderWorker など
  # @param channel [ResultChannel] worker が push する出力先
  def initialize(size:, worker_class:, channel:)

  # work item を投入。 seq は呼び出し側が連番で付与
  def submit(seq:, payload:)

  # 投入終了 + 全 worker 回収。 戻ると channel に全結果が入っとる
  def shutdown(wait: true)
end
```

- Phase 1 実装: `Process.fork` で N 子プロセス + Unix pipe で IPC。 fork 時点で SDK resolver / parser instance は親で完成しとるので fork-friendly。
- 注意: macOS Pipe buffer は 64KB 固定、 1 result が 64KB を超える場合は分割送信 (実装ガード)。
- channel への push は worker が直接実施。 main は `channel.each_ordered` で seq 順に拾う。

### 5.2 `Importer::ProgressReporter`

```ruby
class ProgressReporter
  # tty 判定で出力モード切替
  def initialize(io: $stderr, total_frameworks:, tty: io.tty?)

  def framework_started(name, idx:, total:)
  def header_done(framework:, header:, status:, elapsed_ms:, error: nil)
  def framework_finished(name, processed:, skipped:, elapsed_ms:)
  def finish(processed_total:, skipped_total:, elapsed_ms:)
end
```

- tty=true: `ruby-progressbar` gem を使い 1 行 ANSI bar。 例 `AVFoundation [██████░░░░] 60/100 framework 12/450 elapsed 11m23s`
- tty=false: framework_started で `=== AVFoundation (12/450) ===` を 1 行、 framework_finished で `→ processed=37 skipped=2 elapsed=12s` を 1 行 → 1 framework = 2 行。 header_done は silent (status=:error のときだけ `[importer] skipping #{header}: #{class}: #{message_first_line}` の 1 行に圧縮)。

### 5.3 `Importer::StoreWriter`

```ruby
class StoreWriter
  def initialize(store:, batch_size: 1000)
  def begin!                       # BEGIN TRANSACTION
  def insert_symbol(...)           # @store#insert_symbol を委譲、 batch counter inc、 size 超で commit + begin
  def insert_framework(...)        # 同上
  def flush                        # 残り transaction commit
end
```

- 既存 `Store#insert_symbol` / `Store#insert_framework` をそのまま呼び出す thin wrapper
- SQLite の `PRAGMA synchronous = NORMAL` / `PRAGMA journal_mode = WAL` を Phase 1 で `Store.open` に追加 (rebuild は単一 writer なので WAL でも安全、 commit overhead 大幅減)

### 5.4 `Importer::ResultChannel`

```ruby
class ResultChannel
  def initialize(buffer_size: 64)
  def push(seq:, payload:)
  def each_ordered(&blk)           # 内部で min-heap 的に seq 順 deliver
end
```

- 並列度 N に対し buffer_size = N × 8 程度。 worker が main の処理を 8 step 以上先行できる
- 例外発生 (worker crash 等) は `payload[:error]` で運ぶ → main 側で skip 扱い

## 6. Data flow

```
Pipeline#run
  resolver.frameworks.each_with_index do |fw, idx|
    reporter.framework_started(fw.name, idx:, total:)

    channel = ResultChannel.new(buffer_size: workers * 8)
    pool = WorkerPool.new(size: workers, worker_class: ObjCHeaderWorker, channel: channel)

    fw.headers.each_with_index do |h, seq|
      pool.submit(seq:, payload: {framework: fw, header: h, sdk_path: resolver.sdk_path})
    end
    pool.shutdown(wait: true)

    channel.each_ordered do |item|
      reporter.header_done(framework: fw.name, header: item[:payload][:header],
                           status: item[:error] ? :error : :ok,
                           elapsed_ms: item[:elapsed_ms], error: item[:error])
      next if item[:error]
      consolidated = consolidator.merge(swift_syms_for(fw), item[:result])
      writer.write(framework_id: fw_id, symbols: consolidated)
    end

    reporter.framework_finished(fw.name, processed: ..., skipped: ..., elapsed_ms: ...)
  end

  writer.flush
  store.rebuild_fts!
  reporter.finish(...)
```

- Swift overlay parse は Phase 1 では既存通り serial だが、 同じ `ProgressReporter` event を発火させて見えるようにする (`framework_started` / `framework_finished` の elapsed 内に含む)。

## 7. Error handling

| 事象 | 対応 |
|------|------|
| clang failure (header skip) | worker が `{error: "clang failed: ..."}` を返す。 main は `ProgressReporter#header_done(status: :error, error: msg)` で 1 行記録、 次 header へ。 |
| worker process crash (SIGSEGV 等) | WorkerPool が waitpid で検知。 該当 seq を `{error: "worker crashed: signal=..."}` で channel に push。 |
| SQLite write error | `StoreWriter#insert_symbol` で raise → Pipeline 全体を abort (cache が partial になるより明示 fail)。 reporter は `finish(status: :error)` で締める。 |
| ResultChannel buffer 詰まり | worker は push 待ち。 main 処理が止まれば自然に back-pressure かかる。 deadlock は WorkerPool#shutdown 内の wait 順序で回避。 |

CLAUDE.md ルール「No Silent Exception Swallowing」 を遵守し、 全 rescue は `ProgressReporter#header_done` に渡すか log として propagate する。 空 rescue / `rescue nil` 禁止。

## 8. Testing

`MEMORY.md` の `feedback_test_unit_assert_as_report` (verification は test-unit assert に乗せる) に従う。

### 8.1 Unit tests (test-unit, `knowledge/test/unit/`)

- `test_worker_pool.rb`: size 1 / 2 / 4 で同じ入力 → 出力が seq 順で一致 (`assert_equal`)
- `test_progress_reporter.rb`: tty=true 出力に `\e[` を含む、 tty=false で 1 framework = 2 行に収まる
- `test_store_writer.rb`: batch_size 1 と 1000 で同じ symbol セットを insert → DB content が一致 (`assert_equal` on row hashes)
- `test_result_channel.rb`: out-of-order push でも `each_ordered` は seq 昇順 deliver

### 8.2 Integration tests (`knowledge/test/integration/`)

- `test_pipeline_parallel_bit_identical.rb`:
  - 小規模 framework subset (Foundation / CoreGraphics の 5 framework) を fixture に
  - N=1 / N=2 / N=4 で rebuild → `symbols` テーブル全行を canonical order で SHA256
  - `assert_equal sha_n1, sha_n2`、 `assert_equal sha_n1, sha_n4`

### 8.3 Benchmark task (新規 rake task)

`apple:knowledge:benchmark_rebuild[scope,workers]` を `knowledge/Rakefile` に追加。 `scope` ∈ `{single, ten, full}`、 `workers` ∈ `{1, 2, 4, 8}`。 wall-clock を `tmp/longrun/benchmark-<timestamp>.log` に書く。 検証用、 CI には載せへん。

## 9. Logging / output policy

| Channel | tty | non-tty (longrun) |
|---------|-----|-------------------|
| Framework 進捗 | ANSI progress bar (1 行 in-place) | `=== <name> (i/N) ===` + `→ processed=… skipped=… elapsed=…` |
| Header skip | progress bar 内 skipped counter のみ | `[importer] skipping <header>: <class>: <msg first line>` (full stack 抑制) |
| Critical error | stderr に raise message | 同 |
| 完了 | `✓ done processed=… skipped=… elapsed=…` | 同 + `DONE: exit=…` (既存 longrun pattern) |

- 過去 14000 行 log → 目標 3000 行以下 (S4)。 1 header = 1 行に圧縮するだけで 50 行 → 1 行 = 1/50。

## 10. Configuration surface

| ENV var | Default | 用途 |
|---------|---------|------|
| `APPLE_SDK_MAC_KB_WORKERS` | `2` | WorkerPool 並列度 |
| `APPLE_SDK_MAC_KB_BATCH_SIZE` | `1000` | StoreWriter transaction size |
| `APPLE_SDK_MAC_KB_PROGRESS` | `auto` | `auto` (tty 判定) / `bar` / `summary` / `silent` |
| `APPLE_SDK_MAC_KB_BASE_DIR` | (既存) | 既存通り |

Rakefile / CLI 変更なし。 ENV だけで挙動切替可能。

## 11. Phase plan summary

- **Phase 1 (this spec)**: 半減 target、 上記 architecture 実装。 `Process.fork` × 2、 transaction batching、 ANSI bar、 1 行 skip log。
- **Phase 2 (out of scope)**: N=nproc、 framework 間並列、 swift overlay 並列、 1/3 target。 別 spec / 別 plan。
- **Phase 3 (out of scope)**: libclang FFI、 1/10 target。 別 spec。

各 Phase で SCHEMA_VERSION bump 不要、 importer 内部リファクタのみ。

## 12. Open questions

なし (本 spec 範囲では命題直結の未決事項なし)。 実装中に出てきた疑問は session 内 で私が判断し、 user 露出が必要なものは別途確認する。

## 13. References

- `MEMORY.md` → `feedback_test_unit_assert_as_report` / `feedback_hitl_gate_facts_only` / `project_core_thesis_long_term_improvement` / `feedback_no_kb_abbreviation`
- `docs/superpowers/specs/2026-05-05-longrun-pattern-design.md` (screen detached run pattern との接続)
- `docs/superpowers/specs/2026-05-14-piano-postmortem-gem-precision.md` (Swift overlay 拡大は別軸、 本 spec と直交)
- `knowledge/lib/rb_apple_sdk_knowledge/importer.rb` (現 Pipeline 実装)
- `knowledge/Rakefile` (`apple:knowledge:rebuild` task)
