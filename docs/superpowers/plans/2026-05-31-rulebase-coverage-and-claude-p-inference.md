# ルールベース被覆契約 + claude -p 推論 PoC 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** カバー済み 8 emitter kind の round-trip を機械可読契約で保障し範囲外は loud fail させ、`claude -p` を第一級 backend として推論 glue 生成が実 example で end-to-end に成立することを実証する。

**Architecture:** `glue_compiler.compile` を唯一の合流点にし、template 失敗時に `CoverageContract` で範囲内/外を判定。範囲外は `inference_backend` が `:none` なら `OutOfCoverageError`、有効なら `InferenceBackend#generate_glue` に委譲して**同一の ValidationGates + SwiftcInvoker + cache** に通す。

**Tech Stack:** Ruby (CRuby/MRI), test-unit, swiftc, SQLite Knowledge Base, `claude -p` headless subprocess。

**Spec:** docs/superpowers/specs/2026-05-31-rulebase-coverage-contract-and-claude-p-inference-poc-design.md

---

## ファイル構成

| ファイル | 役割 | 新規/改修 |
|---|---|---|
| `lib/apple_sdk_mac/errors.rb` | `OutOfCoverageError` 追加 | 改修 |
| `lib/apple_sdk_mac/coverage_contract.rb` | kind × param-shape の被覆契約 `covered?` | 新規 |
| `lib/apple_sdk_mac/glue_compiler.rb` | template 失敗時の契約判定 + backend 委譲合流点 | 改修 |
| `lib/apple_sdk_mac/dispatcher.rb` | `OutOfCoverageError` の telemetry + propagate | 改修 |
| `lib/apple_sdk_mac/config.rb` | `inference_backend` 選択 (`:none`/`:claude_p`) | 改修 |
| `lib/apple_sdk_mac/inference/backend.rb` | 推論 backend 抽象 interface | 新規 |
| `lib/apple_sdk_mac/inference/claude_p_backend.rb` | `claude -p` subprocess で glue 生成 | 新規 |
| `lib/apple_sdk_mac/glue_compiler/template_generator.rb` / `marshallers.rb` | audio out-param 穴塞ぎ (診断後に確定) | 改修 |
| `test/coverage_contract_test.rb` | 契約 unit | 新規 |
| `test/inference/backend_test.rb` | 抽象 interface + `:none` 非発火 | 新規 |
| `test/inference/claude_p_backend_test.rb` | プロンプト構築 + 抽出 (subprocess は stub) | 新規 |
| `test/glue_compiler_test.rb` | 範囲外 loud fail / backend 委譲 | 改修 |
| `test/integration/coverage_matrix_test.rb` | 8 kind round-trip (env-gated) | 新規 |
| `test/integration/inference_poc_test.rb` | claude_p で実 example e2e (env-gated) | 新規 |

---

## Phase 0: Green baseline

### Task 0: Knowledge Base rebuild で test suite を green に

**Files:**
- なし (環境整備)

- [ ] **Step 1: 現状の error 件数を記録**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac && bundle exec rake test 2>&1 | tail -5`
Expected: `... 0 failures, 30 errors ...` (全て "knowledge base missing")

- [ ] **Step 2: Knowledge Base を rebuild**

ロングバッチ規律: rebuild は数十分かかるため tmux detached で起動する。

```bash
mkdir -p tmp/longrun
tmux new-session -d -s kb-rebuild-20260531 \
  "bash -c 'cd /Users/bash/dev/src/github.com/bash0C7/rb-apple-sdk-mac && . ~/.swiftly/env.sh; bundle exec rake apple:knowledge:rebuild > tmp/longrun/kb-rebuild-20260531.log 2>&1; echo \"DONE: exit=\$?\" >> tmp/longrun/kb-rebuild-20260531.log'"
```

- [ ] **Step 3: 完了を待つ (後続ターンで grep)**

Run: `grep "^DONE:" tmp/longrun/kb-rebuild-20260531.log`
Expected: 0 行 = 実行中 / `DONE: exit=0` = 成功

- [ ] **Step 4: test suite が green になったことを確認**

Run: `bundle exec rake test 2>&1 | tail -5`
Expected: `0 failures, 0 errors` (omissions は許容)

- [ ] **Step 5: Commit** (コード変更なしのため commit 不要。baseline 確認のみ。次タスクへ)

---

## Phase 1: 境界形式化

### Task 1: `OutOfCoverageError` typed error

**Files:**
- Modify: `lib/apple_sdk_mac/errors.rb`
- Test: `test/errors_test.rb` (なければ作成)

- [ ] **Step 1: 失敗するテストを書く**

`test/errors_test.rb` に追記 (ファイル無ければ `require "test_helper"` + class で新規):

```ruby
require "test_helper"

class OutOfCoverageErrorTest < Test::Unit::TestCase
  def test_carries_structured_metadata
    err = AppleSDKMac::OutOfCoverageError.new(
      framework: "CoreAudio", symbol: "SomeWeirdSym",
      pattern: "swift_macro", reason: "macro expansion not bridgeable"
    )
    assert_equal "CoreAudio", err.framework
    assert_equal "SomeWeirdSym", err.symbol
    assert_equal "swift_macro", err.pattern
    assert_equal "macro expansion not bridgeable", err.reason
    assert_kind_of AppleSDKMac::Error, err
    assert_match(/outside rule-based coverage/, err.message)
    assert_match(/swift_macro/, err.message)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rake test TESTOPTS="-n /OutOfCoverage/"`
Expected: FAIL — `uninitialized constant AppleSDKMac::OutOfCoverageError`

- [ ] **Step 3: 実装**

`lib/apple_sdk_mac/errors.rb` の `SwiftError` クラス定義の直後 (末尾 `end` の前) に追加:

```ruby
  # Raised when a symbol falls outside the rule-based CoverageContract and no
  # inference backend resolved it. Distinct from UnsupportedPatternError
  # (which marks Knowledge-Base-flagged unbridgeable shapes): OutOfCoverageError
  # is the loud-fail boundary of the *currently guaranteed* rule coverage.
  class OutOfCoverageError < Error
    attr_reader :framework, :symbol, :pattern, :reason

    def initialize(framework:, symbol:, pattern:, reason:)
      @framework = framework
      @symbol = symbol
      @pattern = pattern
      @reason = reason
      super("#{framework}::#{symbol} is outside rule-based coverage " \
            "(pattern=#{pattern}): #{reason}")
    end
  end
