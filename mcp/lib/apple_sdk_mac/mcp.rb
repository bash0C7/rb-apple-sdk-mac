# frozen_string_literal: true

# MCP server exposing the Apple SDK knowledge base to MCP-capable AI agents.
#
# Activated by:
#   require "apple_sdk_mac"      # main gem
#   require "apple_sdk_mac/mcp"  # this sub-gem
#   AppleSDKMac::MCP::Server.new.run  # blocks (stdio transport)
#
# Logical sub-gem inside the rb-apple-sdk-mac repo, path-loaded via Gemfile.
# Never auto-required by lib/apple_sdk_mac.rb so non-MCP users do not pull
# in the mcp gem dependency.
#
# NOTE: the upstream `mcp` gem is referenced as `::MCP::...` because bare
# `MCP` inside `module AppleSDKMac::MCP` resolves to self (this module),
# not the upstream gem — same convention IRB sub-gem uses for stdlib IRB.

require "apple_sdk_mac"
require "mcp"

require_relative "mcp/server"
require_relative "mcp/tools/probe_capabilities"
require_relative "mcp/tools/search"
require_relative "mcp/tools/get_symbol_info"
require_relative "mcp/tools/list_klass_methods"
require_relative "mcp/tools/suggest_discover_call"
require_relative "mcp/tools/dry_run_template"
require_relative "mcp/tools/validate_call"
require_relative "mcp/resources/static_doc_resource"
require_relative "mcp/resources/framework_list_resource"
require_relative "mcp/resources/stats_resource"

module AppleSDKMac
  module MCP
  end
end
