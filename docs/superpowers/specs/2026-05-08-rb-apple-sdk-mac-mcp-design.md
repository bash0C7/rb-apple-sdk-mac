# 2026-05-08 rb-apple-sdk-mac-mcp Sub-gem Design

## 0. Status

**DRAFT** (2026-05-08) — design discussion completed in session 2026-05-08, spec written immediately. Pending TDD entry (T0).

主要 decision points 確定:

- **D1** gem 命名: `rb-apple-sdk-mac-mcp` (親の `rb-` prefix 継承、 user 確定 2026-05-08)
- **D2** 親 gem への依存: 強依存 (`add_dependency "rb-apple-sdk-mac"`) — code 生成 context として親 gem 規約理解が必要 (user 2026-05-08)
- **D3** sub-gem 配置: `mcp/` サブディレクトリ + 別 gemspec、 IRB sub-gem 規約 (memory `feedback_irb_subgem.md`) 継承
- **D4** 検証 host: Claude Code 限定 (Claude Desktop 互換も維持、 user 2026-05-08)
- **D5** 内部規約: chiebukuro-mcp (`/Users/bash/dev/src/github.com/bash0C7/chiebukuro-mcp`) を実装パターンの参照点とする
- **D6** Resources による「gem の自己解説」: AI agent が server 接続直後に gem 内部規約を学習できる self-documenting 構造を採用 (user 2026-05-08「コンテキストとしても重要」)

## 1. Background / Motivation

### 1.1 親 gem の位置取り

`rb-apple-sdk-mac` の存在意義は README L3「Call any public Apple framework API from Ruby with no pre-declarations」に集約される。 これは事実上 **Win32OLE の macOS 版** という位置取りであり、 RubyCocoa (2012 macOS bundle 外、 メンテナンス停止) / MacRuby (2015 終焉) / RubyMotion (2019 商用停止) と全滅した「Mac 上の動的 Ruby ↔ native bridge」の空席を、 Ruby 4 namespace isolation + Apple Foundation Models on-device + content-addressed glue cache という 2026 年素材で埋める第三世代として再挑戦したもの。

### 1.2 AI 時代の補助欠落

しかし `rb-apple-sdk-mac` 単体では AI コード生成補助に弱い。 Apple SDK は 446 framework × 数万シンボル規模で、 LLM の training data には断片的にしか入っておらず、

- ObjC selector ↔ Swift method 命名規則変換 (`initWithCGImage:options:` ↔ `init(cgImage:options:)`)
- async/throws/throws-async 変種、 generics 制約、 deprecated 注釈
- KB classifier の誤判定 (CFStringRef を `string` として、 buffer を `is_out_param=true` として等)

を Claude/GPT/Gemini が外す確率が高い。 特に Apple Intelligence (Foundation Models / Image Playground / Writing Tools) は新しすぎて training data に存在せず、 **AI に Apple SDK の使い方を「教える」 mechanism が必要**。

### 1.3 既存資産

このジェムは既に 2 つの AI 化資産を持っている:

1. **`rb-apple-sdk-knowledge`** — Xcode 同梱 `.swiftinterface` から ingest した SQLite + `sqlite-vec` ベクトル検索済の API カタログ (446 framework / 数万 symbol)
2. **動的 dispatch + dry-run-able TemplateGenerator** — 生成すべき Swift glue を実行前に文字列で取得できる構造

これらを **MCP server として AI host (Claude Code) に公開** すれば、 AI agent は server 接続直後に gem の内部規約と KB を学習し、 候補を elicitation で曖昧解消し、 dry-run で Swift コードを確認してから user に提示する、 self-documenting なコード生成 loop が成立する。

### 1.4 chiebukuro-mcp の先行実装

同 author が既に `chiebukuro-mcp` (read-only SQLite MCP server with elicitation) を実装・運用しており、 以下の解決済み問題が活用できる:

