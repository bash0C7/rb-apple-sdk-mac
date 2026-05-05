# LLM Fallback Prompt Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `LLMGenerator::INSTRUCTIONS` so the LLM fallback path produces Swift glue matching template_generator's `@_silgen_name` + bare-`@c` contract; eliminate references to nonexistent runtime helpers (`Marshal.fromRubyXXX` / `Marshal.toRuby` / `ErrorBridge.rb_raise_via_runtime`).

**Architecture:** `INSTRUCTIONS` becomes a 3-section heredoc: (1) hard-requirement rules, (2) `TemplateGenerator::HEADER` interpolated literally as the `@_silgen_name` block source-of-truth, (3) a hand-coded worked example for the `string` kind. `LLMGenerator` gains `require_relative "template_generator"` to reach the constant. Three offline RED tests pin the contract: bare `@c` on its own line, `@_silgen_name("rb_str_new_cstr")` literal, and absence of phantom-API references.

**Tech Stack:** Ruby 4.x, test-unit, rake-compiler. No Swift toolchain or LLM call needed for the RED/GREEN cycle. E2E verification (Task 4) needs swiftly + Foundation Model on Apple Silicon.

**Spec:** `docs/superpowers/specs/2026-05-05-llm-fallback-prompt-alignment-design.md`

---

### Task 1: RED — three failing offline contract tests

**Files:**
- Modify: `test/llm_generator_test.rb` (append three test methods to existing `class TestLLMGenerator`)

- [ ] **Step 1: Add the three RED tests**

Append these methods inside `class TestLLMGenerator < Test::Unit::TestCase` in `test/llm_generator_test.rb`, immediately after the existing `test_live_ollama_returns_some_swift`:

```ruby
  def test_instructions_specify_bare_at_c_attribute_on_own_line
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_includes instructions, "@c\npublic func",
      "INSTRUCTIONS must show `@c` on its own line above `public func`; " \
      "regex GATE 5 (`/@c\\s+public\\s+func\\s+(\\w+)/`) requires whitespace-separated tokens."
  end

  def test_instructions_embed_silgen_name_header_literally
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    assert_includes instructions, '@_silgen_name("rb_str_new_cstr")',
      "INSTRUCTIONS must embed the @_silgen_name header from TemplateGenerator::HEADER " \
      "so the LLM does not hallucinate signatures."
  end

  def test_instructions_have_no_phantom_runtime_api_references
    instructions = AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS
    refute_match(/Marshal\.(fromRuby|toRuby)/, instructions,
      "Marshal.fromRubyXXX / Marshal.toRuby do not exist in AppleSDKMacRuntime; " \
      "instructing the LLM to use them is the root cause of GATE 5 + compile failures.")
    refute_match(/ErrorBridge/, instructions,
      "ErrorBridge.swift was deleted in commit b262e18; raise via @_silgen_name rb_raise.")
  end
```

- [ ] **Step 2: Run only the new tests to verify they fail**

Run from the repo root (offline, skips rake compile via direct ruby invocation):

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac && \
  bundle exec ruby -Ilib -Itest test/llm_generator_test.rb \
    -n /test_instructions_/
```

Expected output (3 failures):
- `test_instructions_specify_bare_at_c_attribute_on_own_line`: FAIL — current INSTRUCTIONS has `@c-attributed` prose, no `@c\npublic func` literal
- `test_instructions_embed_silgen_name_header_literally`: FAIL — current INSTRUCTIONS has no `@_silgen_name` content
- `test_instructions_have_no_phantom_runtime_api_references`: FAIL — current INSTRUCTIONS contains `Marshal.fromRubyXXX` and `Marshal.toRuby`

Result line should read: `3 tests, X assertions, 3 failures, 0 errors, 0 pendings, 0 omissions`

- [ ] **Step 3: Commit RED**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac && \
git add test/llm_generator_test.rb && \
git commit -m "$(cat <<'EOF'
test: add failing specs for LLM INSTRUCTIONS contract alignment

Three offline assertions pin the prompt contract: bare @c on its own line
(GATE 5 regex compatibility), @_silgen_name("rb_str_new_cstr") embedded
literally (single source of truth via TemplateGenerator::HEADER), and absence
of Marshal.fromRubyXXX / Marshal.toRuby / ErrorBridge references (phantom API
surface that never existed in AppleSDKMacRuntime).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: GREEN — rewrite INSTRUCTIONS with three sections

**Files:**
- Modify: `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` (full file replacement; existing structure preserved except for INSTRUCTIONS body and one new `require_relative` and one new `WORKED_EXAMPLE` constant)

- [ ] **Step 1: Replace the file with the rewritten version**

Overwrite `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` with:

```ruby
# frozen_string_literal: true
require "foundation_model_mac"
require_relative "template_generator"

