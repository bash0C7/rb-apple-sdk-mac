# ルールベース被覆契約の堅牢化 + claude -p 推論フォールバック PoC

- 日付: 2026-05-31
- ブランチ: feature/knowledge-base-rebuild-tuning
- 関連: docs/superpowers/specs/2026-05-15-zero-base-redesign-design.md (NS-1 ルール堅牢化 / NS-3 LLM safety net 復活 を本 spec で具体化・再優先)

## 背景と問題

このブランチは zero-base v2.0 redesign (L8「事前宣言なしで任意の Apple framework API を呼ぶ」) の NS-0 baseline 段階にある。現状の二つの欠陥:

1. **ルールベースの穴**: template_generator は 8 emitter kind をカバーすると称しているが、「カバー済みと表明している範囲」の中に実際は壊れているケースがある (例: `audio_device_count` の `AudioObjectGetPropertyDataSize` — struct-in + int-out param で `TypeError: no implicit conversion of Hash into Integer`)。境界が暗黙で、何がカバー済みで何が範囲外かが機械可読でない。

2. **推論フォールバックが dead end**: LLM safety net は commit 32b6082 (2026-05-10) で削除済み。template が nil を返すと routing 先がなく、`GlueCompileError` を上げるだけ。コメント「未対応 kind は nil で LLM fallback へ流す」だけが残骸として残る。Apple Intelligence (on-device Foundation Models) には性能限界があり、推論経路そのものが viable かが未検証。

## ゴール (done-state)

ユーザ命題の二本立て:

1. **今カバーしている範囲のルールベース動的解決を「万全」に保障する** = (a) カバー済み 8 kind が end-to-end で round-trip することを機械可読な被覆契約 + test matrix で実証し、(b) `audio_device_count` 等「契約上カバー済みなのに壊れている穴」を塞ぎ、(c) 契約範囲外は silent に半壊させず loud に fail する境界を引く。

2. **推論フォールバックの viability を claude -p で PoC** = `InferenceBackend` 抽象 (Apple Intelligence ↔ claude -p ↔ 将来の backend を差し替え可能) を据え、`claude -p` ヘッドレスを第一級の selectable backend として実装し、**実 failing example が推論生成 glue で end-to-end に正値を返すところまで実証**する。「切り替え点が存在するだけ」では不合格 — 推論が実際に効くことを事実 (test stdout / git diff / 動いた example) で示す。

非ゴール (YAGNI):
- 推論結果の永続学習 / 自動 KB 反映 (PoC 成立後に別 spec)
- `foundation_models` 実 backend の実装 (座席のみ用意。viability 実証は claude_p で行う)
- 推論の高度な retry / 温度チューニング (compile 失敗時 1 回再投入まで)

## アーキテクチャ

### 推論 seam の配置 (核心)

現状 `glue_compiler.compile` は `try_template` の `Result` を返すだけで、dispatcher はそれを無視して cache を再 lookup する。`glue_compiler.compile` を**唯一の合流点**にする:

```
compile(framework:, symbol:)
  ├─ try_template → Result(success?: true)          … 成功なら即 return (従来通り)
  └─ template が nil / static_check / swiftc 失敗
        ├─ [トラック1] 契約範囲内なら「穴」→ ルール側を直す対象
        └─ [トラック2] 契約範囲外:
              ├─ inference_backend == :none  → OutOfCoverageError を上げる
              └─ inference backend 有効       → try_inference(backend)
                    └─ backend.generate_glue → Swift source 文字列
                          └─ 同じ ValidationGates + SwiftcInvoker + cache.insert に通す
```

設計原則: **推論の責務は「Swift glue source 文字列を作る」だけ**。compile / gate / swiftc / cache の検証機構はルールベースと完全共有する。これにより「推論が出した glue も静的 gate を通り swiftc を通った事実」が担保される (HITL gate には事実だけを出す方針と整合)。

### コンポーネント境界

