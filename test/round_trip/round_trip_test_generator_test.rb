# test/round_trip/round_trip_test_generator_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/round_trip_test_generator"

# 永続化する自走 test-unit ファイルを生成する。committed glue を team/CI が
# claude -p 無しで再コンパイル+round-trip 再検証できる形に driver_inputs を bake-in する。
class RoundTripTestGeneratorTest < Test::Unit::TestCase
  G = AppleSDKMac::RoundTrip::RoundTripTestGenerator

  def gen(name: "AudioObjectGetPropertyDataSize", di: nil)
    di ||= { call_expr: "MyCall(42)", invoke_args: [], value_kind: :value }
    G.generate(framework: "CoreAudio", symbol: { name: name }, driver_inputs: di)
  end

  def test_is_a_test_unit_file
    src = gen
    assert_match(/require "test\/unit"/, src)
    assert_match(/< Test::Unit::TestCase/, src)
    assert_match(/def test_round_trip_green/, src)
  end

  def test_class_name_is_sanitized_camel
    src = gen(name: "NSString.stringWithUTF8String")
    assert_match(/class RoundTrip\w+Test < Test::Unit::TestCase/, src)
    # dot は class 名に残さない
    refute_match(/class RoundTrip[^\s]*\./, src)
  end

  def test_bakes_driver_inputs
    src = gen(di: { call_expr: "UniqueExpr(9)", invoke_args: [1, nil], value_kind: :value })
    assert_match(/UniqueExpr\(9\)/, src)
    assert_match(/:value/, src)
    assert_match(/\[1, nil\]/, src)
    assert_match(/"CoreAudio"/, src)
  end

  def test_gates_on_poc_env
    assert_match(/RB_APPLE_SDK_MAC_POC/, gen)
    assert_match(/omit/, gen)
  end

  # 検証は ProductionRunner に委ね、report は assert_true outcome.green? に乗せる。
  def test_uses_production_runner_and_asserts_green
    src = gen
    assert_match(/ProductionRunner/, src)
    assert_match(/assert_true\s+outcome\.green\?/, src)
  end

  # sibling .swift を自前で解決して再コンパイルする (claude -p 非依存)。
  def test_resolves_sibling_glue_and_recompiles
    src = gen
    assert_match(/_round_trip_test\\?\.rb/, src)   # __FILE__ から .swift を導出
    assert_match(/SwiftcInvoker/, src)
  end

  # setter は read_expr / set_expr / set_value も bake-in。
  def test_setter_bakes_setter_fields
    src = gen(di: { call_expr: "x", value_kind: :setter,
                    read_expr: "readIt()", set_expr: "setIt(5)", set_value: "5" })
    assert_match(/:setter/, src)
    assert_match(/readIt\(\)/, src)
    assert_match(/setIt\(5\)/, src)
  end
end
