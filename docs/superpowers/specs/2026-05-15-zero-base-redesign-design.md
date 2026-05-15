# Zero-base Redesign — L8 literal claim へ全体最適で到達する設計

**Date**: 2026-05-15
**Status**: Design (awaiting user review before T0 entry)
**Scope**: rb-apple-sdk-mac v2.0 (gross refactor)
**Supersedes**: `docs/superpowers/specs/2026-05-09-v1.2-bootstrap-principle-design.md` の Phase 4 以降 (Phase 4a/4b/5/6 を再設計、 Phase 7 は別 spec へ)

---

## 1. Thesis (北極星)

README.md L8:

> Call any public Apple framework API from Ruby with no pre-declarations.

これを **literal な runtime-verifiable claim** として満たす。 具体的には、 以下が動くこと:

```ruby
require "apple_sdk_mac"

Apple::CoreMIDI.MIDIGetNumberOfSources
Apple::CoreAudio.AudioObjectGetPropertyDataSize(...)
Apple::AVFoundation.AVSpeechSynthesizer.alloc.init.speak(...)
Apple::Vision.VNImageRequestHandler.alloc.initWithCGImage(...)
```

- `AppleSDKMac.bootstrap!` の **明示呼び出し不要**
- `Apple.discover(...)` の **事前宣言不要** (escape hatch demo を除く)
- 失敗時は **typed raise** (`Apple::Knowledge::SymbolMissing` / `Apple::Compile::Unsupported` 等)、 無音 swallow 禁止

`AppleSDKMac.bootstrap!` と `Apple.discover` 自体は **互換のため残す** が、 「principal な使い方」 から外し、 README からも escape 節以外では消す。

### 1.1 User ergonomics > gem internal overhead (user 明示 2026-05-15)

trade-off priority:

- gem 内部 overhead (bootstrap 時間 / KB ingest 時間 / dispatch latency / cache hit までの初回 swiftc 1〜3 s) は **一定許容**
- user 側の「おまじない的なコード」 や「静的設定ファイル」 を不要にすることが **優先**

Memory: `feedback_user_ergonomics_over_overhead.md`

### 1.2 観測事実 (2026-05-15 baseline)

| 項目 | 値 |
|---|---|
| examples 11 個中、 `Apple.discover` ゼロで動くもの | 4 個 (37%) |
| `Apple.discover` 行が残る example | 7 個 (max 20 行) |
| bootstrap! 経由で失敗する pattern | 1 件 (`audio_device_count.rb` で TypeError) |
| 失敗の根源 | KB attribute 不足 + LLM safety net 削除 (commit 32b6082) の合わせ技 |
| 主要 file 巨大化 | `template_generator.rb` 1077 行 / `marshallers.rb` 805 行 |

L8 達成率は機械的に「**examples の discover 削除 + bootstrap! 暗黙化 + 全 example 緑**」 で計測する。

---

## 2. Core diagnosis (構造的単一原因)

```
audio_device_count.rb 失敗 (Hash → Integer cast)
   ↑
marshallers.rb の out_handling=nil semantic conflate
   ↑
template_generator が nil 戻したら routing 先がない (LLM 削除済)
   ↑
struct-in + int-out 混合 pattern が静的 emitter 未対応
   ↑
KB が is_out_param / block_lifetime / cf_create_rule 等の attribute を完全には保存してない
   ↑
Apple.discover で override を user に書かせる以外の解が現状ない
```

7 example に残る `Apple.discover` は **「KB が attribute 持ってないから user 補完しろ」** の表れ。 つまり L8 違反は **多発する症状やのうて単一の構造的原因**。 zero-base で解くなら以下 6 軸を **同時に揃える** 必要がある:

1. **KB を上流で完全化**して attribute 不足を消す (NS-1)
2. **L4 を分解**して emitter を kind 別の独立 file に (NS-2)
3. **LLM safety net を on-device 経由で復活**させて dead end を消す (NS-3)
4. **bootstrap! を no-op 化**して `require` 1 行で動くようにする (NS-4)
5. **NamespaceBuilder を kind 別に解体**して install path 混在を解消 (NS-5)
6. **examples を refactor**して L8 を機械検収可能に (NS-6)

---