- **Path workaround** (Claude Desktop spawn 時の PATH 不通問題): `scripts/start_mcp.sh` で `$HOME/.rbenv/shims/bundle exec` を絶対パス展開
- **Tool define block style**: `MCP::Tool.define(name:, description:, input_schema:) do |args, server_context: nil, **_|`
- **wrap_with_log 構造化 stderr ログ**: tool 呼び出しごとに JSON 1 行を stderr に出力
- **ServerFacade パターン**: テストから `.tool_classes` / `.resource_list` を accessor で見える形に
- **Elicitation accept/decline/cancel 3 分岐**: chiebukuro `query_with_clarification_tool.rb` 完成済
- **Probe capabilities tool**: host が elicitation capability を宣言しているか実地検証

これらを `rb-apple-sdk-mac-mcp` でも踏襲する。

## 2. Goals

- `rb-apple-sdk-mac` を AI coding agent (Claude Code) から動的に活用できる経路を提供する
- KB 検索 / discover-call 提案 / template dry-run を MCP tool として公開
- gem の内部規約 (7 keyword shapes, KIND catalog, override recipes, proxy wrap rules, callback patterns) を MCP Resources として「自己解説」
- 候補曖昧時は MCP elicitation v0.13+ で user に確認
- Claude Code 限定検証で v0.1 リリース、 Claude Desktop も同 shell wrapper で動作

### Non-goals

- Cloud LLM (OpenAI/Anthropic API) からの接続 — 当面 Claude Code のみ
- IDE-LSP 統合 (VS Code / RubyMine) — 別 spec
- 商用配布 (RubyGems publish) — sub-gem として `path:` 限定、 IRB sub-gem 同等運用
- 自然言語 → 完全な Ruby スクリプト 1 発生成 — sampling capability + 多 tool chain 必要、 別 spec

## 3. Architecture

### 3.1 Sub-gem placement (IRB sub-gem 規約継承)

`rb-apple-sdk-mac` repo 内に `mcp/` サブディレクトリ。 既存の `irb/` sub-gem 規約を完全踏襲:

```
rb-apple-sdk-mac/
├── lib/, ext/                              # 親 gem
├── irb/                                    # IRB sub-gem (既存)
│   ├── apple_sdk_mac-irb.gemspec
│   ├── lib/apple_sdk_mac/irb.rb
│   └── ...
└── mcp/                                    # MCP sub-gem (本 spec)
    ├── rb-apple-sdk-mac-mcp.gemspec
    ├── Gemfile, Gemfile.lock, Rakefile, README.md
    ├── exe/
    │   └── rb-apple-sdk-mac-mcp            # CLI entry (serve / probe サブコマンド)
    ├── scripts/
    │   └── start_mcp.sh                    # PATH workaround wrapper
    ├── docs/
    │   └── resources/                      # 静的 markdown 6 本 (Resource handler が読む)
    │       ├── discover-shapes.md
    │       ├── dispatch-flow.md
    │       ├── kind-catalog.md
    │       ├── override-recipes.md
    │       ├── proxy-wrap-rules.md
    │       └── callback-patterns.md
    ├── lib/
    │   └── apple_sdk_mac/
    │       ├── mcp.rb                      # 単一 require entry
    │       └── mcp/
    │           ├── server.rb               # Server / ServerFacade
    │           ├── tools/                  # 7 個
    │           │   ├── search.rb
    │           │   ├── get_symbol_info.rb
    │           │   ├── list_klass_methods.rb
    │           │   ├── suggest_discover_call.rb
    │           │   ├── dry_run_template.rb
    │           │   ├── validate_call.rb
    │           │   └── probe_capabilities.rb
    │           ├── resources/
    │           │   ├── static_doc_resource.rb
    │           │   ├── framework_list_resource.rb
    │           │   └── stats_resource.rb
    │           └── elicit/
    │               └── disambiguator.rb
    └── test/
        ├── test_helper.rb
        ├── server_test.rb
        ├── tools/
        ├── resources/
        └── elicit/
```

### 3.2 親 gem との依存関係

- **強依存**: `add_dependency "rb-apple-sdk-mac"`
  - `AppleSDKMac::PublicAPI._synthesize_symbol_record` を `suggest_discover_call` で呼ぶ
  - `AppleSDKMac::GlueCompiler::TemplateGenerator#generate` を `dry_run_template` で呼ぶ
  - `AppleSDKMac::GlueCompiler::ValidationGates#validate` を `validate_call` で呼ぶ
  - `AppleSDKMac::PublicAPI::KIND_SYM_TO_TYPE` を `override-recipes` Resource で参照
