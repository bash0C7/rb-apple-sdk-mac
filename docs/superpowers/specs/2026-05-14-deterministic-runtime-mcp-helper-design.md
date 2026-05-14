# Deterministic Runtime + MCP Helper Design

Date: 2026-05-14
Status: Draft (pending user review)
Branch: `feature/eliminate-claude-swift-trial-and-error`

## 0. 命題と非命題

### 命題 (load-bearing)

1. **README L8 「any public Apple framework API」 を保全する。** Apple SDK の public framework public API は、 全 pattern が gem 内で deterministic に解決される。
2. **`require "apple_sdk_mac"` のみで動く。** `bootstrap!` / `Apple.discover` の事前呼び出しを user は要しない。 user は `Apple::<Framework>.<API>(args)` を Ruby のいつもの書き方でいきなり書ける。
3. **Knowledge Base miss / kind 推論失敗 / glue compile 失敗 は gem 不具合扱い。** Importer / emitter / dispatcher の完成度向上で潰す。 release-quality gate は全 framework 代表 symbol の smoke test green。
4. **実行時 LLM 動的 fallback は無い。** Foundation Models on-device の確率的 path は runtime から削除。 確率性は dev-time helper (MCP) に逃がす。
5. **gem の MCP 機能利用には Xcode フル install を推奨する。** SDK reference 提供 (docc archive) のため。 gem の runtime path 自体は Command Line Tools のみで動く (現状互換)。

### 非命題 (廃止 / 制約)

- 実行時 Foundation Model 動的 glue 生成 (廃止)
- `bootstrap!` の必須化 (no-op alias として残置、 optional pre-warm)
- gem 実行時の Xcode フル install 強制 (CLT only でも動く)
- 動的 raw web scraping (MCP 経由のみ + allow list + rate limit + robots.txt)

### 構造的に raw glue 化が技術的に不能な pattern (例外)

以下 7 pattern は static rule 例外として KB importer が marker 付与、 emitter / dispatcher は raise (rich diagnostic + workaround hint)。 user (AI 含む) は MCP query で workaround を検討し、 自前 Swift package 等で wrapping。

| Pattern | Reason | User workaround |
|---|---|---|
| Swift macro (`@Observable` 等) | compile-time 展開、 dylib symbol 無し | Swift package で wrapper export |
| Result builder DSL (SwiftUI ViewBuilder, RegexBuilder) | syntactic transformation | Swift package wrapping |
| Function-like C macro (`CGRectMake` 等) | preprocessor 展開、 dylib symbol 無し | Foundation 経由 struct init、 無ければ Swift package |
| Inline-only header function (`static inline`) | dylib symbol 無し | Swift package で re-export |
| C++ pure API | C++ ABI 未対応 | Objective-C++ wrapper |
| `some Protocol` opaque return | runtime type erasure | concrete return type を expose する Swift wrapper |
| Sendable conformance check | compile-time only | gem 範囲外、 user 側で確保 |

---

## 1. Section 1 — Lazy transparent namespace

`Apple` Box に const_missing / method_missing 2 段仕掛けで完全 lazy。 `bootstrap!` は no-op alias として残置 (eager pre-warm 用途、 deprecated)。

### 1.1 const_missing chain

- `Apple::<Framework>` 初回アクセス
  - KB の `frameworks` row lookup
  - hit → namespace `Module` を install (子 symbol は eager install せず lazy)
  - miss → `AppleSDKMac::FrameworkMissingError` raise (rich diagnostic)

- `Apple::<Framework>::<Type>` 初回アクセス
  - KB の `lookup_klass_method` 経路で type symbol lookup
  - hit → proxy `Class` install (前 session の canonical factory `namespace_builder.build_proxy_class` 流用)
  - miss → `AppleSDKMac::SymbolMissingError`

### 1.2 method_missing chain