module AppleSDKMac
  class GlueCompiler
    class LLMGenerator
      WORKED_EXAMPLE = <<~SWIFT.freeze
        // Worked example for a hypothetical "string"-kind C function:
        //   const char * AcmeCopyTitle(int id);
        // in framework AcmeFW, glue_id deadbeef. Substitute the framework,
        // glue_id, symbol, and the per-parameter marshalling for the
        // requested signature; copy the @_silgen_name header block (Section 2)
        // verbatim — it is omitted in this example only to avoid duplication.
        import AcmeFW
        import Foundation

        // ... @_silgen_name header from Section 2 goes here, verbatim ...

        @c
        public func glue_deadbeef_AcmeCopyTitle(
            _ argv: UnsafePointer<UInt>, _ argc: Int32
        ) -> UInt {
            let id: Int64 = rb_num2ll(argv[0])
            let cstr = AcmeCopyTitle(Int32(id))
            if cstr == nil { rb_raise(rb_eRuntimeError, "AcmeCopyTitle returned NULL") }
            return rb_str_new_cstr(cstr!)
        }
      SWIFT

      INSTRUCTIONS = <<~TXT.freeze
        You generate Swift glue code for the rb-apple-sdk-mac runtime bridge.

        SECTION 1 — HARD REQUIREMENTS

        1. Output Swift source only. No prose, no markdown fences, no commentary.
        2. Output exactly one top-level function with this exact shape (note:
           bare `@c` on its own line, then `public func` on the next line):

               @c
               public func glue_<glue_id>_<symbol>(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt

           No `@c("name")`, no `@c-attributed`, no other attribute spelling.
        3. Allowed imports: the target Apple framework, and `Foundation`.
           Nothing else. Do NOT import `AppleSDKMacRuntime`.
        4. Include the @_silgen_name header block (Section 2 below) verbatim,
           before the function definition. Do not add, remove, or rename any
           declaration in it.
        5. Marshal Ruby `VALUE` (`UInt`) inputs from `argv[i]` using only the
           rb_* symbols declared in the header: `rb_string_value_cstr`,
           `rb_num2ll`, `rb_num2ull`, `rb_num2dbl`. No `Marshal.fromRubyXXX` —
           that helper does not exist.
        6. Build the Ruby return value using only the rb_* symbols declared in
           the header (`rb_str_new_cstr`, `rb_ll2inum`, `rb_ull2inum`,
           `rb_float_new`) or the constants `Qnil`, `Qfalse`, `Qtrue`. No
           `Marshal.toRuby` — does not exist.
        7. On status-code errors from the target C function, call
           `rb_raise(rb_eRuntimeError, "<message>")`. Do not invent any other
           raise mechanism. No `ErrorBridge.rb_raise_via_runtime` — does not
           exist.
        8. The only C call permitted inside the function body is the
           user-requested target symbol. No network, file, process, IPC,
           persistence, or environment-mutation APIs.
        9. For C function-pointer parameters (callbacks), emit a runtime
           branch:

               let cb: <CallbackType>?
               if argv[i] == Qnil {
                   cb = nil
               } else {
                   rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")
               }

           Then pass `cb` to the C call. `rb_raise` is `-> Never`, so the
           compiler accepts `cb` as definitely-assigned in the only
           non-terminating branch.
        10. For raw `void *` parameters, mirror rule 9:

               let p: UnsafeMutableRawPointer?
               if argv[i] == Qnil {
                   p = nil
               } else {
                   p = UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[i])))
               }

        SECTION 2 — @_silgen_name HEADER (copy verbatim)

        #{TemplateGenerator::HEADER}

        SECTION 3 — WORKED EXAMPLE

        #{WORKED_EXAMPLE}
      TXT

      def initialize(model: nil, session: nil)
        @session = session || AppleFoundationModel::Session.new(instructions: INSTRUCTIONS, model: model)
      end

      def generate(framework:, symbol:, glue_id:)
        prompt = build_prompt(framework, symbol, glue_id)
        response = @session.respond(to: prompt)
        return nil if response.nil? || response.strip.empty?
        response.gsub(/\A```swift\n/, "").gsub(/\n```\z/, "").strip
      end

      def close
        @session.close
      end

      private

      def build_prompt(framework, sym, glue_id)
        <<~PROMPT
          framework: #{framework}
          glue_id: #{glue_id}
          symbol_name: #{sym[:name]}
          kind: #{sym[:kind]}
          abi: #{sym[:abi]}
          signature: #{sym[:signature]}
          parameters_json: #{sym[:parameters_json]}

          Generate the Swift glue file as specified. Output Swift source only.
        PROMPT
      end
    end
  end
