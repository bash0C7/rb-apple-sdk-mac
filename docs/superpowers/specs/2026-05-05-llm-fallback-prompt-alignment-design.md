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
