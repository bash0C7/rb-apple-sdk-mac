# 2026-05-08 IRB Sub-gem + LLM Doc Preview + Auto-discover Trigger Design

## 0. Status

**APPROVED** (2026-05-08) — 全 4 decision points 確定:
- A1: 専用 irb/ サブディレクトリ
- B2: KB importer 拡張で公式 source 取り込み
- C: LLM cache 不採用 (B2 で documentation 直引き、 LLM fallback も初期不採用)
- D1: popup hover で silent background prefetch

## 1. Background

`feature/irb-autocomplete` で IRB autocompletion を実装したが、 以下 3 つの未解決事項:

1. **アーキテクチャ汚染**: 現状 `lib/apple_sdk_mac.rb` が IRB 検出時に `irb_completion.rb` を auto-require、 main gem に IRB / LLM / repl_type_completor 依存が混入。 「メイン Ruby から Apple SDK を呼び出す世界」 と 「IRB 拡張の世界」 を分離したい (user 2026-05-08)。
2. **doc preview 不在**: `:show_doc` dialog (popup 右側 hover doc) は RDoc 7.2 + Ruby 4.0 の Marshal 非互換で `RDoc::Store#load_class_data` が落ちる。 現在 no-op で抑止してるが、 Apple SDK symbol について本来見たい doc が出ない。
3. **auto-discover trigger 死亡**: 元仕様 「TAB 二回で `dig_perfect_match_proc` 経由 auto-discover」 は `Reline.autocompletion=true` 環境では `complete(_key)` が `move_completed_list` ルートに分岐するため `perform_completion` を経ず、 `dig_perfect_match_proc` は **絶対呼ばれない** (line_editor.rb:1292-1307)。 spinner が出ない root cause。

## 2. Goals

- IRB / LLM / autocomplete 関連を main gem から構造的に分離 (sub-gem 化)。
- popup hover した Apple SDK symbol について doc 表示できる (RDoc 経由でなく KB + LLM 経由)。
- popup から候補選択ライン上で auto-discover が走り、 IRB の eval が呼んだ瞬間には glue 完成済みの状態にする (silent prefetch)。

## 3. Architecture: Internal sub-gem layout

memory `feedback_irb_subgem.md` に従い、 同 repo 内 / 別 gemspec / 外部 publish 無し。

### Decision A — directory layout (要 user 選択)

- **A1 (推奨)**: 専用サブディレクトリ
  ```
  rb-apple-sdk-mac/
  ├── apple_sdk_mac.gemspec        # main gem (no IRB deps)
  ├── lib/apple_sdk_mac/...        # main code
  ├── test/...                     # main tests
  ├── irb/                         # ← logical sub-gem
  │   ├── apple_sdk_mac-irb.gemspec
  │   ├── lib/apple_sdk_mac/irb.rb
  │   ├── lib/apple_sdk_mac/irb/{completion,doc,prefetch,...}.rb
  │   └── test/...
  └── Gemfile (development_dependencies → path: "irb")
  ```
  - 完全分離。 sub-gem ディレクトリだけ見れば独立 gem として読める。
  - 将来外部 publish 時の摩擦小。

- **A2**: lib/ 同居 + 別 gemspec
  ```
  lib/apple_sdk_mac/...               # main
  lib/apple_sdk_mac/irb/...           # IRB code (同じ require root)
  apple_sdk_mac.gemspec               # 既存、 IRB deps 削除
  apple_sdk_mac-irb.gemspec           # 新規、 files = lib/apple_sdk_mac/irb/**
  test/irb/...                        # IRB test 置き場
  ```
  - 移行作業少。 gemspec の `files` glob で切り分け。
  - require root が混在するので「論理的別 gem」感が弱い。

### Decision A 推奨: **A1**

「論理的別 gem」要件 (user 2026-05-08) との適合度で勝る。 移行コストは A2 より高いが、 既存 ファイル数は限定的 (`irb_completion.rb` 1 本 + test/irb_completion/ 5 本)。

### Sub-gem 構成案 (A1 ベース)

- `irb/apple_sdk_mac-irb.gemspec`
  - `add_dependency "apple_sdk_mac", path: ".."`
  - `add_dependency "rb-foundation-model-mac", "~> X"`
  - `add_dependency "irb", "~> 1.18"`
  - `add_dependency "reline", "~> 0.6"`
  - `add_dependency "repl_type_completor"`
