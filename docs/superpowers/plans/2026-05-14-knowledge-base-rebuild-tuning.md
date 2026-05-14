# Knowledge Base Rebuild Tuning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Knowledge Base rebuild を 75 min → 35-40 min に半減し、 stderr に 1 行 progress bar を出す。 結果は serial run と bit-identical。

**Architecture:** `Importer::Pipeline#run` の per-framework loop に WorkerPool (Process.fork × N=2) を挟み、 per-header clang invocation を並列化。 ResultChannel が seq 順 deliver、 StoreWriter が transaction batching (1000 行/commit)。 ProgressReporter が tty / non-tty 切替で出力。 spec: `docs/superpowers/specs/2026-05-14-knowledge-base-rebuild-tuning-design.md`。

**Tech Stack:** Ruby 4.0 (CRuby) / SQLite3 / ruby-progressbar / test-unit / clang AST JSON / Process.fork + IO.pipe IPC

---

## Prerequisites

- **branch**: `feature/knowledge-base-rebuild-tuning` (spec が commit 済)
- **KB rebuild 実行中**: screen `knowledge-rebuild-20260514-114557` が完了 (`grep '^DONE:' tmp/longrun/knowledge-rebuild-20260514-114557.log` で確認) するまで Task 1 開始禁止。 並行で clang を fork すると SDK file cache / SQLite cache が競合し、 観測中の rebuild が不安定化する
- **既存テスト baseline**: `cd knowledge && bundle exec rake test` が green である前提。 Task 開始前に確認

## File Map (全 task で touch する file)

- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/result_channel.rb`
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/store_writer.rb`
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/progress_reporter.rb`
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/objc_header_worker.rb`
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/worker_pool.rb`
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer.rb` (Pipeline#run refactor)
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/store.rb` (`PRAGMA synchronous=NORMAL` 追加)
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/sdk_resolver.rb` (`filter:` option 追加)
- Modify: `knowledge/Gemfile` (`ruby-progressbar` 追加)
- Modify: `knowledge/Rakefile` (`apple:knowledge:benchmark_rebuild` task 追加)
- Modify: `knowledge/README.md` (ENV var 一覧追加)
- Create: `knowledge/test/unit/test_result_channel.rb`
- Create: `knowledge/test/unit/test_store_writer.rb`
- Create: `knowledge/test/unit/test_progress_reporter.rb`
- Create: `knowledge/test/unit/test_worker_pool.rb`
- Create: `knowledge/test/integration/test_pipeline_parallel_bit_identical.rb`

---

### Task 1: ResultChannel — seq 順 deliver の SizedQueue

**Files:**
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/result_channel.rb`
- Test: `knowledge/test/unit/test_result_channel.rb`

- [ ] **Step 1: 失敗テストを書く**

```ruby
# knowledge/test/unit/test_result_channel.rb
# frozen_string_literal: true
require "test/unit"
require "rb_apple_sdk_knowledge/importer/result_channel"

class TestResultChannel < Test::Unit::TestCase
  def test_out_of_order_push_yields_seq_order
    ch = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 8)
    ch.push(seq: 2, payload: { v: "c" })
    ch.push(seq: 0, payload: { v: "a" })
    ch.push(seq: 1, payload: { v: "b" })
    ch.close

    collected = []
    ch.each_ordered { |item| collected << item[:payload][:v] }
    assert_equal ["a", "b", "c"], collected
  end

  def test_blocks_until_next_seq_arrives_then_resumes
    ch = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 8)
    pusher = Thread.new do
      sleep 0.05
      ch.push(seq: 0, payload: { v: "a" })
      sleep 0.05
      ch.push(seq: 1, payload: { v: "b" })
      ch.close
    end
    seen = []
    ch.each_ordered { |item| seen << item[:seq] }
    pusher.join
    assert_equal [0, 1], seen
  end

  def test_close_with_empty_buffer_terminates
    ch = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 8)
    ch.close
    collected = []
    ch.each_ordered { |item| collected << item }
    assert_equal [], collected
  end
end
```

- [ ] **Step 2: テスト実行して fail 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_result_channel.rb`
Expected: `LoadError: cannot load such file -- rb_apple_sdk_knowledge/importer/result_channel`

- [ ] **Step 3: 実装書く**

```ruby
# knowledge/lib/rb_apple_sdk_knowledge/importer/result_channel.rb
# frozen_string_literal: true
require "thread"

module AppleSDKKnowledge
  module Importer
    class ResultChannel
      def initialize(buffer_size: 64)
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @buffer = {}
        @next_seq = 0
        @closed = false
        @buffer_size = buffer_size
      end

      def push(seq:, payload:)
        @mutex.synchronize do
          while @buffer.size >= @buffer_size && !@closed
            @cond.wait(@mutex)
          end
          @buffer[seq] = { seq: seq, payload: payload }
          @cond.broadcast
        end
      end

      def close
        @mutex.synchronize do
          @closed = true
          @cond.broadcast
        end
      end

      def each_ordered
        loop do
          item = @mutex.synchronize do
            until @buffer.key?(@next_seq) || (@closed && !@buffer.key?(@next_seq) && @buffer.size.zero?)
              @cond.wait(@mutex)
            end
            break nil if @closed && !@buffer.key?(@next_seq)
            @buffer.delete(@next_seq).tap { @cond.broadcast }
          end
          break if item.nil?
          @next_seq += 1
          yield item
        end
      end
    end
  end
end
```

