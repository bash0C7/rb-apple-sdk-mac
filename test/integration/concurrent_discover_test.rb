# frozen_string_literal: true
require "test_helper"

class TestConcurrentDiscover < Test::Unit::TestCase
  THREADS = Integer(ENV["CONCURRENT_DISCOVER_THREADS"] || 16)
  PER_THREAD = Integer(ENV["CONCURRENT_DISCOVER_ITERS"] || 100)

  def test_parallel_discover_and_dispatch_is_race_free
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