- `irb/lib/apple_sdk_mac/irb.rb` — entry point、 `AppleSDKMac::IRB.install!` などを公開
- main `lib/apple_sdk_mac.rb` から IRB 関連 require 削除、 `AppleSDKMac::IRBCompletion.install!` 呼び出しも削除
- main `apple_sdk_mac.gemspec` から `repl_type_completor` 削除 (Gemfile も同様)
- main `test/irb_completion/` ディレクトリは `irb/test/` へ移動

## 4. Phase 1: LLM doc preview

### 4.1 Trigger

`Reline.add_dialog_proc(:show_doc, ..., DEFAULT_DIALOG_CONTEXT)` で popup の右側 dialog をフック。 popup の `:autocomplete` dialog で hover している candidate を取得 → Apple SDK 形式判定 → KB 引き → doc 生成 → DialogRenderInfo 返却。

dialog_proc 実装側で `context.pop(4)` から `[cursor_pos_to_render, result, pointer, autocomplete_dialog]` を取れる (input-method.rb:353 と同等)。 `result[pointer]` が hover candidate。

### 4.2 Doc 生成戦略

#### Decision B — doc source

KB の `documentation` 列は **全 0 バイト** (importer が SymbolGraph の doc コメント取り込んでない事実 2026-05-08 確認)。

**確定**: **B2** — KB importer 拡張で公式 source 取り込み (user 2026-05-08)

- 理由
  - **確実性**: SymbolGraph / *.swiftinterface は Apple official、 LLM hallucination リスク無し
  - **横断利得**: doc メタデータは IRB doc preview だけでなく、 LLMGenerator (Swift glue 生成) の prompt material、 reclassifier、 search にも生きる。 「生成ユースケースの大事なコンテキスト」 (user 2026-05-08)
  - 前例: T_irb2 (2026-05-07) `parent_id` 修正と同じ方針 = sibling repo 拡張で構造的に解決

- 実装範囲
  - sibling repo `rb-apple-sdk-knowledge` の `SwiftInterfaceParser` / `SymbolGraphIngester` を拡張、 doc-comment / discussion / abstract を抽出
  - `symbols.documentation` 列への書き込みを `Importer#process_framework` で実行 (parent_id 修正と同じ場所)
  - KB rebuild は longrun screen pattern で実施 (~1-2 時間想定)
  - schema 拡張不要 (`documentation TEXT` 既存)

- LLM 役割の縮小
  - importer で doc が埋まれば LLM 不要 (= dialog は KB documentation を直接表示)
  - 一部 sparse / 不在の symbol については LLM fallback 残す (将来切り捨て可能)
  - sub-gem 側は「KB documentation 優先 / fallback で LLM」 の薄い ResolverFactory パターン

- mac gem 側の進行戦略
  - sibling repo の rebuild blocking dep にせず、 fake KB / stub documentation で TDD 進める
  - rebuild 完了後に integration test で実 KB 接続確認

### 4.3 Cache 設計

#### Decision C — cache 不採用 (確定)

- B2 で `symbols.documentation` 列が埋まる前提なので、 popup 表示は KB SQL 一発で完結 (~1ms)
- LLM fallback も初期リリースでは不採用 → cache 機構そのものが不要
- 将来 sparse symbol 用に LLM fallback を追加する判断が出た時点で改めて cache 設計を起こす (別 spec)

## 5. Phase 2: Auto-discover trigger 代替設計

### 5.1 元仕様の問題

- 仕様: 「TAB 二回で `dig_perfect_match_proc` → spinner → `Apple.discover`」
- 障害: `Reline.autocompletion=true` (= IRB.conf[:USE_AUTOCOMPLETE], default ON) のとき `complete(_key)` が `move_completed_list(:down)` を呼ぶだけで `perform_completion` を経ず、 `dig_perfect_match_proc` は dead code (line_editor.rb:1292-1307)。

### 5.2 Decision D — trigger 設計 (要 user 選択)