- `Apple::<Framework>.<API>(args)` 初回 call
  - KB の `lookup_symbol` 経路で symbol lookup
  - hit + kind が deterministic → glue compile + invoke → 同名 method 定義 (2 回目以降 method_missing 経由せず direct dispatch)
  - hit + kind が `unsupported_pattern` → `AppleSDKMac::UnsupportedPatternError` raise
  - miss → `AppleSDKMac::SymbolMissingError` raise

### 1.3 影響範囲

- `lib/apple_sdk_mac.rb`: `Apple` Box に const_missing / method_missing 配線
- `lib/apple_sdk_mac/namespace_builder.rb`: eager install path は維持 (`bootstrap!` 経路で使う)、 lazy install path を主流に
- `lib/apple_sdk_mac/dispatcher.rb`: lookup miss 時の経路を「LLM fallback」 → 「raise with diagnostic」 に変更
- `lib/apple_sdk_mac.rb` の `bootstrap!`: no-op alias 化 (実体は eager install ループを呼ぶ optional pre-warm)

---

## 2. Section 2 — Knowledge Base schema 拡張

SCHEMA_VERSION 7 → 9 bump。 前 session の bump 候補 (effect flags) を含む。

### 2.1 追加 column

| Column | Type | Nullable | 用途 |
|---|---|---|---|
| `is_throws` | Integer (0/1) | NOT NULL DEFAULT 0 | Swift `throws` / ObjC `NSError **` bridge |
| `is_async` | Integer (0/1) | NOT NULL DEFAULT 0 | Swift `async` |
| `is_failable` | Integer (0/1) | NOT NULL DEFAULT 0 | Swift `init?` |
| `is_settable` | Integer (0/1) | NOT NULL DEFAULT 0 | Property readwrite (setter glue 用) |
| `return_ownership` | TEXT | NULL | `retained` / `unretained` / `unspecified` |
| `throws_error_type` | TEXT | NULL | Swift `throws(MyError)` の error type、 不明時 NULL → fallback `RuntimeError` |
| `callback_signature_json` | TEXT | NULL | `{params: [{type:..., nullable:...}], return_type:...}` |
| `enum_cases_json` | TEXT | NULL | enum / OptionSet の case 列挙 |
| `unsupported_pattern` | TEXT | NULL | static rule 例外 marker (`swift_macro` / `result_builder` / `inline_only` / `function_macro` / `cpp_pure` / `opaque_protocol` 等) |

### 2.2 既存 column の structure 拡張

- `parameters_json`: 要素 schema を拡張
  - 現状: `{name, kind, ...}`
  - 拡張後: `{name, external_label, internal_name, type, kind, nullable, default_value, is_out_param}`
  - `external_label`: Swift method の external label (`init(forReading url:)` の `forReading`)
  - `internal_name`: Swift method の internal name (`url`)
  - `nullable`: `_Nullable` / Swift Optional の per-element flag
  - `default_value`: リテラル値のみ (`String.Encoding.utf8` 等の literal は capture、 complex expression は NULL)

### 2.3 SCHEMA_VERSION bump 効果

- 既存 `<project>/.rb-apple-sdk-mac/knowledge/*.sqlite` は migrate! の `schema_meta.value` 不一致で次回 rebuild 必要
- `apple:knowledge:rebuild` / `apple:knowledge:rebuild_async` で SCHEMA_VERSION 9 schema として regenerate

---

## 3. Section 3 — Importer 拡張

### 3.1 clang_objc importer

`knowledge/lib/rb_apple_sdk_knowledge/importer/` 配下 (現状 clang AST 経由)

- `_Nullable` / `_Nonnull` attribute → `parameters_json[].nullable`
- `cf_returns_retained` / `NS_RETURNS_RETAINED` → `return_ownership = "retained"`
- typed block signature (`^(NSError * _Nullable err)`) → `callback_signature_json`
- `static inline` 検出 → `unsupported_pattern = "inline_only"` marker、 symbol は KB に登録 (call 時 raise する用)
- function-like macro (`#define CGRectMake(...) ...`) → `unsupported_pattern = "function_macro"` marker