## 3. Phasing (NS-0 〜 NS-8)

各 phase 末尾に **verification gate** を置く。 gate を通らへんと次 phase に進まれへん。 全 gate は test-unit assert に乗せる (memory `feedback_test_unit_assert_as_report.md`)。

| Phase | 内容 | depends on | 工数目安 |
|---|---|---|---|
| NS-0 | baseline 計測 + compile_history 復活 | — | 0.5 d |
| NS-1 | Knowledge Base completeness (5 attribute ingest + schema bump) | NS-0 | 1-2 d |
| NS-2 | L4 分解 (template_generator / marshallers) | NS-0 | 1 d |
| NS-3 | LLM safety net 復活 (on-device foundation_model 経由) | NS-2 | 0.5-1 d |
| NS-4 | Dispatcher lazy resolution (bootstrap! no-op 化) | NS-1, NS-3 | 0.5-1 d |
| NS-5 | NamespaceBuilder 解体 (kind-specific module 単位) | NS-2, NS-4 | 0.5 d |
| NS-6 | examples 全 refactor (7 example から discover 削除) | NS-4, NS-5 | 0.5 d |
| NS-7 | README 整合 (L52-114 を escape 節 1 個に縮約) | NS-6 | 0.25 d |
| NS-8 | release_quality rake task + DEFERRED 検出 | NS-7 | 0.25 d |
| **合計** | | | **5-7 営業日** |

---

## 4. NS-0: Baseline 計測 + compile_history 復活

### 4.1 目的

「**現状をどれだけ改善したか**」 を後続 phase で機械的に判定できる baseline を作る。

### 4.2 行動

1. `bundle exec ruby examples/<each>.rb` を全 11 example で実行、 baseline 表 (Section 1.2) を `tmp/baseline-2026-05-15.md` に保存
2. `compile_history` table が 0 row なんは **LLM 削除で記録口そのものを消した** から。 Dispatcher の typed raise path 3 経路 (`symbol_missing` / `unsupported_pattern` / `compile_failed`) 全部で `CompiledGlueCache.record_attempt(...)` を呼ぶようにする
3. `apple:release_quality` rake task の骨組みを置く (実体は NS-8 で詰める): exit code aggregate + DEFERRED line 検出 + per-example timing

### 4.3 Verification gate (NS-0)

| Assert | 内容 |
|---|---|
| `test/integration/baseline_e2e_test.rb` (新規) | 11 example を 1 個 1 test method で smoke run、 baseline 表と一致 (exit code / discover 行数 / bootstrap! 有無) |
| `test/unit/compile_history_record_attempt_test.rb` (拡張) | 3 typed raise 経路で `compile_history` に row が必ず残る (RED→GREEN) |

---

## 5. NS-1: Knowledge Base completeness

### 5.1 追加 attribute 5 種

| Column | 何を保存するか | 入力 source |
|---|---|---|
| `is_out_param` (per-param, parameters_json 内) | 引数が `Pointer<T>` の out 用かどうか | clang AST: `inout` 修飾 / ObjC `out` qualifier / 既存 `*.swiftinterface` の `inout T` |
| `cf_create_rule` (per-symbol) | CF Create-rule 該当 (戻り値が `+1 retained`) | clang AST `cf_returns_retained` attribute |
| `block_lifetime` (per-param) | callback が `noescape` か `persistent` か | clang AST `noescape` attribute / Swift `@escaping` |
| `swift_imported_name` (per-symbol, 既存) | ObjC selector → Swift import 名 | `*.swiftinterface` の `@objc(...)` line 解析 (既に Phase 4a で部分実装) |
| `objc_kind` (per-symbol) | class_method / instance_method / property / init / 等 | clang AST: `+` / `-` / `@property` decoration |

### 5.2 ingester 強化

knowledge/ sub-gem の importer 群 (`knowledge/lib/rb_apple_sdk_knowledge/importer/`) を拡張:

- **ObjC framework importer**: clang AST 走査時に上記 attribute を `parameters_json` / `symbols.*` columns へ
- **Swift overlay importer**: swift-syntax 完全 parse に格上げ (現 regex 版は段階 A、 swift-syntax 版を段階 B として add)
- **schema_version bump**: 既存 cache を自動再生成 trigger

