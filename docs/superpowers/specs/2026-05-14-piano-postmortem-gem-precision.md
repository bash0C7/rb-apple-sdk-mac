# Postmortem: piano_keyboard を動かすために Claude が Swift を生で書いた件

## TL;DR

`examples/piano_keyboard.rb` を 1 つ完成させるために、 1 session 内で:

- gem 本体 (`lib/apple_sdk_mac/`) に **6 か所の挙動修正** を入れた (objc_marshalling.rb の `:uint32` case、 template_generator.rb の `throws` swift_initializer / `AndReturnError:` throws bridge / void return の `let raw` 除去、 namespace_builder.rb の type_constant proxy 拡張 / ruby_method_name の `throws` strip)。
- example 側で **declare を 7 種類書き直した** (`:uint32` 化、 type hint `"URL"`、 `init(forReading:) throws`、 selector を Swift bridged form (`attach:` / `scheduleFile:at:completionHandler:` / `startAndReturnError:` を空 params で throws bridge に乗せる)、 `return_klass:` 追加、 `:nil_literal` 化)。
- `route_to_device` は AudioUnit raw pointer を proxy auto-wrap の壁が抜けられず実装断念、 OS default device に fallback する skip path に。

これは README L3 の「any public Apple framework API call from Ruby with no pre-declarations」 commitment と乖離してる。 user が「実質 Claude Code が Swift コードを生で書いてる」 と指摘した通り、 「Apple Foundation Models の on-device LLM safety-net が context window 4096 で潰れる → user (もしくは Claude) が手で Swift signature を読み直して declare を書き直す」 が常態化してる。

このドキュメントは、 (A) その「Claude が Swift を書く」 状態がなぜ発生したかの解剖、 と (B) gem の精度を上げる 2 方向 (非決定論的動作の許容 / Apple Foundation Models 用 context の整備) の比較。 実装の prescription までは出さん、 user との次フェーズ design 議論用の素材。

## 文脈

- branch: `feature/example-piano-keyboard`
- 起点: handoff doc `tmp/handoff/2026-05-13-piano-keyboard.md` (session 跨ぎ持ち越し、 「CoreAudio 3 declare を escape-hatch shape に書き換える」 まで方針確定済、 実装未着手)
- 目的: 4 framework (CoreAudio / CoreFoundation / Foundation / AVFAudio) を跨いだソフトピアノ example を書いて README L3 を裏付ける
- 終着点: piano 起動 → device list → 番号選択 → MacBook Air スピーカーから音が鳴る、 までユーザ動作確認 OK

## 各 failure の解剖

各 iteration での error → 原因 → 対症の流れ、 そして「本来 gem が deterministic に動くべきだった layer」 を分類。

### 1. cache pollution (古い KB form の dylib が override 適用後も load された)

- 症状: `AudioObjectGetPropertyDataSize` で SIGBUS、 emit が Knowledge Base record の Hash 形 (`mSelector` / `mScope` / `mElement` を `rb_hash_aref` で読む) のままだった
- 原因: `compiled_glue` table に同一 symbol の record が 2 つ (handoff 起点で `override` 適用前に compile された旧 dylib + 適用後の新 dylib)。 lookup は最初に hit したものを load、 古い方が選ばれた
- 対症: `bundle exec rake apple:cache:clear` で全部消して fresh re-compile
- 設計層の本来形: **「Apple.discover に override が渡された場合、 既存 compiled_glue を invalidate (regenerate) する」** か、 cache key に `parameters_json` を含めて override hash で別 row になる

### 2. Apple Foundation Models の context window 4096 が KB miss 時 prompt で枯渇

- 症状: KB record の無い symbol (`AVAudioFormat.init(...)` 等) を Apple.discover した際、 template path が swiftc warning/error で reject → LLM safety-net に流れる → prompt 4089〜4091 tokens で `exceededContextWindowSize`、 6 retry 全 fail
- 原因: `lib/apple_sdk_mac/glue_compiler/llm_examples.rb` の INSTRUCTIONS bundle (Worked Examples + header) が ~4 kT もある。 「KB の無い symbol を LLM に書かせる」 worst-case prompt 占有率が ~100%
- 対症: 今 session では LLM 経路を諦め、 Claude (= 私) が Swift signature を頭で reconstruct して override params を手書き
- 設計層の本来形: **(B) Apple Foundation Models 用 context 整備**。 Worked Examples の dynamic 絞り込み (symbol kind に応じた 1〜2 例だけ inject)、 INSTRUCTIONS header の slim 化、 もしくは on-device LLM ではなく cloud LLM (Claude API) を opt-in fallback として組み込む

