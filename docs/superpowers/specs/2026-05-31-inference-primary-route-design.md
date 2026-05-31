# Spec: 推論を主ルートへ昇格 — round-trip ハーネス駆動の glue 生成

- 日付: 2026-05-31
- ブランチ起点: feature/knowledge-base-rebuild-tuning
- 前提 handoff: `docs/superpowers/handoffs/2026-05-31-pivot-inference-primary-route-brainstorm.md`
- supersede: 推論=fallback の枠組み（`2026-05-31-rulebase-coverage-contract-and-claude-p-inference-poc-design.md` の fallback 位置づけ部分）。rule-coverage-contract 実装は残置。

---

## 0. 中核思想

決定論を **glue 生成** にではなく **ハーネス（round-trip test の green/red）** に宿す。

ルールだけで Apple SDK 全面を決定論的に網羅するのは原理的に不可能（generics / nested optional / macro / struct・class・enum の type-proxy 等、表面が開いている）。代表 symbol を手で選んで matrix を回し壊れた例を 1 個ずつ塞ぐ手法は **もぐら叩き** で、決定論的網羅には永遠に到達しない。

よって「網羅」の定義を **exhaustive な rule coverage** から **「ルールが決定論的に出せるところまで足場を組み、推論が seed に拘束されて残りを仕上げ、round-trip test オラクルで完全動作まで駆動して確定」** に置き換える。推論は fallback ではなく **必須の主ルート**。

事前の corpus 選抜・代表抽出は一切しない。**ユーザが実際に touch した symbol を、その場でフル機構に通す。** 選抜しないので「代表の漏れ」が原理的に発生しない。

---

## 1. オラクル導出（決定論の源泉）

Mac SDK の API（Swift / C）を Ruby から呼ぶ wrapper を作る以上、「どう呼べばどの型で返るか」は signature から自明。さらに Swift ドライバを生成して実走すれば、Ruby から何が返るかまで実測で特定できる。決定論的に決まるので test-unit（Ruby test-unit）を機械生成できる。

- **型契約**: API signature から Ruby 型へのマッピングを固定 assert。
- **値契約**: golden 値を焼かず、**round-trip 等価**で検証する。同一 symbol を「Swift ドライバ直走」と「Ruby wrapper 経由」の両方で叩き、同じ結果が返ることを assert。これによりシステム状態依存 API（接続デバイス数・時刻等）でも stale 化しない。

### 1.1 等価述語は戻り値の性質で段階的に縮退する

機構は「Ruby の挙動を Swift ground-truth と突き合わせる」一本。比較述語だけが degrade する:

| 戻り値の性質 | 述語 |
|---|---|
| 値型（Int / Double / String / Bool / 値の struct） | Swift 直走と Ruby 経由で **値の等価** |
| opaque / reference / 新規確保（`swift_init`・ハンドル・ポインタ） | **型・shape 一致 + non-null**（毎回別アドレス/別オブジェクトなので値等価は無意味） |
| mutating（`swift_property_setter`） | **set → getter 読み戻し == set した値** のペアを **一度だけ** 実行（二度呼ぶと二回書く） |

golden を一切持たないので stale 化しない。これが後述の portability を安全にする（運んだ先で再検証できる）。

---

## 2. 生成パイプライン（per-symbol, runtime オンデマンド）

「ルール 80% / 推論 20%」は比喩。意図は **全面推論はドリフトリスクが高いので、ルールベースで決定論的に出せるところまで足場を組み、その seed で推論を拘束して残りを仕上げさせる**（per-symbol。1 symbol ごとにルールが部分 glue を出し、推論が補完）。

初回呼び出し時のフロー:

1. **ルールが決定論的に出せるところまで足場（scaffold）を出す** — ドリフト抑止の anchor。
2. **推論が seed に拘束されつつ残りを仕上げる** — 現 `glue_compiler.rb#try_inference` の blind 1-retry を置換。
3. **round-trip ハーネスをその場で生成**（Swift ドライバ + Ruby test-unit）して green/red 判定（§1.1 の段階的述語）。
4. RED → **失敗 detail を prompt に feed back する閉ループ**で budget まで retry（test-feedback loop）。ルール出力は seed として常に prompt に注入。
5. budget 内で green にできない → **loud fail**（silent fallback は作らない）。
6. green → cache に焼く（§5）→ 2 回目以降は cache 即返し。

### 2.1 既存 seam の改修

