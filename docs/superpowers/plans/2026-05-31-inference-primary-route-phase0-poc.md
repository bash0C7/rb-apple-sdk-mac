# Inference-Primary-Route Phase 0 PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 推論が「green な round-trip test-unit ＋ 動く glue」を生成できることを、少数の手選び symbol で実証する（spec §1-3 の核を retire し、§4-7 投資の前提を立てる）。

**Architecture:** 決定論は glue 生成でなく round-trip ハーネスに宿す。同一 symbol を「Swift ドライバ直走」と「Ruby wrapper 経由」で叩き、戻り値の性質で段階縮退する等価述語（値/shape/setter）で突き合わせる。生成は per-symbol で、ルール足場を seed に推論が仕上げ、round-trip RED なら失敗 detail を prompt に feed back する閉ループで budget まで retry、超えたら loud fail。

**Tech Stack:** Ruby (test-unit, Bundler), Swift (swiftc), `claude -p` headless（injectable runner で unit から切離し）, 既存 `GlueCompiler` / `ValidationGates` / `SwiftcInvoker` / `Cache` / `ClaudePBackend`。

**スコープ境界:** 本計画は spec §7 Phase 0 のみ。spec §2.1 の production `try_inference` 全面改修、§4 永続化 Tier、§5 Tier 3 還流、§6 運用は **Phase 1 以降**で本計画では触らない。production code への workaround 禁止・RED は RED として報告（`Verify Task Discipline`）。

---

## File Structure

新規モジュール `lib/apple_sdk_mac/round_trip/`（responsibility 単位で分割、各 file 単一責務）:

- `lib/apple_sdk_mac/round_trip/equivalence.rb` — 戻り値の性質（`:value` / `:opaque` / `:setter`）で縮退する等価述語。純関数。claude -p に依存しない。
- `lib/apple_sdk_mac/round_trip/driver_generator.rb` — symbol から「API を native に呼んで結果を 1 行 JSON で stdout に吐く」Swift ドライバ source を生成。文字列生成のみで決定論的。
- `lib/apple_sdk_mac/round_trip/harness.rb` — Swift ドライバ実走（直走値）と Ruby-via-glue 実行（wrapper 値）を集め、`Equivalence` で判定。runner を inject 可能にして unit から subprocess を切離す。
- `lib/apple_sdk_mac/round_trip/poc_loop.rb` — Phase 0 PoC 専用オーケストレータ。ルール足場 seed → backend 生成 → gate+swiftc → round-trip harness → RED なら失敗 detail を seed に足して budget まで retry → green / loud fail。production `try_inference` は触らない。

テスト:
- `test/round_trip/equivalence_test.rb`（決定論 unit）
- `test/round_trip/driver_generator_test.rb`（決定論 unit、生成 source の shape 検証）
- `test/round_trip/harness_test.rb`（決定論 unit、fake runner 注入）
- `test/round_trip/poc_loop_test.rb`（決定論 unit、scripted fake backend）
- `test/integration/inference_round_trip_poc_test.rb`（env-gated 実証、実 `claude -p` + 実 swiftc）

---

## Task 0: 既存 Ruby→glue 呼び出し経路の grounding

**目的:** round-trip の「Ruby-via-glue」辺は既存の dylib 呼び出し機構を再利用する。発明しない（CLAUDE.md「Verify Assumed File Structure Exists Before Scoping Task」）。コード変更なしの調査タスク。

**Files:**
- Read only: `lib/apple_sdk_mac/` 配下の glue ロード/呼び出し実装、`test/integration/examples_*_e2e_test.rb`、`examples/`。

- [ ] **Step 1: 既存の dylib 呼び出し経路を特定**

Run:
```bash
grep -rn "Fiddle\|dlopen\|exported_symbol\|dylib_path" lib/apple_sdk_mac/ | grep -v "_test" | head -40
```
Expected: コンパイル済み dylib の exported symbol を Ruby から呼ぶ実装箇所（Fiddle 等）が判明する。

- [ ] **Step 2: audio_device_count の e2e を確認（value-type の生きた実例）**