| ユニット | 置き場 | 責務 | 依存 |
|---|---|---|---|
| `CoverageContract` | `lib/apple_sdk_mac/coverage_contract.rb` | kind × marshaller の被覆契約テーブル。`covered?(symbol)` を提供 | KB symbol メタ |
| `OutOfCoverageError` | `lib/apple_sdk_mac/errors.rb` (追加) | 契約範囲外を pattern/reason 付きで表す typed error | — |
| `GlueCompiler` (改修) | `lib/apple_sdk_mac/glue_compiler.rb` | template 失敗時に契約判定 → 範囲外なら backend へ委譲 or loud fail | CoverageContract, InferenceBackend |
| `InferenceBackend` | `lib/apple_sdk_mac/inference/backend.rb` | 推論 backend の抽象 interface | — |
| `ClaudePBackend` | `lib/apple_sdk_mac/inference/claude_p_backend.rb` | `claude -p` ヘッドレス subprocess で Swift glue を生成 | KB メタ, 既存成功 glue (few-shot) |
| `Config` (改修) | `lib/apple_sdk_mac/config.rb` | `inference_backend` (:none 既定 / :claude_p) を選択。既存 `llm_model` を一般化 | — |

各ユニットは独立にテスト可能。`InferenceBackend` は interface のみを公開し、`ClaudePBackend` の内部 (プロンプト構築 / subprocess) は consumer から black box。

### トラック1: ルールベース被覆契約

1. **被覆契約 (CoverageContract)**: カバー済み 8 kind それぞれに「この shape は必ず round-trip する」を表明する機械可読テーブル。`covered?(symbol)` が contract 内なら true。kind × marshaller (パラメータ型) の対応 matrix を持つ。
2. **loud fail 境界**: 契約外の shape は `template_nil` を黙って通さず `OutOfCoverageError` (pattern / reason 付き) を上げ、Telemetry に `stage: "out_of_coverage"` を append。「何が範囲外で推論に流れたか」が観測可能になる。
3. **穴塞ぎ**: `audio_device_count` (struct-in + int-out param) 等、契約上カバー済みと表明しているのに壊れているケースを TDD (`superpowers:test-driven-development`) で RED → GREEN。「契約に書いたなら必ず動く」を満たすための実装。

### トラック2: InferenceBackend + claude -p

```ruby
# lib/apple_sdk_mac/inference/backend.rb
module AppleSDKMac
  module Inference
    class Backend
      # symbol メタ (KB record) + framework から Swift glue source 文字列を返す。
      # 生成できなければ nil (→ compile は OutOfCoverageError に確定)。
      def generate_glue(framework:, symbol:, glue_id:, exported:)
        raise NotImplementedError
      end

      # Telemetry 用識別子 (例: "claude_p")
      def name
        raise NotImplementedError
      end
    end
  end
end
```

`ClaudePBackend` の中身:
- **プロンプト構築**: KB の symbol メタ (kind / signature / parameters_json / 既知 marshaller 制約) + 既存の成功 glue を few-shot 例として与える。ValidationGates の制約 (Foundation + framework + AppleSDKMacRuntime 以外 import 禁止、banned API、export shape 等) をプロンプトにも明記し、gate と整合した出力を促す。
- **実行**: `claude -p` を tool 制約付き subprocess で起動し、応答から Swift source のみ抽出。単発推論 (数秒〜十数秒) は Bash subprocess で可。実験を多数回す batch は tmux detached (ロングバッチ規律)。
- **secret 非露出**: claude -p は CLI 認証済み前提で token 引数不要。secret を print / echo / log しない。
- **gem 公開 path の扱い**: 既定 `inference_backend == :none` なので、`require` しただけの利用者には cloud 経路は発火しない。`:claude_p` は明示 opt-in (config / 環境変数)。

backend 選択: `config.inference_backend` で `:none` (既定) / `:claude_p`。将来 `:foundation_models` を足す座席を空けておく (今回は実装しない)。

## データフロー (推論経路)

