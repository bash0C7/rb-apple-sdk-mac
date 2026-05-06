# Polymorphic discover end-to-end — README release-quality completion

Date: 2026-05-06
Status: written-spec — pending implementation in next session
Supersedes: §3.2 章 of `2026-05-06-complete-mac-api-bridge-design.md`
(its other sections — §1, §2, §4, §5, §6, §9 — remain authoritative).

## 0. 命題

ユーザの不可分な命題：**README.md L3「Call any public Apple framework
API from Ruby with no pre-declarations.」を実体として満たすこと。**

DEFERRED-line による退路、scope の削減、リスク回避は明示的に拒否
されている（auto-memory: `release_quality_completion_required.md`）。
本 spec は次セッションでの実装によりこの命題を満たすための設計と
TDD 順序を定める。

## 1. 現状実機計測（commit 01af0de tip）

| Example | EXIT | 動作実態 | README L3 達成 |
|---|---|---|---|
| coremidi_receive | 0 | client + in_port 実値、event_loop drain | ✅ |
| cf_string_create | 0 | autoarc box 実値（round-trip 部分実装） | △ |
| async_demo | 0 | 50→100 実計算（runtime fixture 経由） | ✅ |
| async_taskgroup | 0 | parallel 69ms（実は Ruby thread × runtime fixture、Swift TaskGroup ではない） | △ |
| vision_ocr | 0 | LLM exhaust → namespace bootstrap fallback | ❌ |
| objc_classmethod | 0 | LLM exhaust → DEFERRED line | ❌ |
| urlsession_download | 0 | LLM exhaust → DEFERRED line | ❌ |

3 / 7 examples が DEFERRED 退路で逃げている。これを 0 / 7 に
する作業の spec が本ドキュメント。

## 2. 構造ギャップ

spec § 3.2 polymorphic discover の dispatch chain が全層に浸透
していないことが根本原因。下表 5 ギャップが一直線に詰まり、ObjC /
Swift 系 kind の glue を LLM 経路に押し付け、LLM 側は Foundation
Models の 4096-token context window に収まらず 6 retries exhaust。

| # | 場所 | 問題 |
|---|---|---|
| G1 | `namespace_builder.rb:5-13` | KIND_TO_DEFINER に 7 kind のみ。objc_method_class / objc_method_instance / swift_func / swift_init / swift_property 未マップ → `Apple::<Framework>::<Klass>.<method>` の install 経路なし |
| G2 | `namespace_builder.rb:21-29` | build! は DB 全 49284 symbols を走査、transient overlay 非考慮。Apple.discover 後に install_into_box 呼んでも transient record だけ install できない |
| G3 | `template_generator.rb:72` | `kind == "function" && abi == "c"` 以外 nil → 必ず LLM へ |
| G4 | `glue_compiler.rb:38` | `exported = "glue_#{glue_id}_#{symbol[:name]}"` を Swift identifier に直結。`NSString.stringWithUTF8String` の `.` で Swift 構文壊れる |
| G5 | `dispatcher.rb:19` | cache.lookup は `symbol` 引数直渡し。synth record の name と user-facing 呼び出し名が違う場合 mismatch |

## 3. 設計

### 3.1 命題の操作的定義（Apple.discover 7 shape × 7 examples）

README L3 達成の verifiable 形：

| Shape | 例（実呼び出し） | Demonstrate |
|---|---|---|
| `symbol:` | `MIDIClientCreate("X", nil, nil)` → 非 0 client | coremidi_receive |
| `symbol:` (CF Create-rule) | `CFStringCreateWithCString(nil, "hello", utf8) → CFStringGetCString → "hello"` | cf_string_create（round-trip 完成） |
| `swift_func:` (sync, runtime fixture) | `runtime_async_test_sleep_and_double(50) → 100` | async_demo |
| `swift_func:` (async, real Swift TaskGroup) | runtime に新 fixture `runtime_async_test_taskgroup_double(10,20,30)` 追加し Apple.discover で呼ぶ → `[20,40,60]` | async_taskgroup |
| `selector:` | `VNImageRequestHandler(cgImage:options:) → handler.perform([VNRecognizeTextRequest()]) → recognized strings` | vision_ocr |
| `class_method:` | `+[NSString stringWithUTF8String:"hello"] → Ruby "hello"` | objc_classmethod |
| `swift_func:` + escaping completion | `URLSession.shared.dataTask(with:URL,completionHandler:{_,_,_ in})` → downloaded bytes int > 0 | urlsession_download |