Run:
```bash
ls test/integration/ && grep -rn "audio_device_count\|AudioObjectPropertyAddress" test/integration/ examples/ 2>/dev/null | head
```
Expected: CoreAudio `audio_device_count`（struct-in + int-out, value-type）の動く e2e 経路が判明する。これを Task 5 の value-type 実証 symbol として使う。

- [ ] **Step 3: 調査結果を本計画 Task 3/5 の前提として書き留める**

`Harness#run_ruby_via` と Task 5 で使う「Ruby から exported symbol を呼ぶ具体 API（メソッド名・引数）」を、Step 1-2 で判明した実コードに合わせて確定する。発明した API 名が無いことを確認。
不一致（想定した呼び出し口が無い）なら architectural issue として escalate し、後続 Task のシグネチャを修正してから進む。

*（Task 0 はコード変更なし。commit 不要。）*

---

## Task 1: Equivalence 段階的等価述語

**Files:**
- Create: `lib/apple_sdk_mac/round_trip/equivalence.rb`
- Test: `test/round_trip/equivalence_test.rb`

- [ ] **Step 1: 失敗テストを書く**

```ruby
# test/round_trip/equivalence_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/equivalence"

class EquivalenceTest < Test::Unit::TestCase
  E = AppleSDKMac::RoundTrip::Equivalence

  # value-type: 値が等しければ equivalent
  def test_value_equal
    assert_true E.equivalent?(kind: :value, swift: 3, ruby: 3)
  end

  def test_value_unequal
    assert_false E.equivalent?(kind: :value, swift: 3, ruby: 4)
  end

  # opaque/reference/新規確保: 値等価は問わず、型 tag 一致 + 両者 non-null
  def test_opaque_same_shape_non_null
    a = { "type" => "OpaquePointer", "null" => false }
    b = { "type" => "OpaquePointer", "null" => false }
    assert_true E.equivalent?(kind: :opaque, swift: a, ruby: b)
  end

  def test_opaque_null_fails
    a = { "type" => "OpaquePointer", "null" => false }
    b = { "type" => "OpaquePointer", "null" => true }
    assert_false E.equivalent?(kind: :opaque, swift: a, ruby: b)
  end

  def test_opaque_type_mismatch_fails
    a = { "type" => "OpaquePointer", "null" => false }
    b = { "type" => "CGRect", "null" => false }
    assert_false E.equivalent?(kind: :opaque, swift: a, ruby: b)
  end

  # setter: set→getter 読み戻しが set した値に一致
  def test_setter_readback_matches
    assert_true E.equivalent?(kind: :setter, swift: { "set" => 5, "readback" => 5 },
                                            ruby: { "set" => 5, "readback" => 5 })
  end

  def test_setter_readback_mismatch_fails
    assert_false E.equivalent?(kind: :setter, swift: { "set" => 5, "readback" => 9 },
                                             ruby: { "set" => 5, "readback" => 9 })
  end

  def test_unknown_kind_raises
    assert_raise(ArgumentError) { E.equivalent?(kind: :bogus, swift: 1, ruby: 1) }
  end
end
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/equivalence_test.rb`
Expected: FAIL — `cannot load such file -- .../round_trip/equivalence`

- [ ] **Step 3: 最小実装**

```ruby
# lib/apple_sdk_mac/round_trip/equivalence.rb
# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    # 戻り値の性質で段階縮退する等価述語。
    # :value  -> 値の等価
    # :opaque -> 型 tag 一致 + 両者 non-null (毎回別アドレス/別オブジェクトなので値は問わない)
    # :setter -> set した値と getter 読み戻しが一致 (set/readback ペア)
    module Equivalence
      module_function

      def equivalent?(kind:, swift:, ruby:)
        case kind
        when :value
          swift == ruby
        when :opaque
          shape_ok?(swift) && shape_ok?(ruby) && swift["type"] == ruby["type"]
        when :setter
          readback_ok?(swift) && readback_ok?(ruby)
        else
          raise ArgumentError, "unknown equivalence kind: #{kind.inspect}"
        end
      end

      def shape_ok?(obj)
        obj.is_a?(Hash) && obj["null"] == false && !obj["type"].to_s.empty?
      end

      def readback_ok?(obj)
        obj.is_a?(Hash) && obj.key?("set") && obj["set"] == obj["readback"]
      end
    end
  end
end
```

