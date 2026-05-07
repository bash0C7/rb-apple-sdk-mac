# irb autocomplete for Apple SDK

**Date:** 2026-05-07
**Status:** design (brainstorming complete, awaiting writing-plans)

## Goal

Apple SDK のクラス / 関数 / 定数 / メソッドを IRB の TAB 補完に対応させ、
TAB で method を確定した瞬間に `Apple.discover` を sync 実行して shape を解決する。
事前宣言ゼロでの探索利用 (Apple SDK を「触って覚える」) を実現する。

## Constraints

- macOS 26+ / Ruby 4.x master / `RUBY_BOX=1` (既存と同条件)
- IRB 起動時のみ activate (lib のテストや non-IRB スクリプトには影響しない)
- LLM 推論を含む discover の同期実行を許容 (UX としてタイムラグ可)
- spinner で進捗を可視化 (Claude Code の `*+*+` 風)
- TDD コミット境界規律 (RED / GREEN / REFACTOR を独立 commit)

## Approach

A1 — sync on-TAB:

```
[input] Apple::Foundation::NSData.dataW<TAB>
   ↓
[CompletionContext.parse]
   ↓
[CandidateProvider]   (KnowledgeCache.list_framework_symbols + prefix filter)
   ↓ user が候補から選択 (確定)
[Spinner.start]       (* + * + 交互、 stderr 100ms 周期)
   ↓
[AutoDiscoverer]      (Apple.discover sync; LLMGenerator が KB から shape 推論)
   ↓
[Spinner.stop + clear line]
   ↓
[cursor 戻る、 method install 済]
```

A2 (bg thread async) と A3 (補完だけ、 discover lazy) は v1 で除外。 A2 は v2 で
incremental 化可能。

## Components

新ファイル `lib/apple_sdk_mac/irb_completion.rb` に集約。

### `AppleSDKMac::IRBCompletion::Context`
`Struct.new(:framework, :klass, :receiver_kind, :prefix)`。 Reline 入力 line を
parse する。

| 入力                                      | framework  | klass     | receiver_kind | prefix       |
|-------------------------------------------|------------|-----------|---------------|--------------|
| `Apple::`                                 | `nil`      | `nil`     | `:apple_root` | `""`         |
| `Apple::Foundation::`                     | `Foundation` | `nil`   | `:module`     | `""`         |
| `Apple::Foundation::NSData.`              | `Foundation` | `NSData`| `:class`      | `""`         |
| `Apple::Foundation::NSData.dataW`         | `Foundation` | `NSData`| `:class`      | `"dataW"`    |
| (proxy instance via `from_ref` 戻り値) | -          | -         | `:proxy_skip` | -            |

`:proxy_skip` は v1 で対象外 (TODO で v2 候補)。

### `AppleSDKMac::IRBCompletion::CandidateProvider`

`call(context)` → `Array<String>`。

- `receiver_kind=:apple_root` → `KnowledgeCache.list_frameworks` (大文字始まり filter)
- `receiver_kind=:module` → kind in `[class, struct, protocol, enum_module, function, swift_func, global_constant, actor]`
- `receiver_kind=:class` → kind in `[objc_method_instance, objc_method_class, swift_init, swift_property, class_method, instance_method]`
- prefix で前方一致 filter (case-insensitive)
- 候補 100 件超は cap (Reline UI 崩れ防止)、 cap 表示マーカは追加しない

### `AppleSDKMac::IRBCompletion::AutoDiscoverer`

`run(context, chosen_name)` で Apple.discover 同期実行。

- 既に install 済 (proxy class または method が defined?) なら no-op
- 未 install:
  - `kind` 別に discover keyword args を組み立て
    - `objc_method_class` → `class_method:`
    - `objc_method_instance` → `selector:`
    - `swift_init` → `swift_initializer:`
    - `swift_property` → `swift_property:` + `instance: true`
    - `function` / `swift_func` / `global_constant` → `symbol:`
    - `class` / `struct` / `protocol` / `enum_module` / `actor` → 既に build! で install 済 (no-op)
  - `params:` / `return_kind:` は **指定しない** (TemplateGenerator → LLMGenerator 経路で推論)
- 失敗時は stderr に `discover failed: <error>` を出し、 例外は呑まない (再 raise)

### `AppleSDKMac::IRBCompletion::Spinner`

- `start(message)`: Thread を起こして `frames = %w[* +]` を 100ms 周期で stderr に
  `\r{frame} {message}` 形式で出す
- `stop`: Thread.kill + `\r\033[K` で line clear
- `STDERR.tty?` が false なら全 no-op (smoke / pipe redirect で汚れない)
- thread で uncaught exception が出たら親に伝播 (`Thread.report_on_exception = true` 既定)

### Reline hook

`Reline.completion_proc` を wrap:

```ruby
original = Reline.completion_proc
Reline.completion_proc = ->(input) {
  context = Context.parse(input)
  if context && context.receiver_kind != :proxy_skip
    CandidateProvider.call(context)
  else
    original ? original.call(input) : []
  end
}
```

