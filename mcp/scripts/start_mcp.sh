#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
exec "$HOME/.rbenv/shims/bundle" exec ruby exe/rb-apple-sdk-mac-mcp serve