- **強依存**: `add_dependency "rb-apple-sdk-knowledge"` — KB 検索本体
- **強依存**: `add_dependency "mcp", ">= 0.13.0"` — Elicitation `create_form_elicitation` サポート版

親 gem `lib/apple_sdk_mac.rb` から MCP sub-gem を **auto-require しない**。 ユーザは明示的に `require "apple_sdk_mac/mcp"` した時だけロード。 IRB sub-gem と同じ規律。

### 3.3 命名規約

| 対象 | 名前 |
|---|---|
| gemspec name | `rb-apple-sdk-mac-mcp` |
| gemspec ファイル | `mcp/rb-apple-sdk-mac-mcp.gemspec` |
| CLI executable | `rb-apple-sdk-mac-mcp` |
| shell wrapper | `mcp/scripts/start_mcp.sh` |
| Ruby module | `AppleSDKMac::MCP` |
| Tool 名 prefix | `apple_sdk_mac_<verb>` |
| Resource URI prefix | `apple-sdk-mac://<topic>` |

### 3.4 名前衝突回避

`AppleSDKMac::MCP` 内で `MCP::Server` と書くと自分自身に解決されるため、 **`::MCP::...` (top-level) と書く規約を全 tool で徹底**。 IRB sub-gem の `::IRB::Context` と同じ流儀。

### 3.5 stdio transport + path workaround

`mcp/scripts/start_mcp.sh` (chiebukuro-mcp コピペ):

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
exec "$HOME/.rbenv/shims/bundle" exec ruby exe/rb-apple-sdk-mac-mcp serve
```

理由: Claude Code/Desktop が `command:` で spawn する際、 shell PATH が通っていないため `bundle` や `ruby` が直接呼べない。 絶対パスで bundle/ruby を起動し、 `cd "$SCRIPT_DIR/.."` で repo root に移動して `Gemfile` の path: dependency を解決させる。 `exec` でプロセス置換するから kill/restart も綺麗。

Claude Code 登録 (`~/.claude.json` or プロジェクト `.claude.json`):

```json
{
  "mcpServers": {
    "apple-sdk": {
      "command": "/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/mcp/scripts/start_mcp.sh"
    }
  }
}
```

shell wrapper の絶対パス 1 行のみ。

## 4. Tools (7 個)

全 tool 共通:
- `::MCP::Tool.define` block style
- `server_context: nil, **_` キーワードを受ける (chiebukuro-mcp 規約)
- 末尾 `rescue => e; ::MCP::Tool::Response.new([{type: 'text', text: e.message}], error: true)` でエラー応答
- `AppleSDKMac::MCP::Server.wrap_with_log(tool_name:)` ブロックで包む

### 4.1 `apple_sdk_mac_search`

KB の semantic + lexical 検索。

- **input_schema**:
  ```ruby
  {
    type: 'object',
    properties: {
      query: { type: 'string', description: '検索したい機能の自然言語表現' },
      framework: { type: 'string', description: '(optional) 特定 framework に限定' },
      kinds: { type: 'array', items: { type: 'string' },
               description: '(optional) function/class/swift_func/objc_method_instance 等で絞り込み' },
      limit: { type: 'integer', default: 10 }
    },
    required: ['query']
  }
  ```
- **behavior**: `KnowledgeCache#search` 呼び出し、 結果を JSON テキストで返す
- **元実装**: 親 gem の `lib/apple_sdk_mac/knowledge_cache.rb#search`

### 4.2 `apple_sdk_mac_get_symbol_info`

symbol full record (parameters_json 込み)。

- **input_schema**: `{ framework: string, symbol: string }`, both required
- **behavior**: `KnowledgeCache#lookup_symbol` 呼び出し、 transient → DB の優先順で record 返却

### 4.3 `apple_sdk_mac_list_klass_methods`

クラス子要素列挙。

- **input_schema**: `{ framework: string, klass: string }`, both required
- **behavior**: `KnowledgeCache#list_klass_methods` 呼び出し
- **用途**: `Apple::Foundation::URL.<TAB>` で見える候補と同じものを AI に渡す

### 4.4 `apple_sdk_mac_suggest_discover_call`