- [ ] **Step 4: テスト合格を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/equivalence_test.rb`
Expected: PASS — 8 tests, 0 failures, 0 errors

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/round_trip/equivalence.rb test/round_trip/equivalence_test.rb
git commit -m "feat(round_trip): tiered equivalence predicate (value/opaque/setter)"
```

---

## Task 2: DriverGenerator（Swift 直走ドライバ生成）

**Files:**
- Create: `lib/apple_sdk_mac/round_trip/driver_generator.rb`
- Test: `test/round_trip/driver_generator_test.rb`

ドライバは「API を native に呼び、結果を `RTRESULT:` 接頭の 1 行 JSON で stdout へ吐く `main`」を出力する。Harness はその行を parse する。生成は決定論的（文字列組み立てのみ）。

- [ ] **Step 1: 失敗テストを書く**

```ruby
# test/round_trip/driver_generator_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/driver_generator"

class DriverGeneratorTest < Test::Unit::TestCase
  G = AppleSDKMac::RoundTrip::DriverGenerator

  def setup
    @symbol = { name: "audio_device_count", kind: "function", signature: "() -> Int",
                call_expr: "audioDeviceCount()" }
  end

  def test_imports_target_framework
    src = G.generate(framework: "CoreAudio", symbol: @symbol, value_kind: :value)
    assert_match(/import CoreAudio/, src)
    assert_match(/import Foundation/, src)
  end

  def test_value_kind_prints_rtresult_line
    src = G.generate(framework: "CoreAudio", symbol: @symbol, value_kind: :value)
    assert_match(/RTRESULT:/, src)
    assert_match(/audioDeviceCount\(\)/, src)
  end

  def test_opaque_kind_emits_type_and_null_fields
    sym = { name: "make_obj", kind: "swift_init", call_expr: "MyType()" }
    src = G.generate(framework: "Foundation", symbol: sym, value_kind: :opaque)
    assert_match(/"type"/, src)
    assert_match(/"null"/, src)
  end

  def test_setter_kind_emits_set_and_readback_fields
    sym = { name: "set_x", kind: "swift_property_setter",
            set_expr: "obj.x = 5", read_expr: "obj.x", set_value: "5" }
    src = G.generate(framework: "Foundation", symbol: sym, value_kind: :setter)
    assert_match(/"set"/, src)
    assert_match(/"readback"/, src)
  end

  def test_unknown_value_kind_raises
    assert_raise(ArgumentError) do
      G.generate(framework: "CoreAudio", symbol: @symbol, value_kind: :bogus)
    end
  end
end
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/driver_generator_test.rb`
Expected: FAIL — `cannot load such file -- .../round_trip/driver_generator`

- [ ] **Step 3: 最小実装**