- [ ] **Step 4: テスト pass 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_result_channel.rb`
Expected: 3 tests, 3 assertions, 0 failures, 0 errors

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/result_channel.rb knowledge/test/unit/test_result_channel.rb
git commit -m "feat(knowledge/importer): add ResultChannel for ordered worker delivery"
```

---

### Task 2: StoreWriter — transaction batching

**Files:**
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/store_writer.rb`
- Test: `knowledge/test/unit/test_store_writer.rb`

- [ ] **Step 1: 失敗テストを書く**

```ruby
# knowledge/test/unit/test_store_writer.rb
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/importer/store_writer"

class TestStoreWriter < Test::Unit::TestCase
  N_SYMBOLS = 2500

  def insert_with(batch_size)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      store = AppleSDKKnowledge::Store.open(path)
      writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: batch_size)
      writer.begin!
      fw_id = writer.insert_framework(name: "F", swift_module: "F")
      N_SYMBOLS.times do |i|
        writer.insert_symbol(
          framework_id: fw_id,
          name: "Sym#{i.to_s.rjust(5, '0')}",
          kind: "function",
          abi: "c",
          content_hash: "h#{i}"
        )
      end
      writer.flush
      rows = store.db.execute("SELECT name FROM symbols ORDER BY id").flatten
      store.close
      rows
    end
  end

  def test_batch_size_1_and_1000_yield_identical_row_order
    rows1 = insert_with(1)
    rows1000 = insert_with(1000)
    assert_equal N_SYMBOLS, rows1.size
    assert_equal rows1, rows1000
  end

  def test_flush_without_begin_is_noop
    Dir.mktmpdir do |dir|
      store = AppleSDKKnowledge::Store.open(File.join(dir, "kb.sqlite"))
      writer = AppleSDKKnowledge::Importer::StoreWriter.new(store: store, batch_size: 10)
      assert_nothing_raised { writer.flush }
      store.close
    end
  end
end
```

- [ ] **Step 2: fail 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_store_writer.rb`
Expected: `LoadError` for `store_writer`

- [ ] **Step 3: 実装**

```ruby
# knowledge/lib/rb_apple_sdk_knowledge/importer/store_writer.rb
# frozen_string_literal: true
module AppleSDKKnowledge
  module Importer
    class StoreWriter
      def initialize(store:, batch_size: 1000)
        @store = store
        @batch_size = batch_size
        @counter = 0
        @in_tx = false
      end

      def begin!
        return if @in_tx
        @store.db.execute("BEGIN")
        @in_tx = true
        @counter = 0
      end

      def insert_symbol(**kwargs)
        ret = @store.insert_symbol(**kwargs)
        bump!
        ret
      end

      def insert_framework(**kwargs)
        ret = @store.insert_framework(**kwargs)
        bump!
        ret
      end

      def flush
        return unless @in_tx
        @store.db.execute("COMMIT")
        @in_tx = false
        @counter = 0
      end

      private

      def bump!
        @counter += 1
        return if @counter < @batch_size
        flush
        begin!
      end
    end
  end
end
```

- [ ] **Step 4: pass 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_store_writer.rb`
Expected: 2 tests, ≥2 assertions, 0 failures

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/store_writer.rb knowledge/test/unit/test_store_writer.rb
git commit -m "feat(knowledge/importer): add StoreWriter with transaction batching"
```

---

### Task 3: Store.open に `PRAGMA synchronous = NORMAL` 追加

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/store.rb` (`PRAGMA` block 周辺、 既に `journal_mode = WAL` がある場所)
- Test: `knowledge/test/test_store.rb` (regression として既存テストが green を維持することで充分)

- [ ] **Step 1: 既存 PRAGMA block を確認**

Run: `grep -n 'PRAGMA' knowledge/lib/rb_apple_sdk_knowledge/store.rb`
Expected: `12: PRAGMA journal_mode = WAL;` / `13: PRAGMA foreign_keys = ON;`

- [ ] **Step 2: PRAGMA 追加 (`store.rb` line 12-13 ブロック)**

修正前:
```ruby
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
```

修正後:
```ruby
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
```

- [ ] **Step 3: 既存テスト regression check**

Run: `cd knowledge && bundle exec rake test`
Expected: 全テスト green (新 PRAGMA は既存テストの semantics を破らない)

- [ ] **Step 4: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/store.rb
git commit -m "perf(knowledge/store): add PRAGMA synchronous=NORMAL for rebuild throughput"
```

---

### Task 4: ruby-progressbar gem 追加

**Files:**
- Modify: `knowledge/Gemfile`

- [ ] **Step 1: `Gemfile` に gem 追加**

