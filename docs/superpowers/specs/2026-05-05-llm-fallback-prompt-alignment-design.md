# LLM Fallback Prompt — Runtime Contract Alignment Design

**Date:** 2026-05-05
**Scope:** rb-apple-sdk-mac (gem C) — `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` and adjacent test
**Status:** approved by user, ready for implementation plan
**Related:** `2026-05-05-bug-c-template-runtime-integration-design.md` (Bug C)

## Context

Bug C smoke-test acceptance T10 (`test_create_client_and_dispose`) is blocked. `MIDIClientCreate` has a callback parameter (`MIDINotifyProc`) and a `void *` opaque payload; per Bug C spec these are kind=`unsupported` → handed to the LLM fallback path. That path then fails 3 times in a row at `error_stage=static_check` with `GATE 5 no @c public func found`.

Inspection of `compile_history.llm_response` for ids 1–3 (CoreMIDI / MIDIClientCreate, generator=llm) reveals two distinct defects:

1. **Literal-prose leak.** INSTRUCTIONS rule #1 reads "Output exactly one **@c-attributed** public function". The model writes that English phrase verbatim as Swift syntax: `@c-attributed public func glue_<id>_<symbol>(…)`. The hyphen breaks GATE 5's regex `/@c\s+public\s+func\s+(\w+)/`.

2. **Phantom runtime API.** The prompt instructs use of `AppleSDKMacRuntime.Marshal.fromRubyXXX` / `Marshal.toRuby` / `ConformanceBridge.lookup` / `ErrorBridge.rb_raise_via_runtime`. **None of these exist.** The actual runtime exposes only `Marshal.swiftString(fromCString:)` / `Marshal.cString(fromSwift:)`. The LLM dutifully invents calls to `fromRubyCFString`, `fromRubyMIDINotifyProc`, `fromRubyVoidPtr`, `fromRubyOpaqueRef`, `ConformanceBridge.lookup(symbol:, args:)`, etc.

Bug C's design (lines 14–24) explicitly states: *"The template was written against a planned runtime API surface that was never implemented. This spec replaces that surface with a simpler architecture rather than catching up."* Bug C did the replacement for `template_generator`, but the LLM prompt still references the planned-but-never-implemented surface. The LLM fallback path was therefore broken from day 1; T10 only made it visible because Bug B finally produced symbols that escalate to the fallback.

The ABI contract chosen by Bug C (which the prompt must adopt):
- Bare `@c` attribute, signature `func glue_<id>_<sym>(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt`.
- Imports: target framework + `Foundation`. No `AppleSDKMacRuntime` import in the glue file.
- CRuby symbols (`rb_string_value_cstr`, `rb_num2ll`, `rb_str_new_cstr`, `rb_raise`, `rb_eRuntimeError`, `Qfalse`, `Qnil`, `Qtrue`, etc.) declared via `@_silgen_name` and resolved at dlopen time against the host process (swiftc already passes `-Xlinker -undefined -Xlinker dynamic_lookup`).

## Goal

Rewrite `LLMGenerator::INSTRUCTIONS` so the LLM emits Swift glue that:

1. Passes the existing GATE 3/4/5 static checks against the real regex.
2. Compiles via `SwiftcInvoker` against the actual `AppleSDKMacRuntime` package and CRuby ABI, with no reference to nonexistent helpers.
3. Has the same shape as `TemplateGenerator`'s output, so the LLM only needs to fill in marshalling for kinds the template cannot dispatch (callbacks, raw `void *`, multi-out-param).

Establish `TemplateGenerator::HEADER` as the **single source of truth** for the `@_silgen_name` block; `LLMGenerator` references it directly so the two paths cannot drift.

## Non-goals

- Restructuring the LLM fallback dispatch (retry loop, model selection, session lifecycle). Bug C spec calls these out of scope.
- Adding new validation gates. The current GATE 3/4/5 stay as-is — the prompt change alone makes them pass on well-formed output.
- Implementing callback support inside the runtime. If the LLM correctly bridges a callback (e.g. by passing `nil` for `MIDINotifyProc` when the Ruby caller passes `Qnil`), great; if not, the symbol stays in `error_stage=compile` and T10 stays omitted. The follow-up "callback marshalling for LLM fallback" is its own issue, recorded against this spec's exit criteria.
- Changing `compute_glue_id` or cache invalidation behavior.
- Editing the Bug C spec itself. This document supersedes Bug C only at the level of the prompt body, which Bug C did not specify.

## Architecture

### Single source of truth for the CRuby ABI header

