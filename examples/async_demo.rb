# frozen_string_literal: true
# Phase 7 example: Swift `async` / single `await` round-trip from Ruby.
#
# Demonstrates the Async pillar's DispatchSemaphore + Task skeleton: the
# Ruby thread blocks on a Swift Task that awaits Task.sleep, doubles the
# argument, and returns. The skeleton is the same one the Glue Compiler
# enforces for all `await`-bearing glue (LLM Worked Example E1).
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/async_demo.rb
require "apple_sdk_mac"

ms = Integer(ENV["ASYNC_SLEEP_MS"] || 50)
result = AppleSDKMacRuntime::Test.async_await_sleep_and_double(ms)
puts "input=#{ms}"
puts "result=#{result}"
raise "expected #{ms * 2}, got #{result}" unless result == ms * 2
puts "async OK"