```ruby
# lib/apple_sdk_mac/round_trip/driver_generator.rb
# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    # symbol を native に呼び結果を `RTRESULT:<json>` 1 行で stdout に吐く Swift ドライバを生成。
    # value_kind ごとに吐く JSON 形が変わる:
    #   :value  -> {"v": <serialized>}            (Harness 側で v を取り出し値比較)
    #   :opaque -> {"type": "...", "null": <bool>}
    #   :setter -> {"set": <v>, "readback": <v>}
    # call_expr / set_expr / read_expr / set_value は symbol メタ (KB or 手書き) が供給する。
    module DriverGenerator
      module_function

      def generate(framework:, symbol:, value_kind:)
        body =
          case value_kind
          when :value  then value_body(symbol)
          when :opaque then opaque_body(symbol)
          when :setter then setter_body(symbol)
          else raise ArgumentError, "unknown value_kind: #{value_kind.inspect}"
          end
        <<~SWIFT
          import #{framework}
          import Foundation

          func emit(_ json: String) { print("RTRESULT:" + json) }

          #{body}
        SWIFT
      end

      def value_body(symbol)
        <<~SWIFT
          let __v = #{symbol[:call_expr]}
          emit("{\\"v\\":\\(__v)}")
        SWIFT
      end

      def opaque_body(symbol)
        # 新規確保/参照: 非 nil なら null=false。type は Swift の動的型名。
        <<~SWIFT
          let __o = #{symbol[:call_expr]}
          let __t = String(describing: type(of: __o))
          emit("{\\"type\\":\\"\\(__t)\\",\\"null\\":false}")
        SWIFT
      end

      def setter_body(symbol)
        # set → getter 読み戻し。set 値と readback を一緒に吐く。
        <<~SWIFT
          #{symbol[:set_expr]}
          let __rb = #{symbol[:read_expr]}
          emit("{\\"set\\":#{symbol[:set_value]},\\"readback\\":\\(__rb)}")
        SWIFT
      end
    end
  end
end
```

- [ ] **Step 4: テスト合格を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/driver_generator_test.rb`
Expected: PASS — 5 tests, 0 failures, 0 errors

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/round_trip/driver_generator.rb test/round_trip/driver_generator_test.rb
git commit -m "feat(round_trip): Swift driver generator emitting RTRESULT json per value_kind"
```

---

## Task 3: Harness（直走値 vs wrapper 値の突き合わせ）

**Files:**
- Create: `lib/apple_sdk_mac/round_trip/harness.rb`
- Test: `test/round_trip/harness_test.rb`

`Harness` は (1) Swift ドライバを compile+実走して `RTRESULT:` 行を parse（`swift_runner` inject）、(2) Ruby-via-glue を実行して wrapper 値を得る（`ruby_runner` inject）、(3) `Equivalence` で判定。subprocess/glue 実行は runner 注入で unit から切離す。`ruby_runner` の実体は Task 0 で特定した既存呼び出し経路を Phase 1/Task 5 で束ねる。

- [ ] **Step 1: 失敗テストを書く**

```ruby
# test/round_trip/harness_test.rb
# frozen_string_literal: true
require "test/unit"
require "json"
require_relative "../../lib/apple_sdk_mac/round_trip/harness"

class HarnessTest < Test::Unit::TestCase
  H = AppleSDKMac::RoundTrip::Harness

  # value: Swift 直走 stdout の RTRESULT 行を parse し、ruby 値と値比較
  def test_value_match
    swift = ->(_src) { "noise\nRTRESULT:{\"v\":3}\nmore" }
    ruby  = ->() { 3 }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "CoreAudio",
                symbol: { name: "audio_device_count", call_expr: "audioDeviceCount()" },
                value_kind: :value)
    assert_true r.green?
  end

  def test_value_mismatch_red
    swift = ->(_src) { "RTRESULT:{\"v\":3}" }
    ruby  = ->() { 4 }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "CoreAudio",
                symbol: { name: "audio_device_count", call_expr: "audioDeviceCount()" },
                value_kind: :value)
    assert_false r.green?
    assert_match(/swift=3/, r.detail)
    assert_match(/ruby=4/, r.detail)
  end

  def test_missing_rtresult_line_is_red_with_detail
    swift = ->(_src) { "compile produced no output" }
    ruby  = ->() { 3 }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "CoreAudio",
                symbol: { name: "audio_device_count", call_expr: "audioDeviceCount()" },
                value_kind: :value)
    assert_false r.green?
    assert_match(/no RTRESULT/, r.detail)
  end

  def test_opaque_match
    swift = ->(_src) { "RTRESULT:{\"type\":\"OpaquePointer\",\"null\":false}" }
    ruby  = ->() { { "type" => "OpaquePointer", "null" => false } }
    h = H.new(swift_runner: swift, ruby_runner: ruby)
    r = h.check(framework: "Foundation",
                symbol: { name: "make_obj", call_expr: "MyType()" },
                value_kind: :opaque)
    assert_true r.green?
  end
end
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/harness_test.rb`
Expected: FAIL — `cannot load such file -- .../round_trip/harness`