end
```

- [ ] **Step 2: Run the three new tests to verify they pass**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac && \
  bundle exec ruby -Ilib -Itest test/llm_generator_test.rb \
    -n /test_instructions_/
```

Expected: `3 tests, 4 assertions, 0 failures, 0 errors, 0 pendings, 0 omissions`

(4 assertions because `test_instructions_have_no_phantom_runtime_api_references` does two `refute_match` calls.)

- [ ] **Step 3: Run the full `llm_generator_test.rb` to confirm pre-existing tests still pass**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac && \
  bundle exec ruby -Ilib -Itest test/llm_generator_test.rb
```

Expected: `7 tests, 8 assertions, 0 failures, 0 errors, 0 pendings, 1 omissions`

(7 = 3 new + 3 existing + 1 live-ollama; 1 omission = `test_live_ollama_returns_some_swift` which omits unless `RB_APPLE_SDK_MAC_LIVE_LLM=1`.)

- [ ] **Step 4: Commit GREEN**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac && \
git add lib/apple_sdk_mac/glue_compiler/llm_generator.rb && \
git commit -m "$(cat <<'EOF'
feat: rewrite LLM INSTRUCTIONS to match @_silgen_name CRuby ABI contract

Replaces three structural defects in the prompt: (1) "@c-attributed" English
prose that the model rendered as literal Swift `@c-attributed public func`,
breaking GATE 5; (2) references to Marshal.fromRubyXXX / Marshal.toRuby — a
planned-but-never-implemented API surface that Bug C explicitly replaced for
template_generator; (3) ErrorBridge.rb_raise_via_runtime — deleted in b262e18.

INSTRUCTIONS now has three sections: hard requirements with bare-@c shape and
explicit Qnil-branch patterns for callback / void* parameters, the
TemplateGenerator::HEADER block interpolated verbatim as single source of
truth, and a worked example for the string kind. The LLM fallback path now
emits the same shape as the template path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Full test suite verification (subagent-delegated)

**Files:** None modified.

- [ ] **Step 1: Delegate full `bundle exec rake test` to a general-purpose subagent**

Per `feedback_rake_test_subagent` memory rule, the parent agent must dispatch a subagent (not run `rake test` inline) to keep verbose rake-compiler / Test::Unit dot output out of the main conversation context. Subagent prompt template:

> Run `cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac && . ~/.swiftly/env.sh && bundle exec rake test` and report only:
> 1. Final test count line: "N tests, M assertions, F failures, E errors, P pendings, O omissions".
> 2. Whether the run succeeded (failures + errors == 0) — yes/no.
> 3. If F+E > 0, the file:line of each failing assertion plus the assertion message (no full stack traces).
>
> Do not paste the rake-compiler make log or the Test::Unit dot progress.

Expected report: `50 tests, ~ assertions, 0 failures, 0 errors, 0 pendings, 1 omissions, success: yes`. (50 = previous 47 + 3 new tests; the omission is `test_live_ollama_returns_some_swift`.)

- [ ] **Step 2: If failures or errors are reported, stop and triage**

If the subagent reports F+E > 0, do NOT proceed to Task 4. Diagnose with `superpowers:systematic-debugging` Phase 1 against the specific failing tests — common candidates:
- ERB-style heredoc interpolation surprised by `#{...}` inside HEADER if HEADER is later changed to include literal `#{...}`. Currently HEADER has none, so this is a future risk only.
- `require_relative "template_generator"` path resolution if file naming changes.

- [ ] **Step 3: No commit at this step.** Verification only; nothing changed.

---

### Task 4: E2E manual verification — clear cache and observe `compile_history`

**Files:** None modified.