```ruby
# knowledge/Gemfile (`gem "test-unit", "~> 3.0"` の上に追加)
gem "ruby-progressbar", "~> 1.13"
```

- [ ] **Step 2: bundle install**

Run: `cd knowledge && bundle install`
Expected: `Bundle complete!`、 `Gemfile.lock` に `ruby-progressbar (1.13.x)` が現れる

- [ ] **Step 3: commit**

```bash
git add knowledge/Gemfile knowledge/Gemfile.lock
git commit -m "chore(knowledge): add ruby-progressbar dependency for rebuild progress UI"
```

---

### Task 5: ProgressReporter — tty / non-tty 切替出力

**Files:**
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/progress_reporter.rb`
- Test: `knowledge/test/unit/test_progress_reporter.rb`

- [ ] **Step 1: 失敗テストを書く**

```ruby
# knowledge/test/unit/test_progress_reporter.rb
# frozen_string_literal: true
require "test/unit"
require "stringio"
require "rb_apple_sdk_knowledge/importer/progress_reporter"

class TestProgressReporter < Test::Unit::TestCase
  def tty_io
    io = StringIO.new
    def io.tty?; true; end
    io
  end

  def non_tty_io
    io = StringIO.new
    def io.tty?; false; end
    io
  end

  def test_tty_outputs_ansi_escape_sequence
    io = tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 2)
    reporter.framework_started("Foundation", idx: 0, total: 2)
    reporter.framework_finished("Foundation", processed: 10, skipped: 1, elapsed_ms: 1234)
    reporter.finish(processed_total: 10, skipped_total: 1, elapsed_ms: 1234)
    assert_match(/\e\[/, io.string)
  end

  def test_non_tty_one_line_per_framework_event
    io = non_tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 3)
    reporter.framework_started("Foundation", idx: 0, total: 3)
    reporter.framework_finished("Foundation", processed: 5, skipped: 0, elapsed_ms: 800)
    lines = io.string.lines
    assert_equal 2, lines.size
    assert_match(/=== Foundation \(1\/3\) ===/, lines[0])
    assert_match(/processed=5/, lines[1])
    assert_match(/skipped=0/, lines[1])
    assert_match(/0\.8s/, lines[1])
  end

  def test_non_tty_compresses_clang_error_to_single_line
    io = non_tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 1)
    long_error = "clang failed for /path/x.h: /path/x.h:11:15: error: type specifier missing\n   11 | API_AVAILABLE\n      |               ^\n      |               int\n"
    reporter.header_done(framework: "F", header: "/path/x.h", status: :error, elapsed_ms: 12, error: long_error)
    lines = io.string.lines
    assert_equal 1, lines.size
    assert_match(%r{\[importer\] skipping /path/x\.h:}, lines[0])
    refute_match(/\n.*\|/, lines[0])
  end

  def test_non_tty_silent_on_header_ok
    io = non_tty_io
    reporter = AppleSDKKnowledge::Importer::ProgressReporter.new(io: io, total_frameworks: 1)
    reporter.header_done(framework: "F", header: "/path/y.h", status: :ok, elapsed_ms: 5)
    assert_equal "", io.string
  end
end
```

- [ ] **Step 2: fail 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_progress_reporter.rb`
Expected: `LoadError` for `progress_reporter`

- [ ] **Step 3: 実装**

```ruby
# knowledge/lib/rb_apple_sdk_knowledge/importer/progress_reporter.rb
# frozen_string_literal: true
require "ruby-progressbar"

module AppleSDKKnowledge
  module Importer
    class ProgressReporter
      def initialize(io: $stderr, total_frameworks:, tty: io.tty?)
        @io = io
        @total = total_frameworks
        @tty = tty
        if @tty
          @bar = ProgressBar.create(
            output: io,
            total: total_frameworks,
            format: "%t [%B] %c/%C %e"
          )
        end
      end

      def framework_started(name, idx:, total:)
        if @tty
          @bar.title = name
        else
          @io.puts "=== #{name} (#{idx + 1}/#{total}) ==="
        end
      end

      def header_done(framework:, header:, status:, elapsed_ms:, error: nil)
        return if @tty           # bar 内 counter で集約、 個別 line は出さへん
        return unless status == :error
        first = error.to_s.lines.first.to_s.strip
        @io.puts "[importer] skipping #{header}: #{first}"
      end

      def framework_finished(name, processed:, skipped:, elapsed_ms:)
        if @tty
          @bar.increment
        else
          @io.puts "→ processed=#{processed} skipped=#{skipped} elapsed=#{format_elapsed(elapsed_ms)}"
        end
      end

      def finish(processed_total:, skipped_total:, elapsed_ms:)
        msg = "✓ done processed=#{processed_total} skipped=#{skipped_total} elapsed=#{format_elapsed(elapsed_ms)}"
        @bar.finish if @tty
        @io.puts msg
      end

      private

      def format_elapsed(ms)
        s = ms / 1000.0
        return "#{s.round(1)}s" if s < 60
        m = (s / 60).to_i
        rem = (s - m * 60).round
        "#{m}m#{rem}s"
      end
    end
  end
end
```