- [ ] **Step 3: 最小実装**

```ruby
# lib/apple_sdk_mac/round_trip/harness.rb
# frozen_string_literal: true
require "json"
require_relative "equivalence"
require_relative "driver_generator"

module AppleSDKMac
  module RoundTrip
    # 直走値(Swift driver) と wrapper 値(Ruby-via-glue) を突き合わせ green/red を返す。
    # swift_runner: lambda(swift_source) -> stdout 文字列 (compile+実走の実体は注入)
    # ruby_runner:  lambda() -> Ruby wrapper の戻り値
    class Harness
      Outcome = Struct.new(:green?, :detail, :swift, :ruby, keyword_init: true)

      def initialize(swift_runner:, ruby_runner:)
        @swift_runner = swift_runner
        @ruby_runner = ruby_runner
      end

      def check(framework:, symbol:, value_kind:)
        src = DriverGenerator.generate(framework: framework, symbol: symbol, value_kind: value_kind)
        stdout = @swift_runner.call(src)
        swift_obj = parse_rtresult(stdout)
        if swift_obj.nil?
          return Outcome.new(green?: false,
                             detail: "no RTRESULT line in swift driver output: #{stdout.to_s[0, 200]}")
        end
        swift_val = unwrap(value_kind, swift_obj)
        ruby_val = @ruby_runner.call
        green = Equivalence.equivalent?(kind: value_kind, swift: swift_val, ruby: ruby_val)
        Outcome.new(green?: green, swift: swift_val, ruby: ruby_val,
                    detail: green ? "equivalent" : "mismatch: swift=#{swift_val.inspect} ruby=#{ruby_val.inspect}")
      end

      private

      def parse_rtresult(stdout)
        line = stdout.to_s.each_line.find { |l| l.start_with?("RTRESULT:") }
        return nil unless line
        JSON.parse(line.sub("RTRESULT:", "").strip)
      rescue JSON::ParserError => e
        nil # parse 不能は RTRESULT 無し扱い (detail は呼び出し側で表面化)
      end

      # value_kind ごとに driver JSON から比較対象を取り出す。
      def unwrap(value_kind, obj)
        case value_kind
        when :value  then obj["v"]
        when :opaque then obj            # {"type","null"} を Equivalence にそのまま渡す
        when :setter then obj            # {"set","readback"}
        else raise ArgumentError, "unknown value_kind: #{value_kind.inspect}"
        end
      end
    end
  end
end
```

- [ ] **Step 4: テスト合格を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/harness_test.rb`
Expected: PASS — 4 tests, 0 failures, 0 errors

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/round_trip/harness.rb test/round_trip/harness_test.rb
git commit -m "feat(round_trip): harness comparing native driver vs ruby wrapper via equivalence"
```

---

## Task 4: PoC 閉ループ（足場 seed → 生成 → round-trip → feedback retry → green/loud-fail）

**Files:**
- Create: `lib/apple_sdk_mac/round_trip/poc_loop.rb`
- Test: `test/round_trip/poc_loop_test.rb`

production `try_inference` は触らず、PoC 専用に閉ループを組む。backend は `generate_glue` を持つ任意 object（fake で scripted 応答）。round-trip は注入した `harness_check`（lambda）で判定。RED なら失敗 detail と直前 glue を seed に足して再生成、budget 超で loud fail。

- [ ] **Step 1: 失敗テストを書く**

```ruby
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
    assert_not_nil backend.calls[1][:last_failure]
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
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/poc_loop_test.rb`
Expected: FAIL — `cannot load such file -- .../round_trip/poc_loop`

- [ ] **Step 3: 最小実装**

