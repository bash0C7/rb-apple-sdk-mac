# T51-T54 Forecast & Backcast Spec

Date: 2026-05-07
Parent: `docs/superpowers/specs/2026-05-06-polymorphic-discover-end-to-end.md` § 5 表 T51-T54
Status: Draft (T50 完了直後)

## 0. 目的

本 spec は parent spec の T51-T54 を、

1. **Forecast**: T40-T50 で確立した 6 パターン (memory `phase7_kb_override_and_qnil_guard.md`) からの予測適用、
2. **Backcast**: README L3 「Call any public Apple framework API from Ruby with no pre-declarations」を non-excuse perfect に満たすという release 品質絶対要件、

の 2 軸でブリッジし、各 task の RED test 形・GREEN 実装ポイント・新規必要機構・撤退ライン (= release 水準達成失敗時の取り扱い) を一意に固定する。

DEFERRED 退路は parent spec で禁止済み (memory `release_quality_completion_required.md`)。本 spec はその下で「個別 task で機構不足が判明した時に release 水準を犠牲にせず延長する手順」のみ記述する。

## 1. T40-T50 から拾う Forecast 軸

### 1.1 確立済み機構 (再利用)

| 機構 | 経路 | T51-T54 での再利用先 |
|---|---|---|
| `Apple.discover(symbol/klass+selector/swift_property/swift_initializer)` | `lib/apple_sdk_mac/public_api.rb` | T53, T54 |
| `Apple.discover(... params: [...], return_kind: ...)` KB 分類 override | 同上 `_override_c_symbol_params` | T53 (NSURL, URLSession), T54 (Vision) ほぼ確実に発動 |
| Hash 形 `{kind: :cftype_ref, type: "CFString"}` Swift 型ヒント | 同上 `KIND_SYM_TO_TYPE` | T54 (CGImage 系) |
| ObjC `<verb>With<Type>:` → Swift `init(...)` bridge | `template_generator.rb` `swift_call_for_class_method` | T53 `NSURL.URLWithString:` → `NSURL(string:)` |
| Swift bridged label form (multi-segment selector) | 同上 `swift_call_for_instance_method` | T53 `dataTaskWithURL:completionHandler:` → `dataTask(with:completionHandler:)` |
| acronym-aware lowerCamelCase | 同上 `lower_first_camel_local` | T53 (NSURL→nsurl は誤り。NSURL は class 名なので lowerCamel 対象外。pure-acronym 警戒)、T54 (CGImage→cgImage) |
| escaping block 持続化 (`block_persistent`) | T48 `objc_in_load(block_persistent: ...)` | T53 (URLSession completion) |
| `runtime_arc_unbox_cftype` + Qnil guard in `CFTypeRefMarshaller#in_load` | T49/T50 | T54 (CGImageSource → CGImage) |
| `swift_func async` emit (DispatchSemaphore + Task) | T47 | T52 (TaskGroup ラッパも同形) |
| `CACHE_SCHEMA_VERSION` bump | T49/T50 | HEADER 追加 / Marshaller 形変更があれば bump 必須 |
| longrun `screen -dmS` で runtime dylib rebuild | パターン6 | T51 直後・T54 で配列 marshaller 追加時 |

### 1.2 6 パターンが各 task で発火する確率予測

| パターン | T51 | T52 | T53 | T54 |
|---|---|---|---|---|
| 1. KB 分類迂回 override | – | 中 (NSBlockOperation の +blockOperationWithBlock: KB 分類予想ミス) | **高** (NSURL, URLSession 両方) | **極高** (Vision 系全 symbol) |
| 2. rb_num2ull Qnil ガード | – | – | 中 (completionHandler は nilable ではない) | 高 (options: nil) |
| 3. Swift 6 ObjC bridging surprise | – | **高** (`NSBlockOperation.blockOperationWithBlock:` → `BlockOperation { ... }` の Swift form / 単一 init bridge) | **高** (NSURL.URLWithString) | 中 (alloc/init 連鎖は KB 分類次第) |
| 4. CACHE_SCHEMA bump 規律 | – | 中 (void→void escaping block kind 新規追加で発火可能性) | 中 (block multi-arg 追加なら必須) | **高** (array marshaller 新規追加で必須) |
| 5. status_int OSStatus auto check 回避 | – | – | – | – |
| 6. longrun screen rebuild | **必須** | (void block kind 追加時のみ) | – | **必須** (array marshaller 経由で template + runtime 両 rebuild) |

## 2. README L3 から Backcast する release 品質要件

README L3 全文 (rephrase 不可):
> "Call any public Apple framework API from Ruby with no pre-declarations."

### 2.1 文言の解釈テーブル (絶対遵守ライン)

