# test/round_trip/poc_loop_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/poc_loop"

class PocLoopTest < Test::Unit::TestCase
  L = AppleSDKMac::RoundTrip::PocLoop

  # green を最初の試行で出す backend
  class GreenBackend
    attr_reader :calls
    def initialize; @calls = []; end
    def generate_glue(seed:, **)
      @calls << seed
      "glue-v#{@calls.size}"
    end
  end

  def test_green_on_first_try
    backend = GreenBackend.new
    harness = ->(glue) { glue == "glue-v1" } # 一発 green
    loop_ = L.new(backend: backend, harness_check: harness, budget: 3)
    r = loop_.run(framework: "CoreAudio", symbol: { name: "x" },
                  rule_scaffold: "SEED")
    assert_true r.green?
    assert_equal "glue-v1", r.glue
    assert_equal 1, backend.calls.size
    assert_equal "SEED", backend.calls.first[:rule_scaffold] # ルール足場が seed に注入される
  end

  def test_red_then_green_feeds_failure_detail_back
    backend = GreenBackend.new
    # v1 は RED, v2 で green。失敗 detail が次 seed に渡ることを確認。
    harness = ->(glue) { glue == "glue-v2" }
    loop_ = L.new(backend: backend, harness_check: harness, budget: 3)
    r = loop_.run(framework: "CoreAudio", symbol: { name: "x" }, rule_scaffold: "SEED")
    assert_true r.green?
    assert_equal "glue-v2", r.glue
    assert_equal 2, backend.calls.size
    # 2 回目の seed には直前失敗 detail と直前 glue が入る
    assert_not_nil backend.calls[1][:failure_detail]
    assert_equal "glue-v1", backend.calls[1][:last_glue]
  end

  def test_budget_exhausted_loud_fails
    backend = GreenBackend.new
    harness = ->(_glue) { false } # 常に RED
    loop_ = L.new(backend: backend, harness_check: harness, budget: 2)
    assert_raise(AppleSDKMac::RoundTrip::PocLoop::LoudFail) do
      loop_.run(framework: "CoreAudio", symbol: { name: "x" }, rule_scaffold: "SEED")
    end
    assert_equal 2, backend.calls.size # budget 回だけ試す
  end
end
