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
end
