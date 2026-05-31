# Handoff: ルールベース fix → 推論を主ルートへ昇格(brainstorm 途中)

- 日付: 2026-05-31
- ブランチ: feature/knowledge-base-rebuild-tuning (working tree clean, main..HEAD = 124 commits)
- 状態: **方針転換の brainstorming を最初の clarifying question 直前で中断。次セッションで brainstorming を再開 → 新 spec → 新 plan。**

---

## 次セッションの入口(そのまま読む)

`superpowers:brainstorming` を再発動し、下記「未解決の設計論点」の **Q1 から** 詰める。design 合意 → `docs/superpowers/specs/` に新 spec → `superpowers:writing-plans`。
**実装(Task 10 PoC / Task 11 final review)は pivot で位置づけが変わったので、新 spec 確定まで着手しない。**

---

## 今セッションで確定した方針転換(これが主題)

ユーザ明示の新方向(2026-05-31):

> もうルールベースはここまでで fix。明確なバグは直すが、あくまで **LLM が推論して仕上げてくれるのを「ルート」にする。fallback という位置づけから引き上げ**。ルールベースで 80% 作る、残り 20% を推論。**unit test をハーネスとして「完全動作」まで持っていって確定**。これを必須ルートとする。

転換に至った経緯(decision の why):
- ルールだけで Apple SDK 全面を **決定論的に網羅するのは原理的に不可能**(generics / nested optional / macro / struct・class・enum の type-proxy 等、表面が開いている)と合意。
- 「代表 symbol を手で選んで matrix を回し、壊れた例を 1 個ずつ塞ぐ」= **もぐら叩き**で、決定論的網羅には永遠に到達しないと user が見抜いた(「この調子で決定論的な網羅はできるの? そもそも」)。
- KB 全件監査(163,593 symbol)で **語彙ギャップ** が判明: CoverageContract の `COVERED_KINDS` は generator 語彙(`objc_method_class`/`swift_init`/`swift_property`…)、KB は生カタログ語彙(`instance_method` 70,470 / `global_constant` 44,470 / `function` 14,871 / `class_method` 14,184 / `instance_property` 2,404 …)。両者は直接対応せず、到達可否は `bootstrap!`/`Apple.discover` の**正規化層に依存**するが、それが未監査。`swift_property_setter` が到達不能なのもこの構造の一症状(どの生 kind も setter に正規化されない / importer が `is_settable` 未記録)。
- → 「網羅」の定義を **exhaustive な rule coverage** から **「ルール 80% 足場 + 推論 20% 仕上げ、unit test オラクルで完全動作まで駆動して確定」** に置き換える。**決定論は glue 生成にではなく、ハーネス(unit test の green/red)に宿らせる**。

過去 memory `feedback_gem_internal_encapsulation`(cloud LLM は gem 公開 path 不可)は本セッション方針で**上書き済み**(handoff 前回分にも記載)。推論を主ルートに置く前提。次セッションで当該 memory entry を見直すこと。

---

## 未解決の設計論点(brainstorming で詰める。Q1 が中断点)

- **Q1(中断したまさにここ): unit-test-harness ループは「いつ・どこで」走るか。**
  - 仮説 A(有力): **gem 開発時**に corpus を curate → ルール足場 + 推論仕上げ → unit test green → **確定 glue を cache に焼いて ship**。runtime は確定済み cache を読むだけ。
  - 仮説 B: **runtime**(初回呼び出しで推論ループ)。
  - 効く洞察: unit test がオラクルになるには「その symbol が何を返すべきか」の期待値が要る。それは **dev 時に人間/生成 test が与えるもの**で、runtime にユーザが任意に叩く symbol には期待値オラクルが無い(あるのは compile 通る/crash しない/ABI 形が合う、程度)。→ 仮説 A が自然だが user 確認必須。
- **Q2: 「80% / 20%」の意味** — (a) **per-symbol**(1 symbol ごとにルールが部分 glue=足場を出し、推論が残りを補完) か (b) **per-population**(symbol の 80% はルール完結、20% は推論)か。「推論して仕上げてくれる」は (a) 寄り。アーキテクチャが大きく変わる。
- **Q3: ハーネスの unit test はどこから来るか** — 例ごとの手書き e2e? 生成? symbol ごと? corpus の定義は?
- **Q4: 「必須ルート」のスコープ** — 全 symbol が rule→推論→test を通るのか、covered 範囲外だけか。
- **Q5: コスト/レイテンシ** — `claude -p` を symbol ごとに叩く前提(dev 時なら許容、runtime なら重い)。`Apple Intelligence Overhead Tolerance` の許容は on-device 前提で、cloud `claude -p` は別物。
- **Q6: 既存 seam の改修** — 現 `try_inference` は **盲目的 1 retry**(失敗 detail を backend に渡さない)。新設計は **unit test 失敗を prompt に feed back する閉ループ** と、**ルール出力を seed として prompt に渡す**(80% 足場)が要る。

