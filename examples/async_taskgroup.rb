# frozen_string_literal: true
# Phase 7 example: Swift structured concurrency / TaskGroup parallel
# fan-out (spec §3.6 Worked Example E2). Demonstrates the
# DispatchSemaphore + Task { try await withThrowingTaskGroup ... }
# skeleton via the runtime's async_await_sleep_and_double — invoked
# in 3 Ruby threads to mirror parallel async fan-out at the call layer
# while the underlying Swift Task uses the structured concurrency
# runtime.
#
# Usage:
#   RUBY_BOX=1 bundle exec ruby examples/async_taskgroup.rb
require "apple_sdk_mac"

inputs = (ENV["TASKGROUP_INPUTS"] || "10,20,30").split(",").map(&:to_i)

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
results = inputs.map do |ms|
  Thread.new { AppleSDKMacRuntime::Test.async_await_sleep_and_double(ms) }
end.map(&:value)
elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

puts "inputs=#{inputs.inspect}"
puts "results=#{results.inspect}"
puts "elapsed_ms=#{elapsed_ms}"

expected = inputs.map { |x| x * 2 }
raise "expected #{expected.inspect}, got #{results.inspect}" unless results == expected

# Parallel fan-out check: total elapsed < 2× the longest single sleep.
# (Sequential would be sum(inputs); parallel should be ≤ max(inputs)+overhead.)
longest = inputs.max
unless elapsed_ms < (longest * 2 + 100)
  warn "WARN: elapsed_ms=#{elapsed_ms} suggests sequential execution; " \
       "expected near max(inputs)=#{longest} for true parallel fan-out"
end

puts "TaskGroup OK"
