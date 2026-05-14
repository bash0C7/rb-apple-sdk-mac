# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in rb-apple-sdk-mac.gemspec
gemspec

# Local sibling repo during development. Comment out once swift_gem is published.
gem "swift_gem", git: "https://github.com/bash0C7/swift_gem"

gem "rb-apple-sdk-knowledge", path: "knowledge"

gem "rake", "~> 13.0"
gem "rake-compiler", "~> 1.2"
gem "test-unit", "~> 3.0"
gem "fiddle"  # Test-only: MIDIPacketList byte-packing in test_send_packet_via_midi_received

# Logical sub-gem inside this repo (irb/). Path-loaded so users developing
# the IRB autocomplete + LLM doc preview features get the dependency tree
# (irb / reline / repl_type_completor / foundation_model_mac) without
# polluting the main gemspec.
group :development do
  gem "apple_sdk_mac-irb", path: "irb"
  # tooling/ HITL emitter-improvement RedundancyScanner (Ruby AST 走査)
  gem "parser"
end