- [ ] **Step 4: pass 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_progress_reporter.rb`
Expected: 4 tests, ≥4 assertions, 0 failures

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/progress_reporter.rb knowledge/test/unit/test_progress_reporter.rb
git commit -m "feat(knowledge/importer): add ProgressReporter with tty/non-tty modes"
```

---

### Task 6: ObjCHeaderWorker — fork-safe な 1 header parser ラッパ

**Files:**
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/objc_header_worker.rb`
- Test: `knowledge/test/unit/test_objc_header_worker.rb`

注: 既存 `HeaderParser#parse_file(path)` (引数は path 単独) を内部利用し、 `{result:, error:, elapsed_ms:}` を返す pure-function form に packaging する。

- [ ] **Step 1: 失敗テストを書く**

```ruby
# knowledge/test/unit/test_objc_header_worker.rb
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "rb_apple_sdk_knowledge/importer/objc_header_worker"

class TestObjCHeaderWorker < Test::Unit::TestCase
  def test_returns_symbols_for_valid_header
    Dir.mktmpdir do |dir|
      header = File.join(dir, "Foo.h")
      File.write(header, "int foo_add(int a, int b);\n")
      worker = AppleSDKKnowledge::Importer::ObjCHeaderWorker.new(sdk_path: nil)
      result = worker.call(framework: "Foo", header: header)
      assert_nil result[:error]
      assert_kind_of Array, result[:result]
      names = result[:result].map { |s| s[:name] }
      assert_includes names, "foo_add"
      assert_operator result[:elapsed_ms], :>=, 0
    end
  end

  def test_returns_error_for_invalid_header
    Dir.mktmpdir do |dir|
      header = File.join(dir, "Broken.h")
      File.write(header, "this is not valid C\n")
      worker = AppleSDKKnowledge::Importer::ObjCHeaderWorker.new(sdk_path: nil)
      result = worker.call(framework: "Broken", header: header)
      assert_nil result[:result]
      assert_match(/clang failed/, result[:error])
    end
  end
end
```

- [ ] **Step 2: fail 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_objc_header_worker.rb`
Expected: `LoadError` for `objc_header_worker`

- [ ] **Step 3: 実装**

```ruby
# knowledge/lib/rb_apple_sdk_knowledge/importer/objc_header_worker.rb
# frozen_string_literal: true
require_relative "header_parser"

module AppleSDKKnowledge
  module Importer
    class ObjCHeaderWorker
      def initialize(sdk_path:)
        @parser = HeaderParser.new(sdk_path: sdk_path)
      end

      def call(framework:, header:)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        symbols = @parser.parse_file(header)
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

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_objc_header_worker.rb`
Expected: 2 tests, 0 failures (clang available on macOS 前提)

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/objc_header_worker.rb knowledge/test/unit/test_objc_header_worker.rb
git commit -m "feat(knowledge/importer): add ObjCHeaderWorker as fork-safe header parse unit"
```

---

### Task 7: WorkerPool — Process.fork × N の IPC pool

**Files:**
- Create: `knowledge/lib/rb_apple_sdk_knowledge/importer/worker_pool.rb`
- Test: `knowledge/test/unit/test_worker_pool.rb`

注: payload は JSON serializable な値だけを許可。 framework は name (String) のみ送る (Object は送らへん)。 worker factory は fork 後の子 process で評価される lambda。

- [ ] **Step 1: 失敗テストを書く**

```ruby
# knowledge/test/unit/test_worker_pool.rb
# frozen_string_literal: true
require "test/unit"
require "rb_apple_sdk_knowledge/importer/result_channel"
require "rb_apple_sdk_knowledge/importer/worker_pool"

class TestWorkerPool < Test::Unit::TestCase
  class EchoWorker
    def call(framework:, header:)
      { result: { fw: framework, hdr: header }, error: nil, elapsed_ms: 1 }
    end
  end

  def submit_and_drain(size:, count:)
    channel = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: count + 4)
    pool = AppleSDKKnowledge::Importer::WorkerPool.new(
      size: size,
      worker_factory: -> { EchoWorker.new },
      channel: channel
    )
    count.times { |i| pool.submit(seq: i, payload: { framework: "F", header: "h#{i}" }) }
    pool.shutdown(wait: true)

    collected = []
    channel.each_ordered { |item| collected << item[:payload][:result][:hdr] }
    collected
  end

  def test_n1_processes_items_in_seq_order
    assert_equal (0...20).map { |i| "h#{i}" }, submit_and_drain(size: 1, count: 20)
  end

  def test_n2_processes_items_in_seq_order
    assert_equal (0...20).map { |i| "h#{i}" }, submit_and_drain(size: 2, count: 20)
  end

  def test_n4_processes_items_in_seq_order
    assert_equal (0...20).map { |i| "h#{i}" }, submit_and_drain(size: 4, count: 20)
  end
end
```