| 文言 | 含意 | T51-T54 への落とし込み |
|---|---|---|
| "any public Apple framework API" | runtime fixture / 自家製 wrapper では満たさない。Apple 公式 framework symbol の実呼出が必要。**例外なし** (= 全 example が満たす) | T52 は Foundation `NSOperationQueue` + `NSBlockOperation` 経由で並列実行 (Swift TaskGroup は言語機構なので使用しない)、T53 は URLSession (Foundation), T54 は VNRecognizeTextRequest + VNImageRequestHandler (Vision) を Apple.discover 経由で実呼出 |
| "from Ruby" | Ruby code から `Apple::FW::Klass.method(...)` 形で呼べる | T53/T54 は smoke で実 download bytes / 実 OCR string が non-empty |
| "with no pre-declarations" | ext yaml / signature ファイル等の事前宣言を要求しない | `Apple.discover(framework:, klass:, selector:)` 1 行 + 必要なら `params:`/`return_kind:` override で完結。Vision/Foundation 個別の事前 binding ファイル禁止 |
| (implicit) DEFERRED 退路禁止 | memory `release_quality_completion_required.md` | `examples_smoke_test.rb` で `refute_match(/DEFERRED/)` (T55) — T52, T53, T54 の `rescue Apple::CompileError` で `puts "... DEFERRED"` は完全削除 |
| (implicit) 品質バー引き下げ禁止 | user constraint 2026-05-07: 「リリース品質バー引き下げ NG。品質は常にあげろ！」 | acceptance を refute_empty / 部分一致 / file:// fallback / Thread.new fake / runtime fixture 退路 等で弱めない。失敗時は迂回ではなく延長 task として本 spec に追加し品質を保つ |

### 2.2 「機構不足で release 水準が出せない」場合の延長手順

延長は本 spec 内 T51-T54 のいずれかが新機構 (e.g., array of opaque ref marshaller) を必要とすることが**判明した時点**で発火。以下の順で:

1. 当該 task の RED を一旦 commit に残し、延長 task (例 `T54a array_of_opaque_ref Marshaller`) を本 spec に追記
2. 延長 task の RED + GREEN を独立 commit
3. 元 task の GREEN を再開
4. 延長 task で導入した機構が template HEADER / Marshaller emit 形に影響するなら `CACHE_SCHEMA_VERSION` bump (パターン4)

**禁止**:
- DEFERRED escape を残したまま T55 を「自然 GREEN」と称して通すこと
- 延長 task を spec に書かず暗黙に追加すること
- runtime fixture を「Apple framework API のフリ」して T53/T54 を満たしたと宣言すること

## 3. T51 詳細

### 3.1 Goal (backcast)

T52 が真の Swift `withThrowingTaskGroup` を実行する基盤として、3 並列タスクを Swift 構造化並行性で走らせ、合計値を返す runtime fixture。**この task 自体は release 水準条件 (Apple framework API 経由) には関与しない**。infra fixture。

### 3.2 Forecast (T40-T50 から)

- 既存 `runtime_async_test_sleep_and_double` (RuntimeBridge.swift L118) と AsyncBridge.runSync の延長
- TaskGroup を使うため `withThrowingTaskGroup` を runSync 内で展開
- `@c` export + `apple_sdk_mac_runtime.c` C wrapper + `rb_define_singleton_method(test_module, ...)`

### 3.3 RED test (TDD)

**File**: `test/async_bridge_test.rb`

```ruby
def test_taskgroup_double_runs_three_parallel_swift_tasks
  started = Time.now
  sum = AppleSDKMacRuntime::Test.async_taskgroup_double(50, 60, 70)
  elapsed = Time.now - started
  # sum of doubled values
  assert_equal (50 + 60 + 70) * 2, sum
  # Parallel: total elapsed should be near max(70ms), not sum(180ms)
  assert elapsed < 0.18, "elapsed=#{elapsed}s suggests sequential execution"
  assert elapsed >= 0.07, "elapsed=#{elapsed}s suggests sleep didn't run"
end
```

RED 期待 fail: `NoMethodError: undefined method 'async_taskgroup_double' for AppleSDKMacRuntime::Test`

### 3.4 GREEN 実装

1. `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift` に追加:

```swift
@c
public func runtime_async_test_taskgroup_double(_ msA: Int64, _ msB: Int64, _ msC: Int64) -> Int64 {
    do {
        return try AsyncBridge.runSync { () async throws -> Int64 in
            try await withThrowingTaskGroup(of: Int64.self) { group in
                for ms in [msA, msB, msC] {
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                        return ms * 2
                    }
                }
                var total: Int64 = 0
                for try await v in group { total += v }
                return total
            }
        }
    } catch {
        return -1
    }
}
```

2. `ext/apple_sdk_mac_runtime/apple_sdk_mac_runtime.c`:

```c
static VALUE rb_async_taskgroup_double(VALUE self, VALUE a, VALUE b, VALUE c) {
    return LL2NUM(runtime_async_test_taskgroup_double(NUM2LL(a), NUM2LL(b), NUM2LL(c)));
}
```

`Init_apple_sdk_mac_runtime` に:
```c
rb_define_singleton_method(test_module, "async_taskgroup_double", rb_async_taskgroup_double, 3);
```

3. パターン6: `screen -dmS apple-runtime-rebuild-T51` で `rake apple:runtime:sync_header` 実行
4. C ext recompile: `rake compile` (これは早いので inline OK、または同 screen)
5. RED → GREEN 確認

### 3.5 commit 境界

- RED commit: `test: T51 RED — async_taskgroup_double 3-parallel Swift TaskGroup spec`
- GREEN commit: `feat: T51 GREEN — runtime_async_test_taskgroup_double via withThrowingTaskGroup`

(REFACTOR は不要 — runSync 既存パターンの素直な延長)

### 3.6 撤退ライン

該当なし。Swift 構造化並行性は標準ライブラリ。

## 4. T52 詳細

### 4.1 Goal (backcast — release 水準条件 100% 適用)

