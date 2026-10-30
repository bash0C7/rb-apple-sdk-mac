# rb-apple-sdk-mac-mcp

MCP server that exposes [rb-apple-sdk-mac](https://github.com/bash0C7/rb-apple-sdk-mac)'s Apple SDK Knowledge Base to MCP-capable AI coding agents (Claude Code, Claude Desktop, and others).

This is a sub-gem of the parent repository with its own gemspec and a `path:` dependency on the parent. It is not published to rubygems.org.

## What it does

The parent gem calls Apple SDK APIs through per-symbol Swift glue. To write an `Apple.discover` call, an agent needs the framework, the symbol form, and the parameter shape. This server provides them on demand:

- Search the Knowledge Base by natural-language phrase
- Look up full symbol records (signature, `parameters_json`, return kind, documentation)
- List the members of a class, struct, actor, or protocol
- Synthesize an `Apple.discover` call from an intent, asking the user through elicitation when several candidates match
- Preview the Swift glue `TemplateGenerator` would emit
- Validate Ruby snippets that call `Apple.discover(...)` or `Apple::FW::Klass.method(...)`
- Probe whether the host implements elicitation and sampling

Every tool call writes one JSON line to stderr: `{ts, kind: "tool_call", tool, result_rows, elapsed_ms}`. `result_rows` is the length of an array payload, or 0.

## Layout

```
mcp/
├── exe/rb-apple-sdk-mac-mcp         # CLI: serve | probe
├── scripts/start_mcp.sh             # launcher for MCP hosts
├── rb-apple-sdk-mac-mcp.gemspec
├── Gemfile
├── sig/apple_sdk_mac_mcp.rbs
├── lib/apple_sdk_mac/mcp.rb
├── lib/apple_sdk_mac/mcp/
│   ├── server.rb
│   ├── tools/
│   └── resources/
├── docs/resources/                  # markdown served as MCP resources
└── test/
```

## Installation

The server runs under the parent repository's bundle, which includes this sub-gem, and reads the Knowledge Base under the parent's `.rb-apple-sdk-mac/`. In the repository root:

```bash
bundle install
bundle exec rake compile
bundle exec rake apple:knowledge:rebuild
```

## Run

From the repository root:

```bash
bundle exec ruby mcp/exe/rb-apple-sdk-mac-mcp serve
bundle exec ruby mcp/exe/rb-apple-sdk-mac-mcp probe
```

`serve` reads JSON-RPC on stdin; `probe` prints the registered tool names.

### From Claude Code

The repository's `.mcp.json` registers the server as `apple-sdk`. To add it to another project:

```bash
claude mcp add apple-sdk -- /path/to/rb-apple-sdk-mac/mcp/scripts/start_mcp.sh
```

`start_mcp.sh` changes to the repository root and runs `$HOME/.rbenv/shims/bundle` by absolute path, so it does not depend on the host's `PATH`.

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
| `apple_sdk_mac_search` | Knowledge Base search by phrase; a multi-word phrase is split into tokens of three or more characters and OR-joined |
| `apple_sdk_mac_get_symbol_info` | Full Knowledge Base record for a (framework, symbol) pair |
| `apple_sdk_mac_list_klass_methods` | Members of a class, struct, actor, or protocol |
| `apple_sdk_mac_suggest_discover_call` | Intent → `Apple.discover` keyword arguments; asks through elicitation when two or more candidates match and returns the candidate list when the host lacks elicitation |
| `apple_sdk_mac_dry_run_template` | Swift glue preview from `TemplateGenerator` without running `swiftc` |
| `apple_sdk_mac_validate_call` | Checks `Apple.discover(...)` blocks and `Apple::FW(::Klass)?.method(...)` calls in a Ruby snippet and reports unknown symbols |
| `apple_sdk_mac_probe_capabilities` | Probes host elicitation and sampling support with real calls |

## Resources

| URI | Content |
|---|---|
| `apple-sdk-mac://discover-shapes` | The keyword shapes of `Apple.discover` |
| `apple-sdk-mac://dispatch-flow` | `Apple.discover` → glue compile → method dispatch |
| `apple-sdk-mac://kind-catalog` | Knowledge Base `kind` ↔ generated Ruby method form |
| `apple-sdk-mac://override-recipes` | `params:` / `return_kind:` override recipes |
| `apple-sdk-mac://proxy-wrap-rules` | `opaque_ref` / `cftype_ref` auto-wrap rules |
| `apple-sdk-mac://callback-patterns` | Callback, async, threading, and `event_loop` guide |
| `apple-sdk-mac://framework-list` | Frameworks in the local Knowledge Base |
| `apple-sdk-mac://stats` | Framework count, symbol count, and kind breakdown |

## Development

In `mcp/`:

```bash
bundle install
bundle exec rake test
```

`rake test` validates `sig/apple_sdk_mac_mcp.rbs`, then runs the tests against fake Knowledge Bases.

`bundle exec rake probe:headless_e2e` runs all seven tools through nested `claude -p` in a detached `screen` session and logs to `tmp/longrun/apple-mcp-e2e-<ts>.log` in the repository root, ending with a `DONE:` line. Headless `claude -p` cancels elicitation forms, so `suggest_discover_call` reports `action: cancel` there; `docs/elicitation-headless-investigation.md` covers the interactive accept and decline paths.

## License

MIT