- [ ] **Step 2: fail 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_worker_pool.rb`
Expected: `LoadError` for `worker_pool`

- [ ] **Step 3: 実装**

```ruby
# knowledge/lib/rb_apple_sdk_knowledge/importer/worker_pool.rb
# frozen_string_literal: true
require "json"

module AppleSDKKnowledge
  module Importer
    class WorkerPool
      def initialize(size:, worker_factory:, channel:)
        @size = size
        @worker_factory = worker_factory
        @channel = channel
        @pids = []
        @to_worker = []     # parent → worker (request)
        @from_worker = []   # worker → parent (response)
        @next_worker = 0
        spawn_workers
        @reader = start_reader
      end

      def submit(seq:, payload:)
        msg = JSON.dump(seq: seq, payload: payload)
        @to_worker[@next_worker].puts(msg)
        @next_worker = (@next_worker + 1) % @size
      end

      def shutdown(wait: true)
        @to_worker.each(&:close)
        @pids.each { |pid| Process.waitpid(pid) }
        @reader.join if wait
        @channel.close
      end

      private

      def spawn_workers
        @size.times do
          req_r, req_w = IO.pipe
          res_r, res_w = IO.pipe
          pid = Process.fork do
            req_w.close
            res_r.close
            worker = @worker_factory.call
            req_r.each_line do |line|
              data = JSON.parse(line, symbolize_names: true)
              payload = data[:payload]
              res = worker.call(framework: payload[:framework], header: payload[:header])
              res_w.puts JSON.dump(
                seq: data[:seq],
                result: res[:result],
                error: res[:error],
                elapsed_ms: res[:elapsed_ms],
                payload: payload
              )
            end
            res_w.close
            exit 0
          end
          req_r.close
          res_w.close
          @pids << pid
          @to_worker << req_w
          @from_worker << res_r
        end
      end

      def start_reader
        Thread.new do
          readers = @from_worker.dup
          until readers.empty?
            ready, = IO.select(readers)
            ready.each do |r|
              line = r.gets
              if line.nil?
                readers.delete(r)
                next
              end
              data = JSON.parse(line, symbolize_names: true)
              @channel.push(seq: data[:seq], payload: data)
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: pass 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/unit/test_worker_pool.rb`
Expected: 3 tests, 3 assertions, 0 failures

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/worker_pool.rb knowledge/test/unit/test_worker_pool.rb
git commit -m "feat(knowledge/importer): add WorkerPool with fork-based IPC"
```

---

### Task 8: SDKResolver に `filter:` option 追加

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer/sdk_resolver.rb`
- Modify: `knowledge/test/test_sdk_resolver.rb`

注: 既存 `SDKResolver#frameworks` は SDK の全 framework を返す。 integration test (Task 10) で subset 限定が要るため `initialize(filter: nil)` の白リスト追加。

- [ ] **Step 1: 失敗テストを書く (`test_sdk_resolver.rb` 末尾に追加)**

```ruby
class TestSDKResolverFilter < Test::Unit::TestCase
  def test_filter_returns_only_listed_frameworks
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: ["Foundation"])
    names = resolver.frameworks.map(&:name)
    assert_equal ["Foundation"], names
  end

  def test_filter_nil_returns_all_frameworks
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: nil)
    assert_operator resolver.frameworks.size, :>=, 50
  end
end
```

- [ ] **Step 2: fail 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/test_sdk_resolver.rb`
Expected: `wrong number of arguments` または `unknown keyword: :filter`

- [ ] **Step 3: 実装 (`sdk_resolver.rb`)**

`SDKResolver#initialize` を以下に変更 (`@filter` 追加)、 `frameworks` に filter 適用ロジック追加:

```ruby
def initialize(filter: nil)
  @filter = filter
end

def frameworks
  @frameworks ||= begin
    all = enumerate_frameworks   # 既存ロジックの内部 method 名に揃える
    @filter ? all.select { |fw| @filter.include?(fw.name) } : all
  end
end
```

(`enumerate_frameworks` は既存の `@frameworks ||= begin ... end` ブロック内ロジックを private method に切り出して呼び出す。 切り出し対象が複雑な場合はブロック内の `all = ...` 化で済ます)

- [ ] **Step 4: pass 確認**

Run: `cd knowledge && bundle exec rake test TEST=test/test_sdk_resolver.rb`
Expected: 全テスト green

- [ ] **Step 5: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer/sdk_resolver.rb knowledge/test/test_sdk_resolver.rb
git commit -m "feat(knowledge/importer): add filter: option to SDKResolver"
```

---

### Task 9: Pipeline#run refactor — WorkerPool 経由に切替

**Files:**
- Modify: `knowledge/lib/rb_apple_sdk_knowledge/importer.rb`
- Test: 既存 `knowledge/test/test_importer_pipeline_idempotence.rb` が regress せえへんことを確認

注: 既存 `process_framework` の two-pass insert (parents / children) ロジックは温存。 worker からは framework 単位の symbols 配列を受け取り、 既存 `Consolidator.merge` + `insert_one` を main thread で実行する。 swift overlay 部分は **Phase 1 では既存 serial 維持**、 progress reporter event だけ流す。

- [ ] **Step 1: 既存 `run` のバックアップ用ノートを作る**

Run: `git show HEAD:knowledge/lib/rb_apple_sdk_knowledge/importer.rb | head -140 > /tmp/importer.rb.bak`
これは後で diff 比較用、 commit には含めへん。

- [ ] **Step 2: `Pipeline#run` を refactor**

