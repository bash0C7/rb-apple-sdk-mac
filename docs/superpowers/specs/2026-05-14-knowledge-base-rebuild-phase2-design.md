# Knowledge Base Rebuild Phase 2 — Design Spec

- Date: 2026-05-14
- Branch: `feature/knowledge-base-rebuild-tuning` (Phase 1 と同じ branch、 続き)
- Author: bash0C7 + Claude
- Status: Draft → implementation

## 1. Motivation

Phase 1 実測 (2026-05-14 17:25 終了): full rebuild = 50m20s = 3020s。

Phase 1 spec の半減 target (75min → 35-40min) には届かず 1.5x speedup で stop。 Phase 2 で 1/3 target (75min → 25min) を狙う。

Phase 1 から得た知見 (`[[kb_rebuild_phase1_result_2026_05_14]]` 参照):
- per-framework WorkerPool が spawn/shutdown 296 framework 分 = fork overhead 累積
- swift overlay parse が Phase 1 では serial (parallel 化対象外) → 全 elapsed の supposed 40-50% を占めとる仮説
- workers=2 は CPU 並列度を活かしきれてへん (M2 Pro は perf 8 + efficiency 2 = 10 core)
- sqlite3 fork_safety warning per fork × 596 = log noise (Phase 1 S4 では OK だが多)

## 2. Non-goals

- Knowledge Base schema 変更 (Phase 1 と同じ schema を踏襲)
- 既存 `Importer::Pipeline#run` の public API 変更
- libclang FFI (Phase 3 の path として spec に残す のみ)
- Phase 1 で確立した bit-identical (S2)、 ANSI bar (S3)、 ENV var surface (R10) の挙動変更
- 既存 spec / plan / 実装 の retroactive 変更 (Phase 1 の commit はそのまま、 Phase 2 は加算のみ)

## 3. Success criteria

| ID | 条件 | 検証手段 |
|----|------|----------|
| S1 | full rebuild が 25 min (1500s) 以内 | `time bundle exec rake apple:knowledge:benchmark_rebuild[full,nproc]`、 3 回計測中央値 |
| S2 | bit-identical: N=1 / 2 / 4 / 8 で `symbols` 内容が一致 | 既存 integration test (Task 10 of Phase 1) + N=8 を追加 |
| S3 | log size ≤ Phase 1 比同等以下 (≤ 1500 行) | `wc -l tmp/longrun/benchmark-*.log` |
| S4 | 既存 全 test green を維持 | `bundle exec rake test` |
| S5 | README L3 examples が end-to-end 実行可能 | `bundle exec rake test:release_quality` または個別 example smoke |

memory「README release-quality completion is non-negotiable」 を踏襲。 S5 は Phase 2 完了の non-negotiable 条件。

## 4. Architecture (Phase 2 拡張)

```
Pipeline#run (Phase 2)
  ├── SDKResolver           [既存] framework / header 列挙
  ├── ProgressReporter      [既存]
  ├── GlobalWorkerPool      [新規] nproc workers、 framework / swift overlay 横断
  │     ├── ObjCHeaderWorker × N  ── clang AST dump
  │     └── SwiftInterfaceWorker × M  ── swift overlay parse (新規 worker class)
  ├── FrameworkScheduler    [新規] framework を並列起動 (K 個並行)、 完了集約
  ├── ResultChannel × K     [既存] per-framework channel (FrameworkScheduler が管理)
  └── StoreWriter           [既存] SQLite 単一 writer + transaction batching
```

### 4.1 主な変更点 (Phase 1 → Phase 2)

| Layer | Phase 1 | Phase 2 |
|-------|---------|---------|
| WorkerPool spawn 単位 | per-framework | global (1 pool、 framework 全期 reuse) |
| workers default | 2 | nproc (M2 Pro = 10) |
| framework iteration | serial | K 並列 (K ≤ nproc / 2、 default = 4) |
| swift overlay parse | serial in main | WorkerPool 内 SwiftInterfaceWorker |
| WorkerPool 内 task 種別 | ObjCHeaderWorker のみ | ObjCHeader / SwiftInterface 両方 (polymorphic) |
| store insert 順 | per-framework serial | per-framework serial、 framework 間は完了順 (S2 維持のため framework key を hash で sort) |

### 4.2 Determinism (S2 維持)

並列度上げても bit-identical を維持する不変条件:
1. `resolver.frameworks` の hash 計算順 (existing) を維持
2. Per-framework insert は framework 単位で deterministic (Phase 1 と同じ)
3. Framework 間の insert 順は `framework_id` を seed とした deterministic order (e.g. name sort) で固定
4. `content_hash` 計算は入力に対し pure function → 並列化無影響
5. S2 test を N=8 まで拡張、 既存 N=1/2/4 と共に CI で検証

### 4.3 swift overlay polymorphism

WorkerPool は payload に `kind` field を持ち、 child 側でルーティング:

```ruby
case payload[:kind]
when "objc_header" then @objc_worker.call(framework:, header:)
when "swift_interface" then @swift_worker.call(framework:, path:)
end
```