```
lib/apple_sdk_mac/glue_compiler/template_generator.rb
  └─ HEADER = <<~SWIFT…SWIFT (already exists)

lib/apple_sdk_mac/glue_compiler/llm_generator.rb
  └─ require "apple_sdk_mac/glue_compiler/template_generator"
  └─ INSTRUCTIONS = build_instructions(TemplateGenerator::HEADER)
```

The dependency direction is `llm_generator → template_generator`. Both are siblings in `glue_compiler/`, so the coupling is local and acceptable. No new module is introduced.

### Three-section INSTRUCTIONS

The rewritten INSTRUCTIONS has three regions, in order:

**Section 1 — Hard requirements (rules).**
Replaces the current 9-rule list with a tighter set:

1. Output Swift source only. No prose, no markdown fences, no commentary.
2. Output exactly one top-level function: `@c\npublic func glue_<glue_id>_<symbol>(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt`. The `@c` attribute appears on its own line above `public func`. Bare `@c`, no string argument, no hyphen.
3. Allowed imports: the target Apple framework, `Foundation`. No others. (Notably: `AppleSDKMacRuntime` is NOT imported.)
4. Include the provided `@_silgen_name` header block verbatim, before the function definition. Do not add, remove, or rename any declaration in it.
5. Marshal Ruby `VALUE` (`UInt`) inputs from `argv[i]` using only the `rb_*` symbols declared in the header (`rb_string_value_cstr`, `rb_num2ll`, `rb_num2ull`, `rb_num2dbl`).
6. Build the Ruby-side return value using only the `rb_*` symbols in the header (`rb_str_new_cstr`, `rb_ll2inum`, `rb_ull2inum`, `rb_float_new`) or the constants `Qnil`/`Qfalse`/`Qtrue`.
7. On status-code errors from the C function, call `rb_raise(rb_eRuntimeError, "<message>")`. Do not invent any other raise mechanism.
8. No network, file, process, IPC, persistence, or environment-mutation APIs. The only C call permitted inside the function body is the user-requested target symbol.
9. For C function-pointer parameters (callbacks), the generated function body must include a runtime branch that **passes `nil` when the Ruby argument is `Qnil`, and calls `rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")` otherwise.** Concrete shape (with the actual C-typed callback type substituted for `<CallbackType>`):
   ```swift
   let cb: <CallbackType>?
   if argv[i] == Qnil {
       cb = nil
   } else {
       rb_raise(rb_eRuntimeError, "non-nil callback not yet supported")
   }
   ```
   `rb_raise` is declared `-> Never`, so the Swift compiler accepts `cb` as definitely-assigned. The dylib compiles; non-nil callbacks fail at call time, not compile time.
10. For raw `void *` parameters, mirror rule 9: pass `nil` when the Ruby argument is `Qnil`, otherwise `UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[i])))`.
    ```swift
    let p: UnsafeMutableRawPointer?
    if argv[i] == Qnil {
        p = nil
    } else {
        p = UnsafeMutableRawPointer(bitPattern: Int(rb_num2ll(argv[i])))
    }
    ```

**Section 2 — Header block (literal).**
The full text of `TemplateGenerator::HEADER` is interpolated here. The model is instructed to copy it byte-for-byte. This is the surface where hallucinated `@_silgen_name` signatures would otherwise creep in.

**Section 3 — Worked example.**
A complete glue function for a synthetic `string`-kind symbol, demonstrating the full shape: `import` block, header, `@c\npublic func`, in-load via `rb_string_value_cstr`, status-zero check + raise, `rb_str_new_cstr` return.

### Prompt body (per-call)

Unchanged from current `build_prompt`: framework / glue_id / symbol_name / kind / abi / signature / parameters_json. The `INSTRUCTIONS` carry the contract; the prompt body carries the per-symbol data.

## File-level changes

| File | Change |
|---|---|
| `lib/apple_sdk_mac/glue_compiler/llm_generator.rb` | Rewrite `INSTRUCTIONS` (computed at load time from `TemplateGenerator::HEADER`). Add `require "apple_sdk_mac/glue_compiler/template_generator"`. The `generate` method body, `build_prompt`, markdown-fence stripping, and `Session` injection remain untouched. |
| `lib/apple_sdk_mac/glue_compiler/template_generator.rb` | None. `HEADER` is already a public constant on the class. |
| `test/llm_generator_test.rb` | Add three RED tests (see below). |

No changes to `validation_gates.rb`, `swiftc_invoker.rb`, the runtime Swift package, or the C ext.

## Testing strategy

t-wada style. RED → GREEN → REFACTOR each as an independent commit (per project CLAUDE.md).