`knowledge/lib/rb_apple_sdk_knowledge/importer.rb` の冒頭 require に追加:

```ruby
require_relative "importer/result_channel"
require_relative "importer/store_writer"
require_relative "importer/progress_reporter"
require_relative "importer/objc_header_worker"
require_relative "importer/worker_pool"
```

`Pipeline#run` を以下に置換:

```ruby
def run
  resolver      = @resolver || SDKResolver.new
  store         = AppleSDKKnowledge::Store.open(@store_path)
  swift_parser  = SwiftInterfaceParser.new
  consolidator  = Consolidator.new
  swift_overlay = SwiftOverlay.new(store)
  writer        = StoreWriter.new(store: store, batch_size: (ENV["APPLE_SDK_MAC_KB_BATCH_SIZE"] || 1000).to_i)
  reporter      = ProgressReporter.new(io: $stderr, total_frameworks: resolver.frameworks.size)
  workers       = (ENV["APPLE_SDK_MAC_KB_WORKERS"] || 2).to_i
  sdk_path      = resolver.sdk_path

  t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  total_processed = 0
  total_skipped = 0

  writer.begin!
  resolver.frameworks.each_with_index do |fw, idx|
    reporter.framework_started(fw.name, idx: idx, total: resolver.frameworks.size)
    fw_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    fw_id = store.find_framework_id_by_name(fw.name) ||
            writer.insert_framework(name: fw.name, swift_module: fw.name)

    headers = fw.headers
    processed = 0
    skipped = 0

    if headers.empty?
      # nothing to parse
    else
      channel = ResultChannel.new(buffer_size: workers * 8)
      pool = WorkerPool.new(
        size: workers,
        worker_factory: -> { ObjCHeaderWorker.new(sdk_path: sdk_path) },
        channel: channel
      )
      headers.each_with_index { |h, seq| pool.submit(seq: seq, payload: { framework: fw.name, header: h }) }
      pool.shutdown(wait: true)

      c_syms_all = []
      channel.each_ordered do |item|
        payload = item[:payload]
        elapsed_ms = payload[:elapsed_ms]
        if payload[:error]
          reporter.header_done(framework: fw.name, header: payload[:payload][:header],
                               status: :error, elapsed_ms: elapsed_ms, error: payload[:error])
          skipped += 1
        else
          reporter.header_done(framework: fw.name, header: payload[:payload][:header],
                               status: :ok, elapsed_ms: elapsed_ms)
          c_syms_all.concat(payload[:result] || [])
          processed += 1
        end
      end

      swift_syms = collect_swift_symbols(fw, swift_parser)
      merged = consolidator.merge(swift_syms, c_syms_all)
      two_pass_insert(merged, writer, fw_id)
    end

    import_swift_overlay(fw, swift_overlay)
    fw_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - fw_start) * 1000).to_i
    reporter.framework_finished(fw.name, processed: processed, skipped: skipped, elapsed_ms: fw_ms)
    total_processed += processed
    total_skipped += skipped
  end
  writer.flush

  store.rebuild_fts!
  store.db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                   ["sdk_version", resolver.sdk_version])
  store.close
  reporter.finish(processed_total: total_processed, skipped_total: total_skipped,
                  elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).to_i)
end
```

`two_pass_insert` private method を追加 (既存 `process_framework` の parents / children 分岐ロジックをそのまま移植):

```ruby
private

def two_pass_insert(merged, writer, fw_id)
  parents, children = merged.partition do |sym|
    PARENT_KINDS.include?(sym[:kind]) && sym[:parent_name].nil?
  end

  parent_id_by_name = {}
  parents.each do |sym|
    id = insert_one(writer, fw_id, sym, nil)
    parent_id_by_name[sym[:name]] = id if id
  end

  children.each do |sym|
    parent_id = parent_id_by_name[sym[:parent_name]]
    insert_one(writer, fw_id, sym, parent_id)
  end
end
```

`insert_one` の第一引数は既存 `store` から `writer` (StoreWriter) に変更。 既存実装で `store.insert_symbol(...)` を呼んでる箇所を `writer.insert_symbol(...)` に置換。 `find_framework_id_by_name` 等の read 系は `store` を直接使うため、 `insert_one` に `store` reference をフィールドとして渡すか、 Pipeline インスタンス変数として保持する (このタスク内の判断は実装者に委ねる、 plain instance var が最小)。

- [ ] **Step 3: 既存テスト regression check**

Run: `cd knowledge && bundle exec rake test`
Expected: 全テスト green (含む `test_importer_pipeline_idempotence`)

- [ ] **Step 4: commit**

```bash
git add knowledge/lib/rb_apple_sdk_knowledge/importer.rb
git commit -m "refactor(knowledge/importer): route Pipeline#run through WorkerPool + StoreWriter"
```