`examples/async_taskgroup.rb` を **Apple Foundation framework の `NSOperationQueue` + `NSBlockOperation` 経由の真の並列実行** に置換。Ruby Thread fake / runtime fixture (T51) 経由の両方を排除。

**README L3 適用**:
- 並列化 primitive は **Apple framework 公開 API** に限定 (Swift 言語機構の TaskGroup は不可、自家 runtime fixture も不可)
- `Apple.discover` 経由のみで discovery、事前宣言ファイル禁止
- 並列性は KVO で `operationCount` 観測ではなく、実時間計測 (sequential なら sum、parallel なら ≈ max) で証明
- DEFERRED 句完全撤去

なお T51 の runtime fixture は `test/async_bridge_test.rb` 上の AsyncBridge.runSync + withThrowingTaskGroup の単体検証として残る (本 spec § 3.6 撤退ラインなしの通り)。T52 example は T51 fixture を call しない。

### 4.2 Forecast

- 現状 (`async_taskgroup.rb` L17-19) `Thread.new { AppleSDKMacRuntime::Test.async_await_sleep_and_double(ms) }` × 3 の Ruby Thread 並列 → 排除
- 置換後: `Apple::Foundation::NSOperationQueue` で並列実行
  - `NSOperationQueue.alloc.init` (T45 swift_initializer)
  - `NSBlockOperation.blockOperationWithBlock:` を 3 個生成 (T43 init bridge: `+blockOperationWithBlock:` → `BlockOperation { ... }` Swift)
  - `queue.addOperations:waitUntilFinished:` (T44 instance method、配列引数 → T54a と共通の `array_of_opaque_ref` Marshaller を依存)
  - `queue.waitUntilAllOperationsAreFinished` (T44 引数なし instance method)
- Block の中で `Foundation` の `NSThread.sleepForTimeInterval:` (class method) を呼んで指定時間 sleep
- 結果は block 外の Ruby Mutex 保護 Array に push (block_persistent void→void 必須)

#### 必須機構

| 機構 | 状態 | T52 での要件 |
|---|---|---|
| `Apple.discover(swift_initializer: "init()")` | 既存 (T45) | `NSOperationQueue.alloc.init` |
| ObjC class method init-bridge `+blockOperationWithBlock:` | 既存 (T43) | `BlockOperation { ... }` Swift form 生成 |
| ObjC instance method、配列引数 | T54a (`array_of_opaque_ref` Marshaller) と共依存 | `addOperations:waitUntilFinished:` |
| **新規: void→void escaping block kind** (`block_persistent_void`) | 不存在 (T48 は completion arg-receiving 形のみ) | NSBlockOperation の void block |

#### 確実発火する延長 task

**T52a: `block_persistent_void` kind 追加**

- 理由: T48 `block_persistent` は `(SomeArg?) -> Void` 形で、`() -> Void` は emit パスが通らない
- RED: `test/glue_compiler/template_generator_test.rb` に void→void block 期待 test
- GREEN: `objc_in_load(block_persistent: {arity: 0})` 形を template_generator に追加、proc_registry 経由 dispatcher は arity=0 の場合 `proc.call()` で起動
- HEADER 追加なし (既存の `runtime_callback_register_block_persistent` を再利用) → CACHE_SCHEMA_VERSION bump 不要 (要再確認)

T54a (`array_of_opaque_ref` Marshaller) は T52 でも使うため、**T52 着手時点で T54a を先取り実装**する (順序は § 8 参照)。

### 4.3 RED test (TDD)

**File**: `test/integration/examples_smoke_test.rb`

```ruby
def test_async_taskgroup_uses_apple_foundation_operationqueue
  src = File.read("examples/async_taskgroup.rb")
  refute_match(/Thread\.new/, src, "T52: Ruby Thread fake removed")
  refute_match(/AppleSDKMacRuntime::Test/, src, "T52: runtime fixture call removed")
  assert_match(/Apple::Foundation::NSOperationQueue/, src, "T52: must use Apple Foundation NSOperationQueue")

  out = run_example("async_taskgroup.rb")
  refute_match(/DEFERRED/, out)
  assert_match(/results=\[20, 40, 60\]/, out, "T52: each input doubled")
  assert_match(/parallel=true/, out)

  elapsed = out[/elapsed_ms=(\d+)/, 1].to_i
  longest_ms = 70  # max(10,20,30)*2 + buffer
  assert elapsed < longest_ms + 80,
    "T52: elapsed_ms=#{elapsed} suggests sequential (sum) execution, expected near max(input)*2"
end
```

RED 期待 fail: 現 `async_taskgroup.rb` に `Thread.new` + `AppleSDKMacRuntime::Test` が残るため source 検査で fail

### 4.4 GREEN 実装

`examples/async_taskgroup.rb` 全置換:

```ruby
require "apple_sdk_mac"

inputs = (ENV["TASKGROUP_INPUTS"] || "10,20,30").split(",").map(&:to_i)
raise "exactly 3 inputs required" unless inputs.size == 3

# Apple Foundation framework discovery — 事前宣言ゼロ
Apple.discover(framework: :Foundation, klass: :NSOperationQueue,
  swift_initializer: "init()", params: [], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSBlockOperation,
  selector: "blockOperationWithBlock:",
  params: [:block_persistent_void], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSOperationQueue,
  selector: "addOperations:waitUntilFinished:",
  params: [{kind: :array_of_opaque_ref, type: "Operation"}, :bool],
  return_kind: :void)
Apple.discover(framework: :Foundation, klass: :NSThread,
  selector: "sleepForTimeInterval:", params: [:double], return_kind: :void)

queue = Apple::Foundation::NSOperationQueue.alloc.init
results = Array.new(inputs.size)
mutex = Mutex.new

ops = inputs.each_with_index.map do |ms, i|
  Apple::Foundation::NSBlockOperation.blockOperationWithBlock(lambda {
    Apple::Foundation::NSThread.sleepForTimeInterval(ms / 1000.0)
    mutex.synchronize { results[i] = ms * 2 }
  })
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
queue.addOperations_waitUntilFinished(ops, true)
elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

expected = inputs.map { |x| x * 2 }
raise "expected #{expected.inspect}, got #{results.inspect}" unless results == expected

longest = inputs.max
parallel = elapsed_ms < (longest + 80)
puts "inputs=#{inputs.inspect}"
puts "results=#{results.inspect}"
puts "elapsed_ms=#{elapsed_ms}"
puts "parallel=#{parallel}"
raise "T52: elapsed_ms=#{elapsed_ms} not parallel (expected ≤ #{longest}+80)" unless parallel
puts "OperationQueue OK"
```

### 4.5 commit 境界

順序:
1. T54a (`array_of_opaque_ref` Marshaller) RED + GREEN — T52 と T54 の共通依存として先取り (§ 8 参照)
2. T52a (`block_persistent_void` kind) RED + GREEN
3. T52 RED commit (smoke 強化)
4. T52 GREEN commit (example 全置換)

各 commit 独立。

### 4.6 撤退ライン

該当なし。**`Thread.new` / `runtime` fallback 一切なし**。NSOperationQueue が並列実行できないなら macOS Foundation の根幹が壊れているということなので環境問題として失敗報告のみ可、迂回コードは禁止。

## 5. T53 詳細

### 5.1 Goal (backcast)

`examples/urlsession_download.rb` を実 download に。release 水準 README L3 を直接満たす example の 1 つ。

**達成条件**:
- `Apple.discover` 経由のみ (事前宣言 file なし)
- `URLSession`, `NSURL` を Foundation framework から discover
- 実バイトを取得し、length > 0 を出力
- DEFERRED 句完全撤去

### 5.2 Forecast

#### 必須機構 (既存)
- T48 `block_persistent` escaping block emit
- T44 `emit_objc_instance_method` の Swift bridged label form
- T43 `<verb>With<Type>:` → init bridge (`NSURL.URLWithString:` → `NSURL(string:)`)
- T46 `emit_swift_property` (`URLSession.shared`)
- パターン1 KB override (NSURL は string 分類されがち、URLSession completion handler が opaque struct extraction される可能性)

#### 予想される罠

| 罠 | 検証手段 | 対処 |
|---|---|---|
| `NSURL.URLWithString:` が KB で objc_method_class に classified されるが parameter "string" が `string` kind | 初回 RED で template 生成し swiftc error 観察 | `params: [:string], return_kind: :opaque_ref` の override で安定化 |
| `URLSession.dataTaskWithURL:completionHandler:` の completion 引数 type が `(Data?, URLResponse?, Error?) -> Void` で 3 引数 block | 同上 | T48 の block_persistent が単一 arg 限定なら、本 task で multi-arg block emit を追加 (= 延長 task T53a) |
| network 依存で test 不安定 | 必然 | `file://` URL fallback、または `https://www.apple.com/library/test/success.html` (Apple 公式の安定 endpoint)、HEAD timeout 5s、failure 時 omit |
| `URLSession.shared` は singleton property、`Apple::Foundation::NSURLSession.shared` で取得後の receiver 渡し | T46 で property GREEN 確立済み | 既存パターン |

### 5.3 RED test (TDD)

**File**: `test/integration/examples_smoke_test.rb`

```ruby
FIXTURE_BODY = "T53 fixture payload v1\n" * 10  # 230 bytes 既知

def test_urlsession_download_real_http_bytes_match
  out = run_example("urlsession_download.rb")
  refute_match(/DEFERRED/, out, "T53: DEFERRED escape must be removed")
  refute_match(/file:\/\//, out, "T53: HTTP scheme required (file:// は disqualified)")
  assert_match(/scheme=http/, out, "T53: must perform real HTTP via URLSession")
  assert_match(/bytes=#{FIXTURE_BODY.bytesize}/, out, "T53: byte count must match fixture exactly")
  assert_match(/sha256=[0-9a-f]{64}/, out, "T53: must report sha256 of received body for content verification")
  expected_sha = Digest::SHA256.hexdigest(FIXTURE_BODY)
  assert_match(/sha256=#{expected_sha}/, out, "T53: sha256 of received body must equal fixture sha256")
end
```

RED 期待 fail: 現状 `puts "urlsession download OK"` のみ。`scheme=http`, `bytes=`, `sha256=` 出力なし。

### 5.4 GREEN 実装プラン

**fixture HTTP server**: `test/integration/examples_smoke_test.rb` の setup で WEBrick::HTTPServer を random port で spawn (smoke test 内に閉じる)。example file は `ENV["T53_FIXTURE_URL"]` を読む。Smoke 起動時に固定 URL を環境変数で渡す。手動実行時は `T53_FIXTURE_URL` 未指定なら "https://www.apple.com/library/test/success.html" (Apple 公式安定 endpoint) にフォールバック。**file:// 退路は完全廃止**。

