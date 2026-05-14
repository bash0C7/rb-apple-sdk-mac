# frozen_string_literal: true
require "test/unit"
require "rb_apple_sdk_knowledge/importer/result_channel"

class TestResultChannel < Test::Unit::TestCase
  def test_out_of_order_push_yields_seq_order
    ch = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 8)
    ch.push(seq: 2, payload: { v: "c" })
    ch.push(seq: 0, payload: { v: "a" })
    ch.push(seq: 1, payload: { v: "b" })
    ch.close

    collected = []
    ch.each_ordered { |item| collected << item[:payload][:v] }
    assert_equal ["a", "b", "c"], collected
  end

  def test_blocks_until_next_seq_arrives_then_resumes
    ch = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 8)
    pusher = Thread.new do
      sleep 0.05
      ch.push(seq: 0, payload: { v: "a" })
      sleep 0.05
      ch.push(seq: 1, payload: { v: "b" })
      ch.close
    end
    seen = []
    ch.each_ordered { |item| seen << item[:seq] }
    pusher.join
    assert_equal [0, 1], seen
  end

  def test_close_with_empty_buffer_terminates
    ch = AppleSDKKnowledge::Importer::ResultChannel.new(buffer_size: 8)
    ch.close
    collected = []
    ch.each_ordered { |item| collected << item }
    assert_equal [], collected
  end
end
