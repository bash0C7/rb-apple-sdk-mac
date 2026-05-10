# frozen_string_literal: true
require "test_helper"

# thread-safety acceptance. 16 threads × 100
# discover/dispatch calls against the shared cache, registry, and
# dispatcher must complete with:
# - no race / no exception
# - no double-compile (same glue_id appears once in compiled_glue table)
# - no Hash corruption (transient lookup tier remains consistent)
#
# Iteration count is configurable; spec target is 16×100 = 1600 calls.
class TestConcurrentDiscover < Test::Unit::TestCase
  THREADS = Integer(ENV["CONCURRENT_DISCOVER_THREADS"] || 16)
  PER_THREAD = Integer(ENV["CONCURRENT_DISCOVER_ITERS"] || 100)

  def test_parallel_discover_and_dispatch_is_race_free
    # Pre-discover so the first concurrent call doesn't trigger 16
    # parallel compiles for the same symbol — that would be a separate
    # double-compile race we test below.
    Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

    errors = Queue.new
    threads = THREADS.times.map do |tid|
      Thread.new do
        begin
          PER_THREAD.times do |i|
            client = Apple::CoreMIDI.MIDIClientCreate("t#{tid}i#{i}", nil, nil)
            errors << "thread #{tid} iter #{i} got nil client" if client.nil?
            errors << "thread #{tid} iter #{i} got 0 client"   if client == 0
          end
        rescue => e
          errors << "thread #{tid}: #{e.class}: #{e.message}"
        end
      end
    end
    threads.each(&:join)

    if errors.size > 0
      msgs = []
      msgs << errors.pop until errors.empty?
      flunk "concurrent dispatch reported #{msgs.size} errors. First 5:\n  - #{msgs.first(5).join("\n  - ")}"
    end
  end

  def test_concurrent_discover_does_not_double_compile
    # A symbol not yet discovered in this process — first thread to win
    # the lock compiles, the others should reuse the compiled glue.
    sym = :MIDIClientDispose
    cache = AppleSDKMac.glue_cache
    db = cache.db
    before_n = db.execute("SELECT COUNT(*) FROM compiled_glue WHERE symbol_name = ?", [sym.to_s]).first[0]

    threads = THREADS.times.map do
      Thread.new do
        Apple.discover(framework: :CoreMIDI, symbol: sym)
      rescue => e
        Thread.current[:err] = e
      end
    end
    threads.each(&:join)
    raised = threads.compact.map { |t| t[:err] }.compact
    assert_empty raised, "concurrent discover raised: #{raised.first(3).inspect}"

    after_n = db.execute("SELECT COUNT(*) FROM compiled_glue WHERE symbol_name = ?", [sym.to_s]).first[0]
    delta = after_n - before_n
    assert_operator delta, :<=, 1,
      "expected at most 1 new compiled_glue row (single compile, others reuse); got delta=#{delta}"
  end
end
