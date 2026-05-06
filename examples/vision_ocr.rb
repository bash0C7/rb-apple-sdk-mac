#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "apple_sdk_mac"

# Apple.bootstrap! eagerly populates Apple::<Framework> modules and type
# constants from the knowledge base. No glue is compiled until a method is
# actually called.
Apple.bootstrap!

# Phase 7: Vision class instantiation (alloc/init) and Block-based completion
# handlers are out of scope. This example demonstrates that the namespace is
# discoverable — listing the first 10 Vision types the knowledge base knows
# about is a useful smoke test of bootstrap!.
puts Apple::Vision.constants.first(10).inspect
