# Phase 2 — Emitter Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 1 で揃った Knowledge Base metadata (`is_throws` / `is_async` / `is_failable` / `is_settable` / `return_ownership` / `callback_signature_json` / `parameters_json[].external_label` / `throws_error_type` / `unsupported_pattern`) を emitter が全消化する。 signature 文字列 `include?` / naming heuristic / `try? else Qnil` silent swallow を全廃し、 unsupported pattern は明示的 `UnsupportedPatternError` で diagnostic surface に上げる。

**Architecture:** `lib/apple_sdk_mac/glue_compiler/template_generator.rb` の `emit_swift_init` / `emit_swift_func` / `emit_swift_property` / `emit_c_function_escape_hatch` 各路を KB record (KnowledgeCache `lookup_symbol` 経由 Hash) から取った column 値で分岐する。 `errors.rb` に Section 6.1 hierarchy (`FrameworkMissingError` / `SymbolMissingError` / `UnsupportedPatternError` / `GlueCompileError` / `ObjcError` / `SwiftError`) を追加、 dispatcher と glue_compiler が silent return nil する path を全て raise に置換。

**Tech Stack:** Ruby 4.x、 test-unit、 SQLite (Phase 1 で schema_version=9 の sdk_knowledge.sqlite)、 Apple Foundation framework headers、 swiftc 6.x。

---

## File Structure

| File | Responsibility | 変更種別 |
|---|---|---|
| `lib/apple_sdk_mac/errors.rb` | Phase 2 exception hierarchy 追加 | Modify |
| `lib/apple_sdk_mac/glue_compiler/template_generator.rb` | KB metadata 駆動の emitter 群 | Modify (主) |
| `lib/apple_sdk_mac/glue_compiler.rb` | template_generator が UnsupportedPatternError raise した場合の propagate (現状 return nil 経由) | Modify |
| `lib/apple_sdk_mac/dispatcher.rb` | lookup_symbol miss → SymbolMissingError、 compile fail → GlueCompileError | Modify |
| `lib/apple_sdk_mac/diagnostics.rb` | rich diagnostic message builder (Section 6.2 形式) | Modify |
| `test/test_errors_phase2.rb` | exception hierarchy 単体 test | Create |
| `test/glue_compiler/test_template_generator_phase2.rb` | emit_* が KB metadata から正しく分岐するか golden test | Create |
| `test/integration/test_dispatcher_phase2_diagnostics.rb` | dispatcher → emitter raise が user 経路まで届くか + diagnostic message に必要情報が embed されとるか | Create |
| `docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md` | Phase 2 完了 mark を Section 17 に追記 | Modify (T13) |

---

## Task 1: Exception hierarchy 整備

**目的:** spec Section 6.1 の 7 class hierarchy を `errors.rb` に確立。 既存 `DiscoveryError` / `CompileError` / `CallError` は phase 3 で整理予定なので保持、 Phase 2 で新規追加するのは `FrameworkMissingError` / `SymbolMissingError` / `UnsupportedPatternError` / `GlueCompileError` (alias) / `ObjcError` / `SwiftError` の 6 class。

**Files:**
- Modify: `lib/apple_sdk_mac/errors.rb`
- Create: `test/test_errors_phase2.rb`

- [ ] **Step 1: Write the failing test**

`test/test_errors_phase2.rb`:

```ruby
# frozen_string_literal: true
require "test-unit"
require "apple_sdk_mac/errors"

class TestErrorsPhase2 < Test::Unit::TestCase
  def test_framework_missing_error_is_apple_sdk_mac_error
    e = AppleSDKMac::FrameworkMissingError.new("framework not in KB")
    assert_kind_of AppleSDKMac::Error, e
    assert_equal "framework not in KB", e.message
  end

  def test_symbol_missing_error_is_apple_sdk_mac_error
    e = AppleSDKMac::SymbolMissingError.new("symbol absent")
    assert_kind_of AppleSDKMac::Error, e
  end

  def test_unsupported_pattern_error_carries_pattern_metadata
    e = AppleSDKMac::UnsupportedPatternError.new(
      pattern: "swift_macro",
      framework: "Foundation",
      symbol: "Observable::someMethod"
    )
    assert_kind_of AppleSDKMac::Error, e
    assert_equal "swift_macro", e.pattern
    assert_equal "Foundation", e.framework
    assert_equal "Observable::someMethod", e.symbol
    assert_match(/swift_macro/, e.message)
    assert_match(/Foundation/, e.message)
    assert_match(/Observable::someMethod/, e.message)
  end

  def test_glue_compile_error_is_alias_of_compile_error
    assert_same AppleSDKMac::CompileError, AppleSDKMac::GlueCompileError
  end

  def test_objc_error_is_apple_sdk_mac_error
    e = AppleSDKMac::ObjcError.new("NSError: domain=NSCocoaErrorDomain code=4")
    assert_kind_of AppleSDKMac::Error, e
  end

  def test_swift_error_is_apple_sdk_mac_error
    e = AppleSDKMac::SwiftError.new("Swift threw URLError")
    assert_kind_of AppleSDKMac::Error, e
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /Phase2/"`
Expected: FAIL with `NameError: uninitialized constant AppleSDKMac::FrameworkMissingError`

- [ ] **Step 3: Write minimal implementation**

`lib/apple_sdk_mac/errors.rb` 末尾 (既存 `CallError < Error` の後ろ):

```ruby
  class FrameworkMissingError < Error; end
  class SymbolMissingError < Error; end

  class UnsupportedPatternError < Error
    attr_reader :pattern, :framework, :symbol

    def initialize(pattern:, framework:, symbol:, hint: nil)
      @pattern = pattern
      @framework = framework
      @symbol = symbol
      @hint = hint
      super(format_message)
    end

    private

    def format_message
      parts = ["pattern=#{@pattern}", "framework=#{@framework}", "symbol=#{@symbol}"]
      parts << "hint=#{@hint}" if @hint
      "AppleSDKMac::UnsupportedPatternError #{parts.join(' ')}"
    end
  end

  GlueCompileError = CompileError

  class ObjcError < Error; end
  class SwiftError < Error; end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /Phase2/"`
Expected: PASS (6 tests, 全 assertion pass)

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/errors.rb test/test_errors_phase2.rb
git commit -m "$(cat <<'EOF'
feat(errors): add Phase 2 exception hierarchy

FrameworkMissingError / SymbolMissingError / UnsupportedPatternError
/ ObjcError / SwiftError を追加。 GlueCompileError を CompileError
alias として export。 UnsupportedPatternError は pattern / framework
/ symbol / hint を carry し format_message で diagnostic surface 用
の structured representation を持つ。 spec Section 6.1 hierarchy 完成。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: emit_swift_init を `is_throws` / `is_failable` KB-driven 化

**目的:** `initializer.include?("throws")` / `initializer.include?("?")` の 2 個 heuristic を Knowledge Base record の `is_throws` / `is_failable` column から読む形に置換。 `swift_initializer` 文字列が無くても KB record があれば動くようにする。 既存の文字列 fallback は Apple.discover escape hatch のため残す (KB miss 時のみ heuristic)。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:347-402` (`emit_swift_init`)
- Create: `test/glue_compiler/test_template_generator_phase2.rb`

- [ ] **Step 1: Write the failing test**

`test/glue_compiler/test_template_generator_phase2.rb`:

```ruby
# frozen_string_literal: true
require "test-unit"
require "apple_sdk_mac/glue_compiler/template_generator"