acceptance gate：`RUBY_BOX=1 bundle exec ruby examples/<each>.rb`
で **exit 0** AND **DEFERRED line 含まず** AND **stdout に実値**。

### 3.2 Name 体系の単一化（4 → 2）

| 表現 | 値の例 (NSString.stringWithUTF8String) | 用途 |
|---|---|---|
| canonical_name | `"NSString.stringWithUTF8String"` | synth record :name / cache key (compiled_glue.symbol_name) / dispatcher symbol arg / KnowledgeCache transient lookup key |
| swift_identifier | `"NSString_stringWithUTF8String"` | exported_symbol（Swift identifier 文字集合の制約）。`canonical_name.gsub(/[^A-Za-z0-9_]/, "_")` で機械的に派生 |

ユーザは `Apple::Foundation::NSString.stringWithUTF8String("hello")`
で呼ぶ。NamespaceBuilder が `Apple::Foundation::NSString` proxy class を
作り、配下に singleton method `stringWithUTF8String` を install。
proxy class 内で dispatcher を呼ぶ際の symbol 引数は canonical_name
（`"NSString.stringWithUTF8String"`）。

generator 規則：
- `_synthesize_symbol_record(...)[:name]` = canonical_name
- `_discover_symbol_name(opts)` を **削除**。Ruby method 名は
  NamespaceBuilder が canonical_name から派生（`klass`/`method` 分解）
- `glue_compiler` の `exported_symbol` 計算で symbol[:name] を必ず
  swift_identifier 化（1 行 `gsub` を追加するだけ）
- `dispatcher.dispatch` の cache.lookup は **canonical_name**（=
  sym_meta[:name]）で行う

### 3.3 NamespaceBuilder 拡張

KIND_TO_DEFINER に non-C kind を追加：

```ruby
KIND_TO_DEFINER = {
  "function"             => :method,
  "global_constant"      => :method,
  "objc_method_class"    => :method_under_klass,   # 新
  "objc_method_instance" => :method_under_klass,   # 新
  "swift_init"           => :method_under_klass,   # 新
  "swift_property"       => :method_under_klass,   # 新
  "swift_func"           => :method,               # 新（top-level / static）
  "class" / "struct" / "actor" / "protocol" / "enum_module" => :constant
}
```

`:method_under_klass` は新しい install path：
- proxy class `Apple::<Framework>::<Klass>` を ensure（既存
  `define_type_constant` を再利用）
- そこに singleton method を define、内部で dispatcher を canonical_name
  で呼ぶ

per-symbol install API：

```ruby
class NamespaceBuilder
  def install_one(framework_name, sym_record)
    fw_module = define_framework_module(framework_name)
    install_symbol(fw_module, framework_name, sym_record)
  end
end
```

`Apple.discover` の `install_into_box` を `install_one` 経由に。
build! 全走査の毎回コストも消える（副次効果）。

### 3.4 TemplateGenerator の kind 別 emit

`generate(framework:, symbol:, glue_id:)` を kind dispatcher 化：

```ruby
def generate(framework:, symbol:, glue_id:)
  case symbol[:kind]
  when "function"               then emit_c_function(...)
  when "objc_method_class"      then emit_objc_class_method(...)
  when "objc_method_instance"   then emit_objc_instance_method(...)
  when "swift_func"             then emit_swift_func(...)        # async 含む
  when "swift_init"             then emit_swift_init(...)
  when "swift_property"         then emit_swift_property(...)
  end
end
```