### 3.2 swift_overlay importer

`knowledge/lib/rb_apple_sdk_knowledge/importer/swift_overlay.rb` (前 session の effect modifier 拡張済)

- 引数の external label / internal name 2 種 capture (`init(forReading url:)` の `forReading` と `url`)
- generic type args (`func decode<T>(_:)`) → kind は `generic_func`、 `type_args_required: true` marker
- default value (`encoding: String.Encoding = .utf8`) → literal なら capture、 complex は NULL
- Optional 階層 (`URL??`) の正確 capture
- enum cases 列挙 (`case create / .createAndPrepend`) → `enum_cases_json`
- readwrite flag (`var x: Int { get set }`) → `is_settable = 1`
- Swift macro / result builder usage 検出 → `unsupported_pattern` marker

### 3.3 broader framework

memory `feedback_swift_overlay_importer_broad` の路線完遂。 現状 AVFAudio 等限定 → 主要 framework 全部:

- Foundation / AppKit / SwiftUI / Metal / SceneKit / RealityKit / Vision / CoreML / MapKit / AVFoundation / Combine / OSLog / 他 macOS public framework 全部

`apple:knowledge:rebuild_async` で 50+ 分。 importer の robustness は CI で全 framework rebuild green を gate にする。

---

## 4. Section 4 — Emitter completeness

`lib/apple_sdk_mac/glue_compiler/template_generator.rb` を KB metadata 全消化に書き換え。 signature 文字列 parse / naming heuristic / 手書き route map を全廃。

### 4.1 廃止する heuristic

| 廃止 | 置換 |
|---|---|
| `initializer.include?("throws")` | KB record `is_throws` column |
| `initializer.include?("?")` | KB record `is_failable` column |
| `symbol[:async] == true` (Hash 由来) | KB record `is_async` column |
| `cf_create_naming?(name)` 正規表現 | KB record `return_ownership` |
| `CALLBACK_PILLAR_ROUTES` 手書き route map | KB record `callback_signature_json` 由来 auto-route |
| signature 文字列 regex (`return_kind`) | KB record `return_type` + kind |
| `swift_init_labels(initializer)` 文字列 split | KB record `parameters_json[].external_label` |
| `try? else Qnil` silent swallow | KB record `throws_error_type` → Ruby exception class map |

### 4.2 Ruby exception class map

| KB 値 | Ruby exception class | message |
|---|---|---|
| `throws_error_type` 未設定 (NULL) | `AppleSDKMac::SwiftError` (`StandardError` 子) | swiftc から伝播した Swift error の `localizedDescription` |
| `throws_error_type = "NSError"` (ObjC bridge) | `AppleSDKMac::ObjcError` (`StandardError` 子) | NSError の `localizedDescription` + `code` + `domain` |
| `throws_error_type = "<Concrete>"` (Swift typed throws、 v1.x phase 2) | 当面 `AppleSDKMac::SwiftError` で統一 (concrete type 別 class の dispatch は phase 2) | 同上 + concrete type name を message に embed |

設計上の mapping table 維持コストを抑えるため、 phase 1 は `SwiftError` / `ObjcError` の 2 種だけで完結させる。 phase 2 で concrete error type → 専用 Ruby class の dispatch を追加する余地は schema 側に残す (`throws_error_type` column が concrete type 文字列を保持済)。

### 4.3 setter glue

`is_settable = 1` の property に対して `Apple::<F>::<Type>#<prop>=(val)` の Ruby method を install。 emitter は getter / setter ペアで glue 生成。

### 4.4 callback auto-route

`callback_signature_json` を読んで runtime_callback_pillar_register_* route name を生成。 phase 1 (本 spec scope):