### 3. emitter の `:uint32` case 欠落 (swift_init / objc_method の in_load)

- 症状: `params: [:float, :uint32]` を AVAudioFormat init に渡すと `ObjcMarshalling.in_load: unsupported param kind :uint32` で raise
- 原因: ESCAPE_HATCH_KINDS (`%w[opaque_ref cstring uint32 int bool float]`) は C function path だけ supportしていて、 swift_init/objc_method 側の `ObjcMarshalling.in_load` には `:int` / `:bool` / `:float` / `:opaque_ref` / `:string` しかない。 `:uint32` が gap
- 対症: gem 本体に 1 case 追加 (`let arg#{i}: UInt32 = UInt32(rb_num2ull(argv[#{i}]))`)
- 設計層の本来形: **kind 配列の network 完全性 (in_load × return_lines × escape_hatch_in_load の全マトリクス) を test 駆動で保証**。 現状 kind matrix は emit code に散在、 1 か所変えると別 path が抜ける

### 4. swift_initializer の `throws` 未対応

- 症状: `AVAudioFile.init(forReading:)` は throws、 emit が `let v = AVAudioFile(forReading: arg0)` (try なし) → swiftc error
- 原因: emit_swift_init は `?` (failable) しか看取しない、 throws マーカーが無い
- 対症: `swift_initializer: "init(forReading:) throws"` で末尾 `throws` を user 指定、 emit_swift_init が `try?` で wrap、 ruby_method_name は ` throws` を strip
- 設計層の本来形: **Swift bridged form の標準 syntactic markers (`throws`, `async`, `rethrows`) を初手から discovery_shape の文法に組み込む**。 「user が文字列に手で書く」 path で動かしたんは shortcut、 ideal は Knowledge Base が Swift signature を 1 次 source として持つこと

### 5. ObjC `<verb>AndReturnError:` の throws bridge 不発

- 症状: `AVAudioEngine.startAndReturnError:` を ObjC selector で declare → emit が `receiver.startAndReturnError(arg0)`、 Swift は `start() throws` に rename 済で error
- 原因: throws_bridge 判定が `selector.end_with?(":error:")` (multi-segment の末尾 `:error:` だけ) で、 single-segment `<word>AndReturnError:` を拾わない
- 対症: regex 拡張 (`(?:AndReturn|Returning)Error:\z` 末尾も throws bridge)
- 設計層の本来形: **ObjC→Swift bridged name の resolution は emitter regex ではなく KB lookup**。 selector → Swift method name の対応表 (sourcekitten / Apple docs origin) を Knowledge Base 側に持って、 heuristic は最終 fallback に

### 6. ObjC selector の Swift 3 rename (`attachNode:` → `attach(_:)` 等) を emitter が解決しない

- 症状: `attachNode:` selector で emit すると `receiver.attachNode(arg0)`、 swiftc が "renamed to 'attach(_:)'" で reject
- 原因: swift_call_for_instance_method は selector parts をそのまま label として使う heuristic で、 「Swift 3 で改名された ObjC API」 を解決する仕組みなし (SwiftBridgeName.resolve は class method 側だけ)
- 対症: piano_keyboard.rb 側で user が「Swift bridged 形の selector」 を直接書く (`attach:` / `scheduleFile:at:completionHandler:`)。 つまり「selector 引数」 は ObjC selector でも Swift method 名でも受け付ける semi-typed string になっとる
- 設計層の本来形: **SwiftBridgeName を instance method にも展開**、 ObjC selector → Swift bridged name の resolution を Knowledge Base 側に持って instance method 側 emit でも使う

### 7. void return の `let raw = ...` warning が compile_history を「失敗」 と記録

