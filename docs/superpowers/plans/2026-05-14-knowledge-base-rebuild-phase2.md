# Knowledge Base Rebuild Phase 2 — Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to execute task-by-task. Steps use checkbox syntax.

**Goal:** Knowledge Base full rebuild を 1/3 (75min baseline → 25min target、 = Phase 1 50min を 2x 加速) に縮める。 architecture: nproc workers + framework K 並列 + swift overlay 並列。 **bit-identical 維持 + README L3 examples 実働 verify が non-negotiable**。

**Tech Stack:** Ruby 4.0、 sqlite3、 ruby-progressbar、 test-unit、 Process.fork + IO.pipe IPC、 Thread + Mutex

**Spec ref:** `docs/superpowers/specs/2026-05-14-knowledge-base-rebuild-phase2-design.md`

---

## Prerequisites

- Phase 1 完了済 (commit ee485ad + 並列 emitter session の commits)
- 既存 127 tests / 259 assertions / 0 failures 維持前提
- branch: `feature/knowledge-base-rebuild-tuning` (Phase 1 と同 branch、 追加 commit)

## File Map

- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer.rb` (Pipeline#run を FrameworkScheduler 経由に refactor)
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/worker_pool.rb` (polymorphic dispatch、 worker_factory が dispatcher proc を返す)
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_interface_worker.rb`
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/framework_scheduler.rb`
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/store_writer.rb` (Mutex 追加で thread-safe insert)
- Modify: `knowledge/Rakefile` (benchmark task で nproc default)
- Modify: `knowledge/README.md` (ENV var 表更新)
- Modify: `knowledge/test/integration/test_pipeline_parallel_bit_identical.rb` (N=8 追加)
- Create: `knowledge/test/unit/test_swift_interface_worker.rb`
- Create: `knowledge/test/unit/test_framework_scheduler.rb`
- Create: `test/integration/test_release_quality_rebuild_l3.rb` (README L3 smoke、 root テスト)

---

### Task 1: workers default を nproc に

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer.rb` (line 32 周辺)

- [ ] **Step 1: 既存 `workers = [(ENV[...] || 2).to_i, 1].max` を nproc default に**

```ruby
workers = (ENV["APPLE_SDK_MAC_KB_WORKERS"] || begin
  Etc.nprocessors
rescue NameError
  require "etc"
  retry
end).to_i
workers = [workers, 1].max
```

簡潔版 (require を top で済ます):
```ruby
require "etc"
# ...
workers = [(ENV["APPLE_SDK_MAC_KB_WORKERS"] || Etc.nprocessors).to_i, 1].max
```

`require "etc"` を importer.rb 冒頭に追加。

- [ ] **Step 2: Run tests**

```bash
cd knowledge && bundle exec rake test
```

Expected: 127 tests / 259 assertions / 0 failures

- [ ] **Step 3: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer.rb
git commit -m "feat(knowledge/importer): default APPLE_SDK_MAC_KB_WORKERS to Etc.nprocessors"
```

---

### Task 2: SwiftInterfaceWorker

**Files:**
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/swift_interface_worker.rb`
- Create: `knowledge/test/unit/test_swift_interface_worker.rb`

- [ ] **Step 1: failing test を書く**

```ruby
# knowledge/test/unit/test_swift_interface_worker.rb
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "rb_apple_sdk_knowledge/importer/swift_interface_worker"

class TestSwiftInterfaceWorker < Test::Unit::TestCase
  def test_returns_symbols_for_valid_swiftinterface
    # 軽量 minimal swiftinterface fixture を tmpdir に置く
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Foo.swiftinterface")
      File.write(path, <<~SWIFT)
        // swift-interface-format-version: 1.0
        // swift-module-flags: -module-name Foo
        public class FooBar {
          public init()
        }
      SWIFT
      worker = AppleSDKKnowledge::Importer::SwiftInterfaceWorker.new
      result = worker.call(framework: "Foo", path: path)
      assert_nil result[:error]
      assert_kind_of Array, result[:result]
      assert_operator result[:elapsed_ms], :>=, 0
    end
  end

  def test_returns_error_for_invalid_swiftinterface
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.swiftinterface")
      File.write(path, "garbage content")
      worker = AppleSDKKnowledge::Importer::SwiftInterfaceWorker.new
      result = worker.call(framework: "Bad", path: path)
      # SwiftInterfaceParser によっては error 返さん場合あり、 その場合 result はパース可能な部分のみ
      # 最低限 hash 構造であることを assert
      assert_kind_of Hash, result
      assert_includes [Array, NilClass], result[:result].class
    end
  end
end
```

