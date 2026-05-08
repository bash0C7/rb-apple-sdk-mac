# Elicitation behavior under Claude Code (headless vs interactive)

Phase F E2E (2026-05-08) で `suggest_discover_call` が `action: cancel`
しか返さなかった件の調査記録と、 別 host での再検証手順。

## 観察された事実

`~/Library/Caches/claude-cli-nodejs/-Users-bash-dev-src-github-com-bash0C7-rb-apple-sdk-mac/mcp-logs-apple-sdk/<ts>.jsonl` に
以下の debug 行が残っている:

```jsonl
{"debug":"Elicitation request received in print mode: {…full payload…}","timestamp":"…"}
{"debug":"Tool 'apple_sdk_mac_suggest_discover_call' completed successfully in 16ms","timestamp":"…"}
```

「`Elicitation request received in print mode`」 という文言が決定打。
`claude -p` (= print mode = headless) は elicitation request を**受け取り
ログに記録するが、 UI 提示せず暗黙の cancel response を MCP server に返却
する**仕様。 結果 server 側は `action: cancel` で受領。

## Server 側 wrap_with_log は Claude Code 経由では visible にならない

同じログを見ると、 wrap_with_log の生 stderr `{"kind":"tool_call",…}` は
**素通りしていない**。 代わりに Claude Code が独自の
`{"debug":"Calling MCP tool: …","timestamp":"…","sessionId":"…"}` 形式に
書き換えてログしている。 つまり:

- Claude Code 経由の production observability では Claude Code 自身の log
  で十分 (tool 名 / 経過 ms が同等情報として出る)
- 自前 wrap_with_log は MCP Inspector / unit test / 直起動 (ruby + stdio)
  でのみ visible

ただし wrap_with_log は test で確実に動く (server_test.rb / search_test.rb
の `capture_stderr` 経由で検証済) ので、 ad-hoc 起動時の安心材料として
残す価値はある。

## Interactive Claude Code / MCP Inspector で再検証する手順

`claude -p` ではない経路で同じ tool を呼ぶと、 elicitation が
`action: accept` (候補選択) や `action: decline` まで踏める。

### A. Interactive Claude Code (TTY)

```sh
claude
> mcp で apple-sdk の suggest_discover_call を intent="create a CoreMIDI client", framework="CoreMIDI" で呼んで
```

入力候補 enum の form が画面に出るので 1 つ選ぶ → server は
`action: accept`, `selected: ...` を受領。 cancel ボタンを押せば
`action: cancel`、 form を閉じれば host 仕様による。

### B. MCP Inspector

```sh
npx @modelcontextprotocol/inspector \
  ruby -Imcp/lib mcp/exe/rb-apple-sdk-mac-mcp
```

ブラウザ UI で tool を選び、 引数を入れて呼ぶと Inspector が elicitation
form を modal 表示する。 全 5 action (accept / decline / cancel / candidates
/ unsupported) のうち accept / decline / cancel を交互に試して挙動確認可能。

## Headless 再現 (Phase F の再走)

`bundle exec rake probe:headless_e2e` で screen detached session 起動。
完了は `grep '^DONE:' tmp/longrun/apple-mcp-e2e-<ts>.log`。

`claude -p` 経由なので suggest_discover_call は cancel が返る (期待通り)。
validate_call の `checked_count` は **2** (#1 fix 後)、 1 だと regression。
