# rb-apple-sdk-mac-mcp

MCP server that surfaces [rb-apple-sdk-mac](https://github.com/bash0C7/rb-apple-sdk-mac)'s Apple SDK Knowledge Base to MCP-capable AI coding agents (Claude Code, Claude Desktop, etc.).

Logical sub-gem inside the parent repo: same source tree, separate `gemspec`, `path:` dependency to the parent. Never published independently to rubygems.org — the MCP layer is a development/dogfooding companion to the main gem, not a standalone artifact.

## What it does

The parent gem exposes Apple's macOS SDK to Ruby via dynamic Swift glue (`Apple.discover(...)` → per-symbol dylib build → method dispatch). Discovery requires the AI agent to know which framework + symbol form + parameter shape to feed to `Apple.discover`. This server hands the knowledge to the agent on demand:

- **Search the KB** by natural-language phrase across all 295+ Apple frameworks
- **Look up full records** (signature, parameters_json, return_kind, documentation)
- **List members of a klass** (instance/class methods, properties, init, enum_case)
- **Synthesize a `discover` call** from intent — disambiguates multiple candidates via the host's elicitation form
- **Dry-run TemplateGenerator** to preview the Swift glue source before `Apple.discover` actually compiles it
- **Validate** Ruby snippets that use `Apple.discover(...)` or post-discover `Apple::FW::Klass.method(...)` against the KB
- **Probe host capabilities** (elicitation / sampling) by real call

All seven tools emit a structured JSON line on stderr per invocation (`{ts, kind: "tool_call", tool, result_rows, elapsed_ms}`) so operators can observe traffic without intercepting the stdio JSON-RPC channel.

## Layout

```
mcp/                                 # this sub-gem
├── exe/rb-apple-sdk-mac-mcp         # CLI: serve | probe
├── scripts/start_mcp.sh             # PATH-safe launcher for Claude Code/Desktop subprocess spawn
├── rb-apple-sdk-mac-mcp.gemspec     # path-deps: rb-apple-sdk-mac, rb-apple-sdk-knowledge, mcp >= 0.13
├── Gemfile                          # path overrides matching irb/ sub-gem convention
├── lib/apple_sdk_mac/mcp.rb         # single require entry
├── lib/apple_sdk_mac/mcp/
│   ├── server.rb                    # ServerFacade + wrap_with_log
│   ├── tools/                       # 7 tools, each in its own file
│   └── resources/                   # static doc + dynamic KB resources
├── docs/resources/                  # markdown bundled as MCP Resources
└── test/                            # 70 tests via test-unit
```

## Install

The sub-gem expects the parent repo cloned at `..` and `rb-apple-sdk-knowledge` as a sibling at `../../rb-apple-sdk-knowledge`. Inside `mcp/`:

```bash
bundle install
```

This resolves the `path:` deps via `Gemfile`. The parent gem's KB must already be built; if not:

```bash
cd ..
bundle exec rake apple:knowledge:rebuild
```

## Run

### Direct stdio

```bash
bundle exec rb-apple-sdk-mac-mcp serve     # default — reads JSON-RPC on stdin
bundle exec rb-apple-sdk-mac-mcp probe     # list registered tool names without running the server
```

### From Claude Code

```bash
claude mcp add apple-sdk -- /path/to/rb-apple-sdk-mac/mcp/scripts/start_mcp.sh
```

`start_mcp.sh` calls `$HOME/.rbenv/shims/bundle` with an absolute path, so it works under Claude Code's `PATH`-stripped subprocess environment (same workaround chiebukuro-mcp uses).

### From Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "apple-sdk": {
      "command": "/path/to/rb-apple-sdk-mac/mcp/scripts/start_mcp.sh"
    }
  }
}
```

## Tools

| Name | Purpose |
|---|---|
| `apple_sdk_mac_search` | KB search by phrase; multi-token natural language is split into 3+ char tokens and OR-joined to dodge FTS5 default AND |
| `apple_sdk_mac_get_symbol_info` | Full KB record for a (framework, symbol) pair |
| `apple_sdk_mac_list_klass_methods` | Members of a klass / struct / actor / protocol |
| `apple_sdk_mac_suggest_discover_call` | intent → `Apple.discover` kwargs; uses elicitation when ≥ 2 candidates; falls back to candidates list when host lacks elicitation |
| `apple_sdk_mac_dry_run_template` | Preview Swift glue source from `TemplateGenerator` (no `swiftc`); LLM-fallback path returns `declined` |
| `apple_sdk_mac_validate_call` | Check Ruby snippets — extracts `Apple.discover(...)` blocks AND direct `Apple::FW(::Klass)?.method(...)` calls, reports unknown symbols |
| `apple_sdk_mac_probe_capabilities` | Empirically probe whether the host implements elicitation / sampling by real-call + rescue (chiebukuro-mcp pattern) |

## Resources

Static markdown reference docs are exposed as MCP Resources so the host can pre-load them into context:

| URI | Content |
|---|---|
| `apple-sdk-mac://discover-shapes` | The 7 keyword shapes for `Apple.discover` |
| `apple-sdk-mac://dispatch-flow` | `Apple.discover` → glue compile → method dispatch full flow |
| `apple-sdk-mac://kind-catalog` | KB `kind` ↔ generated Ruby method form mapping |
| `apple-sdk-mac://override-recipes` | `params:` / `return_kind:` override recipes |
| `apple-sdk-mac://proxy-wrap-rules` | `opaque_ref` / `cftype_ref` auto-wrap rules |
| `apple-sdk-mac://callback-patterns` | callback / async / threading / event_loop guide |
| `apple-sdk-mac://framework-list` | (dynamic) all frameworks present in the local KB |
| `apple-sdk-mac://stats` | (dynamic) framework count, symbol count, kind breakdown |

## Logging

Every tool invocation writes one JSON line to stderr:

```json
{"ts":"2026-05-08T10:26:50+09:00","kind":"tool_call","tool":"apple_sdk_mac_search","result_rows":7,"elapsed_ms":42}
```

`result_rows` is best-effort: an array payload's length, or 0 for object/scalar payloads or unparseable text. Runs cleanly alongside the JSON-RPC stream on stdout.

## Tests

```bash
bundle exec rake test
```

70 tests / 132 assertions / 100% pass at the time of writing. The test suite uses `test-unit`, fake `Struct`-based KBs, and `capture_stderr` in `test_helper.rb` to assert log output.

## Design references

- Spec: [`docs/superpowers/specs/2026-05-08-rb-apple-sdk-mac-mcp-design.md`](../docs/superpowers/specs/2026-05-08-rb-apple-sdk-mac-mcp-design.md) — full design, 11 sections, decision points D1-D6
- Reference implementation pattern: [chiebukuro-mcp](https://github.com/bash0C7/chiebukuro-mcp) — `ServerFacade`, `wrap_with_log_proc`, real-call `ProbeTool`, `start_mcp.sh` PATH workaround
- MCP gem: [modelcontextprotocol/ruby-sdk](https://github.com/modelcontextprotocol/ruby-sdk) (`mcp` >= 0.13.0 for elicitation)

## License

MIT, same as the parent gem.
