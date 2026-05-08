# frozen_string_literal: true

require_relative "../lib/apple_sdk_mac/version"

Gem::Specification.new do |spec|
  spec.name = "rb-apple-sdk-mac-mcp"
  spec.version = AppleSdkMac::VERSION
  spec.authors = ["bash0C7"]
  spec.email = ["ksb.4038.nullpointer+github@gmail.com"]

  spec.summary = "MCP server exposing rb-apple-sdk-mac's Apple SDK knowledge to AI coding agents"
  spec.description = <<~DESC
    Logical sub-gem of rb-apple-sdk-mac providing a stdio MCP server that
    surfaces the local Apple SDK knowledge base to MCP-capable AI coding
    agents (Claude Code / Claude Desktop). Ships search / lookup tools and
    an elicitation-driven discover-call synthesizer that disambiguates
    semantic search candidates by asking the user via the host's elicitation
    UI. Bound to the parent gem via path: dependency, never published
    independently to rubygems.org.
  DESC
  spec.homepage = "https://github.com/bash0C7/rb-apple-sdk-mac"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/bash0C7/rb-apple-sdk-mac/tree/main/mcp"

  spec.files = Dir.chdir(__dir__) do
    Dir.glob(["lib/**/*.rb", "exe/*", "scripts/*", "docs/resources/*.md", "README.md"]).reject { |f| File.directory?(f) }
  end
  spec.bindir = "exe"
  spec.executables = ["rb-apple-sdk-mac-mcp"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rb-apple-sdk-mac"
  spec.add_dependency "rb-apple-sdk-knowledge"
  spec.add_dependency "mcp", ">= 0.13.0"

  spec.add_development_dependency "test-unit", "~> 3.6"
  spec.add_development_dependency "rake", "~> 13.0"
end