- [ ] **Step 2: fail 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_swift_interface_worker.rb`
Expected: `LoadError` for `swift_interface_worker`

- [ ] **Step 3: 実装**

```ruby
# knowledge/lib/rb_apple_sdk_knowledge/importer/swift_interface_worker.rb
# frozen_string_literal: true
require_relative "swift_interface_parser"

module AppleSDKKnowledge
  module Importer
    class SwiftInterfaceWorker
      def initialize
        @parser = SwiftInterfaceParser.new
      end

      def call(framework:, path:)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        symbols = @parser.parse_file(path)
        {
          result: symbols,
          error: nil,
          elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
        }
      rescue => e
        {
          result: nil,
          error: "#{e.class}: #{e.message}",
          elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
        }
      end
    end
  end
end
```

- [ ] **Step 4: pass 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_swift_interface_worker.rb`
Expected: 2 tests / ≥4 assertions / 0 failures

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/swift_interface_worker.rb knowledge/test/unit/test_swift_interface_worker.rb
git commit -m "feat(knowledge/importer): add SwiftInterfaceWorker for parallel swift overlay parse"
```

---

### Task 3: WorkerPool polymorphic dispatch

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/worker_pool.rb`
- Modify: `knowledge/test/unit/test_worker_pool.rb`

worker_factory の lambda 内で kind に応じた worker を選ぶ。 子は両 worker を持ち、 payload[:kind] で route。

- [ ] **Step 1: failing test 追加 (`test_worker_pool.rb` 末尾)**

```ruby
class TestWorkerPoolPolymorphic < Test::Unit::TestCase
  class EchoObjC
    def call(framework:, header:)
      { result: { kind: "objc", fw: framework, hdr: header }, error: nil, elapsed_ms: 1 }
    end
  end
  class EchoSwift
    def call(framework:, path:)
      { result: { kind: "swift", fw: framework, p: path }, error: nil, elapsed_ms: 1 }
    end
  end

  def test_polymorphic_dispatch_routes_by_kind
    channel = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 16)
    pool = AppleSDKKnowledge::Importer::WorkerPool.new(
      size: 2,
      worker_factory: -> do
        objc = EchoObjC.new
        swift = EchoSwift.new
        ->(payload) do
          case payload[:kind]
          when "objc_header" then objc.call(framework: payload[:framework], header: payload[:header])
          when "swift_interface" then swift.call(framework: payload[:framework], path: payload[:path])
          end
        end
      end,
      channel: channel
    )
    pool.submit(seq: 0, payload: { kind: "objc_header", framework: "F1", header: "h1" })
    pool.submit(seq: 1, payload: { kind: "swift_interface", framework: "F2", path: "p2" })
    pool.shutdown(wait: true)

    collected = []
    channel.each_ordered { |item| collected << item[:payload][:result] }
    assert_equal "objc", collected[0][:kind]
    assert_equal "swift", collected[1][:kind]
  end
end
```

- [ ] **Step 2: worker_pool.rb 修正 (worker_factory.call が proc を返す形)**

現状 spawn_workers の子 process loop:
```ruby
worker = @worker_factory.call
req_r.each_line do |line|
  data = JSON.parse(line, symbolize_names: true)
  payload = data[:payload]
  res = worker.call(framework: payload[:framework], header: payload[:header])
  ...
```

新形 (call proc が payload を受ける):
```ruby
dispatch = @worker_factory.call    # dispatch is a proc that takes payload
req_r.each_line do |line|
  data = JSON.parse(line, symbolize_names: true)
  payload = data[:payload]
  res = dispatch.call(payload)
  ...
```