```

- [ ] **Step 4: パス確認**

Run: `bundle exec rake test TESTOPTS="-n /OutOfCoverage/"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/errors.rb test/errors_test.rb
git commit -m "feat(errors): add OutOfCoverageError for rule-coverage boundary"
```

---

### Task 2: `CoverageContract`

契約は「ルール generator が round-trip を保証すると**表明する** (kind, param-type) の集合」。`covered? == true` は必ず動くべき(穴なら直す対象)、`false` は loud-fail/推論境界。param 対応型は `marshallers.rb` が実際に扱う型タグを実装ステップで列挙する。

**Files:**
- Create: `lib/apple_sdk_mac/coverage_contract.rb`
- Test: `test/coverage_contract_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

`test/coverage_contract_test.rb`:

```ruby
require "test_helper"

class CoverageContractTest < Test::Unit::TestCase
  def setup
    @contract = AppleSDKMac::CoverageContract.new
  end

  # audio_device_count が依存する shape: C function + (uint32, struct-in,
  # uint32, int-out-pointer)。これは「カバー済みと表明する」範囲 = true。
  def test_audio_property_data_size_shape_is_covered
    sym = {
      kind: "function", abi: "c",
      parameters_json: JSON.generate([
        { "type" => "AudioObjectID" },             # uint32
        { "type" => "AudioObjectPropertyAddress*", "is_struct_in" => true },
        { "type" => "UInt32" },
        { "type" => "UInt32*", "is_out_param" => true }
      ])
    }
    assert_true @contract.covered?(sym)
  end

  def test_unknown_kind_is_not_covered
    sym = { kind: "swift_macro", abi: "swift", parameters_json: "[]" }
    assert_false @contract.covered?(sym)
  end

  def test_known_kind_with_unsupported_param_is_not_covered
    sym = {
      kind: "function", abi: "c",
      parameters_json: JSON.generate([{ "type" => "std::vector<NSObject*>" }])
    }
    assert_false @contract.covered?(sym)
  end

  def test_reason_for_uncovered_is_descriptive
    sym = { kind: "swift_macro", abi: "swift", parameters_json: "[]" }
    reason = @contract.uncovered_reason(sym)
    assert_match(/kind/, reason)
    assert_match(/swift_macro/, reason)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rake test TESTOPTS="-n /CoverageContract/"`
Expected: FAIL — `uninitialized constant AppleSDKMac::CoverageContract`

- [ ] **Step 3: 実装**

実装前に `lib/apple_sdk_mac/glue_compiler/marshallers.rb` を読み、実際に対応している param 型タグ (scalar int/float, c-string, opaque/OpaqueRef, CFTypeRef, struct-in, out-param, fixed/var array, block, variadic) を `SUPPORTED_PARAM_MATCHERS` に正確に反映する。下記は雛形 — marshallers の実体に合わせて matcher を増減させること。

`lib/apple_sdk_mac/coverage_contract.rb`:

```ruby
# frozen_string_literal: true
require "json"

module AppleSDKMac
  # Machine-readable statement of which (kind, parameter-shape) combinations the
  # rule-based template generator GUARANTEES to round-trip. `covered? == true`
  # MUST compile and invoke — a failure there is a bug to fix in the generator,
  # not an inference-fallback trigger. `covered? == false` is the loud-fail /
  # inference boundary. Keeps the boundary explicit instead of relying on the
  # generator silently returning nil.
  class CoverageContract
    COVERED_KINDS = %w[
      function objc_method_class objc_method_instance swift_init
      swift_property swift_property_setter swift_func global_constant
    ].freeze

    # 各 matcher は param Hash を受け、generator がその型を marshalling できるなら
    # true。marshallers.rb の対応型に 1:1 対応させる (実装時に確認・調整)。
    SUPPORTED_PARAM_MATCHERS = [
      ->(p) { p["is_out_param"] },                                  # int/float out-pointer
      ->(p) { p["is_struct_in"] },                                  # struct-in pointer (Hash 入力)
      ->(p) { p["type"] =~ /\A(U?Int(8|16|32|64)?|AudioObjectID|OSStatus|Bool)\z/ },
      ->(p) { p["type"] =~ /\A(Float|Double|CGFloat)\z/ },
      ->(p) { p["type"] =~ /\Aconst char ?\*\z/ },                  # c-string
      ->(p) { p["type"] =~ /CFTypeRef|CF\w+Ref/ },                  # CF auto-arc
      ->(p) { p["type"] =~ /\*\z/ && p["opaque"] },                 # opaque pointer
    ].freeze

    def covered?(symbol)
      uncovered_reason(symbol).nil?
    end

    # 範囲外の理由を返す。範囲内なら nil。
    def uncovered_reason(symbol)
      kind = symbol[:kind].to_s
      unless COVERED_KINDS.include?(kind)
        return "kind '#{kind}' is not in the covered set (#{COVERED_KINDS.join(', ')})"
      end
      params = parse_params(symbol)
      bad = params.reject { |p| SUPPORTED_PARAM_MATCHERS.any? { |m| m.call(p) } }
      unless bad.empty?
        return "unsupported parameter type(s): #{bad.map { |p| p['type'] }.join(', ')}"
      end
      nil
    end

    private

    def parse_params(symbol)
      raw = symbol[:parameters_json].to_s
      return [] if raw.empty?
      parsed = JSON.parse(raw)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end
  end
end
```