class TestTemplateGeneratorPhase2 < Test::Unit::TestCase
  class FakeKnowledgeCache
    def initialize(records = {})
      @records = records
    end

    def lookup_symbol(framework:, symbol:)
      @records[[framework, symbol]]
    end

    def lookup_klass_method(framework:, klass:, method:)
      @records[[framework, klass, method]]
    end
  end

  def test_emit_swift_init_throws_from_kb_is_throws_column
    kc = FakeKnowledgeCache.new(
      ["AVFoundation", "AVAudioFile.init(forReading:)"] => {
        is_throws: true, is_failable: false, is_async: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "AVFoundation",
      symbol: {
        kind: "swift_init",
        name: "AVAudioFile.init(forReading:)",
        swift_class: "AVAudioFile",
        swift_initializer: "init(forReading:)",
        params: [:opaque_ref],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_not_nil swift, "emit_swift_init should produce Swift source"
    assert_match(/try\?/, swift, "is_throws=true should emit try? wrap")
    assert_match(/guard let v = try\?/, swift)
  end

  def test_emit_swift_init_failable_from_kb_is_failable_column
    kc = FakeKnowledgeCache.new(
      ["Foundation", "URL.init(string:)"] => {
        is_throws: false, is_failable: true, is_async: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "Foundation",
      symbol: {
        kind: "swift_init",
        name: "URL.init(string:)",
        swift_class: "URL",
        swift_initializer: "init(string:)",
        params: [:string],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_match(/guard let v = /, swift, "is_failable=true should emit guard let")
    assert_match(/return Qnil/, swift)
  end

  def test_emit_swift_init_non_failable_non_throws_from_kb
    kc = FakeKnowledgeCache.new(
      ["AppKit", "NSWindow.init(contentRect:styleMask:backing:defer:)"] => {
        is_throws: false, is_failable: false, is_async: false
      }
    )
    tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
    swift = tg.generate(
      framework: "AppKit",
      symbol: {
        kind: "swift_init",
        name: "NSWindow.init(contentRect:styleMask:backing:defer:)",
        swift_class: "NSWindow",
        swift_initializer: "init(contentRect:styleMask:backing:defer:)",
        params: [:struct_in, :int, :int, :bool],
        return_kind: :opaque_ref
      },
      glue_id: "abcd1234"
    )
    assert_match(/let v = /, swift, "non-failable + non-throws should emit plain let")
    assert_no_match(/guard let v/, swift)
    assert_no_match(/try\?/, swift)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_init_throws_from_kb/"`
Expected: FAIL — 現状 emit_swift_init は `initializer.include?("?")` / `include?("throws")` で判定、 KB lookup 無し。 fake KC を渡しても is_throws=true は反映されへんため `try?` が emit されない。

- [ ] **Step 3: Implement minimal change**

`lib/apple_sdk_mac/glue_compiler/template_generator.rb:347-402` の `emit_swift_init` 内で:

`failable = initializer.to_s.include?("?")` を
`failable = kb_flag(framework, symbol[:name], :is_failable) { initializer.to_s.include?("?") }`
へ。 同じく throwing も `kb_flag(framework, symbol[:name], :is_throws) { initializer.to_s.include?("throws") }` へ。

private helper を末尾に追加:

```ruby
# Knowledge Base record から flag column を読む。 KB miss 時は block の
# fallback (heuristic / signature 文字列 include?) を返す。 既存の Apple.discover
# escape hatch で synth record を user 渡しする path を壊さない。
def kb_flag(framework, symbol_name, column)
  return yield unless @kc
  rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
  return yield unless rec
  v = rec[column]
  v.nil? ? yield : v
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_init_/"`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        test/glue_compiler/test_template_generator_phase2.rb
git commit -m "$(cat <<'EOF'
feat(emitter): drive emit_swift_init throws/failable from KB columns

initializer.include?("throws") / include?("?") の文字列 heuristic を
Knowledge Base record の is_throws / is_failable column 経由に置換。
@kc が無い / KB miss の場合は既存 heuristic に fallback する shim
(kb_flag helper) を介すため Apple.discover escape hatch 経路は維持。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: emit_swift_func を `is_async` / `is_throws` KB-driven 化

**目的:** `symbol[:async] == true` Hash key 依存を KB record の `is_async` 経由に切り替える。 同時に `is_throws` も KB 経由化 (現状 async path 内に throw 包含、 sync path は throw 未対応 → unsupported pattern 化判断を Task 7 で実施)。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:408-457` (`emit_swift_func`)
- Modify: `test/glue_compiler/test_template_generator_phase2.rb` (test 追加)

- [ ] **Step 1: Write the failing test**

`test/glue_compiler/test_template_generator_phase2.rb` に追記:

```ruby
def test_emit_swift_func_async_from_kb_is_async_column
  kc = FakeKnowledgeCache.new(
    ["Foundation", "URLSession.data(from:)"] => {
      is_throws: true, is_failable: false, is_async: true
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  swift = tg.generate(
    framework: "Foundation",
    symbol: {
      kind: "swift_func",
      name: "URLSession.data(from:)",
      swift_class: "URLSession",
      swift_func: "data",
      params: [:opaque_ref],
      return_kind: :opaque_ref
    },
    glue_id: "abcd1234"
  )
  assert_match(/Task \{/, swift, "is_async=true should emit Task skeleton")
  assert_match(/DispatchSemaphore/, swift)
  assert_match(/try await /, swift)
end

def test_emit_swift_func_sync_from_kb_no_async_column
  kc = FakeKnowledgeCache.new(
    ["Foundation", "ProcessInfo.processInfo.operatingSystemVersionString"] => {
      is_throws: false, is_failable: false, is_async: false
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  swift = tg.generate(
    framework: "Foundation",
    symbol: {
      kind: "swift_func",
      name: "ProcessInfo.osVersion",
      swift_class: "ProcessInfo",
      swift_func: "osVersion",
      params: [],
      return_kind: :string
    },
    glue_id: "abcd1234"
  )
  assert_no_match(/Task \{/, swift, "is_async=false should NOT emit Task skeleton")
  assert_no_match(/DispatchSemaphore/, swift)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_func_async_from_kb/"`
Expected: FAIL — `symbol[:async]` Hash key が無いので falsy 扱い、 sync path に流れる。 Task skeleton が emit されない。

- [ ] **Step 3: Implement minimal change**

`lib/apple_sdk_mac/glue_compiler/template_generator.rb:414` の
`is_async = symbol[:async] == true` を
`is_async = kb_flag(framework, symbol[:name], :is_async) { symbol[:async] == true }`
へ。

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_func_/"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        test/glue_compiler/test_template_generator_phase2.rb
git commit -m "$(cat <<'EOF'
feat(emitter): drive emit_swift_func is_async from KB column

symbol[:async] Hash key 依存を Knowledge Base record の is_async
column 経由に変更。 既存 explicit Hash key も Apple.discover escape
hatch として fallback で参照される。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: swift_init labels を `parameters_json[].external_label` から取る

**目的:** `swift_init_labels(initializer)` の文字列 split (`:` で split → empty reject) を Knowledge Base record の `parameters_json` 配列 (Phase 1 T9 で external_label 追加済) 由来に切り替える。 KB に label が無い場合は既存 split helper にfallback。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:359` (label 取得)
- Modify: `test/glue_compiler/test_template_generator_phase2.rb`

- [ ] **Step 1: Write the failing test**

```ruby
def test_emit_swift_init_labels_from_kb_parameters_json
  kc = FakeKnowledgeCache.new(
    ["AVFoundation", "AVAudioFile.init(forReading:)"] => {
      is_throws: true, is_failable: false, is_async: false,
      parameters_json: JSON.generate([
        { "external_label" => "forReading", "internal_name" => "url", "type" => "URL" }
      ])
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  swift = tg.generate(
    framework: "AVFoundation",
    symbol: {
      kind: "swift_init",
      name: "AVAudioFile.init(forReading:)",
      swift_class: "AVAudioFile",
      swift_initializer: "init()",  # 文字列 fallback では label 0 個 (誤判定)、 KB driven なら正しく取れる
      params: [:opaque_ref],
      return_kind: :opaque_ref
    },
    glue_id: "abcd1234"
  )
  assert_match(/AVAudioFile\(forReading: arg0\)/, swift,
    "labels should come from parameters_json external_label, not initializer string")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_init_labels_from_kb/"`
Expected: FAIL — `init()` 文字列 split で labels=[] になり `AVAudioFile()` が emit される。 想定の `AVAudioFile(forReading: arg0)` にならない。

- [ ] **Step 3: Implement minimal change**

`template_generator.rb:359` を:

```ruby
labels = kb_labels(framework, symbol[:name]) || swift_init_labels(initializer)
```

private helper 追加:

```ruby
# Knowledge Base record の parameters_json から external_label 配列を取り出す。
# external_label が無い (Hash 形 string indexed) record は nil 返しで caller
# に文字列 split helper へ fallback してもらう。
def kb_labels(framework, symbol_name)
  return nil unless @kc
  rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
  return nil unless rec && rec[:parameters_json]
  parsed = JSON.parse(rec[:parameters_json])
  return nil unless parsed.is_a?(Array) && parsed.any?
  labels = parsed.map { |p| p.is_a?(Hash) && p["external_label"] }
  return nil if labels.any? { |l| l.nil? || l == "" || l == "_" }
  labels
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_init_labels_from_kb/"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        test/glue_compiler/test_template_generator_phase2.rb
git commit -m "$(cat <<'EOF'
feat(emitter): drive emit_swift_init labels from parameters_json

swift_init_labels(initializer) の文字列 split を Knowledge Base record
の parameters_json[].external_label 由来に切り替え。 KB miss / `_`
underscore label / parameters_json 不在は既存 helper に fallback して
Apple.discover escape hatch を壊さない。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: emit_c_function を `return_ownership` KB-driven 化

**目的:** `cf_create_naming?(name)` 正規表現 (CFCreate / CFCopy で始まる関数名を CF retained と判定) を Knowledge Base record の `return_ownership` column 経由に切り替え。 KB に値 (`cf_returns_retained` 等) が入っている場合はそれを真実値とし、 名前 regex を fallback に降格。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:854 周辺` (`cf_create_naming?` 呼び出し path)
- Modify: `test/glue_compiler/test_template_generator_phase2.rb`

- [ ] **Step 1: Read existing cf_create_naming? path**

Run: `grep -n "cf_create_naming\|cf_returns_retained\|return_ownership" lib/apple_sdk_mac/glue_compiler/template_generator.rb lib/apple_sdk_mac/glue_compiler/marshallers.rb`

cf_create_naming? の caller を全て特定 (期待: marshallers.rb の return marshalling path)。 該当箇所が `cf_create_naming?(symbol[:name])` shape ならその場で `kb_return_ownership(framework, symbol[:name]) == "cf_returns_retained"` の OR 条件に置換。

- [ ] **Step 2: Write the failing test**

```ruby
def test_emit_c_function_return_ownership_from_kb_overrides_naming
  kc = FakeKnowledgeCache.new(
    # 名前が CFCreate / CFCopy で始まらないが KB で cf_returns_retained と marked
    ["CoreFoundation", "CFBundleGetMainBundleCopyExecutableURL"] => {
      return_ownership: "cf_returns_retained"
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  # cf_create_naming? を直接 query (private なので send 経由)
  retained = tg.send(:cf_returns_retained?,
    framework: "CoreFoundation",
    symbol_name: "CFBundleGetMainBundleCopyExecutableURL"
  )
  assert_equal true, retained,
    "KB return_ownership='cf_returns_retained' should override name regex"
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_c_function_return_ownership/"`
Expected: FAIL — `cf_returns_retained?` method が無い (NameError: NoMethodError)

- [ ] **Step 4: Implement minimal change**

template_generator.rb 末尾の private section に:

```ruby
def cf_returns_retained?(framework:, symbol_name:)
  if @kc
    rec = @kc.lookup_symbol(framework: framework, symbol: symbol_name)
    if rec && rec[:return_ownership]
      return rec[:return_ownership] == "cf_returns_retained"
    end
  end
  cf_create_naming?(symbol_name)
end
```

そして既存 cf_create_naming? の caller を `cf_returns_retained?(framework:, symbol_name:)` 経路に切り替える。 caller 場所は Step 1 で特定済。

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_c_function_return_ownership/"`
Expected: PASS

- [ ] **Step 6: Run full template_generator test suite**

Run: `bundle exec rake test TESTOPTS="-n /TemplateGenerator/"`
Expected: 既存 test 全 pass (回帰無し)

- [ ] **Step 7: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        test/glue_compiler/test_template_generator_phase2.rb
git commit -m "$(cat <<'EOF'
feat(emitter): drive CF retained detection from KB return_ownership

cf_create_naming? の名前 regex を Knowledge Base record の
return_ownership column 経由に降格。 cf_returns_retained?(framework:,
symbol_name:) helper を新設し、 KB に return_ownership 値があれば
真実値とし、 KB miss 時のみ既存 name regex を fallback として参照。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: callback_signature_json で auto-route、 lookup miss UnsupportedPatternError

**目的:** `CALLBACK_PILLAR_ROUTES` 手書き Hash を「KB record の callback_signature_json → route name 解決」 経路に拡張。 KB record に signature shape があり、 かつ `CALLBACK_PILLAR_ROUTES` の hash key として存在すれば既存 register/get_fnptr に route。 unregistered shape は `UnsupportedPatternError` raise + `pattern: "callback_signature_unregistered"` + hint「ext/apple_sdk_mac_runtime/ に register/get_fnptr を追加すれば対応可能」。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb` (callback path、 位置は 753-832 escape_hatch path 近辺)
- Modify: `test/glue_compiler/test_template_generator_phase2.rb`

- [ ] **Step 1: Read CALLBACK_PILLAR_ROUTES shape**

Run: `grep -n "CALLBACK_PILLAR_ROUTES" lib/apple_sdk_mac/glue_compiler.rb lib/apple_sdk_mac/glue_compiler/*.rb`

期待: glue_compiler.rb 直下に Hash `CALLBACK_PILLAR_ROUTES = { "<signature normalized>" => "<route name>" }` がある。

- [ ] **Step 2: Write the failing test**

```ruby
def test_callback_route_from_kb_signature_known_shape
  kc = FakeKnowledgeCache.new(
    ["CoreMIDI", "MIDIClientCreate"] => {
      callback_signature_json: JSON.generate({
        "params" => ["const MIDINotification*", "void*"],
        "return_type" => "void",
        "normalized" => "midi_notify"  # CALLBACK_PILLAR_ROUTES の hash key
      })
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  route = tg.send(:resolve_callback_route,
    framework: "CoreMIDI",
    symbol_name: "MIDIClientCreate"
  )
  assert_equal "midi_notify", route
end

def test_callback_route_unregistered_raises_unsupported_pattern_error
  kc = FakeKnowledgeCache.new(
    ["MyFramework", "MyAPI_unknownCallback"] => {
      callback_signature_json: JSON.generate({
        "params" => ["MyCustomStruct*", "void*"],
        "return_type" => "int",
        "normalized" => "my_custom_unregistered"
      })
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
    tg.send(:resolve_callback_route,
      framework: "MyFramework",
      symbol_name: "MyAPI_unknownCallback"
    )
  end
  assert_equal "callback_signature_unregistered", err.pattern
  assert_equal "MyFramework", err.framework
  assert_match(/my_custom_unregistered/, err.message)
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_callback_route/"`
Expected: FAIL — `resolve_callback_route` method が無い

- [ ] **Step 4: Implement minimal change**

template_generator.rb 末尾 private に:

```ruby
def resolve_callback_route(framework:, symbol_name:)
  rec = @kc&.lookup_symbol(framework: framework, symbol: symbol_name)
  return nil unless rec && rec[:callback_signature_json]
  parsed = JSON.parse(rec[:callback_signature_json])
  normalized = parsed["normalized"] || parsed[:normalized]
  return nil unless normalized
  route_table = ::AppleSDKMac::GlueCompiler::CALLBACK_PILLAR_ROUTES
  hit = route_table.values.uniq.find { |r| r.to_s == normalized.to_s }
  if hit
    return hit
  else
    raise AppleSDKMac::UnsupportedPatternError.new(
      pattern: "callback_signature_unregistered",
      framework: framework,
      symbol: symbol_name,
      hint: "callback signature '#{normalized}' is not registered in ext/apple_sdk_mac_runtime/. " \
            "Add runtime_callback_pillar_register_#{normalized} / get_#{normalized}_fnptr + " \
            "Marshaller route map entry."
    )
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_callback_route/"`
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        test/glue_compiler/test_template_generator_phase2.rb
git commit -m "$(cat <<'EOF'
feat(emitter): resolve callback route from KB signature, raise on miss

KB record の callback_signature_json.normalized を route name として
解決する resolve_callback_route helper を新設。 CALLBACK_PILLAR_ROUTES
に対応 route があれば返す、 無ければ UnsupportedPatternError raise
(pattern=callback_signature_unregistered, hint に register/get_fnptr
追加 path を明示)。 spec Section 4.4 + 6.1 整合。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: unsupported_pattern 検出 → emitter raise UnsupportedPatternError

**目的:** Knowledge Base record の `unsupported_pattern` column (Phase 1 で `static_inline_function` / `function_like_macro` / `swift_macro` / `swift_result_builder` 等の marker が入る) を emitter 入口で check し、 該当時は早期 raise する。 現状の `return nil` (silent LLM fallback への投げ) を廃止し、 user / dispatcher 経路まで明示 propagate。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:90-106` (`generate` entry)
- Modify: `test/glue_compiler/test_template_generator_phase2.rb`

- [ ] **Step 1: Write the failing test**

```ruby
def test_emit_raises_unsupported_pattern_when_kb_has_marker
  kc = FakeKnowledgeCache.new(
    ["Foundation", "Observable.someMethod"] => {
      unsupported_pattern: "swift_macro"
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
    tg.generate(
      framework: "Foundation",
      symbol: { kind: "swift_func", name: "Observable.someMethod", swift_class: "Observable", swift_func: "someMethod", params: [], return_kind: :void },
      glue_id: "abcd1234"
    )
  end
  assert_equal "swift_macro", err.pattern
  assert_equal "Foundation", err.framework
  assert_equal "Observable.someMethod", err.symbol
end

def test_emit_no_raise_when_kb_unsupported_pattern_is_nil
  kc = FakeKnowledgeCache.new(
    ["Foundation", "NSString.length"] => {
      unsupported_pattern: nil, is_throws: false, is_failable: false
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  # 期待: raise しない、 普通に Swift source 返す (or nil for unknown kind、
  # でも raise しない事を確認)
  begin
    tg.generate(
      framework: "Foundation",
      symbol: { kind: "swift_property", name: "NSString.length", swift_class: "NSString", swift_property: "length", return_kind: :int, instance: true },
      glue_id: "abcd1234"
    )
  rescue AppleSDKMac::UnsupportedPatternError
    flunk "should not raise UnsupportedPatternError when unsupported_pattern is nil"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_raises_unsupported_pattern/"`
Expected: FAIL — generate は unsupported_pattern を check しない、 raise しない、 (nil or partial Swift source 返す)。

- [ ] **Step 3: Implement minimal change**

`template_generator.rb:90` (generate 冒頭) に check 追加:

```ruby
def generate(framework:, symbol:, glue_id:)
  if @kc
    rec = @kc.lookup_symbol(framework: framework, symbol: symbol[:name])
    if rec && rec[:unsupported_pattern]
      raise AppleSDKMac::UnsupportedPatternError.new(
        pattern: rec[:unsupported_pattern],
        framework: framework,
        symbol: symbol[:name].to_s,
        hint: hint_for_pattern(rec[:unsupported_pattern])
      )
    end
  end
  # 以下既存 dispatcher 経路 ...
```

末尾 private に hint_for_pattern:

```ruby
PATTERN_HINTS = {
  "swift_macro"           => "Create a Swift package wrapping the macro-generated API as a public func, then add via apple:knowledge:add-framework.",
  "swift_result_builder"  => "Result builders are compile-time DSLs; provide a builder-evaluated Swift wrapper func and add to KB.",
  "static_inline_function"=> "Static inline C functions cannot be dlopen'd; provide a Swift / C wrapper function with external linkage and add to KB.",
  "function_like_macro"   => "C function-like macros are expansion-only; reimplement as Swift / C function and add to KB."
}.freeze

def hint_for_pattern(pattern)
  PATTERN_HINTS[pattern.to_s] ||
    "Pattern '#{pattern}' is not directly bridgeable. Provide a public Swift/C wrapper and add it to the Knowledge Base."
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_(raises|no_raise)_unsupported/"`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        test/glue_compiler/test_template_generator_phase2.rb
git commit -m "$(cat <<'EOF'
feat(emitter): raise UnsupportedPatternError on KB marker

generate() 入口で Knowledge Base record の unsupported_pattern column
を check し、 swift_macro / swift_result_builder / static_inline_function
/ function_like_macro いずれかが marked された symbol は早期 raise
する。 PATTERN_HINTS で workaround 文面を hint に embed。 silent
return nil → LLM fallback の経路を廃止し、 user に明示的 diagnostic
を届ける。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: throws_error_type → SwiftError / ObjcError dispatch、 `try? else Qnil` 廃止

**目的:** Swift throws を `try?` で握り潰して Qnil に転換する silent swallow path を、 `do { try ... } catch { rb_raise(klass, "\(error)") }` の明示 raise に置換。 `throws_error_type` が `"NSError"` 系なら `Apple::ObjcError`、 それ以外 (typed throws 含む) は `Apple::SwiftError` を rb_raise に渡す。 Apple::Error.message に rich context (framework / symbol / localizedDescription) を embed。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:380-388` (`init_binding` の throwing branch、 swift_init)
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:444` (`rb_raise(rb_eRuntimeError ...)` の Swift func async path)
- Modify: emit 時に追加で `@_silgen_name("rb_eAppleSDKObjcError")` 等の Swift 側 const declaration が必要 → HEADER に追加

- [ ] **Step 1: Read Ruby-side exception class export to C**

Run: `grep -rn "rb_define_class\|rb_eRuntimeError\|AppleSDKObjcError\|AppleSDKSwiftError" ext/apple_sdk_mac_runtime/`

期待: ext/apple_sdk_mac_runtime/ 内に Apple::ObjcError / Apple::SwiftError class を C 経路で expose する仕組みが必要。 現状無ければ Task 8a として ext/ への追加 step が要る。 Step 2 で確認後決定。

- [ ] **Step 2: Decide minimal exposure path**

ext/ 経路を追加するなら:
- ext/apple_sdk_mac_runtime/runtime.c に `VALUE rb_eAppleSDKObjcError; VALUE rb_eAppleSDKSwiftError;` を追加
- Init_apple_sdk_mac_runtime() で `rb_eAppleSDKObjcError = rb_const_get(rb_const_get(rb_cObject, rb_intern("AppleSDKMac")), rb_intern("ObjcError"))` 風 fetch
- HEADER に `@_silgen_name("rb_eAppleSDKObjcError") var rb_eAppleSDKObjcError: UInt` 追加

ext/ 触る場合は rake-compiler の build が再要、 implementation 中に `rake compile` を 1 回挟む。 ext/ 触らない場合は Ruby 側 raise 経路に統一 (rb_raise(rb_eRuntimeError, ...) で常に投げ、 dispatcher 側で文字列見て ObjcError/SwiftError 再 raise) の workaround。

**Step 2 outcome から Step 3 以降を分岐:**
- ext/ 必要なら: Task 8a で ext/ 追加 → rake compile → Task 8b で HEADER + emit
- ext/ 不要 (既存に Apple error const あり) なら: Task 8 内で HEADER + emit のみ

- [ ] **Step 3: Write the failing test (ext 経路有無に応じて分岐)**

例 (ext/ 不要 path 仮定):

```ruby
def test_emit_swift_init_throws_emits_do_catch_with_swift_error_raise
  kc = FakeKnowledgeCache.new(
    ["AVFoundation", "AVAudioFile.init(forReading:)"] => {
      is_throws: true, is_failable: false, throws_error_type: nil  # untyped
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  swift = tg.generate(
    framework: "AVFoundation",
    symbol: {
      kind: "swift_init",
      name: "AVAudioFile.init(forReading:)",
      swift_class: "AVAudioFile",
      swift_initializer: "init(forReading:) throws",
      params: [:opaque_ref], return_kind: :opaque_ref
    },
    glue_id: "abcd1234"
  )
  assert_match(/do \{[\s\S]+try AVAudioFile\(/, swift,
    "throws init should emit do/try block")
  assert_match(/catch \{[\s\S]+rb_raise\(rb_eAppleSDKSwiftError/, swift,
    "untyped throws should rb_raise rb_eAppleSDKSwiftError")
  assert_no_match(/guard let v = try\? /, swift,
    "try? else Qnil silent swallow must be eliminated")
end

def test_emit_swift_init_throws_nserror_emits_objc_error_raise
  kc = FakeKnowledgeCache.new(
    ["UIKit", "UIDocument.init(fileURL:)"] => {
      is_throws: true, is_failable: false, throws_error_type: "NSError"
    }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  swift = tg.generate(
    framework: "UIKit",
    symbol: {
      kind: "swift_init",
      name: "UIDocument.init(fileURL:)",
      swift_class: "UIDocument",
      swift_initializer: "init(fileURL:) throws",
      params: [:opaque_ref], return_kind: :opaque_ref
    },
    glue_id: "abcd1234"
  )
  assert_match(/rb_raise\(rb_eAppleSDKObjcError/, swift,
    "throws_error_type=NSError should rb_raise rb_eAppleSDKObjcError")
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_init_throws_emits_/"`
Expected: FAIL

- [ ] **Step 5: Implement** (ext/ 追加が要れば ext/ → rake compile → emit、 不要なら emit のみ)

template_generator.rb の throwing init_binding を:

```ruby
init_binding =
  if throwing
    raise_klass = throws_error_type == "NSError" ? "rb_eAppleSDKObjcError" : "rb_eAppleSDKSwiftError"
    <<~SWIFT.chomp
      let v: #{swift_klass}
      do {
          v = try #{call_expr}
      } catch {
          rb_raise(#{raise_klass}, "\\(#{framework}.#{symbol[:name]}: \\(error.localizedDescription))")
      }
    SWIFT
  elsif labels.empty? || !failable
    "let v = #{call_expr}"
  else
    "guard let v = #{call_expr} else { return Qnil }"
  end
```

throws_error_type は `kb_metadata(framework, symbol[:name], :throws_error_type)` helper で取る。

HEADER に declarations 追加:

```swift
@_silgen_name("rb_eAppleSDKObjcError")
var rb_eAppleSDKObjcError: UInt
@_silgen_name("rb_eAppleSDKSwiftError")
var rb_eAppleSDKSwiftError: UInt
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_init_throws_/"`
Expected: PASS (2 tests)

- [ ] **Step 7: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        test/glue_compiler/test_template_generator_phase2.rb \
        ext/apple_sdk_mac_runtime/runtime.c \  # only if ext/ changed
        ext/apple_sdk_mac_runtime/extconf.rb  # only if ext/ changed
git commit -m "$(cat <<'EOF'
feat(emitter): replace try? swallow with do/catch + rb_raise dispatch

Swift throws init / func の try? else Qnil silent swallow を廃止し、
do { try ... } catch { rb_raise(klass, message) } の明示 raise に置換。
throws_error_type='NSError' は rb_eAppleSDKObjcError、 それ以外は
rb_eAppleSDKSwiftError を dispatch。 HEADER に該当 Swift @_silgen_name
declaration を追加。 ext/ 側で Ruby exception const を register。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: setter glue (`is_settable=1` property)

**目的:** spec Section 4.3。 `is_settable=1` の Swift property に対して setter form の glue を emit し、 Ruby 側で `Apple::<F>::<Type>#<prop>=(val)` が呼べるようにする。 emit_swift_property を拡張、 namespace_builder で setter method install path を確保。

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/template_generator.rb:486-530` (`emit_swift_property`)
- Modify: `lib/apple_sdk_mac/namespace_builder.rb` (setter method install)
- Modify: `test/glue_compiler/test_template_generator_phase2.rb`

- [ ] **Step 1: Write the failing test**

```ruby
def test_emit_swift_property_setter_when_is_settable_true
  kc = FakeKnowledgeCache.new(
    ["AppKit", "NSWindow.title"] => { is_settable: true }
  )
  tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: kc)
  swift = tg.generate(
    framework: "AppKit",
    symbol: {
      kind: "swift_property_setter",  # 新 kind
      name: "NSWindow.title=",
      swift_class: "NSWindow",
      swift_property: "title",
      params: [:string],
      return_kind: :void,
      instance: true
    },
    glue_id: "abcd1234"
  )
  assert_not_nil swift
  assert_match(/receiver\.title = arg0/, swift, "setter form should assign argv[1] to property")
  assert_match(/return Qnil/, swift)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_property_setter/"`
Expected: FAIL — kind=swift_property_setter は generate dispatcher に case 文無し

- [ ] **Step 3: Implement minimal change**

template_generator.rb の generate 内 case 文に `when "swift_property_setter"` を追加:

```ruby
when "swift_property_setter"
  return emit_swift_property_setter(framework: framework, symbol: symbol, glue_id: glue_id)
```

emit_swift_property_setter helper を追加 (emit_swift_property の直後):

```ruby
def emit_swift_property_setter(framework:, symbol:, glue_id:)
  klass = swift_bridged_class_name(symbol[:swift_class].to_s)
  prop = symbol[:swift_property].to_s
  swift_id = symbol[:name].to_s.gsub(/[^A-Za-z0-9_]/, "_")
  exported = "glue_#{glue_id}_#{swift_id}"
  body = <<~SWIFT.chomp
    let receiver = unsafeBitCast(
        OpaquePointer(bitPattern: UInt(rb_num2ull(argv[0])))!,
        to: #{klass}.self
    )
    let arg0 = #{ObjcMarshalling.in_load(symbol[:params][0], 1)}
    receiver.#{prop} = arg0
    return Qnil
  SWIFT
  <<~SWIFT
    import #{framework}
    import Foundation

    #{HEADER}
    @c
    public func #{exported}(
        _ argv: UnsafePointer<UInt>, _ argc: Int32
    ) -> UInt {
        #{body}
    }
  SWIFT
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_emit_swift_property_setter/"`
Expected: PASS

- [ ] **Step 5: Wire namespace_builder to install setter when KB has is_settable=1**

namespace_builder.rb の property install path に:

```ruby
if rec[:is_settable]
  klass.define_method("#{prop_name}=") do |val|
    AppleSDKMac::Dispatcher.dispatch(framework: framework, symbol: "#{klass_name}.#{prop_name}=", args: [self, val])
  end
end
```

(具体 path は namespace_builder.rb の既存 install_property method を改修、 Step 5 内で見て調整)

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/glue_compiler/template_generator.rb \
        lib/apple_sdk_mac/namespace_builder.rb \
        test/glue_compiler/test_template_generator_phase2.rb
git commit -m "$(cat <<'EOF'
feat(emitter): setter glue for is_settable=1 swift properties

swift_property_setter kind を generate dispatcher に追加し、 receiver
property = arg0 の minimal setter glue を emit。 namespace_builder
を拡張し、 KB record の is_settable=1 property に Ruby setter method
(prop=) を install。 spec Section 4.3 整合。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: dispatcher / glue_compiler の silent return-nil-cascade 廃止

**目的:** `dispatcher.rb:14` の `raise Error, "unknown symbol"` を `SymbolMissingError` 化、 `compile failed` を `GlueCompileError` 化。 `glue_compiler.rb` の template path が `return nil` (template_nil) を返す経路を `UnsupportedPatternError` propagate に置換 (template_generator が raise した場合 try_template が rescue せず流す)。

**Files:**
- Modify: `lib/apple_sdk_mac/dispatcher.rb`
- Modify: `lib/apple_sdk_mac/glue_compiler.rb:32-87` (`compile`, `try_template`)
- Create: `test/integration/test_dispatcher_phase2_diagnostics.rb`

- [ ] **Step 1: Write the failing test**

`test/integration/test_dispatcher_phase2_diagnostics.rb`:

```ruby
# frozen_string_literal: true
require "test-unit"
require "apple_sdk_mac"

class TestDispatcherPhase2Diagnostics < Test::Unit::TestCase
  def setup
    @fake_kc = Object.new
    def @fake_kc.lookup_symbol(framework:, symbol:)
      return nil if symbol == "NoSuchAPI"
      return { unsupported_pattern: "swift_macro", name: symbol } if symbol == "Observable.someMethod"
      { name: symbol, kind: "function" }
    end
  end

  def test_dispatcher_raises_symbol_missing_when_kb_lookup_returns_nil
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: @fake_kc, glue_cache: nil, loader: nil, compiler: nil
    )
    err = assert_raise(AppleSDKMac::SymbolMissingError) do
      d.dispatch(framework: "Foundation", symbol: "NoSuchAPI", args: [])
    end
    assert_match(/Foundation/, err.message)
    assert_match(/NoSuchAPI/, err.message)
  end

  def test_dispatcher_propagates_unsupported_pattern_error_from_emitter
    fake_cache = Object.new
    def fake_cache.lookup(*); nil; end
    fake_compiler = Object.new
    fake_compiler.instance_variable_set(:@kc, @fake_kc)
    def fake_compiler.compile(framework:, symbol:)
      raise AppleSDKMac::UnsupportedPatternError.new(
        pattern: "swift_macro",
        framework: framework,
        symbol: symbol[:name].to_s
      )
    end
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: @fake_kc, glue_cache: fake_cache, loader: nil, compiler: fake_compiler
    )
    err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
      d.dispatch(framework: "Foundation", symbol: "Observable.someMethod", args: [])
    end
    assert_equal "swift_macro", err.pattern
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /TestDispatcherPhase2/"`
Expected: FAIL — 現状 dispatcher は `raise Error, ...` (specific class じゃない)、 emitter UnsupportedPatternError は @cache.lookup → @compiler.compile 経由で catch / `compile failed` に化ける。

- [ ] **Step 3: Implement dispatcher 修正**

`lib/apple_sdk_mac/dispatcher.rb`:

```ruby
def dispatch(framework:, symbol:, args: [])
  sym_meta = @knowledge.lookup_symbol(framework: framework, symbol: symbol)
  unless sym_meta
    raise SymbolMissingError, "unknown symbol #{framework}::#{symbol}"
  end
  canonical = sym_meta[:name]
  cache_hit = @cache.lookup(framework: framework, symbol: canonical)
  if cache_hit.nil?
    @compiler.compile(framework: framework, symbol: sym_meta)
    cache_hit = @cache.lookup(framework: framework, symbol: canonical)
    raise GlueCompileError, "compile failed for #{framework}::#{canonical}" if cache_hit.nil?
  end
  fn_ptr = @loader.load(dylib_path: cache_hit[:dylib_path], exported_symbol: cache_hit[:exported_symbol])
  @loader.invoke(fn_ptr, args)
end
```

`lib/apple_sdk_mac/glue_compiler.rb:32-36` の `compile` :

```ruby
def compile(framework:, symbol:)
  # template_generator が UnsupportedPatternError raise した場合は rescue
  # せず propagate。 silent LLM fallback への流入を遮断。
  result = try_template(framework: framework, symbol: symbol)
  return result if result.success?
  return result if result.error_stage == "unsupported_pattern_propagated"
  try_llm(framework: framework, symbol: symbol, prior_failure: result)
end
```

`try_template` 内の `swift_source = @template.generate(...)` を rescue 経路で:

```ruby
swift_source =
  begin
    @template.generate(framework: framework, symbol: symbol, glue_id: glue_id)
  rescue AppleSDKMac::UnsupportedPatternError => e
    # 早期 propagate: LLM fallback も意味が無い (KB が明示的に unsupported
    # と marked) ため raise を caller に届ける。
    raise e
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /TestDispatcherPhase2/"`
Expected: PASS (2 tests)

- [ ] **Step 5: Run full integration suite**

Run: `bundle exec rake test`
Expected: 既存 test 全 pass (回帰なし)

- [ ] **Step 6: Commit**

```bash
git add lib/apple_sdk_mac/dispatcher.rb \
        lib/apple_sdk_mac/glue_compiler.rb \
        test/integration/test_dispatcher_phase2_diagnostics.rb
git commit -m "$(cat <<'EOF'
feat(dispatcher,compiler): replace silent return-nil with typed raises

dispatcher の "unknown symbol" / "compile failed" を SymbolMissingError
/ GlueCompileError に格上げ。 glue_compiler.compile は
UnsupportedPatternError を template path で受けたら LLM fallback を
回さず caller に propagate する。 silent return nil の cascade 経路
全廃。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Diagnostic message 形式整備 (Section 6.2)

**目的:** `UnsupportedPatternError#message` を Section 6.2 例の multiline 形式 (Pattern / Framework / macOS SDK / gem version / Knowledge Base schema / Workaround / Report URL) に整える。 既存 `format_message` を rich version に置換。

**Files:**
- Modify: `lib/apple_sdk_mac/errors.rb`
- Modify: `test/test_errors_phase2.rb`

- [ ] **Step 1: Write the failing test**

```ruby
def test_unsupported_pattern_error_diagnostic_message_includes_section_6_2_fields
  e = AppleSDKMac::UnsupportedPatternError.new(
    pattern: "swift_macro",
    framework: "Foundation",
    symbol: "Observable::someMethod",
    hint: "Use Swift package wrapper."
  )
  msg = e.message
  assert_match(/Pattern: swift_macro/, msg)
  assert_match(/Framework: Foundation/, msg)
  assert_match(/Symbol: Observable::someMethod/, msg)
  assert_match(/macOS SDK:/, msg)
  assert_match(/gem version:/, msg)
  assert_match(/Knowledge Base schema:/, msg)
  assert_match(/Workaround:/, msg)
  assert_match(/Use Swift package wrapper/, msg)
  assert_match(%r{https://github.com/bash0C7/rb-apple-sdk-mac/issues}, msg)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rake test TESTOPTS="-n /test_unsupported_pattern_error_diagnostic_message/"`
Expected: FAIL — 現状 format_message は単 line `pattern=... framework=... symbol=...` shape のみ。

- [ ] **Step 3: Implement minimal change**

`lib/apple_sdk_mac/errors.rb` の UnsupportedPatternError を:

```ruby
class UnsupportedPatternError < Error
  attr_reader :pattern, :framework, :symbol, :hint

  def initialize(pattern:, framework:, symbol:, hint: nil)
    @pattern = pattern
    @framework = framework
    @symbol = symbol
    @hint = hint
    super(format_message)
  end

  private

  def format_message
    require "apple_sdk_mac/version"
    sdk_version = ENV["APPLE_SDK_MAC_SDK_VERSION"] ||
                  defined?(AppleSDKMac::SDK_VERSION) && AppleSDKMac::SDK_VERSION || "unknown"
    <<~MSG.chomp
      AppleSDKMac::UnsupportedPatternError:
        Symbol '#{@framework}::#{@symbol}' uses pattern that cannot be bridged.

        Pattern: #{@pattern}
        Framework: #{@framework}
        Symbol: #{@symbol}
        macOS SDK: #{sdk_version}
        gem version: #{AppleSDKMac::VERSION}
        Knowledge Base schema: 9

        Workaround:
          #{@hint || "See https://github.com/bash0C7/rb-apple-sdk-mac for guidance."}

        Report at https://github.com/bash0C7/rb-apple-sdk-mac/issues if you
        believe this pattern should be supported.
    MSG
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rake test TESTOPTS="-n /test_unsupported_pattern_error_diagnostic_message/"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/apple_sdk_mac/errors.rb test/test_errors_phase2.rb
git commit -m "$(cat <<'EOF'
feat(errors): rich diagnostic message for UnsupportedPatternError

format_message を Section 6.2 multiline shape (Pattern / Framework
/ Symbol / macOS SDK / gem version / KB schema / Workaround / Report
URL) に進化。 user / AI が message から workaround コードを生成可能。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Regression smoke — Phase 1 metadata path の golden test

**目的:** Phase 1 で populate された KB column の各種 (is_throws / is_async / is_failable / is_settable / return_ownership / callback_signature_json / unsupported_pattern / throws_error_type) を経路ごとに 1 example で smoke 取る。 既存の emitter test golden を Phase 2 path 経由でも green であることを確認。

**Files:**
- Create: `test/integration/test_emitter_phase2_smoke.rb`

- [ ] **Step 1: Write the smoke test**

```ruby
# frozen_string_literal: true
require "test-unit"
require "apple_sdk_mac"

class TestEmitterPhase2Smoke < Test::Unit::TestCase
  def setup
    @kc = AppleSDKMac::KnowledgeCache.new(
      db_path: File.join(
        File.expand_path("~/.cache/rb-apple-sdk-mac"),
        "knowledge", "26.4.1", "sdk_knowledge.sqlite"
      )
    )
    omit "Knowledge Base 未 build" unless @kc.real_knowledge_built?
    @tg = AppleSDKMac::GlueCompiler::TemplateGenerator.new(knowledge_cache: @kc)
  end

  def test_smoke_avaudio_file_init_for_reading_emits_do_catch
    sym = @kc.lookup_symbol(framework: "AVFoundation", symbol: "AVAudioFile.init(forReading:)")
    omit "AVAudioFile.init(forReading:) not in KB" unless sym && sym[:is_throws]
    swift = @tg.generate(
      framework: "AVFoundation",
      symbol: sym.merge(kind: "swift_init", swift_class: "AVAudioFile",
                         swift_initializer: "init(forReading:) throws",
                         params: [:opaque_ref], return_kind: :opaque_ref),
      glue_id: "smoketest"
    )
    assert_not_nil swift
    assert_match(/do \{/, swift)
    assert_match(/rb_raise\(rb_eAppleSDK(Objc|Swift)Error/, swift)
  end

  def test_smoke_unsupported_pattern_swift_macro_raises
    # KB に swift_macro marked symbol が >0 件あることを Phase 1 で確認済 (3290 件 unsupported_pattern)
    db = @kc.instance_variable_get(:@db)
    row = db.execute("SELECT framework_id, name FROM symbols WHERE unsupported_pattern = 'swift_macro' LIMIT 1").first
    omit "swift_macro marked symbol not in KB" unless row
    fw_row = db.execute("SELECT name FROM frameworks WHERE id = ?", [row[0]]).first
    omit "framework lookup failed" unless fw_row
    framework_name = fw_row[0]
    symbol_name = row[1]
    err = assert_raise(AppleSDKMac::UnsupportedPatternError) do
      @tg.generate(
        framework: framework_name,
        symbol: { kind: "swift_func", name: symbol_name, swift_class: symbol_name.split(".").first, swift_func: symbol_name.split(".").last, params: [], return_kind: :void },
        glue_id: "smoketest"
      )
    end
    assert_equal "swift_macro", err.pattern
  end
end
```

- [ ] **Step 2: Run test**

Run: `bundle exec rake test TESTOPTS="-n /TestEmitterPhase2Smoke/"`
Expected: PASS (KB built 前提) or all omit (KB 未 build 環境)

- [ ] **Step 3: Run full suite**

Run: `bundle exec rake test`
Expected: 全 green (assertion count baseline 1117 → +9 程度の増)

- [ ] **Step 4: Commit**

```bash
git add test/integration/test_emitter_phase2_smoke.rb
git commit -m "$(cat <<'EOF'
test(integration): Phase 2 emitter smoke against real Knowledge Base

KB が build されている環境 (real_knowledge_built? true) で、 throws
init / unsupported_pattern marker / return_ownership 等 Phase 1
metadata path が emitter で消費されるか smoke。 KB 未 build 環境は
omit、 CI gate にしない。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Phase 2 完了 mark + spec append + commit

**目的:** spec doc Section 17 に Phase 2 完了結果 (T1-T12 全 green / 廃止 heuristic 一覧 / Phase 3 引き継ぎ backlog) を append、 commit。

**Files:**
- Modify: `docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md`

- [ ] **Step 1: Append Phase 2 結果 block**

spec Section 17 の Phase 1 結果 block の直後、 Phase 2 backlog block の直前に挿入:

```markdown
### Phase 2 結果 (2026-05-14 完了)

- [x] AppleSDKMac::Error hierarchy 整備 (FrameworkMissingError / SymbolMissingError / UnsupportedPatternError / GlueCompileError / ObjcError / SwiftError) — T1
- [x] emit_swift_init が KB is_throws / is_failable から分岐 — T2
- [x] emit_swift_func が KB is_async から分岐 — T3
- [x] swift_init labels が KB parameters_json[].external_label 由来 — T4
- [x] CF retained 判定が KB return_ownership 由来、 name regex は fallback に降格 — T5
- [x] callback_signature_json から route 解決、 unregistered shape は UnsupportedPatternError raise — T6
- [x] emitter 入口で unsupported_pattern marker 検出 → UnsupportedPatternError raise — T7
- [x] Swift throws の try? else Qnil silent swallow 廃止、 do/catch + rb_raise(ObjcError|SwiftError) に置換 — T8
- [x] is_settable=1 property の setter glue + namespace_builder install — T9
- [x] dispatcher / glue_compiler の silent return-nil-cascade 廃止 — T10
- [x] UnsupportedPatternError diagnostic message を Section 6.2 形式に進化 — T11
- [x] Phase 2 smoke test against real Knowledge Base — T12

廃止 heuristic 一覧 (spec Section 4.1 全消化):

- `initializer.include?("throws")` → `is_throws` column
- `initializer.include?("?")` → `is_failable` column
- `symbol[:async] == true` (Hash 由来) → `is_async` column
- `cf_create_naming?(name)` 正規表現 → `return_ownership` column
- `CALLBACK_PILLAR_ROUTES` 手書き → `callback_signature_json` 由来 auto-route + unregistered raise
- `swift_init_labels(initializer)` 文字列 split → `parameters_json[].external_label`
- `try? else Qnil` silent swallow → `throws_error_type` → `SwiftError`/`ObjcError` dispatch

Phase 3 引き継ぎ:

- `AppleSDKMac::DiscoveryError` の deprecate (Phase 3 で `Apple.discover` lazy 化と同時に整理)
- `AppleSDKMac::CallError` を `ObjcError` / `SwiftError` 階層に統合 (現状 raw OSStatus 系は CallError、 Phase 3 で再評価)
- LLM fallback の dispatcher 経路全廃 (現状 `try_llm` は残置、 Phase 3 で removal)
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-05-14-deterministic-runtime-mcp-helper-design.md
git commit -m "$(cat <<'EOF'
docs(specs): mark phase 2 (emitter completeness) complete

Phase 2 result section + 廃止 heuristic 一覧 + Phase 3 引き継ぎ
backlog を spec Section 17 に append。 spec Section 4.1 の 8 件
heuristic 全消化。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 完了基準

- [ ] 全 13 task の checkbox が完了
- [ ] `bundle exec rake test` full green (assertion count baseline 1117 → +N、 N は新規 test 合計)
- [ ] 既存 emit_swift_init / emit_swift_func test (signature 文字列 path) も green を維持 (Apple.discover escape hatch 互換)
- [ ] commit log が Conventional Commits / Co-Authored-By 全件遵守
- [ ] main 直 push は user handoff (memory rule)
- [ ] spec Section 4.1 の廃止 heuristic 表 8 件すべて KB 経由化済

---

## Phase 3-5 outline (本 plan scope 外、 Phase 2 完了後 writing-plans で詳細化)

### Phase 3 — Lazy transparent namespace + bootstrap! deprecation (spec Section 1)

`lib/apple_sdk_mac.rb` の Apple Box に const_missing / method_missing 配線。 `namespace_builder.rb` を lazy install path 主流に。 `dispatcher.rb` の LLM fallback path を削除。 `bootstrap!` を no-op alias 化。 DiscoveryError / CallError の整理。

### Phase 4 — MCP server 拡張 (spec Section 7 + 8 + 9)

`mcp/` sub-gem に search_apple_api / lookup_symbol / generate_ruby_snippet / suggest_related / suggest_wrapper_template / lookup_documentation の endpoint 追加。 web fetch infrastructure (allow list + 2s rate limit + robots.txt) 実装。 docc archive parser 実装。

### Phase 5 — IRB autocomplete + release_quality_smoke_test + README (spec Section 10 + 11 + 12)

`irb/` sub-gem の reline hook を lazy namespace 経路で動作確認。 :show_doc を MCP lookup_documentation 経由化。 release_quality_smoke_test 全 framework 代表 symbol scaffold + green まで importer / emitter / dispatcher loop。 README 修正 (`bootstrap!` を optional pre-warm 化、 KB miss = gem bug 文言追加、 MCP 章追加)。

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-deterministic-runtime-phase2-emitter-completeness.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — Phase 2 の 13 task を 1 task / subagent dispatch で進行、 task 間に spec compliance review + code quality review、 fast iteration、 main context 汚染最小。 superpowers:subagent-driven-development を使う。
2. **Inline Execution** — 本 session 内で executing-plans skill で task batch 実行、 commit 単位の checkpoint で review。