```ruby
# lib/apple_sdk_mac/round_trip/poc_loop.rb
# frozen_string_literal: true

module AppleSDKMac
  module RoundTrip
    # Phase 0 PoC のオーケストレータ。ルール足場 seed → backend 生成 → round-trip 判定 →
    # RED なら失敗 detail+直前 glue を seed に足して budget まで retry → green / loud fail。
    # production try_inference は触らない。
    class PocLoop
      LoudFail = Class.new(StandardError)
      Outcome = Struct.new(:green?, :glue, :attempts, keyword_init: true)

      # backend: generate_glue(framework:, symbol:, seed:) -> glue 文字列
      # harness_check: lambda(glue) -> true(green)/false(red)
      def initialize(backend:, harness_check:, budget: 3)
        @backend = backend
        @harness_check = harness_check
        @budget = budget
      end

      def run(framework:, symbol:, rule_scaffold:)
        last_failure = nil
        last_glue = nil
        attempt = 0
        while attempt < @budget
          seed = { rule_scaffold: rule_scaffold, last_failure: last_failure, last_glue: last_glue }
          glue = @backend.generate_glue(framework: framework, symbol: symbol, seed: seed)
          attempt += 1
          if @harness_check.call(glue)
            return Outcome.new(green?: true, glue: glue, attempts: attempt)
          end
          last_failure = "round-trip RED on attempt #{attempt}"
          last_glue = glue
        end
        raise LoudFail, "#{framework}.#{symbol[:name]}: no green round-trip glue within budget=#{@budget}"
      end
    end
  end
end
```

- [ ] **Step 4: テスト合格を確認**

Run: `bundle exec ruby -Itest -Ilib test/round_trip/poc_loop_test.rb`
Expected: PASS — 3 tests, 0 failures, 0 errors

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/round_trip/poc_loop.rb test/round_trip/poc_loop_test.rb
git commit -m "feat(round_trip): PoC closed loop (scaffold seed, test-feedback retry, loud fail)"
```

---

## Task 5: env-gated 実証（実 claude -p + 実 swiftc + 実 symbol）

**Files:**
- Create: `test/integration/inference_round_trip_poc_test.rb`
- 参照: Task 0 で特定した Ruby→glue 呼び出し経路、`ClaudePBackend`、`SwiftcInvoker`、CoreAudio `audio_device_count`。

**これが Phase 0 の実証本体。** `RB_APPLE_SDK_MAC_POC=1` のときだけ走る（既存 env-gate 慣行に倣う）。実 `claude -p` で glue を生成し、round-trip harness が green を出すことを test-unit assert に乗せる（`feedback_test_unit_assert_as_report`）。`RUBY_BOX=1` で回さない（raise する RED が sibling を巻き込む quirk）。

- [ ] **Step 1: 実証テストを書く（value-type: audio_device_count）**

```ruby
# test/integration/inference_round_trip_poc_test.rb
# frozen_string_literal: true
require "test/unit"
require_relative "../../lib/apple_sdk_mac/round_trip/harness"
require_relative "../../lib/apple_sdk_mac/round_trip/poc_loop"
require_relative "../../lib/apple_sdk_mac/inference/claude_p_backend"
# Task 0 で特定した glue compile/呼び出し資産を require:
#   - SwiftcInvoker, Cache, 既存 Ruby→glue 呼び出し経路
# (具体 require は Task 0 Step 3 の確定結果に合わせる)