`lib/apple_sdk_mac.rb` (または lib エントリ) に `require_relative "apple_sdk_mac/coverage_contract"` を追加。

- [ ] **Step 4: パス確認**

Run: `bundle exec rake test TESTOPTS="-n /CoverageContract/"`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/coverage_contract.rb test/coverage_contract_test.rb lib/apple_sdk_mac.rb
git commit -m "feat(coverage): machine-readable CoverageContract for rule boundary"
```

---

### Task 3: `glue_compiler.compile` 合流点 + dispatcher propagate (`:none` 既定)

template 失敗時に契約判定。範囲内失敗は従来 Result を返す(穴=後続 Task で修正)。範囲外は backend 無効なら `OutOfCoverageError`。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler.rb`
- Modify: `lib/apple_sdk_mac/dispatcher.rb:41-59`
- Modify: `lib/apple_sdk_mac/config.rb`
- Test: `test/glue_compiler_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

`test/glue_compiler_test.rb` に追記 (既存ファイルの末尾 class 内、なければ新規):

```ruby
require "test_helper"

class GlueCompilerCoverageBoundaryTest < Test::Unit::TestCase
  # template が nil を返し、かつ契約範囲外なら OutOfCoverageError。
  def test_out_of_coverage_raises_when_backend_none
    fake_template = Object.new
    def fake_template.generate(**) = nil   # 常に template_nil
    cache = make_fake_cache
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template,
      inference_backend: nil   # :none 相当
    )
    sym = { name: "WeirdMacro", kind: "swift_macro", abi: "swift",
            signature: "()", parameters_json: "[]" }
    assert_raise(AppleSDKMac::OutOfCoverageError) do
      compiler.compile(framework: "Foo", symbol: sym)
    end
  end

  # 範囲内 (covered) で template が nil の場合は OutOfCoverageError を上げず
  # success?:false Result を返す (これは「穴」= バグとして別途修正対象)。
  def test_in_coverage_template_nil_returns_failed_result_not_raise
    fake_template = Object.new
    def fake_template.generate(**) = nil
    cache = make_fake_cache
    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template, inference_backend: nil
    )
    sym = { name: "AudioObjectGetPropertyDataSize", kind: "function", abi: "c",
            signature: "()",
            parameters_json: JSON.generate([{ "type" => "UInt32*", "is_out_param" => true }]) }
    result = compiler.compile(framework: "CoreAudio", symbol: sym)
    assert_false result.success?
    assert_equal "template_nil", result.error_stage
  end

  private

  def make_fake_cache
    cache = Object.new
    def cache.base_dir = "/tmp"
    def cache.sdk_version = "26.5"
    def cache.record_attempt(**) = nil
    cache
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rake test TESTOPTS="-n /GlueCompilerCoverageBoundary/"`
Expected: FAIL — `compile` が `inference_backend:` kwarg を知らない / OutOfCoverageError を上げない

- [ ] **Step 3: 実装 — GlueCompiler**

`lib/apple_sdk_mac/glue_compiler.rb`:

`require` に追加:
```ruby
require_relative "coverage_contract"
```

`initialize` に `inference_backend:` と `coverage_contract:` を追加:
```ruby
    def initialize(cache:, runtime_dylib_path:, runtime_modules_paths: [],
                    swiftc_invoker: nil,
                    template_generator: nil,
                    knowledge_cache: nil,
                    gates: nil,
                    inference_backend: nil,
                    coverage_contract: nil)
      @cache = cache
      @runtime_dylib_path = runtime_dylib_path
      @runtime_modules_paths = runtime_modules_paths
      @template = template_generator || GlueCompiler::TemplateGenerator.new(knowledge_cache: knowledge_cache)
      @gates = gates || GlueCompiler::ValidationGates.new
      @swiftc = swiftc_invoker || GlueCompiler::SwiftcInvoker.new
      @inference_backend = inference_backend
      @contract = coverage_contract || CoverageContract.new
    end
```

`compile` を変更し、template 失敗時に境界判定を挟む:
```ruby
    def compile(framework:, symbol:)
      result = try_template(framework: framework, symbol: symbol)
      return result if result.success?

      # template が成功しなかった。契約範囲内なら「穴」= バグなので
      # Result(success?:false) をそのまま返す(呼び出し側で別途修正対象)。
      # 範囲外なら inference backend に委譲、無効なら loud fail。
      if @contract.covered?(symbol)
        return result
      end

      reason = @contract.uncovered_reason(symbol) || "uncovered shape"
      if @inference_backend
        return try_inference(framework: framework, symbol: symbol, reason: reason)
      end

      raise OutOfCoverageError.new(
        framework: framework.to_s, symbol: symbol[:name].to_s,
        pattern: symbol[:kind].to_s, reason: reason
      )
    end
```

`try_inference` は Task 9 で実装。今は placeholder ではなく **本タスクのスコープ外**なので、`@inference_backend` が nil の経路のみ通る (テストも nil 経路)。`try_inference` 未定義参照を避けるため、本タスクでは最小の private stub を置く:
```ruby
    def try_inference(framework:, symbol:, reason:)
      raise NotImplementedError, "inference wiring lands in Task 9"
    end
```

- [ ] **Step 4: 実装 — dispatcher が OutOfCoverageError を telemetry + propagate**

`lib/apple_sdk_mac/dispatcher.rb` の `begin ... rescue UnsupportedPatternError` ブロック (41-59 行) に `OutOfCoverageError` の rescue を追加:
```ruby
        begin
          @compiler.compile(framework: framework, symbol: sym_meta)
        rescue UnsupportedPatternError => e
          detail = e.respond_to?(:pattern) ? e.pattern.to_s : "unknown"
          Telemetry.append_event(stage: "unsupported_pattern", framework: framework.to_s,
                                  symbol: symbol.to_s, detail: detail)
          safe_record_attempt(framework: framework.to_s, symbol: symbol.to_s,
                              generator: "template", error_stage: "unsupported_pattern",
                              error_detail: detail)
          raise
        rescue OutOfCoverageError => e
          Telemetry.append_event(stage: "out_of_coverage", framework: framework.to_s,
                                  symbol: symbol.to_s, detail: e.reason)
          safe_record_attempt(framework: framework.to_s, symbol: symbol.to_s,
                              generator: "coverage_boundary", error_stage: "out_of_coverage",
                              error_detail: e.reason)
          raise
        end