---

### Task 10: Bit-identical integration test (S2 担保)

**Files:**
- Create: `knowledge/test/integration/test_pipeline_parallel_bit_identical.rb`
- Modify: `knowledge/Rakefile` (`integration` test task 追加)

注: フル framework set だと 75 分かかるので、 Task 8 の `filter:` option を使い小規模 subset で検証する。 default では skip (heavy)、 `APPLE_SDK_MAC_KB_INTEGRATION=1` のとき走る。

- [ ] **Step 1: integration test を書く**

```ruby
# knowledge/test/integration/test_pipeline_parallel_bit_identical.rb
# frozen_string_literal: true
require "test/unit"
require "tmpdir"
require "digest"
require "rb_apple_sdk_knowledge/importer"

class TestPipelineParallelBitIdentical < Test::Unit::TestCase
  FRAMEWORK_SUBSET = %w[CoreGraphics CoreFoundation].freeze

  def rebuild_with(workers:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: FRAMEWORK_SUBSET)
      ENV["APPLE_SDK_MAC_KB_WORKERS"] = workers.to_s
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

  def test_n1_n2_n4_produce_bit_identical_symbols
    omit "set APPLE_SDK_MAC_KB_INTEGRATION=1 to run" unless ENV["APPLE_SDK_MAC_KB_INTEGRATION"]
    n1 = rebuild_with(workers: 1)
    n2 = rebuild_with(workers: 2)
    n4 = rebuild_with(workers: 4)
    assert_equal n1, n2, "N=1 と N=2 で symbols が一致しない"
    assert_equal n1, n4, "N=1 と N=4 で symbols が一致しない"
  end
end
```

- [ ] **Step 2: Rakefile に integration task を追加 (`knowledge/Rakefile` の既存 `Rake::TestTask.new(:test)` ブロックの後)**

```ruby
Rake::TestTask.new(:integration) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/integration/test_*.rb"]
end
```

- [ ] **Step 3: integration test を実行 (KB rebuild 完了後の独立 verification)**

Run:
```bash
cd knowledge && APPLE_SDK_MAC_KB_INTEGRATION=1 bundle exec rake integration
```

Expected: 1 test, ≥2 assertions, 0 failures (3 サイズ ≈ N=1 と N=2 と N=4 の小規模 rebuild が 5 min 以内に完了し、 SHA256 が一致)

- [ ] **Step 4: commit**

```bash
git add knowledge/test/integration/test_pipeline_parallel_bit_identical.rb knowledge/Rakefile
git commit -m "test(knowledge/importer): verify N=1/2/4 bit-identical rebuild on subset"
```

---

### Task 11: Benchmark rake task (S1 計測手段)

**Files:**
- Modify: `knowledge/Rakefile`

- [ ] **Step 1: benchmark task 追加 (`knowledge/Rakefile` の `namespace :apple do` 内 `namespace :knowledge do` 内 既存 `:info` task の後)**

```ruby
desc "Benchmark rebuild with given scope and worker count"
task :benchmark_rebuild, [:scope, :workers] do |_, args|
  require "rb_apple_sdk_knowledge"
  scope = (args[:scope] || "single").to_sym
  workers = (args[:workers] || "2").to_i
  filter = case scope
           when :single then %w[CoreFoundation]
           when :ten then %w[Foundation CoreGraphics CoreFoundation AppKit AVFoundation Security CFNetwork CoreData CoreServices CoreText]
           when :full then nil
           else raise "unknown scope: #{scope}"
           end
  ENV["APPLE_SDK_MAC_KB_WORKERS"] = workers.to_s
  sdk_version = AppleSDKKnowledge::SDK.version
  base_dir = ENV["APPLE_SDK_MAC_KB_BASE_DIR"]
  path = AppleSDKKnowledge.knowledge_path(sdk_version: sdk_version, base_dir: base_dir)
  FileUtils.mkdir_p(File.dirname(path))
  resolver = AppleSDKKnowledge::Importer::SDKResolver.new(filter: filter)
  log_path = "tmp/longrun/benchmark-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{scope}-w#{workers}.log"
  FileUtils.mkdir_p(File.dirname(log_path))
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  AppleSDKKnowledge::Importer::Pipeline.new(store_path: path, resolver: resolver).run
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  File.write(log_path, "scope=#{scope} workers=#{workers} elapsed=#{elapsed.round(2)}s sdk=#{sdk_version}\n")
  puts "elapsed=#{elapsed.round(2)}s log=#{log_path}"
end
```

- [ ] **Step 2: smoke 実行 (scope=single なら 1 framework 30s 以内)**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac && APPLE_SDK_MAC_KB_BASE_DIR=$(pwd)/tmp/bench-kb bundle exec rake -f knowledge/Rakefile apple:knowledge:benchmark_rebuild[single,2]
```

Expected: 30s 以内に `elapsed=...` 行が出る、 `tmp/longrun/benchmark-*.log` が生成

- [ ] **Step 3: commit**

```bash
git add knowledge/Rakefile
git commit -m "feat(knowledge/rake): add apple:knowledge:benchmark_rebuild task"
```

---

### Task 12: README に ENV var surface を記述

**Files:**
- Modify: `knowledge/README.md`

- [ ] **Step 1: ENV var 一覧 section を追加 (`README.md` 末尾)**

```markdown
## Environment variables