**RED commit — `test: add failing specs for LLM INSTRUCTIONS contract alignment`**

Three assertions on `LLMGenerator::INSTRUCTIONS`:

1. `assert_includes INSTRUCTIONS, "@c\npublic func"` — bare `@c` on its own line, with `\n` separator. Catches the `@c-attributed` and inline `@c public` regressions.
2. `assert_includes INSTRUCTIONS, "@_silgen_name(\"rb_str_new_cstr\")"` — the header is embedded literally.
3. `refute_match(/Marshal\.(fromRuby|toRuby)/, INSTRUCTIONS)` and `refute_match(/ErrorBridge/, INSTRUCTIONS)` — phantom API surface is gone.

These three are the contract pin. They run offline (no LLM call, no Swift toolchain).

**GREEN commit — `feat: rewrite LLM INSTRUCTIONS to match @_silgen_name CRuby ABI contract`**

Implement Sections 1–3 above. Existing 3 tests (`test_generate_post_processes_markdown_fences` / `test_generate_returns_nil_for_empty_response` / `test_prompt_includes_framework_signature_and_glue_id`) and the live-Ollama omit guard remain green unchanged.

**REFACTOR commit (optional)**

If `INSTRUCTIONS` builds with an awkward heredoc-plus-interpolation, split into named methods (`hard_requirements`, `worked_example`) on the class. Skip if the GREEN form is already readable.

**E2E verification (manual, not in CI)**

After RED+GREEN merge:
1. Clear stale rows: `sqlite3 ~/.cache/rb-apple-sdk-mac/26.2/glue.sqlite "DELETE FROM compile_history WHERE generator='llm' AND symbol IN ('MIDIClientCreate','MIDIClientDispose');"`
2. Re-run smoke: delegated to subagent per `feedback_rake_test_subagent` and `feedback_longrun_screen_pattern` memory rules. Test suite > 2 min uses `screen -dmS bug-c-t10-verify`; otherwise direct subagent dispatch.
3. Inspect new `compile_history` rows. Three observable outcomes:
   - **Best case:** rows have `error_stage IS NULL`, T10 flips omit → pass. Done.
   - **Middle case:** GATE 5 passes; `error_stage='compile'`; LLM-emitted Swift fails swiftc. Capture `error_detail` and decide whether to iterate the prompt or close T10 with "callback marshalling = follow-up issue".
   - **Worst case:** GATE 5 still fails. Bug not fully diagnosed; return to systematic-debugging Phase 1 with the new evidence.

## Risks and mitigations

- **LLM still hallucinates despite the embedded header.** Foundation Model on-device may copy from instructions inconsistently. Mitigation: the worked example in Section 3 plus the `refute_match` assertions in tests pin the contract; if the LLM produces something off-contract, GATE 3/4/5 catches it and the existing retry loop re-tries (up to N attempts). Long-tail symbols may exhaust retries; that is a follow-up.
- **`HEADER` from `template_generator.rb` changes shape later.** Both paths drift together by construction (single source of truth). The RED test on `@_silgen_name("rb_str_new_cstr")` keeps the header presence pinned even if its content evolves.
- **Token budget on Apple on-device model.** The HEADER is ~30 lines; the worked example is ~20 lines. Total prompt remains comfortably under typical context limits.
- **Bug C spec stale-reference.** Bug C says "any change to the LLM fallback path is out of scope". This spec changes the *prompt body*, not the dispatch / retry / session structure. The non-goal language is honored. To prevent confusion, this spec is a sibling, not an amendment.

## Out of scope

- Callback marshalling support inside the runtime (would let LLM produce real `MIDIClientCreate` glue rather than the rb_raise stub for non-nil callbacks).
- Multi-out-param support.
- Changing the LLM model, retry count, or session lifecycle.
- Replacing the LLM fallback with an explicit `UnsupportedSymbolError` (Approach B from brainstorming, rejected: contradicts Bug C non-goal).
- Cleaning orphaned glue dylibs left over from earlier failed compiles.
- Linux portability of the glue dylib.

## Acceptance

This spec is acceptance-complete when:
1. RED + GREEN commits land, all gem C tests green.
2. After cache clear and smoke re-run, `compile_history` shows the LLM path moves past `error_stage=static_check` for at least one previously-failing symbol.

T10 acceptance flip is **expected but not strictly required by this spec** — it depends on whether the LLM can produce compileable callback handling, which is a downstream LLM-quality issue. If T10 stays omitted with `error_stage=compile`, that result is the input to the next issue (callback marshalling support).

## Verification (2026-05-05)