1. emitter は KB record の callback signature shape を hash key 化 (例: `"(URL,Error?)->Void"` 等の正規形)
2. `CALLBACK_PILLAR_ROUTES` (現状の手書き Hash) を route 一覧の source とし、 hash key で lookup
3. lookup hit → 既存 register/get_fnptr 経路 (現状 MIDINotifyProc 統合) で route
4. lookup miss → `unsupported_pattern = "callback_signature_unregistered"` 扱い、 Section 5 経路で raise (rich diagnostic + 「`ext/apple_sdk_mac_runtime/` に該当 signature の register/get_fnptr を追加すれば対応可能」 hint)

phase 2 (本 spec scope 外): callback signature 由来で `ext/apple_sdk_mac_runtime/` 内の register/get_fnptr 函数 + Marshaller route map を auto-generate。 ただし phase 1 の手作業追加 path は smoke test で発見された signature shape を 1 つずつ pillar route に手追加する progressive enhancement で対応可能。

---

## 5. Section 5 — Static rule 例外検出

KB importer が `unsupported_pattern` marker を付与 (Section 3 参照)。 emitter / dispatcher は marker 検出時:

- `emit_*` family が早期 return nil (現状) → 代わりに raise `AppleSDKMac::UnsupportedPatternError` (with marker name + rich context)
- dispatcher は emitter の raise を捕捉せず user 経路まで propagate (silent swallow 禁止、 memory CLAUDE.md rule 「No Silent Exception Swallowing」)

---

## 6. Section 6 — Rich diagnostic surface

KB miss / unsupported / compile fail で sane diagnostic + workaround hint + MCP query suggestion 出す。

### 6.1 Exception class hierarchy

```
AppleSDKMac::Error (StandardError)
├─ AppleSDKMac::FrameworkMissingError       # Apple::<F> の F が KB に無い
├─ AppleSDKMac::SymbolMissingError          # F.<S> の S が KB に無い
├─ AppleSDKMac::UnsupportedPatternError     # KB に `unsupported_pattern` marker あり
├─ AppleSDKMac::GlueCompileError            # emitter は通ったが swiftc 失敗
├─ AppleSDKMac::ObjcError                   # ObjC NSError bridge 由来
└─ AppleSDKMac::SwiftError                  # Swift typed throws 由来
```

### 6.2 Diagnostic message 形式

例:
```
AppleSDKMac::UnsupportedPatternError:
  Symbol 'Foundation::Observable::someMethod' uses Swift @Observable macro.

  Pattern: swift_macro
  Framework: Foundation
  macOS SDK: 26.0
  gem version: 1.x
  Knowledge Base schema: 9

  Workaround:
    1. Create a Swift package wrapping the macro-generated API as a public func.
    2. Add the wrapper framework to your Knowledge Base via `apple:knowledge:add-framework`.
    3. Or use MCP: mcp.suggest_wrapper_template(framework: "Foundation", symbol: "Observable")

  Report at https://github.com/bash0C7/rb-apple-sdk-mac/issues if you believe
  this should be supported.
```

KB miss / compile fail も同 shape (Section 内容 + workaround + MCP query)。 user (AI 含む) はこの message から workaround コードを生成可能。

### 6.3 Internal telemetry (opt-in)

`~/.cache/rb-apple-sdk-mac/diagnostics/<date>.jsonl` に failure event を append。 opt-out env (`APPLE_SDK_MAC_NO_DIAGNOSTICS=1`) で disable。 gem 自己改善のための statistics、 user PII は含まへん。

---

## 7. Section 7 — MCP server NL search + lookup_symbol 拡張

`mcp/` sub-gem 既存 endpoint に追加:

| Endpoint | 用途 |
|---|---|
| `mcp.search_apple_api(natural_language, framework: nil, limit: 5)` | fuzzy + semantic search (KB symbols_fts 経由) |
| `mcp.lookup_symbol(framework, symbol)` | KB record 全 column 構造化 return + documentation embed |
| `mcp.generate_ruby_snippet(framework, symbol, args_hint: nil)` | `Apple::<F>.<S>(args)` の Ruby template、 args の型注釈付き |
| `mcp.suggest_related(framework, symbol)` | related symbol cluster (例: MIDIClientCreate → MIDIPortCreate / MIDISend) |
| `mcp.suggest_wrapper_template(framework, symbol)` | unsupported_pattern 用 Swift package wrapper template (snippet) |