### 5.3 schema 変更

```sql
ALTER TABLE symbols ADD COLUMN cf_create_rule INTEGER DEFAULT 0;
ALTER TABLE symbols ADD COLUMN objc_kind TEXT;
-- parameters_json の各 element に is_out_param / block_lifetime keys を追加
-- swift_imported_name は既存 column を維持
```

CACHE_SCHEMA を bump、 KnowledgeCache.open で SCHEMA mismatch 検出 → `rake apple:knowledge:rebuild` 案内 raise (`Apple::Knowledge::SchemaMismatchError`)。

### 5.4 後方互換

- 旧 schema の cache は raise (silent fallback 禁止、 memory `No Silent Exception Swallowing`)
- error message に `bundle exec rake apple:knowledge:rebuild` を含める

### 5.5 Verification gate (NS-1)

| Assert | 内容 |
|---|---|
| `test/unit/knowledge/importer/objc_attribute_test.rb` | clang AST から 5 attribute が全 populate (fixture `*.h` 経由) |
| `test/unit/knowledge/importer/swift_overlay_attribute_test.rb` | Foundation / AVFoundation の `*.swiftinterface` 由来で attribute 完全 |
| `test/unit/knowledge_cache_schema_mismatch_test.rb` | 旧 schema cache を開くと `SchemaMismatchError` raise (RED→GREEN) |
| `test/integration/kb_attribute_coverage_test.rb` | KB の全 symbol のうち `objc_kind` populated 率 ≥ 95% (ObjC framework only) |

---

## 6. NS-2: L4 分解 (template_generator + marshallers)

### 6.1 template_generator.rb (1077 行) → 6 emitter file

新規 dir `lib/apple_sdk_mac/glue_compiler/emitters/`:

| File | 担当 kind |
|---|---|
| `c_function_emitter.rb` | C function (CoreMIDI / CoreAudio / CoreFoundation 系) |
| `objc_class_method_emitter.rb` | `+stringWithUTF8String:` 等 |
| `objc_instance_method_emitter.rb` | `-init...` / instance selector |
| `swift_init_emitter.rb` | `init(string:)` 等 |
| `swift_func_emitter.rb` | top-level Swift func + module-level |
| `swift_property_emitter.rb` | property getter / setter |

各 emitter は単一 public method `emit(symbol_record, glue_id) → String | nil`、 内部 helper は private。

template_generator.rb は **router** に縮減 (router + 共有 helper、 200 行以下目標):

```ruby
class TemplateGenerator
  EMITTERS = {
    function:              CFunctionEmitter,
    objc_method_class:     ObjcClassMethodEmitter,
    objc_method_instance:  ObjcInstanceMethodEmitter,
    swift_init:            SwiftInitEmitter,
    swift_func:            SwiftFuncEmitter,
    swift_property:        SwiftPropertyEmitter
  }.freeze

  def generate(framework:, symbol:, glue_id:)
    record = @kc.lookup_symbol(framework, symbol)
    emitter_class = EMITTERS.fetch(record[:kind].to_sym) do
      raise Apple::Compile::UnsupportedKind, "#{record[:kind]} (#{framework}.#{symbol})"
    end
    emitter_class.new(record, glue_id, helpers: shared_helpers).emit
  end
end
```

shared helper module (4 個):
- `SwiftTypeHelper` — type token / generic / Optional 階層
- `ArcHelper` — auto-ARC wrap / unwrap
- `ErrorHelper` — try / catch / OSStatus → Ruby raise
- `SwiftNamingHelper` — selector → Swift call expression

### 6.2 marshallers.rb (805 行) → 3 dir

新規 dir `lib/apple_sdk_mac/glue_compiler/marshallers/`:

| Dir | 含む marshaller |
|---|---|
| `primitive/` | StringMarshaller, IntMarshaller, BoolMarshaller, FloatMarshaller |
| `complex/` | OpaqueRefMarshaller, CFTypeRefMarshaller, StructInMarshaller, StructOutMarshaller, StructInPointerMarshaller, ArrayOfOpaqueRefMarshaller, VoidPtrNilableMarshaller, VariadicMarshaller |
| `callback/` | BlockNilableMarshaller, BlockPersistentMarshaller, CallbackMarshaller |