**Outcome class (b) — middle case** per the plan's three-outcome taxonomy.

After cache rows for `MIDIClientCreate` / `MIDIClientDispose` were deleted and the smoke test was re-run under `screen -dmS bug-c-t10-verify-20260505` (commits `5381ed4` REFACTOR + earlier RED/GREEN/RED-followup active), the three retry attempts produced:

| compile_history.id | error_stage | Observation |
|---|---|---|
| 1 (oldest) | `swiftc` | GATE 5 PASS. Header block + bare `@c\npublic func` + callback Qnil-branch all correctly emitted. swiftc error: `cannot convert value of type 'UInt' to expected argument type 'UnsafeMutablePointer<UInt>'` — LLM wrote `rb_string_value_cstr(argv[0])` instead of the required `var v0 = argv[0]; rb_string_value_cstr(&v0)` pattern that `template_generator.rb` uses for string-input parameters. |
| 2 | `swiftc` | GATE 5 PASS. Header + shape correct. Body went off-rails into hallucinated `unsafeBitCast` / `(void)cString` / `ptr(to: argv)` — invalid Swift parse. |
| 3 (newest) | `static_check` | GATE 5 FAIL. LLM ignored format entirely and emitted Markdown prose plus a fabricated Swift `midiClientCreate` function unrelated to the requested glue. Demonstrates Foundation Model non-determinism. |

Smoke test omitted with `LLM exhausted 3 attempts`, T10 still omit. **Acceptance criterion 2 is met**: 2 of 3 attempts now move past `error_stage=static_check` for `MIDIClientCreate`, where prior to this spec's commits 0 of 3 did.

Two follow-up issues identified, both out of scope for this spec:

1. **WORKED_EXAMPLE coverage gap.** Section 3's example demonstrates an `int` input + `string` return path (`rb_num2ll(argv[0])` then `rb_str_new_cstr(cstr!)`). It does NOT demonstrate the `string` input path — the `var v_i = argv[i]; let s = String(cString: rb_string_value_cstr(&v_i))` shape from `template_generator.rb:97`. The LLM must extrapolate this for `MIDIClientCreate`'s `name: CFStringRef` parameter and got it wrong in attempt 1. Adding a second worked example covering string-input marshalling would close this gap.
2. **LLM output consistency.** Attempt 3 ignored the prompt entirely. This is a Foundation Model on-device behavior characteristic, not addressable purely via prompt tuning. Mitigations: (a) raise retry budget from 3 to higher (configurable); (b) add a `regenerate_on_off_format` post-filter that detects markdown-or-prose responses and triggers an immediate retry without consuming the formal retry slot; (c) try a different `model:` parameter on `Session.new`.

### Follow-up consumption (2026-05-05, same day)

Both follow-ups identified above have been consumed by RED+GREEN commits in this branch.

| # | Follow-up | Resolution | Commits |
|---|---|---|---|
| 1 | WORKED_EXAMPLE coverage gap | `WORKED_EXAMPLE_STRING_IN_STATUS_OUT` constant added alongside the renamed `WORKED_EXAMPLE_INT_IN_STRING_OUT`. Section 3 of `INSTRUCTIONS` now demonstrates the `var v0 = argv[0]; let title = String(cString: rb_string_value_cstr(&v0))` pattern literally as Swift, eliminating the comment-only description that required the LLM to extrapolate. | `50c51cb` (RED), `ed015fb` (GREEN) |
| 2 | LLM output non-determinism | Chose mitigation (a). `MAX_LLM_RETRIES = 3` constant replaced with `DEFAULT_MAX_LLM_RETRIES = 6` plus a `max_llm_retries:` kwarg on `GlueCompiler.new`. Retry loop and exhaustion message both reference the per-instance value. At the observed ~1/3 off-format rate, budget=6 yields an expected ~4 well-formed attempts (vs. the prior ~2). Mitigations (b) off-format inner-retry and (c) alternate model remain on the table if (a) proves insufficient. | `c755cd3` (RED), `c12cb74` (GREEN) |

Full test suite passes (`69 tests, 110 assertions, 0 failures, 0 errors, 2 omissions`) after both follow-ups land.

E2E re-verification (cache clear + `coremidi_smoke_test.rb` under `screen -dmS`) is the natural next step to observe whether T10 acceptance now flips. Per spec line 167 ("T10 acceptance flip is expected but not strictly required by this spec"), this is left as an explicit user decision rather than auto-triggered, since it requires Apple Silicon Foundation Model session time.

## Verification — post-followup re-run (2026-05-05)