class InferenceRoundTripPocTest < Test::Unit::TestCase
  def setup
    omit "PoC gate off (set RB_APPLE_SDK_MAC_POC=1)" unless ENV["RB_APPLE_SDK_MAC_POC"] == "1"
  end

  # 実証 1: value-type。推論が green round-trip glue を生成できる。
  def test_value_type_audio_device_count_reaches_green
    # symbol メタ: CoreAudio audio_device_count (struct-in + int-out, value)。
    # call_expr 等は Task 0 で確認した実 KB メタ/実 e2e に合わせて埋める。
    symbol = {
      name: "audio_device_count",
      kind: "function",
      call_expr: "<Task0で確定: native 呼び出し式>",
    }

    backend = AppleSDKMac::Inference::ClaudePBackend.new

    # harness_check: 生成 glue を compile し、Swift 直走 vs Ruby-via-glue を round-trip 比較。
    # swift_runner / ruby_runner は Task 0 で確定した実 SwiftcInvoker + Ruby 呼び出し経路で束ねる。
    harness_check = lambda do |glue|
      # 1) glue を swiftc で dylib 化 (SwiftcInvoker)
      # 2) Swift driver を DriverGenerator で生成 → compile+実走 (swift_runner)
      # 3) Ruby-via-glue で値取得 (ruby_runner)
      # 4) RoundTrip::Harness#check で green/red
      harness = AppleSDKMac::RoundTrip::Harness.new(
        swift_runner: method(:run_swift_driver), # Task 0 確定の実走
        ruby_runner: -> { call_ruby_via_glue(glue) } # Task 0 確定の呼び出し
      )
      harness.check(framework: "CoreAudio", symbol: symbol, value_kind: :value).green?
    end

    loop_ = AppleSDKMac::RoundTrip::PocLoop.new(
      backend: wrap_backend(backend, symbol), harness_check: harness_check, budget: 4
    )

    outcome = loop_.run(framework: "CoreAudio", symbol: symbol,
                        rule_scaffold: rule_scaffold_for(symbol))
    assert_true outcome.green?,
      "推論が green round-trip glue を #{outcome.attempts} 回以内に生成できること"
  end

  # 実証 2: context-resume。RED を context 注入で green に転じる。
  def test_context_resume_turns_red_into_green
    symbol = { name: "<Task0で確定: ルール単独では解けない reachable symbol>", kind: "function",
               call_expr: "<native 呼び出し式>" }
    backend = AppleSDKMac::Inference::ClaudePBackend.new

    # context 無しでは budget 内に green に至らない想定 → LoudFail を捕捉し context 付きで再実行。
    no_ctx = AppleSDKMac::RoundTrip::PocLoop.new(
      backend: wrap_backend(backend, symbol), harness_check: harness_check_for(symbol), budget: 2
    )
    failed = false
    begin
      no_ctx.run(framework: "Foundation", symbol: symbol, rule_scaffold: rule_scaffold_for(symbol))
    rescue AppleSDKMac::RoundTrip::PocLoop::LoudFail
      failed = true
    end
    omit "symbol resolved without context; pick a harder symbol" unless failed

    with_ctx = AppleSDKMac::RoundTrip::PocLoop.new(
      backend: wrap_backend(backend, symbol, context: "<gap を埋める hint>"),
      harness_check: harness_check_for(symbol), budget: 4
    )
    outcome = with_ctx.run(framework: "Foundation", symbol: symbol,
                           rule_scaffold: rule_scaffold_for(symbol))
    assert_true outcome.green?, "context 注入で RED→green に転じること"
  end

  # --- helpers: 実体は Task 0 確定の資産で埋める ---
  def run_swift_driver(swift_source); raise NotImplementedError, "Task0で確定"; end
  def call_ruby_via_glue(glue); raise NotImplementedError, "Task0で確定"; end
  def wrap_backend(backend, symbol, context: nil); raise NotImplementedError, "Task0/seed配線"; end
  def rule_scaffold_for(symbol); raise NotImplementedError, "ルール足場生成 (TemplateGenerator 流用)"; end
  def harness_check_for(symbol); raise NotImplementedError, "上 test と同形"; end