- `lib/apple_sdk_mac/glue_compiler.rb#try_inference`: blind 1-retry を **test-feedback 閉ループ** に改修。round-trip 失敗 detail を prompt に渡し、ルール scaffold を seed として注入する。
- `lib/apple_sdk_mac/inference/backend.rb` / `claude_p_backend.rb`: `generate_glue` に「ルール seed」「直前の round-trip 失敗 detail」「（あれば）ユーザ context」を受ける口を足す。
- gates（ValidationGates の 16 banned API）と swiftc compile は rule 経路と共有済み。round-trip 実走をこの合流点に足す。

---

## 3. 失敗時の context 受け取り

happy path では事前 context を要求しない（README L8 "no pre-declarations" / `feedback_user_ergonomics_over_overhead`）。context は **fail 境界でのみ reactive に** 受ける。ユーザは「何が欲しかったか」を知っている＝gem に無い context を持っている。

- **(a) rich exception + resume（背骨）**: gem は失敗時に「何を試したか（ルール足場・Swift ドライバ・round-trip diff）」を自己記述する構造化 error を raise。ユーザは埋まってない gap だけを hint として渡し再開する。
  ```ruby
  begin
    Apple::SomeFramework.tricky(args)
  rescue Apple::OutOfCoverageError => e
    e.retry_with(context: "戻りは [CGRect]、用法は <snippet>")
  end
  ```
- **(b) IRB elicitation（上乗せ）**: 対話実行中なら fail 時にその場で「X が解決不能。期待する用法/型は?」と尋ね、答えをループに投入。非対話では (a) の loud raise に縮退。
- **(c) call site の hint kwarg は不採用**: 全 call を汚し、失敗を事前に知る前提＝pre-declaration に逆戻りするため。

受け取った context は §2 の閉ループの追加 seed になる。green round-trip が出れば cache に焼かれるので、**そのユーザがその symbol に context を払うのは生涯一度きり**。試行錯誤ループ自体は gem user に露出させない black box とし、最終的に「値が返る」か「明示 raise」かだけを見せる（`feedback_gem_internal_encapsulation`）。

---

## 4. 永続化（portable）

round-trip 採用ゆえ glue はマシン固有の観測値を含まず portable。永続化する単位は **「確定した glue ソース（Swift wrapper）＋ 生成された round-trip test」** のみ。キーは `(framework, symbol, SDK version)`（SDK version で必ず切る。glue は 26.5 で green でも別 version で compile 通らない可能性）。

- **Tier 1 — プロジェクトローカルの committable glue store**: 例 `.rb-apple-sdk-mac/glue/<sdk-version>/<framework>/<symbol>.swift` ＋ 生成 round-trip test。これが portable な単位。消費側アプリの repo に commit され、`Gemfile.lock` 的に team / CI / 別マシンが git で受け取り、**round-trip 再検証して使う**（compile + 実走のみ、claude -p 不要）。content-addressed で symbol ごと独立 → revert 単位も独立。
- **Tier 2 — マシンキャッシュ**: `~/Library/Caches/...`。Tier 1 から導出したコンパイル済み dylib + 高速 lookup。commit しない・いつでも再生成可。消去は rake task 経由（`cache_clear_via_rake_task`、直 `rm -rf` 禁止）。CACHE_SCHEMA bump で互換切り。

運用上の効き: ユーザが §3 で一度 context を払って green を出す → Tier 1 に source が落ちる → commit → チーム全員・CI・将来の自分が二度と claude -p を払わない。もぐら叩きで埋めた穴が、その世界では永続的に塞がる。

---

## 5. Tier 3 還流（最小形）

貢献物には 2 段の価値がある:
- **データ還流**: resolved glue を gem 配布物に accrete。穴は埋まるが根は決定論化されない。
- **ロジック還流（本命）**: 推論が「ルールでは解けない symbol 群」を繰り返し解いている＝**ルール層の構造的ギャップ**の信号。それを一般化して新ルール 1 本にすれば、その class 全体が今後決定論的に covered になる（`project_core_thesis_long_term_improvement` 直結）。

glue 1 件は弱い信号でロジックを一般化できない。よって受け取る形式は生 glue ダンプではなく:

**PR 形式 = inference-success bundle（symbol ごと）**:
- symbol identity（framework / symbol / SDK version / kind）
- **ルール層の失敗理由**（決定論被覆がなぜ外したか ← 金脈）
- ルールが出した足場（seed）
- 推論が仕上げた glue
- 生成 round-trip test ＋ green 証跡（upstream 側で再実行して自己検証できる）
- （あれば）ユーザ提供 context、匿名化

受け取り側は既存の `rb-apple-sdk-mac-improve-emitter` HITL workflow に **新しい candidate source** として乗る（candidate ranking → user pick → worktree → implementer subagent → fact bundle で事実提示 → OK で non-ff merge）。`feedback_hitl_gate_facts_only` と整合。