intent → `Apple.discover` kwargs 生成 (+ Elicitation で曖昧候補確認)。

- **input_schema**: `{ intent: string, framework?: string }`
- **behavior**:
  1. `KnowledgeCache#search` で上位 5 候補取得
  2. 上位 2 件の score 差 < `0.05` を 「曖昧」 と判定 → §6 elicitation flow へ
  3. 確定した record を `AppleSDKMac.send(:_synthesize_symbol_record, ...)` 相当ロジックで kwargs 化
  4. `framework: :Foundation, swift_func: :url_appendingPathComponent` 形に整形して JSON 返却
- **親 gem 強依存ポイント**: `_synthesize_symbol_record` の合成ロジックを再利用

### 4.5 `apple_sdk_mac_dry_run_template`

`TemplateGenerator#generate` だけ呼んで Swift glue source 文字列を返す (swiftc は走らせない)。

- **input_schema**: `{ framework: string, symbol_record: object }` — symbol_record は `get_symbol_info` の戻り値そのまま
- **behavior**:
  ```ruby
  template = ::AppleSDKMac::GlueCompiler::TemplateGenerator.new(
    knowledge_cache: kb
  )
  swift_source = template.generate(
    framework: framework,
    symbol: symbol_record,
    glue_id: 'dry_run_' + SecureRandom.hex(8)
  )
  swift_source.nil? ? "TemplateGenerator declined (LLM fallback path required)" : swift_source
  ```
- **用途**: AI が「ユーザが `Apple.discover` 走らせたら↑の Swift がコンパイルされる」を実行前に確認可能。 trust-but-verify ループ
- **親 gem 強依存ポイント**: `TemplateGenerator` 直接呼び出し

### 4.6 `apple_sdk_mac_validate_call`

Ruby コード片の `Apple::*` 呼び出しを KB で検証。

- **input_schema**: `{ ruby_code: string }`
- **behavior**:
  1. 正規表現で `Apple\.discover\(...\)` と `Apple::(\w+)::(\w+)\.(\w+)` を抽出
  2. KB に対して symbol 存在検証 / kind 一致検証
  3. 不存在シンボル / kind 不一致を warning として返す
- **swiftc は走らせない** (重い、 dry-run 役は §4.5)

### 4.7 `apple_sdk_mac_probe_capabilities`

MCP host が elicitation capability を宣言しているか実地確認 (chiebukuro-mcp 流)。

- **input_schema**: `{ type: 'object', properties: {} }` — 引数なし
- **behavior**: `server_context.client_capabilities` を覗いて `elicitation: true/false`、 `sampling: true/false` 等を文字列で報告
- **用途**: Claude Code 接続デバッグ、 elicitation 動作前の事前確認

## 5. Resources (8 URI)

「gem の自己解説」要件 (D6) を Resources で実現。 chiebukuro-mcp の `schema://` / `recipes://` / `hints://` 規約踏襲。

### 5.1 静的 markdown 6 個 (`mcp/docs/resources/` 配下)

| URI | 内容 |
|---|---|
| `apple-sdk-mac://discover-shapes` | 7 個の keyword shape (`symbol`/`selector`/`class_method`/`swift_func`/`swift_initializer`/`swift_property`/`type_args`) のマッピング表 + 各 shape の例 |
| `apple-sdk-mac://dispatch-flow` | `Apple.discover` → KB lookup → TemplateGen / LLM → swiftc → cache → install_into_box の全フロー図 (mermaid 含む) |
| `apple-sdk-mac://kind-catalog` | KB `kind` 全種類 (`function`/`swift_init`/`objc_method_instance`/...) → 生成される Ruby メソッド形 (`Apple::FW.foo` / `Apple::FW::Klass.foo` / `Apple::FW::Klass#foo`) の対応表 |
| `apple-sdk-mac://override-recipes` | `:params` / `:return_kind` override (T50 由来)、 `KIND_SYM_TO_TYPE` カタログ、 nilable Hash 指定。 親 gem の定数と同期 (build 時に `lib/apple_sdk_mac/public_api.rb` から自動抽出も検討) |
| `apple-sdk-mac://proxy-wrap-rules` | `opaque_ref` / `cftype_ref` 戻り値の auto-wrap、 `__opaque_ref` 仕組み、 `from_ref` クラスヘルパー |
| `apple-sdk-mac://callback-patterns` | `block_persistent` / `threading_enqueue_3` / async DispatchSemaphore のテンプレート例 |