`ObjCHeaderWorker` / `SwiftInterfaceWorker` は共通 interface (`call → {result:, error:, elapsed_ms:}`)。

## 5. Components

### 5.1 `Importer::GlobalWorkerPool`

Phase 1 の `Importer::WorkerPool` を rename + 拡張、 もしくは新規 class。 polymorphic worker dispatch。

```ruby
class GlobalWorkerPool
  def initialize(size:, channel:)
    # Phase 1 worker_factory: は dispatcher 化:
    # 子は ObjCHeaderWorker + SwiftInterfaceWorker 両方を hold、
    # payload[:kind] で route
  end
  def submit(seq:, payload:)  # payload[:kind] が "objc_header" / "swift_interface"
  def shutdown(wait: true)
end
```

### 5.2 `Importer::SwiftInterfaceWorker` (新規)

```ruby
class SwiftInterfaceWorker
  def call(framework:, path:)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    syms = @parser.parse_file(path)
    { result: syms, error: nil, elapsed_ms: ... }
  rescue => e
    { result: nil, error: "#{e.class}: #{e.message}", elapsed_ms: ... }
  end
end
```

### 5.3 `Importer::FrameworkScheduler` (新規)

```ruby
class FrameworkScheduler
  def initialize(frameworks:, parallelism:, pool:, store:, writer:, reporter:, ...)
  def run  # K 個 framework を thread で並列実行、 各 thread が own channel を作成
end
```

Per framework thread:
1. ObjC headers を WorkerPool に submit
2. Swift interfaces を WorkerPool に submit
3. Channel で受信、 consolidate、 framework lock 取って StoreWriter で insert

StoreWriter は単一 writer なので thread-safe mutex で guard (新規)。

## 6. Data flow (Phase 2)

```
main thread:
  pool = GlobalWorkerPool.new(size: nproc)
  scheduler = FrameworkScheduler.new(frameworks: ..., parallelism: K, pool: pool, ...)
  scheduler.run
  pool.shutdown
  store.rebuild_fts!
  reporter.finish
```

scheduler.run:
```ruby
queue = Queue.new
frameworks.each { |fw| queue << fw }

K.times.map do
  Thread.new do
    while (fw = queue.pop(true) rescue nil)
      process_framework_concurrent(fw, pool, ...)
    end
  end
end.each(&:join)
```

process_framework_concurrent(fw):
1. headers + swift_paths を pool に submit (with per-fw seq base)
2. Per-framework channel で結果受信
3. consolidator.merge
4. writer_mutex.synchronize { writer.insert ... }
5. reporter.framework_finished

## 7. Error handling

Phase 1 と同じポリシー:
- worker crash → synthetic error (Phase 1 既存)
- ConstraintException → re-raise without rollback (Phase 1 既存)
- 他例外 → rollback + re-raise
- writer_mutex: 例外時 ensure で unlock

## 8. Testing

### 8.1 Unit tests (test-unit)

- `test_global_worker_pool.rb`: polymorphic dispatch (objc_header / swift_interface)
- `test_swift_interface_worker.rb`: parse + error path
- `test_framework_scheduler.rb`: K=1/2/4 並列で同じ framework set を処理 → bit-identical

### 8.2 Integration tests

- 既存 `test_pipeline_parallel_bit_identical.rb` に N=8 case 追加
- `test_release_quality.rb` (新規): README L3 examples の 1 つを smoke 実行 (Knowledge Base 経由 emit + execute)

### 8.3 Benchmark

`apple:knowledge:benchmark_rebuild[full,nproc]` で計測。 Phase 2 後 S1 = 25min 以内なら success。

## 9. Configuration surface (additions)

| ENV var | Default | 用途 |
|---------|---------|------|
| `APPLE_SDK_MAC_KB_WORKERS` | nproc (system 検出) | 既存、 default 変更 |
| `APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM` | 4 | FrameworkScheduler の K |
| `APPLE_SDK_MAC_KB_BATCH_SIZE` | 1000 | 既存 |

## 10. README L3 verification (S5)

memory「README release-quality completion is non-negotiable」 で示された L3 = "any public Apple framework API must execute end-to-end" 条件:
- Phase 2 rebuild 後、 README に書かれた example の 1 つを実行
- Knowledge Base から emit したコードが実機 macOS で動作
- 失敗時は Phase 2 完了せず、 root cause fix

## 11. Phase progression note

- Phase 1 (完了): 半減 target、 workers=2、 per-framework pool、 swift overlay serial
- Phase 2 (this spec): 1/3 target、 workers=nproc、 framework K 並列、 swift overlay pool
- Phase 3 (future): libclang FFI、 process 起動廃止、 1/10 target

## 12. References

- `[[kb_rebuild_phase1_result_2026_05_14]]` Phase 1 実測
- `[[release_quality_completion_required]]` README L3 non-negotiable
- `[[project_core_thesis_long_term_improvement]]` 長期改善 + 安全確実な継続実行
- `docs/superpowers/specs/2026-05-14-knowledge-base-rebuild-tuning-design.md` Phase 1 spec
- `docs/superpowers/plans/2026-05-14-knowledge-base-rebuild-tuning.md` Phase 1 plan