| ENV var | Default | 用途 |
|---------|---------|------|
| `APPLE_SDK_MAC_KB_WORKERS` | `2` | rebuild 時の worker pool 並列度。 macOS の CPU core 数まで上げると 1/3 まで縮む見込み (Phase 2 target) |
| `APPLE_SDK_MAC_KB_BATCH_SIZE` | `1000` | StoreWriter の transaction batch size |
| `APPLE_SDK_MAC_KB_BASE_DIR` | (なし) | Knowledge Base SQLite の base dir。 親 gem の rake task 経由で設定される |
| `APPLE_SDK_MAC_KB_INTEGRATION` | (なし) | `1` で `rake integration` が bit-identical test を実行 (heavy、 default skip) |
```

- [ ] **Step 2: commit**

```bash
git add knowledge/README.md
git commit -m "docs(knowledge/readme): document tuning ENV vars"
```

---

### Task 13: Full rebuild benchmark で S1 / S4 verify

これは plan の **completion gate** で、 実装 task の連続ではなく end-to-end verification。 失敗したら spec の不変条件 / success criteria を見直して plan 修正へ戻る。

**Files:**
- なし (実行と観測のみ)

- [ ] **Step 1: longrun pattern で full rebuild benchmark を起動**

Run:
```bash
mkdir -p tmp/longrun
screen -dmS kb-bench-w2 bash -c '
  cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac
  APPLE_SDK_MAC_KB_BASE_DIR=$(pwd)/tmp/bench-kb-full APPLE_SDK_MAC_KB_WORKERS=2 \
    bundle exec rake -f knowledge/Rakefile apple:knowledge:benchmark_rebuild[full,2] \
    > tmp/longrun/kb-bench-w2.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/kb-bench-w2.log
'
```

- [ ] **Step 2: 完了待ち**

Run: `grep '^DONE:' tmp/longrun/kb-bench-w2.log` (40 min 以上経過してから check)
Expected: `DONE: exit=0`

- [ ] **Step 3: S1 verify (elapsed ≤ 40 min)**

Run: `grep 'elapsed=' tmp/longrun/kb-bench-w2.log`
Expected: `elapsed=` の秒数が **2400 以下** (40 min)。 越えてたら Task 8-9 で N=4 に上げて再計測 (Phase 2 着手判断は別 spec)。

- [ ] **Step 4: S4 verify (log 行数 ≤ 3000 行)**

Run: `wc -l tmp/longrun/kb-bench-w2.log`
Expected: 3000 行以下 (過去 14000 行から 1/5 以下)

- [ ] **Step 5: S2 verify (bit-identical)**

Task 10 の integration test を SDK 全体ではなく subset で別途実行:
```bash
cd knowledge && APPLE_SDK_MAC_KB_INTEGRATION=1 bundle exec rake integration
```
Expected: 1 test, 0 failures

- [ ] **Step 6: 完了報告 / Phase 2 移行判断**

S1-S4 すべて満たせば Phase 1 完了。 結果を `MEMORY.md` に project memory として記録 (elapsed / log 行数 / worker count)。 満たさない指標があれば spec section 11 の Phase 2 移行判断に進む。

---

## Self-review (plan 作成者用)

- **Spec coverage**: spec section 3 (success criteria) S1-S5 は Task 11/13 (S1)、 Task 10 (S2)、 Task 5 (S3)、 Task 13 (S4)、 Task 9 (S5) でカバー
- **Type consistency**: ResultChannel/WorkerPool/ProgressReporter/StoreWriter の method 名は全 task で揃えとる (`push/each_ordered/close`、 `submit/shutdown`、 `framework_started/header_done/framework_finished/finish`、 `begin!/insert_*/flush`)
- **Placeholders**: なし。 Task 9 の `two_pass_insert` 中 `insert_one` の引数置換は具体的指示で表現
- **Open dependencies**: `HeaderParser#parse_file(path)`、 `Store#insert_framework(name:, swift_module:)`、 `Store#insert_symbol(framework_id:, name:, kind:, abi:, content_hash:, ...)` は既存 API として確認済

## References

- Spec: `docs/superpowers/specs/2026-05-14-knowledge-base-rebuild-tuning-design.md`
- Longrun pattern: `docs/superpowers/specs/2026-05-05-longrun-pattern-design.md`
- 既存 Pipeline: `knowledge/lib/rb_apple_sdk_knowledge/importer.rb`
- 既存 Rakefile: `knowledge/Rakefile`
- MEMORY: `feedback_test_unit_assert_as_report`、 `feedback_hitl_gate_facts_only`、 `project_core_thesis_long_term_improvement`、 `feedback_no_kb_abbreviation`、 `cache_clear_via_rake_task`