実装: `StaticDocResource.new(filename)` が `File.read` するだけの薄い handler。

### 5.2 KB 動的 2 個

| URI | 内容 | データソース |
|---|---|---|
| `apple-sdk-mac://framework-list` | 全 framework + symbol 数 + kind 内訳 (markdown 表) | `KnowledgeCache#list_frameworks` + per-framework count query |
| `apple-sdk-mac://stats` | KB metadata (SDK version, ingest 日時, total frameworks/symbols, kind 分布) | KB `schema_meta` テーブル + 集計 query |

### 5.3 Resource handler 設計

`MCP::Server#resources_read_handler` で URI ごとに dispatch:

```ruby
mcp_server.resources_read_handler do |params|
  uri     = params[:uri]
  handler = resource_handlers[uri]
  next [] unless handler
  content = handler.call
  [{ uri: uri, mimeType: 'text/markdown', text: content }]
end
```

## 6. Elicitation flow

`apple_sdk_mac_suggest_discover_call` における曖昧候補解消 (chiebukuro-mcp `query_with_clarification_tool.rb` 同パターン):

```
[user] "URL から path component 追加したい"
   ↓ apple_sdk_mac_suggest_discover_call(intent: "...")
[server] KB.search → 上位 5 候補
   候補1: Foundation::URL.appendingPathComponent(_:)        score 0.91
   候補2: Foundation::URL.appendingPathComponent(_:isDirectory:)  score 0.89  ← score 差 0.02
   候補3: NSURL.URLByAppendingPathComponent:                score 0.74
   ...
   ↓ score 差 < 0.05 で「曖昧」判定
[server] server_context.create_form_elicitation(
            message: "「URL から path component 追加したい」 の候補が複数あります",
            requested_schema: {
              type: 'object',
              properties: {
                choice: {
                  type: 'string',
                  enum: ['Foundation::URL.appendingPathComponent(_:)',
                         'Foundation::URL.appendingPathComponent(_:isDirectory:)',
                         ...],
                  description: '使う Apple SDK symbol を選択'
                }
              },
              required: ['choice']
            }
          )
   ↓ Claude Code が UI で user に提示
[user] "isDirectory: あり版で"
   ↓ accept
[server] 選んだ record を _synthesize_symbol_record 相当で kwargs 化
   → returns {
       framework: :Foundation,
       swift_func: :url_appendingPathComponent_isDirectory,
       canonical_name: "URL.appendingPathComponent(_:isDirectory:)",
       example_ruby: "Apple.discover(framework: :Foundation, swift_func: ...)\nApple::Foundation::URL.appendingPathComponent(...)"
     }
```

`decline` / `cancel` 時:
```ruby
JSON.generate(action: 'decline', message: 'disambiguation declined by user. no kwargs synthesized.')
```

## 7. wrap_with_log (構造化 stderr ログ)

chiebukuro-mcp `Server.wrap_with_log_proc` 完全踏襲:

```ruby
def self.wrap_with_log(tool_name:, &block)
  t0     = Time.now
  result = block.call
  elapsed_ms = ((Time.now - t0) * 1000).to_i
  entry = {
    ts:         t0.iso8601,
    kind:       'tool_call',
    tool:       tool_name,
    elapsed_ms: elapsed_ms
  }
  warn JSON.generate(entry)
  result
end
```

stderr に JSON 1 行/呼び出し。 Claude (stdin/stdout) には漏れない。 性能観測・debug 用。

## 8. Implementation order (TDD)

