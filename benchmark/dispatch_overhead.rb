# frozen_string_literal: true
# Phase 7 / spec §9 — cached-call dispatch latency benchmark.
# Acceptance: p99 ≤ 200µs after cache hit, measured on macOS 26 hardware.
#
# Run: RUBY_BOX=1 bundle exec ruby benchmark/dispatch_overhead.rb
# Exit status 0 on PASS (p99 ≤ 200µs), 1 on FAIL.
require "apple_sdk_mac"

ITERS = Integer(ENV["BENCH_ITERS"] || 5_000)
WARMUP = 200
BUDGET_US = Float(ENV["BENCH_BUDGET_US"] || 200.0)

Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

# Warmup — discover/compile happens above; warmup primes
# Dispatcher#dispatch path cache + branch predictors.
WARMUP.times { Apple::CoreMIDI.MIDIClientCreate("warmup", nil, nil) }

samples = Array.new(ITERS)
clock = Process.method(:clock_gettime)

ITERS.times do |i|
  t0 = clock.call(Process::CLOCK_MONOTONIC, :nanosecond)
  Apple::CoreMIDI.MIDIClientCreate("bench", nil, nil)
  t1 = clock.call(Process::CLOCK_MONOTONIC, :nanosecond)
  samples[i] = t1 - t0
end

samples.sort!
def percentile(samples, p)
  samples[(samples.size * p).to_i]
end

p50_us = percentile(samples, 0.50) / 1000.0
p99_us = percentile(samples, 0.99) / 1000.0
p999_us = percentile(samples, 0.999) / 1000.0

puts "iterations:     #{ITERS}"
puts "p50:            #{p50_us.round(2)}µs"
puts "p99:            #{p99_us.round(2)}µs"
puts "p99.9:          #{p999_us.round(2)}µs"
puts "budget (p99):   #{BUDGET_US}µs"

if p99_us <= BUDGET_US
  puts "RESULT: PASS"
  exit 0
else
  puts "RESULT: FAIL — p99 (#{p99_us.round(2)}µs) exceeds budget #{BUDGET_US}µs"
  exit 1
end