---

## 今セッションで実装・確定した成果(全部 green、commit 済み)

前 plan(`docs/superpowers/plans/2026-05-31-rulebase-coverage-and-claude-p-inference.md`)を subagent-driven で Phase 0-2 まで実行。全タスク review pass。

- KB rebuild 完了(163,593 symbol、49m2s、`.rb-apple-sdk-mac/knowledge/26.5/sdk_knowledge.sqlite` 168MB)。
- 本セッションの commit(古い順): `b657a4c` OutOfCoverageError / `8262dd9`+`72151fc` CoverageContract(8 kind, marshaller REGISTRY と 1:1, 実 metadata 形状) / `014bda7` compile 合流点+dispatcher propagate+config :none / `36b48f7` InferenceBackend 抽象 / `32ad93c` ClaudePBackend(prompt は ValidationGates の 16 banned API と整合) / `5d15e33` try_inference 配線(gates+swiftc+cache を rule と共有, bypass 無し確認済) / `247602b` config test / `68d6f07` 8-kind matrix(env-gated) / `e1e463f` coreaudio e2e gate / `a5453db` global_constant emitter。
- **matrix 8 kind: 7 PASS、`swift_property_setter` のみ RED**(到達不能=上記語彙ギャップの症状。importer+KB rebuild+discover shape が要る大物。今回 untouched、escalate 済み)。
- **HOLE A(audio)は generator バグではなく stale KB データが原因**だった。`AudioObjectPropertyAddress` の `fields_json` 欠落で hash-path に乗れず `TypeError`。**今回の rebuild で fields が入りコード変更ゼロで解消**(e2e gate のみ追加)。→ coverage の正しさは generator コードより **KB データ完全性に依存**する好例。
- full suite: **424 tests, 0 failures, 0 errors, 3 omissions**(omissions は `knowledge/test/` の別 path テスト、無関係)。

前 spec/plan は **部分的に superseded**: rule-coverage-contract は実装済み、推論=fallback の枠組みは「主ルート」へ昇格中。

---

## 次セッションが使える既存資産

- `lib/apple_sdk_mac/inference/backend.rb`(抽象)+ `claude_p_backend.rb`(injectable runner, prompt は gate 制約反映)。
- `lib/apple_sdk_mac/glue_compiler.rb` の `try_inference`(gates+swiftc+cache 共有 — ただし **blind 1-retry**。新設計で test-feedback ループ + ルール seed 注入に改修要)。
- `lib/apple_sdk_mac/coverage_contract.rb`(8 kind, kind-based)。**KB 全件監査するなら語彙ギャップ補正(生 kind → generator kind 正規化)を噛ませること**。
- `test/integration/coverage_matrix_test.rb`(env-gated, 8 kind)。
- `Config#inference_backend`(:none 既定、`RB_APPLE_SDK_MAC_INFERENCE_BACKEND` で override)。

---

## 実行規律(踏み抜き防止)

- TESTOPTS は `--name=/Pattern/`(`-n` は file path 扱いで効かない)。単発は `bundle exec ruby -Itest -Ilib <file>` が確実。
- **e2e/matrix を `RUBY_BOX=1` で回さない** — raise する RED test が sibling を巻き込んで中断する Ruby::Box quirk。integration test file は RUBY_BOX 無しで実行(examples/ スクリプト単体は RUBY_BOX=1 で可)。
- `bootstrap!` は default で `.rb-apple-sdk-mac/knowledge/26.5/...` の rebuild 済み KB を引く。swiftc は shell env で動作。
- `rake test` は subagent 委譲(make/dot log で main 汚染を避ける)。pass/fail+count のみ回収。
- ロングバッチ(KB rebuild ~49分)は tmux detached + `DONE:` sentinel。完了待ちは background bash の until-loop(harness が exit で再起動)。
- main 直 push は hook deny(handoff 案件)。merge は `--ff-only` local default、可否は user 判断。