- 症状: `attach(_:)` の戻り値 void を `let raw = receiver.attach(arg0)` に bind して swiftc warning、 compile_history は `error_stage='swiftc'` (template) → LLM fallback
- 原因: emit_objc_instance_method の return path が void を区別せず `let raw =` を unconditional に出してた + 別の本物 error (rename) と warning が混ざって判定がぼやけた
- 対症: void return は単独 statement (`receiver.method(args)`) に
- 設計層の本来形: **swiftc の exit code + error/warning 分離を template/LLM 振り分けの判定に正しく使う**。 warning だけで LLM 経路に流すのはコスト過剰

### 8. proxy auto-wrap の class 不整合 (`outputNode` が AVAudioEngine instance を返す)

- 症状: `@engine.outputNode` が `Apple::AVFAudio::AVAudioEngine` の instance を返した (期待は AVAudioOutputNode)。 そこで `.audioUnit` 呼んで NoMethodError
- 原因: `define_method_under_klass` の wrap_class default = receiver class。 `return_klass:` 未指定だと receiver class proxy で wrap される
- 対症: piano_keyboard.rb 側で `return_klass: :AVAudioOutputNode` 明示
- 設計層の本来形: **Swift method の return type を Knowledge Base が知ってる前提**、 そこを wrap_class に自動 plumb。 「user が return_klass を明示」 は KB に return type 情報が無い場合の fallback だけ

### 9. type_constant 経由 proxy が `from_ref` を持たない

- 症状: bootstrap! が Foundation の `NSURL` を type_constant として install (proxy class 作る、 ただし `from_ref` 無し) → 後で `Apple.discover(...class_method: "URLWithString:")` で wrap_class.from_ref(result) → NoMethodError
- 原因: `define_type_constant` で作る proxy が `ensure_proxy_class` と shape 不一致 (initialize/from_ref/__opaque_ref が無い)
- 対症: define_type_constant も `ensure_proxy_class` と同 shape に揃える
- 設計層の本来形: **proxy class factory を 1 つの canonical 実装に統一**、 path 分岐 (type_constant 経由 vs ensure 経由) でも同じ shape を保証

### 10. ruby_method_name_for が `throws` suffix を method 名に残す

- 症状: `init(forReading:) throws` → `init_forReading_ throws` (空白入り、 Ruby method 名としては定義できるが呼べない)
- 原因: ruby_method_name_for は `(` / `)` / `:` / `_+` を normalize するだけ、 Swift 末尾 modifier を strip しない
- 対症: ruby_method_name_for の先頭で `\s+throws\z` を sub("")
- 設計層の本来形: **Swift identifier → Ruby identifier の normalize を canonical な 1 関数に集約**、 corner case (throws / async / rethrows / @MainActor 等) を予め全部潰す

### 11. AudioUnit raw pointer 取り出しの設計的限界

- 症状: `outputNode.audioUnit` の戻り値が AVAudioOutputNode proxy にも raw integer にも取れない (swift_property の return emit `Unmanaged.passRetained(raw as AnyObject)` は OpaquePointer の bit pattern を保持しない)
- 対症: piano では route_to_device 自体を skip して OS default device に fallback
- 設計層の本来形: **opaque type return の raw pointer 直 emit path (`return_kind: :raw_ptr` ベース) を swift_property emit にも適用できるようにする**、 `Unmanaged.passRetained(as AnyObject)` は class 型 return 用、 非 class opaque pointer は別経路

### 12. AVFAudio Swift overlay class が Knowledge Base 未登録 (= ↑全部の遠因)

- 症状: `AVAudioFormat` / `AVAudioEngine` / `AVAudioFile` / `AVAudioPlayerNode` / `AVAudioOutputNode` / `AVAudioIONode` の Swift overlay は KB 空 (`project_kb_doc_coverage_2026_05_08.md` の bimodal coverage 報告通り)
- 原因: 現 KB importer は ObjC framework header から取り込んでて、 Swift overlay (Foundation / AppKit / AVFAudio の Swift 化された class 群) は範囲外
- 対症: 今 session では importer 拡張せず、 「user (Claude) が Swift signature を頭で reconstruct」 でしのいだ
- 設計層の本来形: **Knowledge Base の Swift overlay coverage 拡大** (sourcekitten 経由 / xcrun swift-symbolgraph-extract / Swift API JSON dump 等)、 これが全 1〜11 の上位 root cause

## 「Claude Code が Swift コードを生で書いてる」 のメカニズム

