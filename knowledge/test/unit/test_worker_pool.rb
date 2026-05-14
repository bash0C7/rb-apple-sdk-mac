# frozen_string_literal: true
require "test/unit"
require "rb_apple_sdk_knowledge/importer/result_channel"
require "rb_apple_sdk_knowledge/importer/worker_pool"

class TestWorkerPool < Test::Unit::TestCase
  class EchoWorker
    def call(framework:, header:)
      { result: { fw: framework, hdr: header }, error: nil, elapsed_ms: 1 }
    end
  end

  def submit_and_drain(size:, count:)
    channel = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: count + 4)
    pool = AppleSDKKnowledge::Importer::WorkerPool.new(
      size: size,
      worker_factory: -> { EchoWorker.new },
      channel: channel
    )
    count.times { |i| pool.submit(seq: i, payload: { framework: "F", header: "h#{i}" }) }
    pool.shutdown(wait: true)

    collected = []
    channel.each_ordered { |item| collected << item[:payload][:result][:hdr] }
    collected
  end

  def test_n1_processes_items_in_seq_order
    assert_equal (0...20).map { |i| "h#{i}" }, submit_and_drain(size: 1, count: 20)
  end

  def test_n2_processes_items_in_seq_order
    assert_equal (0...20).map { |i| "h#{i}" }, submit_and_drain(size: 2, count: 20)
  end

  def test_n4_processes_items_in_seq_order
    assert_equal (0...20).map { |i| "h#{i}" }, submit_and_drain(size: 4, count: 20)
  end

  def test_worker_response_includes_original_request_under_request_key
    channel = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 16)
    pool = AppleSDKKnowledge::Importer::WorkerPool.new(
      size: 1,
      worker_factory: -> { EchoWorker.new },
      channel: channel
    )
    pool.submit(seq: 0, payload: { framework: "Foo", header: "h0" })
    pool.shutdown(wait: true)
    item = nil
    channel.each_ordered { |i| item = i }
    assert_equal "h0", item[:payload][:request][:header]
    assert_equal "Foo", item[:payload][:request][:framework]
  end

  class CrashWorker
    def call(framework:, header:)
      Process.kill("KILL", $$)
      sleep 1
    end
  end

  def test_worker_crash_yields_error_payload_for_pending_seqs
    channel = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 16)
    pool = AppleSDKKnowledge::Importer::WorkerPool.new(
      size: 1,
      worker_factory: -> { CrashWorker.new },
      channel: channel
    )
    pool.submit(seq: 0, payload: { framework: "Foo", header: "h0" })
    pool.shutdown(wait: true)
    collected = []
    channel.each_ordered { |i| collected << i }
    assert_equal 1, collected.size
    assert_nil collected[0][:payload][:result]
    assert_match(/worker crashed/, collected[0][:payload][:error])
  end

  def test_processes_more_items_than_buffer_size_without_deadlock
    # ResultChannel buffer (4) より多くの item (20) を投入し、 deadlock せず取れる
    channel = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 4)
    pool = AppleSDKKnowledge::Importer::WorkerPool.new(
      size: 2,
      worker_factory: -> { EchoWorker.new },
      channel: channel
    )

    # 別 thread で submit + shutdown を実行、 main は drain
    bg = Thread.new do
      20.times { |i| pool.submit(seq: i, payload: { framework: "F", header: "h#{i}" }) }
      pool.shutdown(wait: true)
    end

    collected = []
    channel.each_ordered { |item| collected << item[:payload][:request][:header] }
    bg.join

    assert_equal (0...20).map { |i| "h#{i}" }, collected
  end
end