base `Marshaller` class (interface 定義) は `marshallers.rb` 直下に残す (50 行以下)。

### 6.3 out_handling semantic 分離

現状: `out_handling → Hash | nil` の `nil` が 2 意味 conflate:

1. 「この marshaller は out_param 非対応」 (例: StringMarshaller)
2. 「is_out_param=false なので out 不要」 (例: IntMarshaller で in 専用)

→ Sentinel 値オブジェクト導入:

```ruby
class Marshaller
  # 戻り値: OutHandling.from_hash(...) | OutHandling::INAPPLICABLE | OutHandling::UNSUPPORTED
  def out_handling
    OutHandling::INAPPLICABLE
  end
end
```

router (template_generator) は `UNSUPPORTED` を検出したら early-return nil + telemetry record で **LLM safety net 経路 (NS-3)** に明示的に流す。

### 6.4 Verification gate (NS-2)

| Assert | 内容 |
|---|---|
| `test/unit/glue_compiler/emitters/<each>_test.rb` (6 file) | 既存 template_generator test を kind 別にバラした coverage 維持 |
| `test/unit/glue_compiler/marshallers/<dir>/<each>_test.rb` | 既存 marshallers test を dir 別にバラした coverage 維持 |
| `test/unit/glue_compiler/template_generator_router_test.rb` | unknown kind → `Apple::Compile::UnsupportedKind` raise (RED→GREEN) |
| `test/unit/glue_compiler/out_handling_sentinel_test.rb` | `INAPPLICABLE` / `UNSUPPORTED` / `Hash` の 3 分岐が router で正しく routing (RED→GREEN) |
| `bundle exec rake test` (subagent 委譲) | 404/1022/0 baseline を **同等以上** に維持 (回帰なし) |

---

## 7. NS-3: LLM safety net 復活 (on-device foundation_model 経由)

### 7.1 復活方針

過去 commit 32b6082 で削除した `LLMGenerator` + `LLMExamples` を **on-device foundation_model 専用で復活**。 ただし以下制約:

- gemspec の **runtime dependency** に `rb-foundation-model-mac` を**戻さん** (memory `feedback_gem_internal_encapsulation.md` 反映)
- 代わりに **optional dependency**: `require "apple_sdk_mac"` 時に `defined?(FoundationModelMac)` を check、 居なければ LLM 経路 skip + telemetry warn
- gem user の Gemfile に `gem "rb-foundation-model-mac"` が居れば自動的に LLM safety net 有効化、 居らんでもエラーで止めへん
- stdout に LLM ログ一切出さん (encapsulation 維持)、 telemetry jsonl にのみ event 残す

### 7.2 routing

```
Dispatcher.dispatch
  ↓
GlueCompiler.compile (試行 1: template)
  ↓ Result.unsupported? なら ↓
GlueCompiler.compile (試行 2: LLM safety net)
  ↓ optional dependency 不在 / 6 retry 全失敗 なら ↓
raise Apple::Compile::Unsupported (typed)
```

### 7.3 implementation discipline

spec doc 2026-05-09 Section 7.2 通り「単一 retry 境界」:

```ruby
def compile(framework:, symbol:)
  result = TemplateGenerator.new(@kc).generate(framework: framework, symbol: symbol, glue_id: ...)
  return wrap_success(result) if result.is_a?(String)
  return fallback_llm(framework, symbol) if llm_available?
  raise Apple::Compile::Unsupported, "#{framework}.#{symbol} (template miss, no LLM fallback)"
end
```

### 7.4 Verification gate (NS-3)

| Assert | 内容 |
|---|---|
| `test/unit/glue_compiler_llm_routing_test.rb` | template が `UNSUPPORTED` 戻したら LLM 経路に行く (RED→GREEN) |
| `test/unit/glue_compiler_no_llm_dependency_test.rb` | `FoundationModelMac` 未 require 環境で typed raise が走る (silent skip 禁止) |
| `test/integration/audio_device_count_e2e_test.rb` | bootstrap! 経由で AudioObjectGetPropertyDataSize 動く (LLM 経由でも static でも OK、 exit 0 + audio device 数 stdout) |

---