各 emitter は HEADER 共通、boilerplate 共通、call 部分だけ kind 別。

#### 3.4.1 ObjC class method

```swift
import #{framework}; import Foundation
#{HEADER}
@c
public func #{exported}(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
    #{in_loads_for_argv_from(0)}
    let raw = #{Klass}.#{swiftMethod}(#{call_args})
    #{return_emit_for(return_kind)}
}
```

selector → Swift method 名変換規則：
- single-segment selector (`stringWithUTF8String:`) → `stringWithUTF8String`
- multi-segment selector (`initWithCGImage:options:`) → `init(cgImage:options:)`
  形式（init 専用）。class method の multi-segment は spec 範囲では
  rare、必要時 selector→Swift 名 mapping を symbol record に持たせる。

#### 3.4.2 ObjC instance method

```swift
let receiver = unsafeBitCast(
    OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
    to: #{Klass}.self
)
#{in_loads_for_argv_from(1)}
let raw = receiver.#{swiftMethod}(#{call_args})
#{return_emit_for(return_kind)}
```

argv[0] = receiver、argv[1..] = arguments。Marshaller は既存実装を
そのまま使う（`@index` constructor 引数で offset 制御）。

#### 3.4.3 Swift initializer

```swift
#{in_loads_for_argv_from(0)}
guard let v = #{Klass}(#{call_args}) else { return Qnil }
let p = Unmanaged.passRetained(v as AnyObject).toOpaque()
return rb_ull2inum(UInt64(UInt(bitPattern: p)))
```

#### 3.4.4 Swift property（read-only）

```swift
let receiver = unsafeBitCast(...)
let raw = receiver.#{property}
#{return_emit_for(return_kind)}
```

#### 3.4.5 Swift func（同期 / async）

同期：

```swift
#{in_loads}
let raw = #{Klass}.#{func}(#{call_args})  # or top-level: #{func}(...)
#{return_emit_for(return_kind)}
```

async（DispatchSemaphore + Task skeleton、既存 spec § 3.6）：

```swift
let sema = DispatchSemaphore(value: 0)
var result: T?
var captured: Error?
Task {
    do { result = try await #{Klass}.#{func}(#{call_args}) }
    catch { captured = error }
    sema.signal()
}
sema.wait()
if let e = captured { rb_raise(rb_eRuntimeError, "\(e)"); return Qnil }
#{return_emit_for(return_kind)}
```

#### 3.4.6 generic resolution（type_args:）

```swift
let raw = #{func}<#{type_args.join(",")}>(#{call_args})
```

`User` 型などが framework module 経由で visible なら動く。

#### 3.4.7 @MainActor isolated（async + actor）

```swift
Task {
    do {
        result = try await MainActor.run { try #{call} }
    } catch { captured = error }
    sema.signal()
}
```

### 3.5 escaping completion block の glue

NSURLSession dataTask completion block は **template から**直接 emit。
glue HEADER に既存の `runtime_callback_register_block_persistent` /
`runtime_callback_release_auto_block` の `@_silgen_name` 宣言を
そのまま使う。

```swift
#{in_loads_for_argv_from(0..-2)}      # last argv = completion block
let pid_v = rb_obj_id(argv[#{last}])
rb_hash_aset(runtime_proc_registry_get(), pid_v, argv[#{last}])
let pid_u = rb_num2ull(pid_v)
let slotId = runtime_callback_register_block_persistent(pid_u)
let cb_handle = BoxedBlockHandle(slotId: slotId)
let cb_block: (Data?, URLResponse?, Error?) -> Void = { (data, resp, err) in
    ThreadingBridge.enqueueFromAppleThread(procId: pid_u, arg: ...)
}
let task = receiver.#{method}(#{call_args_with_block})
task.resume()
return rb_ull2inum(UInt64(UInt(bitPattern: Unmanaged.passRetained(cb_handle).toOpaque())))
```