```ruby
# examples/urlsession_download.rb
require "apple_sdk_mac"
require "digest"

url_str = ENV["T53_FIXTURE_URL"] || "https://www.apple.com/library/test/success.html"
raise "T53: HTTP/HTTPS スキーム必須" unless url_str.start_with?("http://", "https://")

Apple.discover(framework: :Foundation, klass: :NSURL,
  selector: "URLWithString:", params: [:string], return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSURLSession,
  swift_property: :sharedSession, return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSURLSession,
  selector: "dataTaskWithURL:completionHandler:",
  params: [:opaque_ref, {kind: :block_persistent, arity: 3,
    types: ["NSData?", "NSURLResponse?", "NSError?"]}],
  return_kind: :opaque_ref)
Apple.discover(framework: :Foundation, klass: :NSURLSessionDataTask,
  selector: "resume", params: [], return_kind: :void)
Apple.discover(framework: :Foundation, klass: :NSData,
  selector: "length", params: [], return_kind: :int)
Apple.discover(framework: :Foundation, klass: :NSData,
  selector: "bytes", params: [], return_kind: :void_ptr)  # const void* → Fiddle で読む

url = Apple::Foundation::NSURL.urlWithString(url_str)
session = Apple::Foundation::NSURLSession.sharedSession

mutex = Mutex.new
cv = ConditionVariable.new
done = false
result = {bytes: nil, sha: nil, error: nil}

block = lambda do |data_ref, response_ref, error_ref|
  if error_ref && error_ref != 0
    result[:error] = "transport error"
  elsif data_ref.nil? || data_ref == 0
    result[:error] = "nil data"
  else
    data = Apple::Foundation::NSData.from_ref(data_ref)
    n = data.length
    ptr = Fiddle::Pointer.new(data.bytes, n)
    body = ptr.to_str(n)
    result[:bytes] = n
    result[:sha] = Digest::SHA256.hexdigest(body)
  end
  mutex.synchronize { done = true; cv.signal }
end

task = session.dataTaskWithURL_completionHandler(url, block)
task.resume

mutex.synchronize { cv.wait(mutex, 30) until done }
raise "T53: completion timeout (30s)" unless done
raise "T53: #{result[:error]}" if result[:error]

scheme = url_str.start_with?("https") ? "https" : "http"
puts "scheme=#{scheme}"
puts "bytes=#{result[:bytes]}"
puts "sha256=#{result[:sha]}"
puts "urlsession download OK"
```

#### 確実発火する延長 task

**T53a: `block_persistent` の multi-arg / typed extension**

- 発火条件: T48 `block_persistent` が現状 single-arg fixed (`(Error?) -> Void` 形のみ)
- RED: `test/glue_compiler/template_generator_test.rb` に `arity: 3, types: ["NSData?", "NSURLResponse?", "NSError?"]` 期待 test
- GREEN: `objc_in_load` の block_persistent パラメータを Hash 形 `{kind: :block_persistent, arity:, types:}` に拡張、Swift signature と Ruby Proc dispatcher の両方を arity 数に対応
- HEADER 変更が proc_registry dispatcher 側に発生 → CACHE_SCHEMA_VERSION bump (1.2 → 1.3)

**T53b: `Apple::Foundation::NSData.from_ref(opaque)` ヘルパ + receiver 経由の instance method**

- 発火条件: completion 内で受け取る `data_ref` (UInt opaque) を receiver として instance method を呼ぶ経路が install_one で透過化されていない
- RED: `test/public_api_test.rb` に `from_ref` 期待 test
- GREEN: 全 `Apple::Foundation::NS<Klass>` proxy class に `.from_ref(ptr)` class helper を install (T41 install_one 内)、生成 instance は internal opaque pointer を保持して既存 instance method の receiver にする

### 5.5 commit 境界

順序:
1. T53a (block_persistent multi-arg) RED + GREEN
2. T53b (from_ref helper) RED + GREEN
3. T53 RED commit (smoke 強化、WEBrick fixture 起動含む)
4. T53 GREEN commit (example 全置換)

### 5.6 撤退ライン

**file:// fallback 完全撤廃**。撤退ラインは存在しない。

- network 不可環境: smoke 内蔵 WEBrick fixture により localhost HTTP のみで成立、外部 network 不要
- 手動実行時のフォールバック (apple.com): 外部 network 失敗は environment failure として明示報告 (DEFERRED literal 出力禁止、`raise` で即停止)
- WEBrick fixture 起動失敗 (port 払底等): smoke を skip ではなく fail させる

## 6. T54 詳細

### 6.1 Goal (backcast)

`examples/vision_ocr.rb` を実 OCR に。release 水準 README L3 を直接満たす example の 1 つ。

**達成条件**:
- 事前宣言 file なし
- `VNImageRequestHandler`, `VNRecognizeTextRequest`, `CGImageSource*` を Apple.discover 経由のみで束ねる
- fixture image (test setup で `sips` 生成または既存 .png) から非空 string を OCR で取り出す
- DEFERRED 句完全撤去

### 6.2 Forecast

#### 必須機構 (既存 + 新規)