## 8. NS-4: Dispatcher lazy resolution (bootstrap! no-op 化)

### 8.1 transparent namespace mechanism

`require "apple_sdk_mac"` 時点で:

1. `Apple` const を Ruby::Box として install
2. `Apple` に `const_missing(framework_sym)` hook を仕掛ける
3. hook 内で KB に `framework_sym` 存在確認 → 存在すれば `Apple::<Framework>` Module を define して、 その module 自身に `method_missing(symbol)` hook を仕掛ける
4. `method_missing` で KB lookup + Dispatcher 起動

例:

```ruby
require "apple_sdk_mac"
# この時点で Apple は Box、 framework Module 一切 define されてない
Apple::CoreMIDI       # const_missing → KB 存在確認 → Apple::CoreMIDI Module define
Apple::CoreMIDI.MIDIGetNumberOfSources   # method_missing → KB lookup → glue compile + dispatch
```

### 8.2 bootstrap! を no-op + deprecation warn

```ruby
module AppleSDKMac
  def self.bootstrap!
    return if @bootstrap_warned
    Telemetry.append(stage: "deprecation", note: "bootstrap! is a no-op since v2.0; transparent dispatch is automatic")
    @bootstrap_warned = true
  end
end
```

理由: 既存 user / examples が呼んでも壊さん。 v3.0 で完全削除予定。

### 8.3 IRB autocomplete との関係

IRB sub-gem `apple_sdk_mac/irb` は `AppleSDKMac::IRB.install!` で reline hook を仕掛ける。 transparent path との関係:

- IRB.install! は **eager-define** path として残す (`KnowledgeCache.list_frameworks` から `Apple::<Framework>` module を一括 define、 method shell も生やす)
- main gem の lazy path とは独立、 重複してもエエ (idempotent design)
- IRB sub-gem だけが eager-define する → main gem 自体は lazy 一貫

### 8.4 ObjC instance method の透過化

`Apple::AVFoundation.AVSpeechSynthesizer.alloc.init.speak(...)` を動かすには:

1. `Apple::AVFoundation` const_missing → Module define
2. `AVSpeechSynthesizer` const_missing → klass Module define (KB の `objc_kind=class` を見て)
3. `.alloc` method_missing → class_method として KB lookup
4. `.alloc` の戻り値 (OpaqueRef wrapped) に `.init` method_missing → instance_method として lookup
5. 戻り値 (initialized instance) に `.speak(...)` method_missing → instance_method として lookup

各段で Dispatcher が KB lookup + glue compile を lazy 実行。 初回は遅い、 cache hit 後 sub-ms。

### 8.5 Verification gate (NS-4)

| Assert | 内容 |
|---|---|
| `test/unit/apple_box_const_missing_test.rb` | `Apple::CoreMIDI` 参照で Module が lazy 生成 + KB に居らへん framework は `Apple::Knowledge::FrameworkMissing` raise |
| `test/unit/apple_framework_method_missing_test.rb` | `Apple::CoreMIDI.UnknownSym` で `Apple::Knowledge::SymbolMissing` raise (RED→GREEN) |
| `test/integration/transparent_dispatch_e2e_test.rb` | `require "apple_sdk_mac"; Apple::CoreMIDI.MIDIGetNumberOfSources` が **bootstrap! 呼ばずに** 動く (RED→GREEN) |
| `test/integration/bootstrap_deprecation_test.rb` | `bootstrap!` 呼ぶと telemetry に deprecation event 1 行、 動作には影響なし |

---

## 9. NS-5: NamespaceBuilder 解体

### 9.1 現状

`namespace_builder.rb` 291 行に `KIND_TO_DEFINER` (12 kinds) × 4 install paths (`define_singleton_method` / `define_method` / `const_set` / setter) 混在。

### 9.2 解体方針

新規 dir `lib/apple_sdk_mac/namespace/`:

| File | 担当 |
|---|---|
| `installer.rb` | router (kind 別 install 振り分け、 60 行以下) |
| `function_installer.rb` | C function を framework module の singleton method として install |
| `class_method_installer.rb` | ObjC class method を klass module の singleton method として install |
| `instance_method_installer.rb` | ObjC instance method を `Apple::OpaqueRef` の instance method として install |
| `swift_init_installer.rb` | Swift init を klass module の `.new(...)` として install (alloc.init 経路と並存) |
| `property_installer.rb` | Swift property を getter/setter として install |