**スコープ（最小形）**:
- 定義するのは **export bundle 形式 + 失敗理由クラスタリング** のみ。
- **自動 PR 投稿は作らない**（publish = 1-way door / supply chain 境界 / gem auto-publish 不可）。ユーザは bundle を export → 手で PR → maintainer が既存 HITL workflow に通す。
- クラスタが集まる失敗理由 = 新ルール 1 本に一般化すべき箇所。maintainer（人 or Claude）が「新ルール化（本命）／データ shipped／reject」を HITL で判断。

---

## 6. コスト / レイテンシ

claude -p は runtime 初回のみ・symbol ごと。cache（Tier 1/2）と portability で支払いは「世界で一度」に漸近。overhead は許容しユーザエルゴを優先（`feedback_user_ergonomics_over_overhead`）。

`Apple Intelligence Overhead Tolerance` は on-device 前提だが、cloud `claude -p` が gem 公開 path に乗る点は本セッション方針で `feedback_gem_internal_encapsulation`（cloud LLM は gem 公開 path 不可）を上書きする。**実装着手前に当該 memory entry を見直すこと。**

---

## 7. 実装フェーズ（実証ファースト）

**根幹仮定「推論が green な round-trip test ＋ 動く glue を生成できる」を、周辺機構に投資する前に実証で retire する**（CLAUDE.md「Pre-implementation Verification」）。

### Phase 0 — 実証 / PoC（§1, §2, §3 の核）

ゴール: **推論で test-unit コードと動く glue が生成できることを実証する。**

- 手で選んだ少数の symbol（§0 の「事前選抜しない」原則は production の話。PoC では仮定実証のため意図的に難所 symbol を数個選ぶ）に対し:
  - ルール足場 → 推論仕上げ → round-trip ハーネス（Swift ドライバ + Ruby test-unit）その場生成 → green まで test-feedback 閉ループ、を実走させる。
  - §1.1 の 3 述語（値型 / opaque / mutating）が少なくとも各 1 例で green になることを示す。
  - 失敗時に §3(a) の rich exception → `retry_with(context:)` で green に転じる経路を 1 例で実証。
- **判定**: 推論が動く glue と green test を生成できれば命題成立 → Phase 1 へ。できなければここで pivot 自体を再検討（escalate）。
- production code への workaround 禁止。RED は RED として報告（`Verify Task Discipline`）。

### Phase 1 以降 — 作り込み（§3 残, §4, §5, §6 の運用化）

Phase 0 で命題が立ってから:
- §2.1 の seam 改修を production 品質に（blind 1-retry → 閉ループ正式実装）。
- §3 の context 受け取り（(a) rich exception + resume を背骨に、IRB (b) を上乗せ）。
- §4 永続化 Tier 1（committable glue store）+ Tier 2（machine cache）の正式実装、rake task 整備、SDK version キーイング。
- §5 Tier 3 export bundle 形式 + 失敗理由クラスタリング、既存 HITL workflow への配線。
- §6 コスト観点の運用確認。
- full suite green + final holistic code review（`Code Review: Final Holistic Review`）。

---

## 8. 非ゴール / スコープ外

- 事前 corpus の構築・代表 symbol の網羅選抜（§0 で明示的に棄却）。
- 自動 PR 投稿 / gem auto-publish（§5、1-way door）。
- 翻訳機能（`reline_dialog_transform_extraction` 方針）。
- `swift_property_setter` 到達不能の語彙ギャップ大物修正（importer + KB rebuild + discover shape）は本 spec の射程外。round-trip 述語側で setter を扱う設計（§1.1）は含むが、KB 正規化層の改修は別案件。

---

## 9. 確定済み設計判断（brainstorm ログ）

| 論点 | 決定 |
|---|---|
| 決定論の宿し先 | glue 生成でなく round-trip ハーネス |
| オラクル | signature（型）+ Swift ドライバ実走 round-trip（値） |
| 値検証 | golden 焼かず round-trip 等価、述語は段階縮退 |
| ルール/推論の関係 | per-symbol。ルール足場が推論の anchor（ドリフト抑止） |
| corpus | 持たない。runtime オンデマンド、touched symbol をその場で通す |
| 失敗時 | test-feedback 閉ループ → budget 超で loud fail |
| context 受領 | (a) rich exception + resume 背骨、(b) IRB elicitation 上乗せ、(c) kwarg 不採用 |
| 永続化 | Tier 1 committable glue store + Tier 2 machine cache、SDK version キー |
| 還流 | Tier 3 最小形（export bundle + クラスタリングのみ、手動 PR、既存 HITL 消費） |
| 着手順 | §1-3 を Phase 0 で実証 → §4-7 を Phase 1 で作り込み |