確定 (perfect-match) hook は `Reline.dig_perfect_match_proc`:

```ruby
Reline.dig_perfect_match_proc = ->(target) {
  context = Context.parse(target)
  return unless context
  Spinner.start("discovering #{context.framework}::#{context.klass}.#{context.prefix}...")
  begin
    AutoDiscoverer.run(context, context.prefix)
  ensure
    Spinner.stop
  end
}
```

## Data Flow (e2e)

```
> Apple::Foundation::NSData.<TAB>
  Reline → completion_proc → CandidateProvider
  → ["dataWithContentsOfFile", "dataWithContentsOfURL", "length", "bytes", ...]

> Apple::Foundation::NSData.dataWithContentsOfFile<TAB>
  Reline → dig_perfect_match_proc fires
  → Spinner.start("discovering Foundation::NSData.dataWithContentsOfFile...")
  → AutoDiscoverer.run
    → Apple.discover(framework: :Foundation, klass: :NSData,
                     class_method: "dataWithContentsOfFile:")
    → TemplateGenerator (KB から shape)
    → LLMGenerator fallback if needed
    → ValidationGates → swiftc compile → dlopen
  → Spinner.stop
  cursor 戻る

> Apple::Foundation::NSData.dataWithContentsOfFile("/path/to/file")
  ↑ install 済、 即実行
```

## Error Handling

- AutoDiscoverer 失敗 → Spinner.stop して stderr に error 表示、 例外を re-raise
- Spinner Thread の例外 → `Thread.report_on_exception` で親に伝播
- 非-IRB / Reline 不在 → no-op (require はするが hook はしない)
- KnowledgeCache 未初期化 → `AppleSDKMac.knowledge_cache` の遅延初期化に乗る
- discover タイムアウト未設定 (LLMGenerator 側のタイムアウトに従う、 v1 では追加制御なし)

## Testing Strategy

### Unit (TDD RED+GREEN)

| ID       | RED test                                              | GREEN impl                          |
|----------|-------------------------------------------------------|-------------------------------------|
| T_irb1   | `Context.parse` が 5 種の入力で正しい struct を返す   | `irb_completion.rb` に `Context.parse` |
| T_irb2   | `CandidateProvider.call` が module/class context で適切な kind フィルタ | `CandidateProvider.call`           |
| T_irb3   | `Spinner.start/.stop` が StringIO に frame シーケンスを書く (tty mock) | `Spinner` class                    |
| T_irb4   | `AutoDiscoverer.run` が install 済で no-op、 未 install で Apple.discover を呼ぶ (mock) | `AutoDiscoverer.run`               |
| T_irb5   | Reline completion_proc wrap が Apple:: と他 path を分離 | `IRBCompletion.install!`           |

### Integration / smoke

| ID       | テスト                                                 |
|----------|--------------------------------------------------------|
| T_irb6   | `examples/irb_completion_demo.rb`: PTY で `Apple::Foundation::NSData.dataW` + TAB をシミュレートして候補取得 + 確定経路で Apple.discover が走り proxy method が install されたことを assert |
| T_irb7   | smoke (`rake test`) 全 GREEN 維持                      |

### LLM mock 戦略

unit (T_irb4) では LLMGenerator は stub に差し替えて Apple.discover の呼び出し有無
だけを検証。 LLM 推論の正しさは既存 LLMGenerator test (T56 系) でカバー。

## Implementation Order

```
T_irb1 RED → GREEN  : Context.parse
T_irb2 RED → GREEN  : CandidateProvider.call
T_irb3 RED → GREEN  : Spinner.start/.stop
T_irb4 RED → GREEN  : AutoDiscoverer.run
T_irb5 RED → GREEN  : IRBCompletion.install! (Reline hook)
T_irb6 GREEN        : examples/irb_completion_demo.rb (release-quality demo)
T_irb7 GREEN        : README L36 に「IRB autocomplete」 セクション追記
```

各 RED / GREEN は独立 commit (CLAUDE.md 規律)。 推定 14-16 commit。

## File Layout

```
lib/apple_sdk_mac/
  irb_completion.rb              (新規, ~250 LoC)
  apple_sdk_mac.rb 経由で auto-require (irb 検出時)

test/
  irb_completion/
    context_test.rb              (T_irb1)
    candidate_provider_test.rb   (T_irb2)
    spinner_test.rb              (T_irb3)
    auto_discoverer_test.rb      (T_irb4)
    install_test.rb              (T_irb5)
  integration/
    irb_completion_demo_test.rb  (T_irb6)

examples/
  irb_completion_demo.rb         (T_irb6, release-quality demo)

README.md                        (T_irb7 追記)
```

## Out of Scope (v2 候補)

- proxy instance receiver (`x = Apple::Foundation::NSData.from_ref(p); x.<TAB>`) の補完
- 候補ランキング (LLM による文脈推論)
- inline doc panel (signature / documentation を Reline message panel に出す)
- async bg discover (A2 アプローチ)
- deprecated / availability フィルタ

## Open Questions

なし (brainstorming で全部解決)。