各 installer は単一 public method `install!(symbol_record, target_module)`、 内部 hook (lazy define vs eager define) は **strategy として外から注入** (NS-4 の lazy path / IRB sub-gem の eager path で共有可能に)。

### 9.3 NS-4 との関係

NS-4 の `method_missing` chain も内部で同 installer 群を呼ぶ。 つまり:

- 「**lookup と install を一度やったら、 二回目は Ruby method 呼び出しが定義済 method を素直に hit する**」
- method_missing の重い経路は初回のみ、 cache hit と同じく sub-ms 化

### 9.4 Verification gate (NS-5)

| Assert | 内容 |
|---|---|
| `test/unit/namespace/<installer>_test.rb` (6 file) | 各 installer 単体で symbol_record 受けて target_module に method 生やす |
| `test/integration/method_missing_to_defined_method_test.rb` | 初回 method_missing → install → 二回目は defined method 直 hit (no method_missing) |
| `test/integration/irb_eager_define_test.rb` | IRB sub-gem の `install!` が全 framework module を eager-define、 method shell が tab で出る (RED→GREEN) |

---

## 10. NS-6: examples 全 refactor

### 10.1 refactor 対象 (7 example)

| File | discover 行数 (現) | refactor 後 | 依存 NS |
|---|---|---|---|
| `async_taskgroup.rb` | 7 | 0 (transparent) | NS-4 |
| `avspeech_synth.rb` | 4 | 0 | NS-1, NS-4 |
| `cf_string_create.rb` | 3 | 0 | NS-1, NS-4 |
| `urlsession_download.rb` | 6 | 0 | NS-1, NS-4 |
| `vision_ocr.rb` | 10 | 0 | NS-1, NS-3, NS-4 |
| `piano_keyboard.rb` | 20 | 0 (interactive 部は維持、 discover のみ消す) | NS-1, NS-4 |
| `discover_escape.rb` | 6 | 6 のまま (**escape demo として残す**) | — |

### 10.2 `bootstrap!` 呼び出しも削除

NS-4 で no-op 化したので、 examples の冒頭から `AppleSDKMac.bootstrap!` 行も削除。 ただし `discover_escape.rb` は example として contrast 示すため `Apple.discover` のみ残し、 `bootstrap!` 行は削除。

### 10.3 examples/README.md 整理

各 example に 1 段落で「何が起きるか / 動かし方 / 依存 framework」 を書く。 `discover_escape.rb` は明示的に「**この example は escape hatch demo です**」 と label 付け。

### 10.4 audio_device_count.rb 修正

現状失敗の TypeError は NS-1 (KB attribute) + NS-2 (out_handling sentinel) + NS-3 (LLM fallback) が揃ったら自動で動く。 example 自体は変更不要、 verification gate でこれを assert。

### 10.5 Verification gate (NS-6)

| Assert | 内容 |
|---|---|
| `test/integration/examples_smoke_test.rb` | 11 example 全部 exit 0 (interactive 系は 5 秒 timeout で kill 後 functional output assert) |
| `test/integration/examples_no_discover_test.rb` | `discover_escape.rb` 以外の 10 example で `Apple.discover` の grep ヒット 0 (RED→GREEN) |
| `test/integration/examples_no_bootstrap_test.rb` | 全 11 example で `AppleSDKMac.bootstrap!` の grep ヒット 0 (RED→GREEN) |

---

## 11. NS-7: README 整合

### 11.1 削る箇所

- L48-80 (Recommended: bootstrap once... / Lightweight: per-symbol on-demand) — **削除**。 transparent dispatch が standard
- L82-114 (When you still need `Apple.discover`) — **escape hatch 節として 1 個に縮約**、 `discover_escape.rb` への link

### 11.2 残す / 書き換える箇所

- L1-7 (experimental banner) — 維持
- L8 tagline — 維持 (literal 達成済)
- 新規 Usage 節:

```ruby
require "apple_sdk_mac"

ins = Apple::CoreMIDI.MIDIGetNumberOfSources
puts ins  #=> 0 (or your MIDI device count)
```