1. Ruby 側 Apple API 呼び出し → dispatcher → `glue_compiler.compile`
2. `try_template` が nil / gate fail / swiftc fail
3. `CoverageContract.covered?(symbol)` 判定:
   - 範囲内 → これはバグ。トラック1 で直すべき穴 (ここに推論は流さない)
   - 範囲外 → `inference_backend` を見る
4. `:none` → `OutOfCoverageError` を raise + Telemetry `out_of_coverage`
5. backend 有効 → `backend.generate_glue` → Swift source
6. source を ValidationGates → swiftc → cache.insert (ルールと同一機構)
7. gate / swiftc 失敗 → 1 回だけ再投入 (失敗 detail をプロンプトに添えて) → なお失敗なら `OutOfCoverageError` + Telemetry `inference_failed`
8. 成功 → cache 経由で通常 invoke。`record_attempt` / `insert` の `generator:` は `"inference:claude_p"` と区別記録

## エラーハンドリング

- 契約範囲内の不具合 = バグ (直す)。範囲外 = `OutOfCoverageError` (backend 無効時の最終形 / 有効時は推論を試す)。
- 既存 `safe_record_attempt` / `Telemetry.append_event` をそのまま使用。`generator:` を `"template"` / `"inference:claude_p"` で区別。
- 推論 subprocess の失敗 (claude CLI 不在 / timeout / 非 0 exit) は named-rescue し Telemetry に記録、`OutOfCoverageError` に落とす。silent swallow しない。

## テスト戦略

| 層 | 置き場 | 検証 |
|---|---|---|
| 被覆契約 round-trip | `test/integration/coverage_matrix_test.rb` | 8 kind が実際に round-trip (1 entry = 1 test method) |
| 穴塞ぎ (TDD) | 各 example の e2e test (`test/integration/baseline_e2e_test.rb` 等) | audio_device_count 等が正値を返す |
| 境界 loud fail | `test/glue_compiler_test.rb` / `test/dispatcher_test.rb` | 契約範囲外で `OutOfCoverageError` (pattern/reason 付き) |
| 推論 PoC | `test/integration/inference_poc_test.rb` | claude_p backend で実 failing example が e2e に正値 (1 example = 1 test method) |
| backend 抽象 | `test/inference/backend_test.rb` | interface 契約 / `:none` で推論が発火しないこと |

検証出力は test-unit の assert に乗せる (自作 raise+puts report ではなく)。PoC の事実 (test stdout / git diff / 動いた example / branch 名) を HITL gate に提示する。

前提整備 (Step 0): 30 件の test error は「Knowledge Base missing」。`rake apple:knowledge:rebuild` で KB を整え green baseline を確保してから着手する。

## ビルド順序 (依存順)

1. **Step 0**: KB rebuild → test green baseline (30 errors 解消)
2. **境界形式化**: `CoverageContract` + `OutOfCoverageError` 新設、`glue_compiler.compile` の合流点を実装 (`:none` 既定なので挙動は loud fail のみ)。`coverage_matrix_test.rb` で 8 kind round-trip を RED→GREEN
3. ここから 2 トラック並列:
   - **トラック1**: 契約内の壊れた穴 (audio_device_count 等) を TDD で塞ぐ
   - **トラック2**: `InferenceBackend` 抽象 + `ClaudePBackend` 実装 + compile 合流点の inference 委譲、`inference_poc_test.rb` で実 failing example の e2e 実証
4. **統合検証**: final code-review (fresh eye、higher model) + verification-before-completion

## 留意 (memory / 規律整合)

- 本 spec は過去 memory「cloud LLM は gem 公開 path に置かない / LLM は on-device のみ」を**ユーザ現指示で上書き**する。claude_p は第一級 backend として実装する (ただし既定 `:none`、cloud 発火は明示 opt-in)。当該 memory entry はセッション後に見直す。
- HITL gate には LLM 自己評価サマリでなく生 artifact (git diff / test stdout / e2e log / branch 名) を出す。
- 推論を多数回す実験は tmux detached、単発は Bash subprocess。
- Claude が emitter/declare を手書きする状態は design failure — glue は KB or 推論 backend が生成する (本 spec はこの原則に沿う)。