```

- [ ] **Step 5: 実装 — Config に inference_backend**

`lib/apple_sdk_mac/config.rb`:
- `DEFAULTS` に `inference_backend: :none` を追加
- `attr_accessor` に `:inference_backend` を追加
- `initialize` で `@inference_backend = DEFAULTS[:inference_backend]`
- `load_yaml` に `@inference_backend = data["inference_backend"].to_sym if data.key?("inference_backend") && !data["inference_backend"].to_s.empty?`
- `apply_env` に `@inference_backend = ENV["RB_APPLE_SDK_MAC_INFERENCE_BACKEND"].to_sym if ENV["RB_APPLE_SDK_MAC_INFERENCE_BACKEND"]`

(`llm_model` は当面そのまま残す。backend 内部の model 指定に転用可能だが本計画では未使用。)

- [ ] **Step 6: パス確認 + 全体回帰**

Run: `bundle exec rake test TESTOPTS="-n /GlueCompilerCoverageBoundary/"`
Expected: PASS (2 tests)
Run (回帰): `bundle exec rake test 2>&1 | tail -5`
Expected: `0 failures, 0 errors`

- [ ] **Step 7: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler.rb lib/apple_sdk_mac/dispatcher.rb lib/apple_sdk_mac/config.rb test/glue_compiler_test.rb
git commit -m "feat(compiler): coverage-boundary merge point — loud fail outside coverage"
```

---

### Task 4: `coverage_matrix_test.rb` — 8 kind round-trip (env-gated)

カバー済み 8 kind が実際に compile + invoke できることを 1 kind = 1 test で実証。既存の通る example / emitter smoke から各 kind の代表 symbol を採る。実 SDK + KB が要るため env-gate (`APPLE_SDK_MAC_RUN_E2E=1`)。

**Files:**
- Create: `test/integration/coverage_matrix_test.rb`

- [ ] **Step 1: 代表 symbol を確定**

実装前に各 kind の round-trip 代表を確定する。出発点 (既存資産):
- `function`(C): `CoreMIDI::MIDIGetNumberOfDestinations` (coremidi_endpoint_count.rb が通る)
- `global_constant`: `coremidi_endpoint_count` 系の定数
- `objc_method_class` / `objc_method_instance` / `swift_init` / `swift_property` / `swift_property_setter` / `swift_func`: `test/test_emitter_phase2_smoke.rb` が既に叩いている symbol を流用する。

Run: `sed -n '1,200p' test/test_emitter_phase2_smoke.rb` で既存 smoke の symbol を確認し、各 kind の代表を 1 つずつ抜き出す。

- [ ] **Step 2: テストを書く**

`test/integration/coverage_matrix_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"

# カバー済み 8 emitter kind が実際に round-trip (compile + invoke) することを
# 1 kind = 1 test で実証する被覆契約の executable な裏付け。CoverageContract が
# covered?==true と表明する kind は、ここで必ず緑でなければならない。
# 実 SDK + Knowledge Base が要るため env-gate。
class CoverageMatrixTest < Test::Unit::TestCase
  def setup
    omit "set APPLE_SDK_MAC_RUN_E2E=1 to run" unless ENV["APPLE_SDK_MAC_RUN_E2E"] == "1"
    require "apple_sdk_mac"
    AppleSDKMac.bootstrap!
  end

  # 各 kind: [framework, ruby 呼び出し proc, 期待アサーション]。
  # Step 1 で確定した代表 symbol を埋める。
  def test_function_c_kind_round_trips
    n = Apple::CoreMIDI.MIDIGetNumberOfDestinations
    assert_kind_of Integer, n
    assert_operator n, :>=, 0
  end

  # 以下、objc_method_class / objc_method_instance / swift_init /
  # swift_property / swift_property_setter / swift_func / global_constant を
  # それぞれ 1 test method で。Step 1 で抜いた代表 symbol を使い、戻り値を
  # assert_kind_of / assert_operator 等で検証する (1 example = 1 test method)。
end
```

(各 kind の test method 本体は Step 1 で確定した symbol に基づき、戻り型の assert を書く。`raise+puts` の自作 report は使わず assert に乗せる。)

- [ ] **Step 3: 実行して緑を確認**

Run: `APPLE_SDK_MAC_RUN_E2E=1 bundle exec rake test TESTOPTS="-n /CoverageMatrix/"`
Expected: 全 kind PASS。落ちた kind があれば、それは「契約に書いたのに動かない穴」= Phase 2 Track 1 で修正対象として記録。

- [ ] **Step 4: Commit**

```bash
git add test/integration/coverage_matrix_test.rb
git commit -m "test(coverage): executable 8-kind round-trip matrix (env-gated)"
```

---

## Phase 2 Track 1: 穴塞ぎ

### Task 5: `audio_device_count` out-param / struct-in 穴を診断して塞ぐ

`covered? == true` と表明する shape (function + struct-in + int-out) が壊れている。**根本原因は marshallers/template を行単位で読み、実験出力で確定してから直す** (debug 規律: 仮定を焼かない)。

**Files:**
- Test: `test/integration/baseline_e2e_test.rb` (audio の actual-run assert を足す) または `test/integration/examples_coreaudio_e2e_test.rb` を新規
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb` および/または `marshallers.rb` (診断結果に応じて)

- [ ] **Step 1: 失敗する e2e テストを書く**

`test/integration/examples_coreaudio_e2e_test.rb` を新規:

```ruby
# frozen_string_literal: true
require "test_helper"
require "open3"