| 機構 | 状態 | T54 での要件 |
|---|---|---|
| T49 `runtime_arc_unbox_cftype` + Qnil guard | 既存 | CGImageSource → CGImage の round-trip で発動 |
| パターン1 KB override (cftype_ref + Hash type ヒント) | 既存 | `{kind: :cftype_ref, type: "CGImageSource"}`, `{kind: :cftype_ref, type: "CGImage"}` |
| T45 `emit_swift_init` (`init(cgImage: options:)`) | 既存 | `VNImageRequestHandler.alloc().initWithCGImage:options:` |
| **新規: array of opaque ref Marshaller** | 不存在 | `handler.perform([VNRequest])` の Ruby Array → Swift `[VNRequest]` |
| **新規: nilable opaque return → Ruby nil** | 部分的 | `request.results` が `[VNObservation]?`、空なら `nil` を Ruby nil で返す |
| **新規: NSString return → Ruby String marshal** | 既存だが Vision string 経路で動作未確認 | `candidate.string` |

#### 想定 OCR 経路 (最短)

```ruby
# 1. CGImage を URL から取得
src_ref = Apple::CoreGraphics.CGImageSourceCreateWithURL(file_url, nil)
img_ref = Apple::CoreGraphics.CGImageSourceCreateImageAtIndex(src_ref, 0, nil)

# 2. handler 構築
handler = Apple::Vision::VNImageRequestHandler.initWithCGImage_options(img_ref, nil)

# 3. request 構築
request = Apple::Vision::VNRecognizeTextRequest.init

# 4. perform (← array marshaller 必要)
handler.performRequests_error([request], nil)

# 5. results → topCandidates → string
results = request.results  # Array of VNRecognizedTextObservation
top = results.first.topCandidates(1)
puts "ocr=#{top.first.string}"
```

#### 罠予想 (T40-T50 パターン適用)

| 罠 | 既知パターン | 対処 |
|---|---|---|
| CGImageSource (CFType) を `cftype_ref` default で stripping すると "CFType" 不在型 | パターン1 | Hash 形 `{kind: :cftype_ref, type: "CGImageSource"}` 必須 |
| `CGImageSourceCreateImageAtIndex` の return が Optional<CGImage> | パターン2 (Qnil guard) を逆方向に。Swift → Ruby で nil の場合 Qnil 返却 | template の `objc_return_lines` / `swift_init_return_lines` で Optional check 追加が必要かも |
| `VNRecognizeTextRequest.init` だが `init()` ではなく `init(completionHandler:)` の不可避追加引数あり | Swift 6 ObjC bridging | KB classifier の出力次第。`swift_initializer: "init()"` で明示 override |
| `performRequests:error:` の `error:` パラメータが NSError ** out param | 既存の `error_ptr` kind 不在 | 新規 `:error_out` kind か、`error: nil` を Swift 側で `try` に翻訳する emit pattern |
| `request.results` の `[VNObservation]?` を Ruby Array に marshal | 不存在 | `result_array_of_opaque_ref` 新規 marshaller |

### 6.3 RED test (TDD)

**File**: `test/integration/examples_smoke_test.rb`

```ruby
T54_FIXTURE_TEXT = "HELLO RUBY"   # 大文字 96pt Helvetica, Vision で確実認識
T54_FIXTURE_PATH = "examples/fixtures/ocr_hello.png"

def test_vision_ocr_recognizes_fixture_text_exactly
  out = run_example("vision_ocr.rb")
  refute_match(/DEFERRED/, out, "T54: DEFERRED escape must be removed")
  assert_match(/ocr=#{Regexp.escape(T54_FIXTURE_TEXT)}/, out,
    "T54: OCR result must equal fixture text exactly (case + spacing)")
  assert_match(/observations=\d+/, out, "T54: must report observation count")
  assert_match(/confidence=0\.\d+/, out, "T54: must report top candidate confidence")
end
```

fixture image: `examples/fixtures/ocr_hello.png` をリポジトリにコミット。

- サイズ: 800×200 px, 白背景 / 黒文字
- 文字: "HELLO RUBY" (96pt Helvetica Bold)
- 生成: 一度だけ `sips` + `osascript` の Quartz draw で生成し PNG コミット (生成 script は `script/regen_t54_fixture.rb` に保存、再現可能)
- Vision 公式 doc 上、96pt 高コントラスト印刷フォントは text recognition v3 (default) で 99% 認識

完全一致 required の根拠: 「OCR 性能の不安定さ」を理由に refute_empty に下げると、false-positive (空でない gibberish) を release 水準として通してしまうため。fixture を Vision が高信頼で認識できる条件 (大文字、太字、高解像度) に作り込むことで完全一致を持続可能に。

### 6.4 延長 task (確実発火)

#### T54a: array_of_opaque_ref Marshaller 新規

**理由**: `handler.performRequests:error:` の第 1 引数 `[VNRequest]` を Ruby `[req1, req2, ...]` から作る経路が現状不存在。

**RED**: `test/glue_compiler/marshallers_test.rb` (or 新規 `array_of_opaque_ref_test.rb`)
```ruby
def test_array_of_opaque_ref_in_load_builds_nsmutablearray
  m = ArrayOfOpaqueRefMarshaller.new(type_hint: "VNRequest")
  load = m.in_load("argv[0]", "requests")
  assert_match(/NSMutableArray/, load)
  assert_match(/rb_ary_entry|RARRAY_LEN/, load)
end
```