This task verifies the prompt change at runtime by re-exercising the LLM fallback path against the real Foundation Model on Apple Silicon. It is run by hand because (a) the Apple on-device model is not available in CI and (b) it modifies the user's `~/.cache` directory.

- [ ] **Step 1: Delete stale failed-attempt rows from `compile_history`**

```bash
sqlite3 ~/.cache/rb-apple-sdk-mac/26.2/glue.sqlite \
  "DELETE FROM compile_history WHERE generator='llm' AND symbol IN ('MIDIClientCreate','MIDIClientDispose');"
```

Verify: subsequent `SELECT count(*) FROM compile_history WHERE generator='llm' AND symbol='MIDIClientCreate'` returns `0`.

This does NOT delete cached glue dylib files (they keyed by glue_id, not symbol); a fresh attempt will overwrite or skip them.

- [ ] **Step 2: Activate swiftly and launch the smoke test under `screen -dmS`**

The CoreMIDI smoke test invokes the full LLM-fallback pipeline (LLM call + swiftc compile + dlopen + Apple SDK call). Per `feedback_longrun_screen_pattern` memory rule, jobs that may exceed 2 minutes must run as a detached `screen` session, not inline Bash, not subagent.

```bash
mkdir -p ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/tmp/longrun && \
screen -dmS bug-c-t10-verify-20260505 bash -c '
  cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
  . ~/.swiftly/env.sh
  bundle exec ruby -Ilib -Itest test/integration/coremidi_smoke_test.rb \
    > tmp/longrun/bug-c-t10-verify-20260505.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/bug-c-t10-verify-20260505.log
'
```

End the conversation turn after launch. Resume after `DONE:` sentinel appears.

- [ ] **Step 3: After completion, classify the outcome by inspecting `compile_history`**

```bash
grep "^DONE:" ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/tmp/longrun/bug-c-t10-verify-20260505.log
sqlite3 ~/.cache/rb-apple-sdk-mac/26.2/glue.sqlite \
  "SELECT id, symbol, generator, error_stage, substr(error_detail,1,200) \
   FROM compile_history \
   WHERE symbol IN ('MIDIClientCreate','MIDIClientDispose') \
   ORDER BY id DESC LIMIT 8;"
```

Three valid outcomes:

- **(a) Best:** New rows have `error_stage IS NULL` and the smoke test log shows `test_create_client_and_dispose: PASS`. T10 acceptance flips. Update Bug C plan to mark T10 done.
- **(b) Middle:** GATE 5 passes (good), but `error_stage='compile'` with swiftc errors. Capture the `error_detail` and the LLM-emitted Swift body (full row blob via `SELECT llm_response FROM compile_history WHERE id=<latest>;`). Open a follow-up issue: "LLM fallback callback marshalling — concrete swiftc errors for `MIDIClientCreate`". This spec is acceptance-complete per its own criteria; T10 stays omitted.
- **(c) Worst:** GATE 5 still failing (`error_stage='static_check'`). Return to `superpowers:systematic-debugging` Phase 1 with the new evidence; the prompt rewrite did not produce the assumed effect.

- [ ] **Step 4: Document the observed outcome**

Whichever of (a)/(b)/(c) was observed, append a short paragraph to the design spec under a new "Verification" section recording: outcome class, date, and a one-line summary of `compile_history` state. This closes the loop between spec and reality. Commit as `docs: record verification outcome for LLM fallback prompt alignment`.

---

## Self-Review

**Spec coverage:** Each spec section maps to a task:
- Spec §"File-level changes / llm_generator.rb" → Task 2
- Spec §"Testing strategy / RED" → Task 1
- Spec §"Testing strategy / GREEN" → Task 2 step 4
- Spec §"E2E verification" → Task 4
- Spec §"Acceptance / item 1 (RED+GREEN green)" → Task 3
- Spec §"Acceptance / item 2 (LLM moves past static_check)" → Task 4 step 3

No gaps.

**Placeholder scan:** No `TBD`, `TODO`, `implement later`, or "add appropriate error handling" patterns. All code blocks contain complete content. Test names spelled identically across Task 1 step 1, 1 step 2, 2 step 2.

**Type consistency:** Constant names match throughout (`AppleSDKMac::GlueCompiler::LLMGenerator::INSTRUCTIONS`, `TemplateGenerator::HEADER`, `WORKED_EXAMPLE`). Test method names identical between Task 1 and Task 2. Commit-message style consistent with recent gem C history (`test:` / `feat:` / `docs:`).