# CoreAudio out-param + struct-in が静的 emitter で round-trip することの
# actual-run gate。env-gated (実 SDK 必要)。
class ExamplesCoreAudioE2ETest < Test::Unit::TestCase
  EXAMPLES_DIR = File.expand_path("../../examples", __dir__)

  def test_audio_device_count_runs_and_prints_count
    omit "set APPLE_SDK_MAC_RUN_E2E=1 to run" unless ENV["APPLE_SDK_MAC_RUN_E2E"] == "1"
    script = File.join(EXAMPLES_DIR, "audio_device_count.rb")
    out, err, status = Open3.capture3(
      { "RUBY_BOX" => "1" }, "bundle", "exec", "ruby", script,
      chdir: File.expand_path("../..", __dir__)
    )
    assert status.success?, "audio_device_count.rb exited non-zero:\n#{err}"
    assert_match(/audio devices: \d+/, out,
                 "expected 'audio devices: N' line, got:\n#{out}")
  end
end
```

- [ ] **Step 2: 失敗を確認 + 症状を捕捉**

Run: `APPLE_SDK_MAC_RUN_E2E=1 bundle exec rake test TESTOPTS="-n /audio_device_count/"`
Expected: FAIL — `TypeError: no implicit conversion of Hash into Integer` (glue_loader.rb 付近) 等。エラーと stack を記録。

- [ ] **Step 3: 診断 (仮定を焼かない)**

以下を行単位で読む:
- `lib/apple_sdk_mac/glue_compiler/marshallers.rb` の `IntMarshaller#out_handling` と struct-in pointer marshaller (`StructInPointerMarshaller` 等) の実装
- `lib/apple_sdk_mac/glue_compiler/template_generator.rb` の C-function emit 経路 (kind=="function" の param marshalling ループ)
- 生成された Swift source (`~/.cache/rb-apple-sdk-mac/<sdk>/sources/<glue_id>.swift`) を実際に開いて、struct-in (Hash) と int-out が Swift 側でどう展開されているか確認

確定手段: 必要なら template_generator / marshallers に一時 `warn` を入れて、生成 Swift と Ruby→C 引数列を実測する。`git diff` で確認し、診断用 `warn` は修正完了時に除去 (commit-then-revert で履歴化)。

- [ ] **Step 4: 最小修正を実装**

診断で確定した root cause のみを直す (struct-in の Hash→pointer 変換 or int-out の戻り marshalling)。スコープ外の emitter には触らない。production code の workaround / disable で緑にしない。

- [ ] **Step 5: パス確認 + 回帰**

Run: `APPLE_SDK_MAC_RUN_E2E=1 bundle exec rake test TESTOPTS="-n /audio_device_count/"`
Expected: PASS — `audio devices: N`
Run (回帰): `bundle exec rake test 2>&1 | tail -5` → `0 failures, 0 errors`
Run (matrix 再確認): `APPLE_SDK_MAC_RUN_E2E=1 bundle exec rake test TESTOPTS="-n /CoverageMatrix/"`

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/ test/integration/examples_coreaudio_e2e_test.rb
git commit -m "fix(marshaller): close struct-in + int-out hole for CoreAudio property size"
```

---

## Phase 2 Track 2: 推論 backend

### Task 6: `Config#inference_backend` のテスト固め

Task 3 で実装済みの選択ロジックに unit test を足す (Task 3 は wiring 中心で config の単体検証が薄い)。

**Files:**
- Test: `test/config_test.rb` (既存に追記、なければ新規)

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "test_helper"

class ConfigInferenceBackendTest < Test::Unit::TestCase
  def test_defaults_to_none
    cfg = AppleSDKMac::Config.new(config_file: "/nonexistent.yml")
    assert_equal :none, cfg.inference_backend
  end

  def test_env_override_to_claude_p
    ENV["RB_APPLE_SDK_MAC_INFERENCE_BACKEND"] = "claude_p"
    cfg = AppleSDKMac::Config.new(config_file: "/nonexistent.yml")
    assert_equal :claude_p, cfg.inference_backend
  ensure
    ENV.delete("RB_APPLE_SDK_MAC_INFERENCE_BACKEND")
  end
end
```

- [ ] **Step 2: 失敗 → パス確認**

Run: `bundle exec rake test TESTOPTS="-n /ConfigInferenceBackend/"`
Expected: Task 3 実装済みなら PASS。FAIL なら Task 3 Step 5 の config 変更を補完。

- [ ] **Step 3: Commit**

```bash
git add test/config_test.rb
git commit -m "test(config): inference_backend default :none + env override"
```

---

### Task 7: `Inference::Backend` 抽象 interface

**Files:**
- Create: `lib/apple_sdk_mac/inference/backend.rb`
- Test: `test/inference/backend_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

`test/inference/backend_test.rb`:

```ruby
require "test_helper"

class InferenceBackendTest < Test::Unit::TestCase
  def test_abstract_generate_glue_raises
    backend = AppleSDKMac::Inference::Backend.new
    assert_raise(NotImplementedError) do
      backend.generate_glue(framework: "Foo", symbol: {}, glue_id: "x", exported: "y")
    end
  end

  def test_abstract_name_raises
    assert_raise(NotImplementedError) { AppleSDKMac::Inference::Backend.new.name }
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rake test TESTOPTS="-n /InferenceBackendTest/"`
Expected: FAIL — `uninitialized constant AppleSDKMac::Inference`

- [ ] **Step 3: 実装**

`lib/apple_sdk_mac/inference/backend.rb`:

```ruby
# frozen_string_literal: true

module AppleSDKMac
  module Inference
    # 推論 backend の抽象 interface。実装は KB の symbol メタから Swift glue
    # source 文字列を返す。生成できなければ nil を返し、compile 側は
    # OutOfCoverageError に確定する。生成物は backend 信用ではなく、呼び出し側で
    # ValidationGates + swiftc + cache に通して初めて採用される。
    class Backend
      # @return [String, nil] Swift glue source、生成不能なら nil
      def generate_glue(framework:, symbol:, glue_id:, exported:)
        raise NotImplementedError, "#{self.class}#generate_glue"
      end

      # @return [String] telemetry 用 backend 識別子
      def name
        raise NotImplementedError, "#{self.class}#name"
      end
    end
  end
end
```

`lib/apple_sdk_mac.rb` に `require_relative "apple_sdk_mac/inference/backend"` を追加。

- [ ] **Step 4: パス確認**

Run: `bundle exec rake test TESTOPTS="-n /InferenceBackendTest/"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/inference/backend.rb test/inference/backend_test.rb lib/apple_sdk_mac.rb
git commit -m "feat(inference): abstract InferenceBackend interface"
```

---

### Task 8: `ClaudePBackend` — プロンプト構築 + subprocess + 抽出

subprocess 実行は injectable にして unit test では stub。プロンプト構築と Swift 抽出を単体検証する。

**Files:**
- Create: `lib/apple_sdk_mac/inference/claude_p_backend.rb`
- Test: `test/inference/claude_p_backend_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

`test/inference/claude_p_backend_test.rb`:

```ruby
require "test_helper"