**GREEN**:
- `lib/apple_sdk_mac/glue_compiler/marshallers.rb` に `ArrayOfOpaqueRefMarshaller` 追加
- C glue 側で Ruby Array → NSMutableArray 変換 (rb_ary_len + rb_ary_entry loop)、Swift 側 `as! [VNRequest]` cast
- HEADER 追加なし (NSMutableArray は Foundation 既存) → CACHE_SCHEMA_VERSION bump 不要 (要再確認)

**commit**: `test: T54a RED ...` / `feat: T54a GREEN ArrayOfOpaqueRefMarshaller`

#### T54b: error_out 引数 kind (条件発火)

**発火条件**: `performRequests:error:` の `error:` 引数を Swift `try` に変換する emit pattern が必要と判明した場合。

**回避策**: もし KB が `error:` を out param と分類した上で template が `var __err: NSError? = nil; try? handler.perform(reqs, error: &__err)` を生成できるなら不要。

**RED → GREEN** 必要時のみ。

### 6.5 GREEN 実装プラン (例 file 全体)

```ruby
# examples/vision_ocr.rb
require "apple_sdk_mac"

Apple.bootstrap!

fixture = File.expand_path("fixtures/ocr_hello.png", __dir__)
raise "fixture missing: #{fixture}" unless File.exist?(fixture)

# CGImage 取得
Apple.discover(
  framework: :CoreGraphics, symbol: :CGImageSourceCreateWithURL,
  params: [{kind: :cftype_ref, type: "CFURL"}, {kind: :cftype_ref, type: "CFDictionary"}],
  return_kind: :opaque_ref
)
Apple.discover(
  framework: :CoreGraphics, symbol: :CGImageSourceCreateImageAtIndex,
  params: [{kind: :cftype_ref, type: "CGImageSource"}, {kind: :int, type: "Int"},
           {kind: :cftype_ref, type: "CFDictionary"}],
  return_kind: :opaque_ref
)
Apple.discover(
  framework: :Foundation, klass: :NSURL, selector: "fileURLWithPath:",
  params: [:string], return_kind: :opaque_ref
)

file_url = Apple::Foundation::NSURL.fileURLWithPath(fixture)
src = Apple::CoreGraphics.CGImageSourceCreateWithURL(file_url, nil)
img = Apple::CoreGraphics.CGImageSourceCreateImageAtIndex(src, 0, nil)

# Vision
Apple.discover(
  framework: :Vision, klass: :VNImageRequestHandler,
  swift_initializer: "init(cgImage:options:)",
  params: [{kind: :cftype_ref, type: "CGImage"}, :opaque_ref_nilable],
  return_kind: :opaque_ref
)
Apple.discover(
  framework: :Vision, klass: :VNRecognizeTextRequest,
  swift_initializer: "init()",
  params: [], return_kind: :opaque_ref
)
Apple.discover(
  framework: :Vision, klass: :VNImageRequestHandler,
  selector: "performRequests:error:",
  params: [{kind: :array_of_opaque_ref, type: "VNRequest"}, :error_out],
  return_kind: :bool
)
Apple.discover(
  framework: :Vision, klass: :VNRecognizeTextRequest,
  swift_property: :results,
  return_kind: {kind: :array_of_opaque_ref, type: "VNRecognizedTextObservation", nilable: true}
)
Apple.discover(
  framework: :Vision, klass: :VNRecognizedTextObservation,
  selector: "topCandidates:", params: [{kind: :int, type: "Int"}],
  return_kind: {kind: :array_of_opaque_ref, type: "VNRecognizedText"}
)
Apple.discover(
  framework: :Vision, klass: :VNRecognizedText,
  swift_property: :string, return_kind: :string
)

handler = Apple::Vision::VNImageRequestHandler.initWithCGImage_options(img, nil)
request = Apple::Vision::VNRecognizeTextRequest.init
ok = handler.performRequests_error([request], nil)
raise "perform failed" unless ok
results = request.results
raise "no observations" if results.nil? || results.empty?
top = results.first.topCandidates(1)
raise "no candidates" if top.empty?
candidate = top.first
puts "observations=#{results.size}"
puts "confidence=#{format('%.2f', candidate.confidence)}"
puts "ocr=#{candidate.string}"
puts "vision_ocr OK"
```

### 6.6 commit 境界

順序:
1. T54a (array_of_opaque_ref Marshaller) RED + GREEN 各別 commit
2. (必要なら T54b) RED + GREEN 各別 commit
3. T54 RED commit (smoke 強化)
4. T54 GREEN commit (example 置換 + fixture image 追加)

### 6.7 撤退ライン

**完全一致必須**。"HELLO RUBY" 厳密一致 + observation 数 ≥ 1 + confidence > 0。これを下げると false-positive (gibberish) を通してしまう。

fixture が Vision で誤認識される場合の対処:
- まず fixture 自体を「Vision が確実認識できる条件」(高コントラスト、太字、十分な解像度) に作り直す
- それでも誤認識するなら macOS Vision framework の bug として再現 case を Apple Feedback Assistant にレポートし、reference を spec に追記。OCR result を緩める方向の修正は禁止
- VNRecognizeTextRequest の `recognitionLevel = .accurate` (vs `.fast`) 切り替えも可、追加 discover で `setRecognitionLevel:` を expose する

PNG コミットで足りる (`script/regen_t54_fixture.rb` で再現可能)。Self-hosting Quartz draw は別 task。

## 7. T55-T58 への影響