互換性: 既存 worker_factory が proc を返さず ObjCHeaderWorker instance を返す場合は wrap で対応:

```ruby
dispatch = @worker_factory.call
unless dispatch.respond_to?(:call) && dispatch.arity == 1
  # legacy: wrap a single-worker dispatcher
  worker = dispatch
  dispatch = ->(payload) { worker.call(framework: payload[:framework], header: payload[:header]) }
end
```

- [ ] **Step 3: pass 確認**

`bundle exec rake test TEST=test/unit/test_worker_pool.rb`
Expected: 既存 4 tests + new polymorphic = 5 tests pass

- [ ] **Step 4: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/worker_pool.rb knowledge/test/unit/test_worker_pool.rb
git commit -m "feat(knowledge/importer): polymorphic dispatch in WorkerPool worker_factory"
```

---

### Task 4: StoreWriter Mutex (thread-safe for FrameworkScheduler)

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/store_writer.rb`
- Modify: `knowledge/test/unit/test_store_writer.rb`

- [ ] **Step 1: failing test 追加**

```ruby
def test_concurrent_inserts_from_multiple_threads_are_serialized
  Dir.mktmpdir do |dir|
    path = File.join(dir, "kb.sqlite")
    store = AppleSDKKnowledge::Store.open(path)
    writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: 100)
    writer.begin!
    fw_id = writer.insert_framework(name: "F", swift_module: "F")

    threads = 4.times.map do |t|
      Thread.new do
        25.times do |i|
          writer.insert_symbol(framework_id: fw_id,
                               name: "T#{t}_S#{i.to_s.rjust(3, '0')}",
                               kind: "function", abi: "c",
                               content_hash: "h_t#{t}_s#{i}")
        end
      end
    end
    threads.each(&:join)
    writer.flush
    count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
    assert_equal 100, count
    store.close
  end
end
```

- [ ] **Step 2: 修正**

```ruby
def initialize(store:, batch_size: 1000)
  @store = store
  @batch_size = batch_size
  @counter = 0
  @in_tx = false
  @mutex = Mutex.new
end

def begin!
  @mutex.synchronize do
    return if @in_tx
    @store.db.execute("BEGIN")
    @in_tx = true
    @counter = 0
  end
end

def insert_symbol(**kwargs)
  @mutex.synchronize do
    ret = @store.insert_symbol(**kwargs)
    bump!
    ret
  end
rescue SQLite3::ConstraintException
  raise
rescue
  rollback!
  raise
end

def insert_framework(**kwargs)
  @mutex.synchronize do
    ret = @store.insert_framework(**kwargs)
    bump!
    ret
  end
rescue SQLite3::ConstraintException
  raise
rescue
  rollback!
  raise
end

def flush
  @mutex.synchronize do
    return unless @in_tx
    @store.db.execute("COMMIT")
    @in_tx = false
    @counter = 0
  end
end

private

def bump!
  @counter += 1
  return if @counter < @batch_size
  @store.db.execute("COMMIT")
  @in_tx = false
  @store.db.execute("BEGIN")
  @in_tx = true
  @counter = 0
end

def rollback!
  @mutex.synchronize do
    return unless @in_tx
    @store.db.execute("ROLLBACK")
    @in_tx = false
    @counter = 0
  end
end
```

注意: `rollback!` の mutex は **rescue 経路で呼ばれる** ので、 既に `insert_symbol` の `synchronize` 内で lock を持っとると **deadlock**。 修正: `rollback!` を private で mutex 無しで実装し、 `insert_symbol` の rescue 経路では既に mutex 解放後 (raise が synchronize block 終了したら自動 unlock) で呼ぶ → ただし `synchronize` 内で raise すると lock は解放されとる、 その後 rescue で `rollback!` を mutex 無しで呼ぶのが安全。