- Architecture 節 — NS-2/NS-5 の解体構造を反映、 emitter 6 file / installer 6 file を箇条書きに
- Escape hatch 節 — `discover_escape.rb` 1 link + 「private framework / 第三者 framework / 自前 ObjC selector」 の 3 ケースのみ言及

### 11.3 Verification gate (NS-7)

| Assert | 内容 |
|---|---|
| `test/unit/readme_consistency_test.rb` (新規) | README.md L8 → 新 Usage 節の code block を `eval` で実行、 exit 0 (RED→GREEN) |
| `test/unit/readme_no_bootstrap_recommendation_test.rb` | README.md grep で「`Recommended: bootstrap`」 不在を確認 |

---

## 12. NS-8: release_quality rake task + DEFERRED 検出

### 12.1 task 定義

```ruby
# Rakefile
namespace :apple do
  desc "Run all release-quality gates"
  task release_quality: ["apple:release_quality:examples", "apple:release_quality:test", "apple:release_quality:no_deferred"]

  namespace :release_quality do
    task :examples do
      # examples/*.rb 全実行、 exit 非 0 / DEFERRED line 検出で fail
    end

    task :test do
      # bundle exec rake test、 1 failure でも fail
    end

    task :no_deferred do
      # lib/ examples/ README.md grep で 「DEFERRED」「TODO」「FIXME」 検出、 1 件でも fail
    end
  end
end
```

### 12.2 CI 連動

repo の `.github/workflows/` には現状 CI なし (要確認)。 task は手動 + sub-agent 経由実行を想定、 CI integration は別 spec で扱う。

### 12.3 Verification gate (NS-8)

| Assert | 内容 |
|---|---|
| `test/unit/release_quality_task_test.rb` | task 3 sub-task が全部 invoke される、 1 個でも fail なら親 task も fail |
| `bundle exec rake apple:release_quality` 単体実行 | exit 0、 全 example 緑、 全 test 緑、 DEFERRED line 0 |

---

## 13. Error handling

| 経路 | 失敗 mode | 挙動 |
|---|---|---|
| `Apple::<Framework>` const_missing | KB に framework 居らへん | `Apple::Knowledge::FrameworkMissing` raise (typed)、 message に `rake apple:knowledge:rebuild` 案内 |
| `Apple::<Framework>.<symbol>` method_missing | KB に symbol 居らへん | `Apple::Knowledge::SymbolMissing` raise、 telemetry record |
| GlueCompiler.compile | template 不可 + LLM 不可 / LLM 6 retry 全 fail | `Apple::Compile::Unsupported` raise、 compile_history record |
| GlueCompiler.compile | swiftc failure | `Apple::Compile::SwiftcFailed` raise、 stderr を error message に圧縮 |
| KnowledgeCache.open | schema mismatch | `Apple::Knowledge::SchemaMismatchError` raise、 案内 message |
| bootstrap! | (no-op) | telemetry deprecation event のみ |
| `Apple.discover` | escape path、 typed 引数不正 | `Apple::Discover::InvalidShape` raise |

すべて typed (memory `No Silent Exception Swallowing`)。 silent rescue 禁止、 named rescue + re-raise or telemetry record only。

---

## 14. Testing strategy 全体

各 phase の verification gate が **golden triangle** (RED → GREEN → REFACTOR の 3 commit シリーズ)。 全 phase 通じて以下を維持:

1. `bundle exec rake test` を **各 phase 末** で subagent 経由実行、 pass count を baseline 比較
2. `test/integration/examples_smoke_test.rb` を各 phase 末で run、 12 example の状態を tracking
3. NS-1 完了後の Knowledge Base rebuild は **screen detached pattern** (memory `~/dev/src/CLAUDE.md` ロングバッチ規律)
4. cache 操作は **rake task 経由** (memory `cache_clear_via_rake_task.md`)

---

## 15. Risks & mitigation