BlockPersistentMarshaller は既存。template から呼ぶだけ。

### 3.6 Marshaller の argv-binding（既存のまま）

Marshaller は constructor で `@index` を取り、`in_load` で
`argv[#{@index}]` を embed する。TemplateGenerator が kind 別に
正しい argv index を渡せば再利用できる（ObjC instance method なら
argv[0]=receiver、argv[1..]=arguments）。**新インターフェイス追加せず**、
既存 Marshaller をそのまま再利用する。Marshaller registry / protocol
は変更なし。

### 3.7 LLM 経路の位置づけ（残す）

**LLM は未知への対応のメタプログラミング手段として保持する。**
template generator が known kind を full coverage しても、Apple は
将来：

- 新 framework
- 新 idiom（macOS 28 で導入される async-let の新 form 等）
- private な ABI quirk

を出してくる。これらに対応するために LLM 経路は必須。削除しない。

ただし v1.0 の **critical path から外す**：

- known kind は 100% template が生成
- LLM 経路は known kind の glue 生成では呼ばれない
- LLM 経路は「template が `nil` を返した = 未知 kind / 未知 shape」の
  場合のみ呼ばれる
- 4096-token context-window 制約は critical でなくなる（known kind
  cover が前提なので、LLM が試行する shape が珍しいケースに限られ、
  prompt boilerplate 削減で十分収まる）

LLM 経路の現状コードは保持。冗長な family-scoped session 場当たり
は維持（4096 制約があるので有用）。Worked Example 群も保持。

### 3.8 真の Swift TaskGroup（async_taskgroup）

現 `async_taskgroup.rb` は Ruby Thread × runtime fixture で parallel
を fake。spec § 3.6 E2 の本物に置換：

- runtime に `runtime_async_test_taskgroup_double(_ ms_a: Int64, _ ms_b: Int64, _ ms_c: Int64) -> [Int64]` 追加
- `try await withThrowingTaskGroup(...) { ... }` で 3 並列
- mac gem 側は Apple.discover swift_func 経由で呼ぶ

LLM は使わない。runtime 拡張 + template の swift_func async emit。

### 3.9 cf_string_create round-trip 完成

現状 `Apple::CoreFoundation.CFStringCreateWithCString(nil, "hello", utf8)`
で autoarc box の Integer を取れる。round-trip には：

- BoxedCFType wrap した値を別 CF API（CFStringGetLength /
  CFStringGetCString）に渡す。box の中の生 CFString pointer を取り
  出す runtime entry `runtime_arc_unbox_cftype(_ raw: UInt) -> UInt`
  を追加（既存 ARCBridge.swift の対称 entry）。
- glue 側は CFTypeRefMarshaller の in_load で「Ruby 値が autoarc
  box ID なら unbox、生 pointer なら as-is」を判定して使う。
  実装簡略：autoarc box は常に `runtime_arc_unbox_cftype` 経由で
  unwrap、unbox 失敗時は raw pointer 扱い。

これで `CFStringGetCString` を呼んで Ruby String "hello" に戻せる。

## 4. 不要コード排除

LLM 経路は残すが、polymorphic discover の前後で**冗長な実装**は
削る：

- `_discover_symbol_name` 削除（NamespaceBuilder 側で canonical_name
  から派生する）
- `Apple::Error` / `AppleSDKMac::Error` の双方向 alias、Box bootstrap
  順依存の workaround → spec 通り Box bootstrap 後に一括 alias を
  1 箇所で行うシンプルな形に
- examples の DEFERRED rescue 経路 → 削除（実 call で動く前提）
- `examples_smoke_test.rb` の DEFERRED line 許容アサート → `refute_match(/DEFERRED/)`
- `glue_compiler.rb` の `Apple::Error` / `AppleSDKMac::Error` 二重
  raise 場当たり → `AppleSDKMac::CompileError` 一本

新規追加は最小限：