既存 `mcp.search` / `mcp.stats` / `mcp.suggest_discover_call` は維持。

---

## 8. Section 8 — MCP server lookup_documentation (chain)

`mcp.lookup_documentation(framework, symbol)` を新規 endpoint。 fallback chain:

1. **KB `documentation` column** (ObjC framework 由来、 即時 return、 source=kb)
2. **Xcode 同梱 docc archive** (Xcode フル install 推奨)
   - `xcode-select -p` から path 解決 (`/Applications/Xcode.app/Contents/Developer`)
   - `find $DEVDIR -maxdepth 6 -name "*.doccarchive"` で発見
   - docc archive 内 `data/documentation/<framework>/<symbol>.json` を直接 parse
   - source=docc
3. **developer.apple.com web fetch** (Section 9 経由、 cache miss 時のみ、 source=web)
4. **fallback**: source=missing で sane response、 client に「user 側で対処」 と伝える

Response shape:
```json
{
  "source": "kb"|"docc"|"web"|"missing",
  "text": "...",
  "url": "https://developer.apple.com/documentation/...",
  "cached_at": "2026-05-14T12:34:56Z"
}
```

---

## 9. Section 9 — MCP web fetch infrastructure

`mcp/lib/.../web_fetch.rb` (新規)

### 9.1 Allow list (固定)

初期:
- `developer.apple.com`
- `swift.org/documentation`

それ以外のドメインは fetch 拒否 (`out_of_allowlist` response)。 user は ローカルで自前 fetch (curl / Ruby script / IRB) で対処。

### 9.2 Rate limit

- domain 単位、 mutex 経由
- 1 fetch / 2 秒 (1 query/2s = 30 query/min)
- 連続 fetch 要求は queue 化、 待機 (synchronous block)

### 9.3 robots.txt 遵守

- `robotex` gem (or 同等) で UA `rb-apple-sdk-mac-mcp/<version>` に対する allow/disallow 確認
- disallow path は fetch 拒否
- robots.txt 自体の cache: domain 単位 24 時間 TTL

### 9.4 User-Agent

`rb-apple-sdk-mac-mcp/<version> (+https://github.com/bash0C7/rb-apple-sdk-mac)`

### 9.5 Cache

- path: `$XDG_CACHE_HOME/rb-apple-sdk-mac/docs-cache/<sha1(url)>.json`
- format: `{url, fetched_at, body, status, headers}`
- TTL: 90 日
- offline degradation: network unreachable → cache hit すれば return、 miss なら source=missing

### 9.6 HTML parse

- `Nokogiri` で `developer.apple.com/documentation/...` の本文 (article > section.description) を抽出
- HTML structure 変動 fragile → fetcher 内 parse はベストエフォート、 fail 時は raw HTML を `text` field に詰めて返す (client 側で対処可能に)

---

## 10. Section 10 — IRB autocomplete (既存延長)

`irb/` sub-gem 既存実装は lazy namespace 化に伴い再確認:

- 既存 reline completion hook は KB lookup 経由で frameworks / types / methods 列挙、 eager namespace install に依存してへん → lazy 化しても動く前提
- `:show_doc` は 現状 KB `documentation` column 直叩き → MCP `lookup_documentation` 経由化 (docc / web fallback を享受)
- `:show_doc` は MCP server が起動してへん環境でも KB column fallback で動く (graceful degradation)
- prefetch (既存) は `Apple.discover` 経由を `Apple::<F>::<S>` reference に置換 (lazy namespace path を hit させる)

---

## 11. Section 11 — release_quality_smoke_test

`test/integration/release_quality_smoke_test.rb` (新規)

### 11.1 Test shape

