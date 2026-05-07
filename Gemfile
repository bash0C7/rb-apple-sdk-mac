# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in rb-apple-sdk-mac.gemspec
gemspec

# Local sibling repo during development. Comment out once swift_gem is published.
gem "swift_gem", git: "https://github.com/bash0C7/swift_gem"

gem "rb-foundation-model-mac", path: "../rb-foundation-model-mac"
gem "rb-apple-sdk-knowledge", path: "../rb-apple-sdk-knowledge"

gem "irb"
# Type-based completor: Box constants を enumerate しないため Ruby 4.0 + RUBY_BOX=1
# でも安全。 Apple:: 以外の input (String. 等) を補完する base として install! が
# IRB.conf[:COMPLETOR] = :type に切り替えて、 Apple Completor が delegate する。
gem "repl_type_completor"
gem "rake", "~> 13.0"
gem "rake-compiler", "~> 1.2"
gem "test-unit", "~> 3.0"
gem "fiddle"  # Test-only: MIDIPacketList byte-packing in test_send_packet_via_midi_received
