# frozen_string_literal: true

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