- 全 framework から代表 symbol N 個 (各 framework 5-10 個程度) を pick
- lazy namespace path で smoke call (`Apple::<F>.<S>` reference + 引数渡し)
- assertion: 例外 raise しないこと、 expected 型の戻り値

### 11.2 Failure mode

- KB miss / kind 推論失敗 / unsupported (期待外) → RED test
- → importer / emitter / dispatcher のどれか修正
- 全 framework green になるまで release-quality gate 通らへん

### 11.3 CI gate

- GitHub Actions or Mac mini CI で nightly rebuild + smoke test
- green じゃないと release tag 切らへん (v1.x policy)

### 11.4 Coverage

- macOS public framework 50+
- 各 framework から:
  - top-level function 2-3 個 (C function 経路)
  - class method 2-3 個 (ObjC class method 経路)
  - instance method 2-3 個 (ObjC instance method 経路、 receiver 必要)
  - init 2-3 個 (Swift init 経路)
  - property 1-2 個

合計 250-500 smoke case 想定。 cache 後は数十秒で全 pass する想定。

---

## 12. Section 12 — README 修正

- L8 「any public Apple framework API」: 維持
- L52-62 「Recommended: bootstrap once, call freely」 → 「Recommended: just call freely」 (`bootstrap!` を optional pre-warm 化)
- L82-110 `Apple.discover` 章: 「Knowledge Base 分類 override」 / 「私的 framework」 / 「pre-warm」 のみ残す、 「KB に無い public framework symbol」 のケースは「gem bug 扱い、 issue 報告 + MCP query で workaround 検討」 に文言変更
- 新章: 「MCP server (dev-time helper, Xcode フル install 推奨)」 追加
  - mcp endpoints 一覧
  - allow list + rate limit + robots.txt 言及
  - Xcode フル install 不要 (CLT only) でも MCP 起動可能、 ただし docc fallback 経路は disabled

---

## 13. Implementation 順序

依存関係に従って:

1. **Section 2** schema 拡張 (SCHEMA_VERSION 9 bump)
2. **Section 3** importer 拡張 (clang + swift overlay、 broader framework)
3. **Section 11** release_quality_smoke_test の skeleton (initial RED 多数)
4. **Section 4** emitter completeness (KB metadata 全消化、 heuristic 廃止)
5. **Section 5 / 6** static rule 例外 + rich diagnostic surface
6. **Section 1** lazy transparent namespace (`bootstrap!` 不要化)
7. **Section 7 / 8 / 9** MCP server 拡張
8. **Section 10** IRB autocomplete 確認 + show_doc 経由化
9. **Section 12** README 修正
10. **Section 11** smoke test を全 framework green まで importer / emitter / dispatcher loop

各 step は TDD (RED → GREEN → REFACTOR)、 commit 単位は小さく (1 logical change / commit)、 主要 milestone で PR merge candidate 化。

---

## 14. TDD policy

各 commit:
1. RED: failing test を先に書く (skipping は禁止、 omit は理由可視化のみ)
2. GREEN: minimal production code で pass
3. REFACTOR: 必要時 cleanup、 test 全 green 維持
4. 全 suite (main gem + knowledge sub-gem + mcp sub-gem + irb sub-gem) green
5. commit message Conventional Commits (feat / fix / chore / docs / test / refactor)、 Co-Authored-By: Claude Opus 4.7

superpowers:test-driven-development に従う。

---

## 15. Branch & merge policy

- 現 branch `feature/eliminate-claude-swift-trial-and-error` を継続使用、 または新派生 branch (`feature/deterministic-runtime`)
- main 直 push は user handoff (memory rule)
- 主要 milestone (Section 単位完了) で local PR-style review 経由
- v1.x release tag は release_quality_smoke_test 全 framework green が gate

---

## 16. 長期改善 / project core thesis との整合