class ClaudePBackendTest < Test::Unit::TestCase
  SYM = {
    name: "AudioObjectGetPropertyDataSize", kind: "function", abi: "c",
    signature: "(AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32, UnsafeMutablePointer<UInt32>) -> OSStatus",
    parameters_json: "[]"
  }.freeze

  # runner を inject して claude を呼ばずにテスト。
  def build(runner)
    AppleSDKMac::Inference::ClaudePBackend.new(runner: runner)
  end

  def test_name_is_claude_p
    assert_equal "claude_p", build(->(_p) { "" }).name
  end

  def test_prompt_includes_gate_constraints_and_symbol
    captured = nil
    runner = ->(prompt) { captured = prompt; "```swift\n// x\n```" }
    build(runner).generate_glue(framework: "CoreAudio", symbol: SYM,
                                glue_id: "abc123", exported: "glue_abc123_AudioObjectGetPropertyDataSize")
    assert_match(/AudioObjectGetPropertyDataSize/, captured)
    assert_match(/glue_abc123_AudioObjectGetPropertyDataSize/, captured)
    assert_match(/import/i, captured)        # import 制約を明記
    assert_match(/AppleSDKMacRuntime/, captured)
    assert_match(/@c public func/, captured) # export shape を明記
  end

  def test_extracts_swift_from_fenced_block
    runner = ->(_p) { "blah\n```swift\n@c public func glue_x() {}\n```\ntrailing" }
    src = build(runner).generate_glue(framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x")
    assert_equal "@c public func glue_x() {}", src.strip
  end

  def test_returns_nil_when_no_swift_block
    runner = ->(_p) { "I cannot help with that." }
    src = build(runner).generate_glue(framework: "F", symbol: SYM, glue_id: "x", exported: "glue_x")
    assert_nil src
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rake test TESTOPTS="-n /ClaudePBackend/"`
Expected: FAIL — `uninitialized constant AppleSDKMac::Inference::ClaudePBackend`

- [ ] **Step 3: 実装**

`lib/apple_sdk_mac/inference/claude_p_backend.rb`:

```ruby
# frozen_string_literal: true
require "open3"
require "shellwords"
require_relative "backend"

module AppleSDKMac
  module Inference
    # `claude -p` ヘッドレスを subprocess で呼び、KB symbol メタから Swift glue
    # source を生成する第一級 backend (PoC)。runner を inject 可能にして
    # subprocess を unit から切り離す。secret は一切扱わない (CLI 認証済み前提)。
    class ClaudePBackend < Backend
      DEFAULT_RUNNER = lambda do |prompt|
        out, _err, status = Open3.capture3("claude", "-p", prompt)
        status.success? ? out : nil
      end

      def initialize(runner: DEFAULT_RUNNER)
        @runner = runner
      end

      def name
        "claude_p"
      end

      def generate_glue(framework:, symbol:, glue_id:, exported:)
        prompt = build_prompt(framework: framework, symbol: symbol,
                              glue_id: glue_id, exported: exported)
        response = @runner.call(prompt)
        return nil if response.nil? || response.empty?
        extract_swift(response)
      end

      private

      def build_prompt(framework:, symbol:, glue_id:, exported:)
        <<~PROMPT
          You are generating a Swift glue function that bridges a single Apple
          framework symbol to C ABI for the rb-apple-sdk-mac gem.

          Target framework: #{framework}
          Symbol: #{symbol[:name]}
          Kind: #{symbol[:kind]}
          Signature: #{symbol[:signature]}
          Parameters (JSON): #{symbol[:parameters_json]}

          HARD CONSTRAINTS (the output is statically validated; violations are rejected):
          - Emit exactly ONE `@c public func #{exported}(...)`.
          - Import ONLY: `import #{framework}`, `import Foundation`, `import AppleSDKMacRuntime`.
          - Do NOT use: URLSession, FileManager, Process, posix_spawn, system,
            NSXPCConnection, UserDefaults, Keychain, raw objc_msgSend.
          - For CFType returns use Unmanaged.takeRetainedValue(); never manual CFRelease.
          - Return a value the C caller can consume (Int/Double/pointer/OpaqueRef).

          Respond with ONLY a single ```swift fenced code block containing the
          function. No prose.
        PROMPT
      end

      # ```swift ... ``` を抽出。無ければ nil。
      def extract_swift(response)
        m = response.match(/```swift\s*\n(.*?)```/m)
        return nil unless m
        body = m[1].to_s.strip
        body.empty? ? nil : body
      end
    end
  end
end
```

`lib/apple_sdk_mac.rb` に `require_relative "apple_sdk_mac/inference/claude_p_backend"` を追加。

- [ ] **Step 4: パス確認**

Run: `bundle exec rake test TESTOPTS="-n /ClaudePBackend/"`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/inference/claude_p_backend.rb test/inference/claude_p_backend_test.rb lib/apple_sdk_mac.rb
git commit -m "feat(inference): ClaudePBackend — headless claude -p glue generation"
```

---

### Task 9: `try_inference` 合流点を実装 (gates + swiftc + cache + 1 retry)

Task 3 の stub を本実装に差し替え。backend が出した Swift を**ルールと同一機構**に通す。失敗時 detail をプロンプトに添えて 1 回だけ再投入。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler.rb`
- Test: `test/glue_compiler_test.rb`

- [ ] **Step 1: 失敗するテストを書く**

`test/glue_compiler_test.rb` に追記:

```ruby
class GlueCompilerInferenceTest < Test::Unit::TestCase
  # backend が valid Swift を返し、gate/swiftc が通れば cache.insert され成功。
  def test_inference_success_inserts_with_inference_generator
    inserted = {}
    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    cache.define_singleton_method(:insert) { |**kw| inserted.replace(kw) }

    fake_template = Object.new
    def fake_template.generate(**) = nil   # template は必ず nil → 範囲外へ

    gates = Object.new
    def gates.validate(*, **) = Struct.new(:pass?, :errors).new(true, [])
    swiftc = Object.new
    def swiftc.compile(**) = [true, nil]

    backend = Object.new
    def backend.name = "claude_p"
    def backend.generate_glue(**) = "@c public func glue_x_Sym() {}"

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template, gates: gates, swiftc_invoker: swiftc,
      inference_backend: backend
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()",
            parameters_json: "[]" }   # 範囲外 kind
    result = compiler.compile(framework: "F", symbol: sym)
    assert_true result.success?
    assert_equal "inference:claude_p", result.generator
    assert_equal "inference:claude_p", inserted[:generator]
  end

  # backend が nil を返したら OutOfCoverageError。
  def test_inference_nil_raises_out_of_coverage
    cache = Object.new
    cache.define_singleton_method(:base_dir) { Dir.mktmpdir }
    cache.define_singleton_method(:sdk_version) { "26.5" }
    cache.define_singleton_method(:record_attempt) { |**| }
    fake_template = Object.new
    def fake_template.generate(**) = nil
    backend = Object.new
    def backend.name = "claude_p"
    def backend.generate_glue(**) = nil

    compiler = AppleSDKMac::GlueCompiler.new(
      cache: cache, runtime_dylib_path: "/tmp/none.dylib",
      template_generator: fake_template, inference_backend: backend
    )
    sym = { name: "Sym", kind: "swift_macro", abi: "swift", signature: "()",
            parameters_json: "[]" }
    assert_raise(AppleSDKMac::OutOfCoverageError) do
      compiler.compile(framework: "F", symbol: sym)
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rake test TESTOPTS="-n /GlueCompilerInference/"`
Expected: FAIL — `NotImplementedError: inference wiring lands in Task 9`

- [ ] **Step 3: 実装 — try_inference 本体**

`lib/apple_sdk_mac/glue_compiler.rb` の Task 3 stub を置換:

```ruby
    def try_inference(framework:, symbol:, reason:)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      FileUtils.mkdir_p(File.join(base, "sources"))
      FileUtils.mkdir_p(File.join(base, "lib"))
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
      swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
      exported = "glue_#{glue_id}_#{swift_id}"
      gen = "inference:#{@inference_backend.name}"

      swift_source = @inference_backend.generate_glue(
        framework: framework, symbol: symbol, glue_id: glue_id, exported: exported
      )
      # gate / swiftc 失敗時は失敗 detail を添えて 1 回だけ再投入。
      attempt = 0
      while attempt < 2
        if swift_source.nil? || swift_source.empty?
          break
        end
        gate_result = @gates.validate(swift_source, framework: framework,
                                                    glue_id: glue_id, symbol: swift_id)
        if gate_result.pass?
          File.write(src, swift_source)
          ok, err = @swiftc.compile(source_path: src, dylib_path: dylib,
                                    runtime_dylib_path: @runtime_dylib_path,
                                    module_search_paths: @runtime_modules_paths)
          if ok
            @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                          swift_source: swift_source, dylib_path: dylib,
                          exported_symbol: exported, generator: gen)
            return Result.new(success?: true, glue_id: glue_id, generator: gen,
                              dylib_path: dylib, exported_symbol: exported)
          end
          fail_detail = "swiftc: #{err}"
        else
          fail_detail = "static_check: #{gate_result.errors.join('; ')}"
        end
        attempt += 1
        break if attempt >= 2
        # 1 回だけ失敗 detail を添えて再投入 (backend が retry hint を受けない
        # 実装なら同じ結果になるが、契約上 1 回試みる)。
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                              generator: gen, error_stage: "inference_retry",
                              error_detail: fail_detail)
        swift_source = @inference_backend.generate_glue(
          framework: framework, symbol: symbol, glue_id: glue_id, exported: exported
        )
      end

      @cache.record_attempt(framework: framework, symbol: symbol[:name],
                            generator: gen, error_stage: "inference_failed",
                            error_detail: reason)
      raise OutOfCoverageError.new(
        framework: framework.to_s, symbol: symbol[:name].to_s,
        pattern: symbol[:kind].to_s,
        reason: "#{reason}; inference backend #{@inference_backend.name} could not produce valid glue"
      )
    end
```

`require "fileutils"` を glue_compiler.rb 冒頭に追加 (未 require なら)。

- [ ] **Step 4: パス確認 + 回帰**

Run: `bundle exec rake test TESTOPTS="-n /GlueCompilerInference/"`
Expected: PASS (2 tests)
Run (回帰): `bundle exec rake test 2>&1 | tail -5` → `0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler.rb test/glue_compiler_test.rb
git commit -m "feat(compiler): wire inference backend through gates+swiftc+cache"
```

---

### Task 10: `inference_poc_test.rb` — claude_p で実 example が e2e に成立

PoC 合格線。範囲外で従来落ちる symbol を `:claude_p` backend で resolve し、example が正値を返すことを assert。実 claude CLI + SDK + KB 要、env-gate (`APPLE_SDK_MAC_RUN_INFERENCE_POC=1`)。

**Files:**
- Create: `test/integration/inference_poc_test.rb`

- [ ] **Step 1: PoC 対象 symbol を選ぶ**

`CoverageContract.covered? == false` で、かつ単純な戻り (Int/構造の浅いもの) の Apple symbol を 1 つ選ぶ。候補は Telemetry の `out_of_coverage` ログ (`~/.cache/rb-apple-sdk-mac/diagnostics/*.jsonl`) を `grep out_of_coverage` して、実際に範囲外に落ちた symbol から戻りが単純なものを採る。

Run: `cat ~/.cache/rb-apple-sdk-mac/diagnostics/*.jsonl 2>/dev/null | grep out_of_coverage | tail -20`

- [ ] **Step 2: テストを書く**

`test/integration/inference_poc_test.rb`:

```ruby
# frozen_string_literal: true
require "test_helper"

# 推論フォールバックの viability PoC。CoverageContract 範囲外で従来は
# OutOfCoverageError になる symbol を、claude_p backend が glue 生成 →
# ValidationGates + swiftc 通過 → invoke して正値を返すことを実証する。
# 「切り替え点が在る」だけでは不合格 — 実際に動くことを assert で示す。
# 実 claude CLI + SDK + Knowledge Base 要。
class InferencePoCTest < Test::Unit::TestCase
  def setup
    unless ENV["APPLE_SDK_MAC_RUN_INFERENCE_POC"] == "1"
      omit "set APPLE_SDK_MAC_RUN_INFERENCE_POC=1 (needs claude CLI + SDK + KB)"
    end
    ENV["RB_APPLE_SDK_MAC_INFERENCE_BACKEND"] = "claude_p"
    require "apple_sdk_mac"
    AppleSDKMac.bootstrap!
  end

  def teardown
    ENV.delete("RB_APPLE_SDK_MAC_INFERENCE_BACKEND")
  end

  # Step 1 で選んだ範囲外 symbol を claude_p backend 経由で呼び、正値を assert。
  # 例 (Step 1 で確定した symbol / framework / 期待戻りに置換すること):
  def test_out_of_coverage_symbol_resolves_via_claude_p
    result = Apple::SomeFramework.SomeOutOfCoverageSymbol(/* args */)
    refute_nil result
    # 戻り型に応じた具体 assert (assert_kind_of / assert_operator 等)。
    # raise+puts の自作 report は使わない。
  end
end
```

- [ ] **Step 3: 実 claude で実行 (HITL gate 用の事実を生成)**

Run: `APPLE_SDK_MAC_RUN_INFERENCE_POC=1 bundle exec rake test TESTOPTS="-n /InferencePoC/" 2>&1 | tee tmp/inference-poc-run.log`
Expected: PASS。生成された glue (`~/.cache/rb-apple-sdk-mac/<sdk>/sources/<glue_id>.swift`)、test stdout、`git diff` を HITL gate に提示する素材として保存。

複数 symbol で試行を回す場合はロングバッチ規律で tmux detached。

- [ ] **Step 4: Commit**

```bash
git add test/integration/inference_poc_test.rb
git commit -m "test(inference): PoC — out-of-coverage symbol resolves via claude_p e2e"
```

---

## Phase 3: 統合検証

### Task 11: final code-review + verification-before-completion

**Files:**
- なし (レビューと検証)

- [ ] **Step 1: 全体回帰**

Run: `bundle exec rake test 2>&1 | tail -5`
Expected: `0 failures, 0 errors`
Run (e2e): `APPLE_SDK_MAC_RUN_E2E=1 bundle exec rake test TESTOPTS="-n '/CoverageMatrix|audio_device_count/'" 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 2: final code-review (fresh eye, higher model)**

`superpowers:requesting-code-review` で changeset 全体をレビュー。focus:
- 推論 seam が gates/swiftc/cache をルールと共有しているか (推論だけ別経路になっていないか)
- `covered?` の matcher が marshallers.rb の実体と乖離していないか
- dispatcher の OutOfCoverageError propagate と telemetry の整合
- test 名と body の乖離、env-gate の取りこぼし

- [ ] **Step 3: verification-before-completion**

`superpowers:verification-before-completion` で「green の証拠 (test stdout)」を確認してから完了宣言。PoC の事実 (動いた example / 生成 glue / branch 名) を HITL gate に提示。

- [ ] **Step 4: finishing-a-development-branch**

ソロ repo + main 直 push は hook で deny される (handoff 案件)。`--ff-only` local merge を default に検討。merge 可否は user 判断に委ねる。

---

## Self-Review メモ

- **Spec coverage**: 境界明示(Task 1-4) / 穴塞ぎ(Task 5) / InferenceBackend 抽象(Task 7) / claude_p 実装(Task 8) / 合流点(Task 3,9) / PoC 実証(Task 10) / KB green(Task 0) / 統合(Task 11) — spec の全節に対応 task あり。
- **型整合**: `CoverageContract#covered?`/`#uncovered_reason`、`Backend#generate_glue(framework:,symbol:,glue_id:,exported:)`/`#name`、`GlueCompiler.new(... inference_backend:, coverage_contract:)`、`Result.generator == "inference:<name>"` — 全 task で一貫。
- **診断 task の非確定コード**: Task 5 の修正本体は debug 規律により「行単位 read + 実測で確定」に委ねる (仮定を焼かない意図的設計)。test と診断手順は具体。
- **env-gate**: matrix / coreaudio e2e は `APPLE_SDK_MAC_RUN_E2E=1`、PoC は `APPLE_SDK_MAC_RUN_INFERENCE_POC=1` で分離。
