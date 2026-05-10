# frozen_string_literal: true
require "test_helper"

# RSS growth budget for example dispatch loops.
# Acceptance: after warmup + N iterations of the example dispatch, RSS
# growth ≤ 5MB. Ensures BoxedBlockHandle / BoxedCFType / opaque ref
# autorelease paths actually release.
#
# Iteration count is small by default so the test runs in CI; bump
# MEMORY_LEAK_ITERS=1000 to exercise the full budget.
class TestMemoryLeak < Test::Unit::TestCase
  ITERS  = Integer(ENV["MEMORY_LEAK_ITERS"] || 200)
  BUDGET_MB = Float(ENV["MEMORY_LEAK_BUDGET_MB"] || 5.0)

  def rss_mb
    # macOS-only — ps -o rss reports KB.
    rss_kb = `ps -o rss= -p #{Process.pid}`.to_i
    rss_kb / 1024.0
  end

  def test_canonical_midi_dispatch_loop_does_not_leak
    Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)
    # Warmup primes Dispatcher cache + JIT + RSS levels.
    50.times { Apple::CoreMIDI.MIDIClientCreate("warmup", nil, nil) }

    GC.start
    rss_before = rss_mb
    ITERS.times { Apple::CoreMIDI.MIDIClientCreate("leak-test", nil, nil) }
    GC.start
    rss_after = rss_mb

    delta = rss_after - rss_before
    assert_operator delta, :<=, BUDGET_MB,
      "RSS grew by #{delta.round(2)} MB over #{ITERS} iters " \
      "(before=#{rss_before.round(2)} MB, after=#{rss_after.round(2)} MB; " \
      "budget=#{BUDGET_MB} MB)"
  end

  def test_cf_string_create_loop_does_not_leak_under_autoarc
    Apple.discover(framework: :CoreFoundation, symbol: :CFStringCreateWithCString)
    50.times { Apple::CoreFoundation.CFStringCreateWithCString(nil, "warm", 0x08000100) }

    GC.start
    rss_before = rss_mb
    ITERS.times { Apple::CoreFoundation.CFStringCreateWithCString(nil, "loop", 0x08000100) }
    GC.start
    rss_after = rss_mb

    delta = rss_after - rss_before
    assert_operator delta, :<=, BUDGET_MB,
      "CF auto-ARC RSS grew by #{delta.round(2)} MB over #{ITERS} iters " \
      "(before=#{rss_before.round(2)} MB, after=#{rss_after.round(2)} MB)"
  end
end