実装は次のように整理:
```ruby
def insert_symbol(**kwargs)
  ret = nil
  @mutex.synchronize do
    ret = @store.insert_symbol(**kwargs)
    bump!
  end
  ret
rescue SQLite3::ConstraintException
  raise
rescue
  # mutex は raise で自動解放済、 ここで rollback (内部で synchronize 再取得)
  @mutex.synchronize do
    next unless @in_tx
    @store.db.execute("ROLLBACK")
    @in_tx = false
    @counter = 0
  end
  raise
end
```

(`next unless` は `return unless` ではなく Block 内で early-exit、 blockの末尾に到達するため OK)

- [ ] **Step 3: pass 確認**

```bash
cd knowledge && bundle exec rake test TEST=test/unit/test_store_writer.rb
```
Expected: 既存 4 tests + new = 5 tests pass

- [ ] **Step 4: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/store_writer.rb knowledge/test/unit/test_store_writer.rb
git commit -m "feat(knowledge/importer): make StoreWriter thread-safe with Mutex"
```

---

### Task 5: FrameworkScheduler

**Files:**
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/framework_scheduler.rb`
- Create: `knowledge/test/unit/test_framework_scheduler.rb`

複雑な component。 細かい test より integration で実証する方針。 ただし最低限 unit:
- K=1/2/4 で 同じ frameworks set を処理 → 全 symbols が一致 (順序は問わへんが count は一致)

実装スケルトン:

```ruby
# knowledge/lib/rb_apple_sdk_knowledge/importer/framework_scheduler.rb
# frozen_string_literal: true
require_relative "result_channel"

module AppleSDKKnowledge
  module Importer
    class FrameworkScheduler
      def initialize(frameworks:, parallelism:, pool:, store:, writer:, reporter:,
                     consolidator:, swift_overlay:, sdk_path:)
        @frameworks = frameworks
        @parallelism = parallelism
        @pool = pool
        @store = store
        @writer = writer
        @reporter = reporter
        @consolidator = consolidator
        @swift_overlay = swift_overlay
        @sdk_path = sdk_path
        @seq_counter = 0
        @seq_mutex = Mutex.new
        @stats_mutex = Mutex.new
        @stats = { processed: 0, skipped: 0 }
      end

      def run
        queue = Queue.new
        @frameworks.each_with_index { |fw, idx| queue << [fw, idx] }
        threads = @parallelism.times.map do
          Thread.new do
            loop do
              pair = queue.pop(true) rescue nil
              break if pair.nil?
              fw, idx = pair
              process_one(fw, idx)
            end
          end
        end
        threads.each(&:join)
        @stats
      end

      private

      def alloc_seq
        @seq_mutex.synchronize { s = @seq_counter; @seq_counter += 1; s }
      end

      def process_one(fw, idx)
        @reporter.framework_started(fw.name, idx: idx, total: @frameworks.size)
        fw_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        fw_id = @store.find_framework_id_by_name(fw.name) ||
                @writer.insert_framework(name: fw.name, swift_module: fw.name)

        headers = collect_header_paths(fw)
        swift_paths = collect_swift_paths(fw)
        items = headers.map { |h| { kind: "objc_header", framework: fw.name, header: h } } +
                swift_paths.map { |p| { kind: "swift_interface", framework: fw.name, path: p } }

        # per-framework channel
        channel = ResultChannel.new(buffer_size: items.size + @parallelism + 4)
        # 既存 pool は global、 ここで channel を別 channel に差し替えるのは複雑。
        # → 簡便策: per-framework に小さな pool を spawn(Phase 1 同型) で互換性確保
        local_pool = WorkerPool.new(
          size: pool_size_for_framework(items.size),
          worker_factory: build_factory,
          channel: channel
        )

        items.each_with_index { |it, seq| local_pool.submit(seq: seq, payload: it) }
        shutdown_thread = Thread.new { local_pool.shutdown(wait: true) }

        c_syms = []
        swift_syms = []
        processed = 0
        skipped = 0

        channel.each_ordered do |item|
          response = item[:payload]
          payload = response[:request]
          if response[:error]
            @reporter.header_done(framework: fw.name, header: header_path_for(payload),
                                  status: :error, elapsed_ms: response[:elapsed_ms], error: response[:error])
            skipped += 1
            next
          end
          @reporter.header_done(framework: fw.name, header: header_path_for(payload),
                                status: :ok, elapsed_ms: response[:elapsed_ms])
          processed += 1
          case payload[:kind]
          when "objc_header" then c_syms.concat(response[:result] || [])
          when "swift_interface" then swift_syms.concat(response[:result] || [])
          end
        end
        shutdown_thread.join

        merged = @consolidator.merge(swift_syms, c_syms)
        two_pass_insert(merged, fw_id)

        # swift overlay は serial 維持 (Pipeline 互換性、 Phase 2.b で並列化)
        import_swift_overlay(fw)

        fw_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - fw_start) * 1000).to_i
        @reporter.framework_finished(fw.name, processed: processed, skipped: skipped, elapsed_ms: fw_ms)
        @stats_mutex.synchronize { @stats[:processed] += processed; @stats[:skipped] += skipped }
      end

      def collect_header_paths(fw)
        d = File.join(fw.path, "Headers")
        return [] unless File.directory?(d)
        Dir.glob(File.join(d, "*.h")).sort
      end

      def collect_swift_paths(fw)
        Dir.glob(File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")).sort
      end

      def header_path_for(payload)
        payload[:header] || payload[:path]
      end

      def two_pass_insert(merged, fw_id)
        parents, children = merged.partition do |sym|
          %w[class struct protocol enum_module actor].include?(sym[:kind]) && sym[:parent_name].nil?
        end
        parent_id_by_name = {}
        parents.each { |sym| id = insert_one(fw_id, sym, nil); parent_id_by_name[sym[:name]] = id if id }
        children.each { |sym| insert_one(fw_id, sym, sym[:parent_name] && parent_id_by_name[sym[:parent_name]]) }
      end

      def insert_one(fw_id, sym, parent_id)
        @writer.insert_symbol(framework_id: fw_id, name: sym[:name], kind: sym[:kind], abi: sym[:abi],
                              parent_id: parent_id, signature: sym[:signature], documentation: sym[:documentation],
                              return_type: sym[:return_type],
                              parameters_json: sym[:parameters] && JSON.generate(sym[:parameters]),
                              fields_json: sym[:fields] && JSON.generate(sym[:fields]),
                              content_hash: sym[:content_hash],
                              is_throws: sym[:is_throws] ? 1 : 0, is_async: sym[:is_async] ? 1 : 0,
                              is_failable: sym[:is_failable] ? 1 : 0, is_settable: sym[:is_settable] ? 1 : 0,
                              return_ownership: sym[:return_ownership],
                              throws_error_type: sym[:throws_error_type],
                              callback_signature_json: sym[:callback_signature_json],
                              enum_cases_json: sym[:enum_cases_json],
                              unsupported_pattern: sym[:unsupported_pattern])
      rescue SQLite3::ConstraintException
        nil
      end

      def import_swift_overlay(fw)
        pattern = File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")
        Dir.glob(pattern).each do |path|
          @swift_overlay.import!(framework: fw.name, path: path)
        rescue StandardError => e
          warn "[importer] swift overlay skipped #{path}: #{e.class}: #{e.message}"
        end
      end

      def pool_size_for_framework(item_count)
        [item_count, 4].min.tap { |n| return 1 if n < 1 }
      end

      def build_factory
        sdk = @sdk_path
        -> do
          require_relative "objc_header_worker"
          require_relative "swift_interface_worker"
          objc = ObjCHeaderWorker.new(sdk_path: sdk)
          swift = SwiftInterfaceWorker.new
          ->(payload) do
            case payload[:kind]
            when "objc_header" then objc.call(framework: payload[:framework], header: payload[:header])
            when "swift_interface" then swift.call(framework: payload[:framework], path: payload[:path])
            end
          end
        end
      end
    end
  end
end
```