end
```

- [ ] **Step 2: gate OFF で omit されることを確認**

Run: `bundle exec ruby -Itest -Ilib test/integration/inference_round_trip_poc_test.rb`
Expected: PASS（全 test が omit。"PoC gate off" の理由付き omission）

- [ ] **Step 3: helper を Task 0 確定の実資産で埋める**

`run_swift_driver` / `call_ruby_via_glue` / `wrap_backend`（backend の `generate_glue` に seed の `rule_scaffold` / `last_failure` / `last_glue` / `context` を prompt へ渡す薄いアダプタ）/ `rule_scaffold_for`（`TemplateGenerator` の出力を足場 seed に流用）/ `harness_check_for` を、Task 0 Step 3 で確定した実 API に合わせて実装。`NotImplementedError` を全て除去。
production code（`glue_compiler.rb` 等）は改変しない。helper はテスト file 内に閉じる。

- [ ] **Step 4: gate ON で実証実行（実 claude -p + 実 swiftc）**

Run:
```bash
RB_APPLE_SDK_MAC_POC=1 bundle exec ruby -Itest -Ilib test/integration/inference_round_trip_poc_test.rb
```
Expected: PASS — value-type の green 到達 + context-resume の green 転化。
失敗時は RED を RED として報告（production workaround で PASS を取らない）。green に至らない場合は「推論主ルートの命題が現状立たない」として user に escalate（pivot 再検討）。

> 注: 実 `claude -p` を叩くため数十秒〜分かかりうる。2 分超が見込まれるなら tmux detached + `DONE:` sentinel で回す（CLAUDE.md ロングバッチ）。

- [ ] **Step 5: Commit**

```bash
git add test/integration/inference_round_trip_poc_test.rb
git commit -m "test(round_trip): env-gated PoC proving inference reaches green round-trip"
```

---

## Task 6: full suite 回帰確認

**Files:** 変更なし（検証のみ）。

- [ ] **Step 1: full suite を subagent 委譲で実行**

`rake test` を general-purpose subagent に委譲（make/dot log の main 汚染回避、`Test Execution Delegation`）。pass/fail + count のみ回収。
Expected: 既存 424 tests に round_trip 系 unit が加算され、0 failures / 0 errors。omissions は既存 3 + PoC gate OFF 分。

- [ ] **Step 2: green を確認したら Phase 0 完了**

full suite green を確認。RED があれば `systematic-debugging` で root cause（production workaround 禁止）。

---

## Self-Review（writing-plans 規律）

**1. Spec coverage（§1-3 が Phase 0 対象）:**
- §1 オラクル（型/値 round-trip）→ Task 2(driver)+Task 3(harness)+Task 5(実走)。
- §1.1 段階的等価述語（値/opaque/setter）→ Task 1(Equivalence) + Task 2/3 の value_kind 分岐。
- §2 生成パイプライン（足場 seed→推論→round-trip→feedback loop→green/loud fail）→ Task 4(PocLoop) + Task 5(実 backend 配線)。
- §3 context 受け取り（fail 境界で reactive、green で確定）→ Task 5 test 2(context-resume 実証)。※ §3 の rich exception `retry_with` API 化・IRB elicitation は Phase 1（PoC では loop への context 注入で命題のみ実証）。
- §4-7 → Phase 1 以降。本計画スコープ外（明記済み）。

**2. Placeholder scan:** Task 5 の `<Task0で確定: ...>` と `NotImplementedError` は **意図的な grounding 依存**。Task 0→Task 5 Step 3 で実資産から埋める手順を明示し、埋め切る（`NotImplementedError` 全除去）ことを Step 3 で要求済み。発明 API を焼かない CLAUDE.md 規律の反映で、放置 placeholder ではない。

**3. Type consistency:** `Equivalence.equivalent?(kind:, swift:, ruby:)` / `DriverGenerator.generate(framework:, symbol:, value_kind:)` / `Harness#check(framework:, symbol:, value_kind:) -> Outcome(green?,detail,swift,ruby)` / `PocLoop#run(framework:, symbol:, rule_scaffold:) -> Outcome(green?,glue,attempts)` / `PocLoop::LoudFail` — Task 間でシグネチャ一致を確認済み。`value_kind`（DriverGenerator/Harness）と `kind`（Equivalence）は別語彙だが Harness が `value_kind` を `Equivalence(kind:)` に渡す箇所で対応付け済み。

---

## 完了条件

- round_trip 系 unit（Task 1-4）全 green。
- Task 5 env-gated 実証が `RB_APPLE_SDK_MAC_POC=1` で green（value-type 到達 + context-resume 転化）。
- full suite green（Task 6）。
- → 命題「推論が green round-trip test + 動く glue を生成できる」が立つ。Phase 1（§2.1 seam 改修 / §4 永続化 / §5 Tier 3 / §6 運用）の spec→plan へ。