| Phase | 内容 | gate |
|---|---|---|
| **v0.1** | scaffold (gemspec / Gemfile / Rakefile / exe / scripts / README) + `probe_capabilities` のみ | Claude Code から `tools/list` で 1 件、 `resources/list` で 0 件 (まだなし) 返ること |
| v0.2 | `apple_sdk_mac_search` | KB query 結果が JSON text response で返る、 framework / kind フィルタ動作 |
| v0.3 | `apple_sdk_mac_get_symbol_info` + `apple_sdk_mac_list_klass_methods` | KB lookup 全引き |
| v0.4 | `apple_sdk_mac_suggest_discover_call` + Elicitation disambiguator | 候補曖昧時に form_elicitation 発動、 accept/decline/cancel 全分岐動作 |
| v0.5 | `apple_sdk_mac_dry_run_template` + `apple_sdk_mac_validate_call` | 親 gem 強依存の dry-run / validation 動作 |
| v0.6 | 静的 Resources 6 個 | `mcp/docs/resources/*.md` を書き起こし、 Resource handler から read できる |
| v0.7 | KB 動的 Resources 2 個 (`framework-list` / `stats`) | KB query 結果が markdown 表として render される |

各 phase ごとに `bundle exec rake test` と Claude Code 接続実証 (`claude mcp call apple-sdk <tool> <args>`) を gate とする。

## 9. Acceptance criteria (v0.1 release)

### 9.1 機能 gate

- Claude Code から `tools/list` で 7 tool 全部見える
- Claude Code から `resources/list` で 8 resource 全部見える
- `apple_sdk_mac_search` が semantic + lexical 両対応で結果返す
- `apple_sdk_mac_suggest_discover_call` が score 差 0.05 以下の候補で elicitation 発動 → user 選択で kwargs 確定
- `apple_sdk_mac_dry_run_template` が TemplateGenerator が出した Swift source を AI に表示
- `apple_sdk_mac_validate_call` が KB に存在しないシンボルを warning として検出
- `apple_sdk_mac_probe_capabilities` が host capability を文字列報告
- `apple-sdk-mac://framework-list` が KB から動的に framework + symbol 数を返す

### 9.2 環境 gate

- shell wrapper 経由で macOS 26 / Ruby 4.x master 上で安定起動
- Claude Code (実行 host) と Claude Desktop (互換 host) の両方で接続成功
- elicitation 経路が `mcp` gem v0.13.0 以降で動作

### 9.3 ライセンス gate

- `git ls-files` 経由 gem build で SQLite 等の Apple SDK 派生物が混入しない (親 gem と同等の保護維持)
- `~/.cache/rb-apple-sdk-mac/...` の per-user glue dylib も commit されない
- `gem build` 後の `.gem` ファイル inspect で confirm

### 9.4 親 gem 影響 gate

- 親 gem `lib/apple_sdk_mac.rb` を **一切変更しない**
- 親 gem の test suite が引き続き全 pass する
- 親 gem `gemspec` の `add_dependency` 一覧に `mcp` / `rb-apple-sdk-mac-mcp` が混入しない

## 10. Out of scope (future spec)

- Cloud LLM 経由 MCP 接続 — Claude API direct, OpenAI ChatGPT plugin, etc.
- VS Code RubyMine LSP integration — 別アプローチ・別 spec
- RubyGems 公開 (商用配布) — IRB sub-gem 同様 path: dependency 限定
- 自然言語 → 完全な Ruby スクリプト 1 発生成 — sampling capability + 多 tool chain 必要
- Auto-update KB on Xcode upgrade — file watcher 機構、 別 spec
- HTTP/SSE transport (リモート MCP server 化) — stdio 限定で当面十分

## 11. References

- 親 gem: `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/README.md` + `docs/superpowers/specs/2026-05-06-complete-mac-api-bridge-design.md`
- IRB sub-gem 規約: `/Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac/irb/apple_sdk_mac-irb.gemspec` + `docs/superpowers/specs/2026-05-08-irb-subgem-and-doc-discover-design.md`
- 先行 MCP 実装: `/Users/bash/dev/src/github.com/bash0C7/chiebukuro-mcp/lib/chiebukuro_mcp/server.rb`、 `lib/chiebukuro_mcp/query_with_clarification_tool.rb`、 `scripts/start_mcp.sh`
- MCP Ruby SDK: `https://github.com/modelcontextprotocol/ruby-sdk` v0.15.0 (Elicitation v0.13.0+ 対応)
- Memory: `feedback_irb_subgem.md` (IRB 拡張 sub-gem 規約、 2026-05-08)
- Memory: `phase7_kb_override_and_qnil_guard.md` (T40-T50 KB 分類オーバーライドパターン)