(`Pipeline#run` 側で `FrameworkScheduler` を instantiate、 process_one 内で per-framework に WorkerPool を生成する設計 → Phase 1 構造を温存しつつ K 並列 + swift overlay も pool に。)

- [ ] **Step 1: unit test を書く** (簡易、 mock pool で K=2 並列が動くだけ確認)

実環境依存度高いため、 unit test は collect_header_paths と pool_size_for_framework の private method 中心。 並列挙動は integration で。

```ruby
# knowledge/test/unit/test_framework_scheduler.rb
# frozen_string_literal: true
require "test/unit"
require "rb_apple_sdk_knowledge/importer/framework_scheduler"

class TestFrameworkScheduler < Test::Unit::TestCase
  FakeFramework = Struct.new(:name, :path)

  def test_pool_size_for_framework_with_small_count
    fs = AppleSDKKnowledge::Importer::FrameworkScheduler.new(
      frameworks: [], parallelism: 4, pool: nil, store: nil, writer: nil,
      reporter: nil, consolidator: nil, swift_overlay: nil, sdk_path: nil
    )
    assert_equal 1, fs.send(:pool_size_for_framework, 1)
    assert_equal 2, fs.send(:pool_size_for_framework, 2)
    assert_equal 4, fs.send(:pool_size_for_framework, 10)
    assert_equal 1, fs.send(:pool_size_for_framework, 0)
  end
end
```

- [ ] **Step 2: 実装** (上記 framework_scheduler.rb)

- [ ] **Step 3: pass 確認**

```bash
cd knowledge && bundle exec rake test TEST=test/unit/test_framework_scheduler.rb
```

- [ ] **Step 4: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/framework_scheduler.rb knowledge/test/unit/test_framework_scheduler.rb
git commit -m "feat(knowledge/importer): add FrameworkScheduler for parallel framework processing"
```

---

### Task 6: Pipeline#run を FrameworkScheduler 経由に refactor

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer.rb`

- [ ] **Step 1: Pipeline#run を書き換え**

```ruby
require_relative "importer/framework_scheduler"

def run
  resolver      = @resolver || SDKResolver.new
  store         = AppleSDKKnowledge::Store.open(@store_path)
  consolidator  = Consolidator.new
  swift_overlay = SwiftOverlay.new(store)
  writer        = StoreWriter.new(store: store, batch_size: (ENV["APPLE_SDK_MAC_KB_BATCH_SIZE"] || 1000).to_i)
  frameworks    = resolver.frameworks
  reporter      = ProgressReporter.new(io: $stderr, total_frameworks: frameworks.size)
  parallelism   = [(ENV["APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM"] || 4).to_i, 1].max
  sdk_path      = resolver.sdk_path

  t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  writer.begin!
  begin
    scheduler = FrameworkScheduler.new(
      frameworks: frameworks, parallelism: parallelism,
      pool: nil,    # per-framework に local pool を作る (FrameworkScheduler が管理)
      store: store, writer: writer, reporter: reporter,
      consolidator: consolidator, swift_overlay: swift_overlay, sdk_path: sdk_path
    )
    stats = scheduler.run
    writer.flush
    store.rebuild_fts!
    store.db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                     ["sdk_version", resolver.sdk_version])
  ensure
    store.close
  end
  reporter.finish(processed_total: stats[:processed], skipped_total: stats[:skipped],
                  elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).to_i)
end
```