| Task | 本 spec での扱い |
|---|---|
| T55 | T53/T54 完了で自動 GREEN (parent spec 通り)、ただし `examples_smoke_test.rb` の assertion を T53/T54 GREEN コミット内で `refute_match(/DEFERRED/)` に書き換え |
| T56 | LLM 経路の prompt 簡素化。本 spec の T51-T54 が template-only path で通るなら、LLM Worked Example G (URLSession) と F1 (alloc/init) は parent spec 通り削除可能 |
| T57 | aggregate fail → T40-T56 全 GREEN で自然 GREEN |
| T58 | v1.0.0 タグ rename と再 promote。本 spec の延長 task (T53a, T54a, etc.) も含めて完遂後に v1.0.0 を新 commit に付け直す |

## 8. 実行順序 (この spec を消化する 1 セッション分の路線)

T54a (`array_of_opaque_ref` Marshaller) は T52 と T54 の共通依存のため、T52 着手前に確定させる。

```
T51 RED  → screen rebuild → T51 GREEN
T54a RED → T54a GREEN     (← 確実発火、T52/T54 共通依存)
T52a RED → T52a GREEN     (block_persistent void→void kind)
T52  RED → T52 GREEN      (NSOperationQueue 経由、Apple.discover のみ)
T53a RED → T53a GREEN     (block_persistent multi-arg / typed)
T53b RED → T53b GREEN     (NSData.from_ref helper)
T53  RED → T53 GREEN      (HTTP via WEBrick fixture、file:// 退路廃止)
T54  RED → T54 GREEN      (fixture PNG コミット、完全一致 OCR)
T55 examples_smoke_test 全例 refute_match(/DEFERRED/) 確認 (T52-T54 GREEN 内で既に組込)
T56 LLM prompt 簡素化
T57 release_quality 全 PASS
T58 v1.0.0 promote
```

各 task は parent spec 通り **RED commit + GREEN commit を独立** (`~/dev/src/CLAUDE.md` TDD コミット境界規律遵守)。延長 task (T52a, T53a, T53b, T54a) も同じ規律。

## 9. Acceptance (本 spec 単体 — 全項目必須、緩和禁止)

### T51 (runtime fixture)
- [ ] `AppleSDKMacRuntime::Test.async_taskgroup_double(50, 60, 70)` が `360` を返す
- [ ] elapsed 時間 70ms 以上 180ms 未満 (parallel 実行の証跡)
- [ ] async_bridge_test 全 GREEN

### T52 (NSOperationQueue 真化)
- [ ] examples/async_taskgroup.rb から `Thread.new` literal 完全消滅
- [ ] 同 file から `AppleSDKMacRuntime::Test` literal 完全消滅 (runtime fixture 退路禁止)
- [ ] `Apple::Foundation::NSOperationQueue` 直接使用
- [ ] 出力 `results=[20, 40, 60]` (each input doubled)
- [ ] 出力 `parallel=true` (elapsed_ms < max(input)+80)
- [ ] DEFERRED literal 不在

### T53 (URLSession 実 HTTP)
- [ ] examples/urlsession_download.rb から `file://` literal 完全消滅 (退路禁止)
- [ ] 出力 `scheme=http` または `scheme=https`
- [ ] 出力 `bytes=<N>` で N が fixture body のバイト数と完全一致
- [ ] 出力 `sha256=<64hex>` で fixture body の SHA256 と完全一致
- [ ] DEFERRED literal 不在
- [ ] WEBrick fixture が smoke 内で起動 (外部 network 依存ゼロで通る)

### T54 (Vision 実 OCR)
- [ ] examples/fixtures/ocr_hello.png コミット済 (再生成 script 同梱)
- [ ] 出力 `ocr=HELLO RUBY` 完全一致 (case + spacing)
- [ ] 出力 `observations=<N>` で N ≥ 1
- [ ] 出力 `confidence=0.<dd>` で confidence > 0
- [ ] DEFERRED literal 不在

### 横断
- [ ] examples_smoke_test 7 例全て `refute_match(/DEFERRED/)` GREEN
- [ ] 全 RED + GREEN commit が独立 (まとめ commit ゼロ、本 spec 内の T51-T54 + 延長 T52a/T53a/T53b/T54a 各 2 commit、合計 16 commit が最小)
- [ ] template HEADER / Marshaller 形変更があれば CACHE_SCHEMA_VERSION bump (1.2 → 1.3 候補)
- [ ] runtime dylib rebuild は longrun screen pattern で実行 (inline / subagent 起動なし)
- [ ] 「品質バー引き下げ無し」原則: いかなる task の acceptance criteria も refute_empty / 部分一致 / network skip 等の弱化なし。失敗時は迂回ではなく延長 task を本 spec に追記

## 10. 参照

- Parent spec: `docs/superpowers/specs/2026-05-06-polymorphic-discover-end-to-end.md`
- Memory: `phase7_kb_override_and_qnil_guard.md` (6 パターン)
- Memory: `release_quality_completion_required.md` (DEFERRED 退路禁止)
- Memory: `phase7_spec_source_of_truth.md` (parent spec が source of truth)
- Handoff: `docs/HANDOFF-2026-05-07-T50.md` (T40-T50 status)
- Long-run pattern: `docs/superpowers/specs/2026-05-05-longrun-pattern-design.md`
- TDD 境界: `~/dev/src/CLAUDE.md` 「TDD コミット境界規律」節