- **D1 (推奨)**: popup hover で silent background prefetch
  - Phase 1 の `:show_doc` dialog_proc 拡張: hover candidate が Apple SDK class-method なら、 doc 生成と並行して `Thread.new { discoverer.run(...) }` を起動
  - 重複 prefetch 防止: `(framework, klass, name)` で `Set` 管理、 1 回限り
  - spinner: dialog content の先頭に "discovering..." 行を表示 (background thread 完了で消える)
  - user は何も意識せず、 popup 開けば prefetch、 IRB 呼び出し時には glue 完成済み
  - LLM doc preview と単一 trigger を共有 → 設計が綺麗

- **D2**: completion_proc 内 prefetch
  - completion_candidates が呼ばれた瞬間 `target == single_candidate && receiver_kind == :class` なら background discover
  - dialog 不要 → spinner UI なし、 silent
  - シンプル、 だが Phase 1 と分離している

- **D3**: USE_AUTOCOMPLETE = false に切り替えて TAB 二回経路復活
  - popup を諦める = Phase 1 が成立しない
  - 不採用

### Decision D 推奨: **D1** (Phase 1 と統合、 単一の hover trigger)

### 5.3 Trade-off (D1)

- (-) user は明示的な「TAB 二回で discover」 操作意識を失う (silent)
- (+) prefetch 結果が UX を高速化、 NoMethodError も出ない
- (+) Phase 1 の dialog_proc を拡張するだけ、 別経路実装不要

## 6. Test plan

### Sub-gem migration
- 既存 test/irb_completion/* を irb/test/ へ移動、 require_relative 修正
- main `rake test` (268 → 263 程度)、 sub-gem `rake test` (新 task) でそれぞれ GREEN
- main gem 単体 require で IRB 関連 const が定義されないことを assert

### Phase 1 (LLM doc preview)
- KB metadata fetcher unit test (fake KB)
- LLM prompt builder unit test (snapshot of prompt for fixed input)
- doc cache (sqlite) unit test (set / get / invalidate)
- DocGenerator integration test (fake LLM stub returning fixed string)
- Dialog proc unit test (hover Apple → returns DialogRenderInfo, hover non-Apple → returns nil)
- 実機 probe (interactive harness with manual verification)

### Phase 2 (prefetch)
- Prefetcher unit test (idempotent: 同 key 2 回呼んでも discover_proc は 1 回)
- Dialog proc 統合 test (Apple class-method hover → prefetcher.start 呼び出し検証)
- Race / threading: prefetch 完了前後で `Apple.discover` 呼んでも例外無し

## 7. Implementation order (推奨)

1. **Step 1** — sub-gem migration (Decision A 確定後)
   - irb/ ディレクトリ作成、 gemspec、 既存 irb_completion.rb と test を移動
   - main gem の autoload 削除、 Gemfile / gemspec から IRB 系依存削除
   - 全 test GREEN 維持
2. **Step 2** — Phase 1: LLM doc preview (Decision B, C 確定後)
   - DocGenerator (KB fetch + LLM call)
   - DocCache (sqlite)
   - Dialog proc 差し替え
   - integration + 実機
3. **Step 3** — Phase 2: prefetch trigger (Decision D 確定後)
   - Prefetcher (idempotent thread launcher)
   - Dialog proc 拡張
   - 実機検証
4. **Step 4** — RDoc rebuild (別 issue, optional)
   - sub-gem 範囲外、 ユーザー手元の `gem rdoc --all` または rdoc downgrade

## 8. Decision points 一覧 (user 確認)

| ID | 内容 | 確定 |
|----|------|------|
| A | sub-gem ディレクトリ layout | **A1** (irb/ サブディレクトリ) |
| B | doc source 戦略 | **B2** (KB importer 拡張で公式 source 取り込み) |
| C | doc cache 永続化 | **不採用** (KB documentation 直引きのみ、 LLM fallback も初期不採用) |
| D | auto-discover trigger | **D1** (popup hover で silent prefetch) |

## 9. Out of scope (この spec)

- RDoc 7.2 × Ruby 4.0 Marshal 非互換 (標準 Ruby class doc): 別 issue。 ユーザー手元で `gem rdoc --all` 試すか rdoc バージョン pin。
- ruby-lang.org への `Ruby::Box × IRB::RegexpCompletor` SEGV upstream report: 別 task、 `tmp/box_irb_segv_repro.rb` を upstream へ。
- Apple SDK Knowledge importer 拡張 (B2): sibling repo の別 issue。