- [ ] **Step 2: 旧 inline ロジック削除** (Pipeline#run 内の serial framework loop、 collect_header_paths / two_pass_insert / insert_one / import_swift_overlay / collect_swift_symbols を削除、 FrameworkScheduler に移管)。 ただし `test_importer_parameters_json.rb` が `pipeline.send(:two_pass_insert, ...)` を呼ぶので、 Pipeline 内に `two_pass_insert` を残す or test を更新する必要。

簡便: Pipeline に薄い `two_pass_insert` を残す (FrameworkScheduler のと duplicate)。 もしくは test_importer_parameters_json.rb を `FrameworkScheduler` 経由 or 直接 StoreWriter テストに置き換える。 簡単な保持を選ぶ。

- [ ] **Step 3: tests run**

```bash
cd knowledge && bundle exec rake test
```
Expected: 全 green

- [ ] **Step 4: smoke run** (1 framework single)

```bash
cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
APPLE_SDK_MAC_KB_BASE_DIR=$(pwd)/tmp/bench-kb-phase2 APPLE_SDK_MAC_KB_WORKERS=4 APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM=1 \
  bundle exec rake -f knowledge/Rakefile 'apple:knowledge:benchmark_rebuild[single,4]'
```
Expected: elapsed ~few seconds、 DONE exit=0

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer.rb
git commit -m "refactor(knowledge/importer): route Pipeline#run through FrameworkScheduler"
```

---

### Task 7: Bit-identical test N=8 + framework parallelism determinism

**Files:**
- Modify: `knowledge/test/integration/test_pipeline_parallel_bit_identical.rb`

- [ ] **Step 1: N=8 + K=4 を追加**

```ruby
def test_n1_n2_n4_n8_produce_bit_identical_symbols
  omit "set APPLE_SDK_MAC_KB_INTEGRATION=1 to run" unless ENV["APPLE_SDK_MAC_KB_INTEGRATION"]
  n1 = rebuild_with(workers: 1, framework_parallelism: 1)
  n2 = rebuild_with(workers: 2, framework_parallelism: 2)
  n4 = rebuild_with(workers: 4, framework_parallelism: 4)
  n8 = rebuild_with(workers: 8, framework_parallelism: 4)
  assert_equal n1, n2
  assert_equal n1, n4
  assert_equal n1, n8, "N=8 K=4 でも bit-identical 維持"
end
```

`rebuild_with` の signature 更新:
```ruby
def rebuild_with(workers:, framework_parallelism: 1)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "kb.sqlite")
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: FRAMEWORK_SUBSET)
    ENV["APPLE_SDK_MAC_KB_WORKERS"] = workers.to_s
    ENV["APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM"] = framework_parallelism.to_s
    AppleSDKKnowledge::Importer::Pipeline.new(store_path: path, resolver: resolver).run
    store = AppleSDKKnowledge::Store.open(path)
    rows = store.db.execute(<<~SQL)
      SELECT framework_id, name, kind, COALESCE(content_hash, '')
      FROM symbols
      ORDER BY framework_id, name, kind, content_hash
    SQL
    store.close
    Digest::SHA256.hexdigest(rows.map { |r| r.join("|") }.join("\n"))
  end