**Outcome class (b) — middle case** again. Acceptance criterion 2 met; T10 stays omitted.

Cache rows for `MIDIClientCreate` / `MIDIClientDispose` were deleted (12 rows, all generator='llm') and the smoke test re-run under `screen -dmS bug-c-t10-verify-followup-20260505` against the post-followup tree (string-input WORKED_EXAMPLE + `max_llm_retries: 6` default in effect). The 6 attempts produced:

| compile_history.id | error_stage | Observation |
|---|---|---|
| 6 (newest) | `static_check` | GATE 5 FAIL (`no @c public func found`). |
| 5 | `static_check` | GATE 5 FAIL. |
| 4 | `swiftc` | GATE 5 PASS. Header + bare `@c\npublic func` correct. swiftc fails with four typed-pointer / cast errors at the `MIDIClientCreate(...)` call site: (1) `c_name_ptr` (`UnsafePointer<CChar>`) passed where `CFString` expected — needs `name as CFString` cast; (2) `notifyProc_ptr` typed as `UInt` (raw `argv[1]`) passed where `MIDINotifyProc` expected — LLM skipped the rule-9 `let cb: <CallbackType>?` binding; (3) `notifyRefCon_ptr` typed as `UInt` passed where `UnsafeMutableRawPointer` expected — LLM skipped rule 10; (4) `outClient` typed `UnsafeMutablePointer<UInt>` passed where `UnsafeMutablePointer<MIDIClientRef>` (aka `UInt32`) expected — out-param marshalling not in WORKED_EXAMPLE. |
| 3 | `static_check` | GATE 5 FAIL. |
| 2 | `static_check` | GATE 5 FAIL. |
| 1 (oldest) | `swiftc` | GATE 5 PASS. swiftc fails on (1) deprecated `UnsafeMutablePointer<Void>?` for the callback (rule 9 misinterpretation: LLM expanded `<CallbackType>` to `UnsafeMutablePointer<Void>` instead of the framework type `MIDINotifyProc`); (2) `outClient_ptr.map { UnsafeMutablePointer<Any>.allocate(capacity: 1) }` — out-param closure error. |

Smoke test omitted with `LLM exhausted 6 attempts`, T10 still omit. GATE 5 pass rate this run: 2 / 6 (33%); prior 3-attempt run was 2 / 3 (67%). The absolute number of swiftc-stage attempts (2) is unchanged — the higher retry budget surfaced more `static_check` noise from off-format LLM outputs, not more well-formed bodies. This is consistent with the Foundation Model non-determinism noted in mitigation rationale (b/c remain on the table).

### Acceptance status (this spec)

Met. Per spec line 165–167, acceptance criterion 2 ("LLM path moves past `error_stage=static_check` for at least one previously-failing symbol") is satisfied: ids 1 and 4 reached `swiftc` stage. T10 acceptance flip is explicitly non-required by this spec.

### Next issue — callback-and-typed-pointer marshalling for LLM fallback

The 4 distinct swiftc errors across ids 1 + 4 all sit in the same conceptual area: the LLM cannot fill the gap between Ruby `VALUE` (`UInt`) inputs and Apple-typed-C parameters (`CFString`, `MIDINotifyProc`, `UnsafeMutableRawPointer`, typed out-pointers). Rules 9 / 10 in `INSTRUCTIONS` describe the Qnil-branch shape but do not provide a worked example for any of these kinds, so the LLM extrapolates and fails.

This is **out of scope for this spec** (declared in Non-goals: *"Implementing callback support inside the runtime"* and Out of scope: *"Callback marshalling support inside the runtime / Multi-out-param support"*). Tracked as the natural follow-up for a separate spec/plan cycle. Concrete starting points captured here for that future work:

- WORKED_EXAMPLE_CALLBACK_NIL_ONLY: a hand-written glue function for a synthetic symbol with a function-pointer parameter, demonstrating the `let cb: <CallbackType>? = nil` + `rb_raise` shape literally with the framework-typed callback type substituted.
- WORKED_EXAMPLE_CFSTRING_IN: explicit `let s = String(cString: rb_string_value_cstr(&v0)); let cf = s as CFString` for `CFString`-parameter symbols.
- WORKED_EXAMPLE_OUT_PARAM: pattern for typed out-pointer parameters (`var out: MIDIClientRef = 0; ... &out; rb_ull2inum(UInt64(out))`).
- Alternative architectural direction: add a `kind=callback_nilable` / `kind=cfstring_in` / `kind=out_typed` dispatch in `template_generator.rb` so these symbols never escalate to LLM. Decision deferred to that spec.