整理すると、 今 session で Claude が「Swift コードを書いた」 のは以下のレイヤーを跨いでた:

- **(L1) gem の emitter / namespace builder の logic gap を埋めた**: `:uint32` case、 throws マーカー、 AndReturnError 末尾 throws bridge、 void return cleanup、 from_ref/__opaque_ref 揃え、 ruby_method_name throws strip。 これは Swift コード本体じゃないが、 「Swift をどう generate するか」 のルールを Claude が補修してる
- **(L2) example 側の declare を Swift signature 準拠で書き直した**: `:float, :uint32`、 `init(... ) throws`、 `selector: "attach:"` (Swift bridged form)、 `return_klass:`、 `:nil_literal`。 Apple.discover の入力を Swift API の真の shape に合わせる行為で、 これは実質「Swift API 知識を declare 文字列に押し込んでる」
- **(L3) AudioUnit raw pointer 周りは諦めた**: route_to_device skip。 これは gem 設計の限界に当たって user が後で踏み直す punt

つまり Claude が果たした役目は、 設計上 (A) Knowledge Base、 (B) Apple Foundation Models、 (C) emitter の自動 fallback、 のどれかが提供すべきだった「Swift API 知識 + glue 生成知能」 の代替。 README L3 commitment と比べると 3 つ全部が部分機能状態。

## 改善方向の比較

user 提示の 2 方向 + 自然な第 3 案:

### (A) 非決定論的動作を「設計として」 許容する

考え方: piano example の 16 declare が初手で全部静的 template path に乗ること自体が無理。 むしろ「最初の N 回は LLM safety-net で確率的に通り、 通った dylib は cache に育つ」 を normal flow と定義する。