| Risk | 影響 | mitigation |
|---|---|---|
| **clang AST 走査で attribute 取れへん symbol が残る** | NS-1 後も discover 必要な例外が残る | NS-3 の LLM safety net が常に網羅率 100% 保証、 discover は escape hatch として残存 OK |
| **method_missing chain で IRB autocomplete が反応せん** | IRB UX 劣化 | NS-5 で eager-define path を IRB sub-gem に残す (independent install path) |
| **bootstrap! を呼ぶ既存 user コードが壊れる** | semver 違反 | no-op + deprecation telemetry で互換、 v3.0 で正式削除予定 |
| **on-device foundation_model 無し環境で audio_device_count が動かん** | optional dep の境界事故 | NS-3 で typed raise + error message に「`gem "rb-foundation-model-mac"` を Gemfile に追加してください」 |
| **404 既存 test の refactor 影響大** | regress 数十件 | 各 phase 末で `rake test` subagent run、 回帰 1 件でも次 phase に進まない |
| **swift-syntax 移行が NS-1 で重い** | NS-1 が 1-2 d を超える | regex 版を段階 A として暫定維持、 swift-syntax 版は段階 B として並走 (v2.1) |

---

## 16. Boundary (含む / 含まない)

### 16.1 含む

- KB attribute 5 種 ingest + schema bump
- L4 (template_generator / marshallers) の 2 file → 12 file 分解
- L5 (NamespaceBuilder) の 1 file → 6 file 分解
- LLM safety net 復活 (on-device 経由、 optional dep)
- bootstrap! no-op 化 + lazy resolution
- examples 全 refactor (7 example から discover 削除)
- README L52-114 縮約
- `apple:release_quality` rake task

### 16.2 含まない (Out of scope)

- **CI integration** (GitHub Actions workflow 設計) — 別 spec
- **rubygems.org publish process** — 別 spec
- **MCP server 拡張** (search_apple_api / lookup_documentation) — Phase 4 引き継ぎ doc の優先度低カテゴリ、 別 spec
- **HITL emitter improvement tool** (`tooling/`) — 既存運用維持、 変更なし
- **Knowledge Base ingest 速度改善** (50 分 → 30 分) — Phase 2 既達、 別 spec
- **`Apple.discover` の互換削除** — escape hatch として残す、 v3.0 でも削除しない予定

---

## 17. Phasing summary

| Phase | 内容 | 工数 | depends on | verification gate |
|---|---|---|---|---|
| NS-0 | baseline 計測 + compile_history 復活 | 0.5 d | — | 11 example baseline 表 + 3 typed raise で record_attempt |
| NS-1 | KB completeness (5 attribute) | 1-2 d | NS-0 | KB attribute coverage ≥ 95% |
| NS-2 | L4 分解 | 1 d | NS-0 | 404 test maintain + 6+12 emitter/marshaller dir |
| NS-3 | LLM safety net 復活 | 0.5-1 d | NS-2 | audio_device_count.rb 緑 |
| NS-4 | lazy resolution | 0.5-1 d | NS-1, NS-3 | `require` 1 行で Apple::CoreMIDI 動く |
| NS-5 | NamespaceBuilder 解体 | 0.5 d | NS-2, NS-4 | 6 installer file + IRB eager path 緑 |
| NS-6 | examples 全 refactor | 0.5 d | NS-4, NS-5 | examples_no_discover / no_bootstrap GREEN |
| NS-7 | README 整合 | 0.25 d | NS-6 | readme_consistency_test GREEN |
| NS-8 | release_quality task | 0.25 d | NS-7 | `rake apple:release_quality` exit 0 |
| **合計** | | **5-7 d** | | |

---

## Appendix A: 大命題達成の機械検収

NS-8 完了時点で以下が全部 GREEN:

```bash
# A. transparent dispatch
require "apple_sdk_mac"
puts Apple::CoreMIDI.MIDIGetNumberOfSources  # → 0 以上の整数

# B. examples 全緑
bundle exec rake apple:release_quality
# → exit 0

# C. discover 削減率
grep -c 'Apple.discover' examples/*.rb | grep -v ':0$'
# → discover_escape.rb のみヒット (escape demo)

# D. bootstrap! 削減率
grep -c 'AppleSDKMac.bootstrap!' examples/*.rb lib/**/*.rb
# → 0 (lib 側 deprecation 実装の 1 行を除く)
```

これが satisfied されたら L8 literal claim 達成。 v2.0 tag 候補。