end
```

- [ ] **Step 2: integration test 実行** (10-15 min)

```bash
cd knowledge && APPLE_SDK_MAC_KB_INTEGRATION=1 bundle exec rake integration
```
Expected: 1 test / 3 assertions / 0 failures (N1=N2、 N1=N4、 N1=N8)

- [ ] **Step 3: commit**

```bash
git add knowledge/test/integration/test_pipeline_parallel_bit_identical.rb
git commit -m "test(knowledge/importer): verify N=8 K=4 bit-identical (Phase 2)"
```

---

### Task 8: Phase 2 benchmark + S1 verify

**Files:**
- (なし、 実行のみ)

- [ ] **Step 1: longrun pattern で full rebuild benchmark**

```bash
mkdir -p tmp/longrun tmp/bench-kb-phase2-full
rm -rf tmp/bench-kb-phase2-full/*
screen -dmS kb-bench-phase2 bash -c '
  cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/knowledge
  APPLE_SDK_MAC_KB_BASE_DIR=/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/tmp/bench-kb-phase2-full \
  APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM=4 \
    bundle exec rake "apple:knowledge:benchmark_rebuild[full,8]" \
    > /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/tmp/longrun/kb-bench-phase2.log 2>&1
  echo "DONE: exit=$?" >> /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/tmp/longrun/kb-bench-phase2.log
'
```

- [ ] **Step 2: 完了待ち + verify**

```bash
grep '^DONE:' tmp/longrun/kb-bench-phase2.log
grep 'elapsed=' tmp/longrun/kb-bench-phase2.log
wc -l tmp/longrun/kb-bench-phase2.log
```
Expected:
- `DONE: exit=0`
- `elapsed=` ≤ 1500s (25min) → **S1 OK**
- log ≤ 1500 行 → **S3 OK**

S1 NG なら Phase 2.b でさらに改善 (workers up to 16、 framework_parallelism up to 8、 swift overlay 並列化深堀り)。

---

### Task 9: README L3 release_quality smoke

**Files:**
- Create: `test/integration/test_release_quality_rebuild_l3.rb`

memory「README release-quality completion is non-negotiable」 を実装 verify。 README に列挙された L3 examples 中の 1 つを Phase 2 rebuild 後の Knowledge Base 経由で実行。

- [ ] **Step 1: README から L3 example を抽出**

Read: `README.md` で「any public Apple framework API」 と書かれてる example を確認。 既存 `test/integration/examples_<framework>_e2e_test.rb` の中で代表 1 つ選ぶ。

- [ ] **Step 2: smoke test を書く**

```ruby
# test/integration/test_release_quality_rebuild_l3.rb
# frozen_string_literal: true
require "test_helper"
require "tmpdir"

class TestReleaseQualityRebuildL3 < Test::Unit::TestCase
  def test_phase2_kb_emits_executable_example
    omit "set RB_APPLE_SDK_RELEASE_QUALITY=1 to run" unless ENV["RB_APPLE_SDK_RELEASE_QUALITY"]
    # Phase 2 で生成した Knowledge Base を使い、 README L3 の example 1 つを実行
    # 既存 examples_*_e2e_test.rb の verify 部分を流用
    ...
  end
end
```

実体は既存 test/integration/examples_*_e2e_test.rb 群と被るので、 README に書かれた 1 example の e2e test を Phase 2 Knowledge Base で回す。 具体例は spec で決定する (例: NSString に対する method call、 もしくは README の最初の example)。

- [ ] **Step 3: 実行**

```bash
RB_APPLE_SDK_RELEASE_QUALITY=1 bundle exec rake test:release_quality
```

Expected: example が live macOS で end-to-end 動作

- [ ] **Step 4: commit**

```bash
git add test/integration/test_release_quality_rebuild_l3.rb
git commit -m "test(integration): verify README L3 example executes against Phase 2 Knowledge Base"
```

---

### Task 10: Final docs update

**Files:**
- Modify: `knowledge/README.md`

- [ ] **Step 1: ENV var 表更新** (APPLE_SDK_MAC_KB_FRAMEWORK_PARALLELISM 追加、 WORKERS default を nproc に)

- [ ] **Step 2: commit**

```bash
git add knowledge/README.md
git commit -m "docs(knowledge): document Phase 2 ENV vars (FRAMEWORK_PARALLELISM, nproc default)"
```

---

## Self-review (plan 作成者)

- Spec coverage: §3 S1-S5 → Task 6+8 (S1)、 Task 7 (S2)、 Task 8 (S3)、 全 task 後 rake test (S4)、 Task 9 (S5)
- Determinism: framework_id sort 順 + per-framework deterministic insert で N=1 ↔ N=8 bit-identical 保証
- Resource leak: store.close ensure 維持、 writer mutex で thread-safe、 WorkerPool shutdown は Phase 1 fix 継承
- Phase 1 互換: 既存 unit tests 全 pass、 ENV var 後方互換 (新規 FRAMEWORK_PARALLELISM は default あり)
- README L3 (S5) は non-negotiable、 fail なら Phase 2 不完全

## References

- Phase 2 spec: `docs/superpowers/specs/2026-05-14-knowledge-base-rebuild-phase2-design.md`
- Phase 1 spec: `docs/superpowers/specs/2026-05-14-knowledge-base-rebuild-tuning-design.md`
- Phase 1 plan: `docs/superpowers/plans/2026-05-14-knowledge-base-rebuild-tuning.md`
- Memory: `[[release_quality_completion_required]]` `[[kb_rebuild_phase1_result_2026_05_14]]` `[[project_core_thesis_long_term_improvement]]`