- 必要なこと:
  - cache pollution 問題 (#1) を消す: override 渡しで cache invalidate
  - LLM safety-net の prompt context を rebalance (#2) — でもこれは (B) と被る
  - LLM の retry budget / 別 model fallback (cloud LLM への opt-in escalation) — 「on-device で 6 retry 全 fail なら Claude API 等に escalate」 path
  - compile_history を「失敗の理由を user が読めて、 declare を直す手がかりが残る」 form に整える
- 良い点: 「Claude が手で書く」 が公式の workflow (= user が declare を試行錯誤、 LLM safety-net or cloud LLM に補ってもらう)。 README L3 は「first try で動く」 を放棄、 「最終的に動く」 にトーンダウン
- 悪い点: dev UX が iterative loop に寄りすぎる。 1 framework 跨ぐと 10〜30 分の compile/error/fix loop。 cache が育つまで pre-release CI 通せない

### (B) Apple Foundation Models が work する context を整える

考え方: 4096 token 制限を所与として、 「symbol kind に対して最も relevant な Worked Example 1〜2 個 + minimal header」 を動的に組む。

- 必要なこと:
  - INSTRUCTIONS bundle (`llm_examples.rb`) の dynamic slicing: symbol kind (swift_init / selector / swift_property / c_function) に応じて bundle の半分以下に絞る
  - param kind 配列を hint として LLM に渡す (現状 prompt の output spec が weak で空 generation を生みやすい)
  - swift_initializer / objc_method の bridged name resolution を KB に持って、 LLM には「正しい method name + 引数 type」 だけ requester
  - on-device LLM の retry strategy: 同一 prompt 6 回じゃなく、 temperature / system prompt variation で multi-shot
- 良い点: README L3 を保てる。 「any public Apple framework API」 を first-try で動かす確率が上がる
- 悪い点: context engineering の精度仕事、 model 改版 (FoundationModels の context window 拡張等) で前提が崩れる
- 重要前提: Apple Foundation Models 自体の言語能力が piano-tier の Swift コードを書ける、 という仮定が必要。 今 session の data point だと「prompt 与えても empty generation」 が頻発、 言語能力以前の context 効率の問題で塞がってた

### (C) Knowledge Base の Swift overlay coverage を埋める (root cause fix)

考え方: 1〜11 の遠因が #12 (Swift overlay 未取り込み)。 importer を Swift overlay 対応に拡張すれば、 emitter / LLM safety-net の双方が drastically 簡単になる。

- 必要なこと:
  - sourcekitten module dump / xcrun swift-symbolgraph-extract で Swift overlay class (AVFAudio / Foundation / AppKit 等) の API surface を抽出
  - 抽出済 record を Knowledge Base に insert (importer 拡張、 sibling repo の knowledge importer に sub-mode 追加)
  - selector → Swift bridged name 対応表 (SwiftBridgeName.resolve の表) を Knowledge Base 由来に
  - throws / async / Optional return 等のマーカーを KB record の field として持つ
- 良い点: emitter の heuristic と LLM 依存の両方が縮む。 README L3 commit 通り「first try で動く」 が realistic に。 user は declare 書くんちゃう、 Apple SDK のメソッド名を Ruby から呼ぶだけ
- 悪い点: importer の作業量大。 Apple SDK の Swift overlay は重く、 全 framework 取り込むと数十時間の処理 (今までの ObjC importer と同 order)。 cache 容量と CI 時間に影響
- (A)/(B) との関係: (C) が進めば (A)/(B) の必要性は薄れる。 (C) は root cause、 (A)/(B) は failure tolerance

## 優先順位の素案

短期 (現 branch / 別 PR で即):

1. **cache invalidation on override** (#1): Apple.discover override で `compiled_glue` の同 symbol を invalidate。 これは regression risk 高いが、 今 session の SIGBUS は cache pollution が真因
2. **emitter logic gap の test 増強** (#3〜#10): kind matrix coverage の matrix test (`:uint32` × swift_init × ObjC selector × C function 等)、 throws / async / void return / `<word>Error:` 末尾の corner case を test 駆動で潰す
3. **proxy class factory の統一** (#9): define_type_constant と ensure_proxy_class を 1 関数に

中期:

4. **Knowledge Base の Swift overlay coverage** (#12 / 改善方向 C): swift-symbolgraph-extract 起点で AVFAudio から始める。 1 framework だけでも先に取り込めば、 piano-tier の example が「declare 不要で動く」 に近づく
5. **LLM context engineering** (改善方向 B): INSTRUCTIONS dynamic slicing。 (C) と並行で進める

長期:

6. **cloud LLM への opt-in escalation** (改善方向 A): on-device LLM で N 回 fail したら、 user が opt-in した cloud LLM (Claude API 等) に escalate。 これは安全性 / cost / consent の design 必要

## Open questions (user 議論用)

1. **piano example を「動いた」 として merge するか、 (C) の Swift overlay 取り込み待ちで保留するか**: 現状 example は動くが、 6 つの gem 内 fix + 7 つの declare 手書き + route_to_device skip という「強度の低い」 example。 README L3 の demonstrator として恥ずかしいか or 「現状の能力を正直に映した」 と allow するか
2. **「実質 Claude Code が Swift を書いてる」 を design failure として扱うか、 transitional workflow として認めるか**: (A) の方向で「これが workflow」 と公式化する選択肢もある
3. **(C) の importer 拡張に投資する判断材料**: 1 framework (AVFAudio) だけ先に試して投資 vs リターン (= example の declare 行数 / 工数削減) を測れる pilot run を切るか
4. **Apple Foundation Models の選択を維持するか、 cloud LLM ハイブリッドに転換するか**: on-device 制約は privacy / cost で強い理由あるが、 4096 token 制限が「全 Swift overlay framework で symbol-by-symbol に潰される」 障壁。 hybrid (on-device first → cloud escalation) が現実解か

## 参考: 今 session で書いた gem patch の sketchy 全リスト

実 commit 単位の粒度はまだ未確定 (PR は user 判断で不要)、 単体 file diff としては以下:

- `lib/apple_sdk_mac/glue_compiler/objc_marshalling.rb`: `when :uint32` case 追加 (in_load)
- `lib/apple_sdk_mac/glue_compiler/template_generator.rb`: 4 か所 (swift_init throws、 swift_init_labels regex の throws 許容、 objc_instance_method の throws bridge regex 拡張、 void return の `let raw =` 単独 statement 化)
- `lib/apple_sdk_mac/namespace_builder.rb`: 2 か所 (define_type_constant の proxy shape 揃え、 ruby_method_name_for の throws strip)

各 patch とも単独で deterministic、 加算的に他 example の挙動を変えるリスクは「あるが小」 — kind matrix test の整備 (短期優先 #2) が裏付けになる。