- runtime に `runtime_arc_unbox_cftype` 1 個
- runtime に `runtime_async_test_taskgroup_double` 1 個
- NamespaceBuilder に `install_one` 1 メソッド + KIND_TO_DEFINER 5 行
- TemplateGenerator に kind 別 emitter 5 メソッド
- glue_compiler.rb `exported_symbol` 計算に gsub 1 行

## 5. TDD 順序

bite-sized、各 = RED + GREEN（必要時 REFACTOR）独立 commit。
番号は既存 spec T0-T20 と重複避け T40 から。

| # | Task | RED | GREEN |
|---|---|---|---|
| **T40** | Name 単一化 + sanitize | test/public_api_test.rb で synth record name と Apple::<Framework>::<Klass>.<method> 経路の整合 | `_synthesize_symbol_record` の name = canonical_name、`glue_compiler` exported sanitize 1 行追加、`dispatcher` cache.lookup を sym_meta[:name] 経由に |
| **T41** | NamespaceBuilder.install_one + KIND_TO_DEFINER 拡張 | namespace_builder_test.rb で per-symbol install できる、Apple::Foundation::NSString に method 生える | install_one + :method_under_klass routing |
| **T42** | TemplateGenerator emit_objc_class_method | template_generator_test.rb で kind=objc_method_class が Swift glue 出す | emit_objc_class_method |
| **T43** | examples/objc_classmethod.rb 実呼び出し（DEFERRED rescue 削除） | smoke で stdout に "hello" が出る、stderr にエラーなし | T40-T42 統合動作 |
| **T44** | TemplateGenerator emit_objc_instance_method | template_generator_test.rb | emit_objc_instance_method |
| **T45** | TemplateGenerator emit_swift_init | 同 | emit_swift_init |
| **T46** | TemplateGenerator emit_swift_property | 同 | emit_swift_property |
| **T47** | TemplateGenerator emit_swift_func（同期 + async） | 同 | emit_swift_func |
| **T48** | TemplateGenerator emit + escaping block path | template_generator_test.rb で last argv = block_persistent 出す | block emit 統合 |
| **T49** | runtime_arc_unbox_cftype + Marshaller 経路 | arc_bridge_test.rb / template_generator_test.rb | runtime entry + glue path |
| **T50** | examples/cf_string_create.rb round-trip 完成 | smoke で "hello" 文字列が読み戻る | T49 使用 |
| **T51** | runtime_async_test_taskgroup_double | async_bridge_test.rb | runtime fixture 実装 |
| **T52** | examples/async_taskgroup.rb 真の TaskGroup | smoke で Apple.discover swift_func 経由 + parallel 確認 | T51 + T47 統合 |
| **T53** | examples/urlsession_download.rb 実 download | smoke で downloaded bytes > 0 | T48 統合 |
| **T54** | examples/vision_ocr.rb 実 OCR | smoke で recognized strings non-empty。fixture image を sips で生成（test setup） | T44 + T45 + T48 統合 |
| **T55** | examples_smoke_test.rb 全例 refute_match(/DEFERRED/) | RED: 現状の DEFERRED 退路で fail | T43 / T50 / T52 / T53 / T54 完了で自動 GREEN |
| **T56** | LLM 経路の prompt 簡素化（critical path から外れた前提で） | llm_generator_test.rb | family-scoped session 維持、Worked Example は known-kind が template に移った分減らす |
| **T57** | rake test:release_quality 全 PASS、acceptance 達成 | aggregate fail | T40-T56 完了で自動 GREEN |
| **T58** | CHANGELOG / README / VERSION の整合、v1.0.0-rc1 → v1.0.0 promote | tag 既存 v1.0.0 を一旦 -rc1 へ rename、release 品質達成後 v1.0.0 を新 commit に付け直す | reflect 最終状態 |

## 6. Acceptance（spec § 9 を README 主張に紐付け）

v1.0 ship 許可条件：

