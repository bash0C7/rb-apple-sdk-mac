# test/round_trip/production_runner_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/production_runner"

# production round-trip 配線: swiftc 成功後の glue dylib を ruby 側、call_expr から
# 生成した swift driver を直走側に流し Harness で突合する。swift_exec と loader を
# inject して実 swiftc / 実 dylib なしに wiring を検証する。
class ProductionRunnerTest < Test::Unit::TestCase
  R = AppleSDKMac::RoundTrip::ProductionRunner

  # invoke 結果を canned で返す loader double。
  def loader_returning(val)
    loader = Object.new
    loader.define_singleton_method(:load) { |dylib_path:, exported_symbol:| :fn }
    loader.define_singleton_method(:invoke) { |_fn, _args| val }
    loader
  end

  # :value で swift 直走値と ruby-via-glue 値が一致 → green。
  def test_value_equivalent_is_green
    swift_exec = ->(_src) { %(RTRESULT:{"v":42}\n) }
    runner = R.new(swift_exec: swift_exec, loader: loader_returning(42))
    sym = { name: "Sym", call_expr: "answer()", invoke_args: [], value_kind: :value }
    outcome = runner.run(framework: "CoreAudio", symbol: sym, dylib: "/x.dylib", exported: "glue_x")
    assert_true outcome.green?, outcome.detail
  end

  # :value で不一致 → red、mismatch detail を持つ。
  def test_value_mismatch_is_red
    swift_exec = ->(_src) { %(RTRESULT:{"v":42}\n) }
    runner = R.new(swift_exec: swift_exec, loader: loader_returning(7))
    sym = { name: "Sym", call_expr: "answer()", invoke_args: [], value_kind: :value }
    outcome = runner.run(framework: "CoreAudio", symbol: sym, dylib: "/x.dylib", exported: "glue_x")
    assert_false outcome.green?
    assert_match(/mismatch/, outcome.detail)
  end

  # swift driver が RTRESULT 行を出さない → red。
  def test_no_rtresult_is_red
    swift_exec = ->(_src) { "compile noise, no result line\n" }
    runner = R.new(swift_exec: swift_exec, loader: loader_returning(42))
    sym = { name: "Sym", call_expr: "answer()", invoke_args: [], value_kind: :value }
    outcome = runner.run(framework: "CoreAudio", symbol: sym, dylib: "/x.dylib", exported: "glue_x")
    assert_false outcome.green?
    assert_match(/RTRESULT/, outcome.detail)
  end

  # invoke_args が driver_inputs から loader.invoke にそのまま渡る。
  def test_invoke_args_passed_through
    seen = nil
    loader = Object.new
    loader.define_singleton_method(:load) { |dylib_path:, exported_symbol:| :fn }
    loader.define_singleton_method(:invoke) { |_fn, args| seen = args; 42 }
    swift_exec = ->(_src) { %(RTRESULT:{"v":42}\n) }
    runner = R.new(swift_exec: swift_exec, loader: loader)
    sym = { name: "Sym", call_expr: "x", invoke_args: [1, nil, { "k" => 2 }], value_kind: :value }
    runner.run(framework: "CoreAudio", symbol: sym, dylib: "/x.dylib", exported: "glue_x")
    assert_equal [1, nil, { "k" => 2 }], seen
  end

  # swift driver source に call_expr が埋め込まれて swift_exec に渡る。
  def test_call_expr_embedded_in_driver_source
    captured = nil
    swift_exec = ->(src) { captured = src; %(RTRESULT:{"v":1}\n) }
    runner = R.new(swift_exec: swift_exec, loader: loader_returning(1))
    sym = { name: "Sym", call_expr: "MyUniqueCallExpr(9)", invoke_args: [], value_kind: :value }
    runner.run(framework: "CoreAudio", symbol: sym, dylib: "/x.dylib", exported: "glue_x")
    assert_match(/MyUniqueCallExpr\(9\)/, captured)
    assert_match(/import CoreAudio/, captured)
  end
end