memory:
- `project_core_thesis_long_term_improvement`: 長期改善 + 安全確実な継続実行
  - **確率性排除** (実行時 LLM 削除) → 「安全確実な継続実行」 に直接効く
  - **importer coverage 拡大** → 「長期改善が組み込まれた状態」 に直接効く
- `feedback_no_claude_swift_writes`: gem は LLM safety-net or KB 自動生成 → 今回 LLM 自体廃止、 KB 100% に振る方針はより radical な long-term solution
- `feedback_gem_internal_encapsulation`: cloud LLM gem 公開 path に置かへん / on-device only → on-device LLM すら runtime から削除、 dev time MCP に逃がす
- `release_quality_completion_required`: DEFERRED 逃避禁止 → smoke test 全 framework green が release gate、 後退選択肢無し

---

## 17. Open items (spec 確定後、 writing-plans skill で詳細化)

- Section 4 setter glue の Ruby 側 syntax (`obj.prop = val` で `__opaque_ref` をどう receive) — Phase 2 で確定
- Section 9 robots.txt 遵守 gem 選定 (`robotex` 維持、 メンテ状況確認) — Phase 4 で確定
- Section 11 各 framework 代表 symbol の具体 list (smoke test scaffold で fixture 化) — Phase 5 で確定
- Section 8 docc archive の data/documentation JSON schema バージョン依存性 (Xcode version 互換性) — Phase 4 で確定

これらは spec 承認後、 writing-plans skill が出す implementation plan で詰める。

### Phase 1 結果 (2026-05-14 完了)

- [x] SCHEMA_VERSION 9 bump 完了、 既存 cache は migrate 経由 invalidate 動作確認 (T1)
- [x] clang importer の `_Nullable` / `cf_returns_retained` / typed block / static inline / function macro capture 全 fixture test green (T3-T7)
- [x] swift_overlay importer の effect flags / labels / default values / Optional / enum cases / `is_settable` / macro marker capture 全 test green (T8-T15)
- [x] KnowledgeCache `lookup_symbol` / `lookup_klass_method` 戻り Hash に Phase 1 metadata expose (T16)
- [x] `apple:knowledge:rebuild_async` smoke run で全 framework re-import、 stats 退行無しを確認 (T17、 commit 1127277 で `Pipeline#insert_one` の metadata pass-through 漏れを fix)

最終 KB stats (sdk_knowledge_26.4.1):
- total symbols: 163,541
- `is_throws=1`: 1,438 / `is_async=1`: 440 / `is_failable=1`: 127 / `is_settable=1`: 748
- `return_ownership IS NOT NULL`: 232
- `callback_signature_json IS NOT NULL`: 10,640
- `enum_cases_json IS NOT NULL`: 761
- `unsupported_pattern IS NOT NULL`: 3,290
- `throws_error_type IS NOT NULL`: 0 (Apple SDK は untyped throws のみ採用、 想定内)

### Phase 2 開始時に再点検する Phase 1 backlog

Phase 1 implementation で発見した edge case を Phase 2 で再評価:

- T3: `ObjCCategoryDecl` の `parent_name` に category 名が入る latent bug (multi-category 環境で衝突予想)
- T3: Consolidator hash strategy と `clang_objc.rb` 直 path の content_hash salt 不一致 (production rebuild では Consolidator 経由のみ、 直 path はテスト専用)
- T5: callback signature の nested paren / generic comma split が fragile (`NSDictionary<NSString *, id> *` 等で word-boundary 誤判定の可能性)
- T9: swift parameter label の inline doc comment + `@attribute` interleave 経路は現状 lookback 未対応
- T10: swift string literal の escape-quote (`"foo\"bar"`) は現状 regex で誤 split の可能性
- T11: swift IUO of Optional (`URL!?`) の edge case test 未追加
- T12: swift nested enum 内側 / case payload with closure type の brace edge case
- T14: swift macro doc comment + `@Observable` interleave 経路の preceding_attrs_for 拡張余地

(以下 phase 2 / 3 / 4 / 5 の open items は既存記述のまま継続)