| Criterion | Acceptance |
|---|---|
| README L3 主張 | 7 examples が DEFERRED line を**含まず**実 framework 値を stdout |
| polymorphic discover 7 shape | test/public_api_test.rb 全 shape の synth + Apple::<Framework>::<Klass>.<method> install まで |
| examples_smoke_test.rb | 7/7 exit 0 AND `refute_match(/DEFERRED/, stdout)` AND 各 example の expected stdout pattern (`/^hello$/`, `/recognized=\[/`, etc.) |
| readme_canonical_test.rb | 既存通り |
| discover_coverage_test.rb | 既存通り（kind vocabulary 拡張済） |
| memory_leak_test.rb | 例 7 個で個別 RSS Δ ≤ 5MB |
| concurrent_discover_test.rb | 既存通り + objc_method_class 1 種追加で multi-kind concurrency |
| dispatch_overhead.rb | strict 200µs に届くまで template path 最適化（v1.0 critical） |
| LLM 退避路の生存性 | llm_generator_test.rb で 1 known-未対応 shape を試して LLM が呼ばれることを assert（メタプログラミング手段の保持確認） |

## 7. 依存（既存 spec / コードへの影響）

- `2026-05-06-complete-mac-api-bridge-design.md` § 3.2 章は本 spec に
  supersede。同 spec の §1 / §2 / §4 / §5 / §6 / §9 は引き続き有効。
- 9-pillar 数は変えない。本 spec の追加は ARC pillar の
  `runtime_arc_unbox_cftype` と Async pillar の test fixture
  `runtime_async_test_taskgroup_double` のみ。新 pillar 不要。
- rb-apple-sdk-knowledge SCHEMA_VERSION=3（c963b2d で landed）の
  cf_create_rule / objc_kind / swift_kind 列は依然として ingest 拡張
  待ち。本 spec は ingest 待たず、Apple.discover の synth record
  経由で kind を渡す path を主にする。

## 8. Implementation handoff（次セッションで読むファイル、フルパス）

新セッションは以下を冒頭で必ず読み込む：

1. **達成命題ファイル**
   `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/README.md`
   L3 / L29-34 / L42-47 が達成すべき命題。

2. **本 spec**
   `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/docs/superpowers/specs/2026-05-06-polymorphic-discover-end-to-end.md`
   実装ガイド。

3. **既存 spec（背景）**
   `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md`
   §1-2 / §4 / §5 / §9 の各 acceptance は本 spec も引き継ぐ。
   §3.2 章は本 spec に supersede。

4. **メモリ（auto-load される）**
   `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-rb-apple-sdk-mac/memory/MEMORY.md`
   `/Users/bash/.claude/projects/-Users-bash-dev-src-github-com-bash0C7-rb-apple-sdk-mac/memory/release_quality_completion_required.md`
   ↑ DEFERRED 退路禁止の前提。

5. **コアコード（事前 grep ターゲット）**
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/public_api.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/dispatcher.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/namespace_builder.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/glue_compiler.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/glue_compiler/template_generator.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/glue_compiler/marshallers.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/glue_compiler/llm_generator.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/lib/apple_sdk_mac/knowledge_cache.rb`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/CallbackPillar.swift`
   - `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift`

6. **examples（実機検証 + DEFERRED 削除対象）**
   `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/examples/{coremidi_receive,cf_string_create,async_demo,async_taskgroup,vision_ocr,objc_classmethod,urlsession_download}.rb`

7. **実行ハンドル**
   - `RUBY_BOX=1 bundle exec ruby examples/<name>.rb`
   - `bundle exec rake test`
   - `BENCH_BUDGET_US=1000 bundle exec rake test:release_quality`

## 9. Verification（このセッション完了条件）

- [x] spec ファイル `docs/superpowers/specs/2026-05-06-polymorphic-discover-end-to-end.md` 作成
- [ ] 既存 spec 末尾に supersede 注記
- [ ] git commit
- [ ] v1.0.0 タグを v1.0.0-rc1 にリネーム（release 品質未達状態のため）
- [ ] auto-memory `release_quality_completion_required.md` 既存（確認済み）
