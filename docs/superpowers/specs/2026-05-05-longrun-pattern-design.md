# Long-Batch Execution Pattern + Bug C T9 Performance Redesign

**Date:** 2026-05-05
**Status:** approved
**Supersedes:** Bug C plan Task 9 (`docs/superpowers/specs/2026-05-05-bug-c-template-runtime-integration-design.md`'s "DB rebuild ~4hr" step)
**Scope:**
- Part 1 (long-batch execution pattern): all long-running batch jobs across `~/dev/src/github.com/bash0C7/{rb-apple-sdk-knowledge,rb-apple-sdk-mac,swift_gem,...}` and any future sibling projects under `~/dev/src/`.
- Part 2 (Bug C T9 perf redesign): specific to Bug C. Replaces the 4hr full DB rebuild with a seconds-to-minutes in-place reclassify, including the operational structure for Claude Code to drive recovery autonomously across turns.

## Motivation

Two problems surfaced while attempting the original Bug C plan:

1. **Long jobs cannot be driven inline.** Several jobs in this project family run longer than is comfortable for a Claude Code synchronous Bash invocation:
   - `rake apple:knowledge:rebuild` — full Apple SDK ingestion (~4 hours)
   - Future LLM-based glue regeneration
   - Any other rake task or script that may exceed Claude Code's 2-minute Bash timeout

   Earlier attempts to drive these via Agent dispatch (general-purpose subagent) hung mid-run and produced no result, costing a full day. Hand-rolled `bin/longrun` scripts were rejected as duplicating well-known process supervision.

2. **The 4hr is mostly waste.** Bug C only adds derived fields (`kind`, `is_out_param`, `nullability`) computed by pure functions over the existing stored `:type` strings in `parameters_json`. Re-fetching headers and re-parsing via clang is unnecessary work; the data needed is already in the DB.

The user priority is (1) **stable execution mechanism first**, then (2) **performance**. Both are addressed below.

---

## Part 1: Long-batch execution pattern

### Tool choice: `screen` (macOS-bundled)

`/usr/bin/screen` ships with macOS. It is mature, well-known, and supports detached sessions with no daemon to manage. Alternatives considered and rejected:

- `pueue` / `task-spooler` — require `brew install`, additional install footprint
- `launchd` LaunchAgent — plist authoring overhead too high for ad-hoc batch jobs
- `nohup` alone — works but lacks named-session ergonomics; harder to monitor

### Execution template

Every long-batch job is started with this exact shape:

```bash
mkdir -p tmp/longrun
screen -dmS <name> bash -c '
  <command> > tmp/longrun/<name>.log 2>&1
  echo "DONE: exit=$?" >> tmp/longrun/<name>.log
'
```

- `<name>` — short identifier unique to the job (e.g. `bug-c-reclassify-20260505`, `apple-sdk-26-2-ingest`)
- `<command>` — the actual work (rake task, ruby script, etc.); env activation (`. ~/.swiftly/env.sh` etc.) goes inside the heredoc
- `tmp/longrun/<name>.log` — per-job log, written under whichever repo's cwd you run the command from

**The screen template applies even when the happy path is fast (e.g. a few seconds).** A job's worst-case duration determines whether to wrap it; once wrapped, the template is invariant. This way the operator (Claude or human) does not have to re-decide each time.

### Stability dimensions covered

| Dimension                | Mechanism                                                                |
|--------------------------|--------------------------------------------------------------------------|
| **A: Process isolation** | `screen -dmS` detaches; Claude Code session restart cannot kill the job |
| **B: Progress visibility** | Shell redirection to log file; `tail -f` streams live                 |
| **C: Completion detection** | `DONE: exit=N` sentinel appended after the command exits             |
| **D: Resumability**      | Out of scope. Killed jobs restart from scratch (the rake task author may add idempotency separately, but the wrapper does not provide it) |
| **E: Idempotency**       | Out of scope at the wrapper layer. Job-author responsibility (see Part 2 for the reclassify case) |
| **F: Native notification** | Not implemented. Detection is via log poll                            |

### Observation commands

```bash
screen -ls                                    # list live sessions
tail -f tmp/longrun/<name>.log                # follow log
grep "^DONE:" tmp/longrun/<name>.log          # 0 lines = running, 1 line = done (with exit code)
screen -X -S <name> quit                      # force-kill if needed (acknowledges D-loss)
```

### Documentation locus

The pattern is documented in `~/dev/src/CLAUDE.md` under a new "ロングバッチ実行パターン" section. That CLAUDE.md is the parent for all sub-repos under `~/dev/src/`, so any Claude session entering one of those repos picks up the convention without per-repo duplication.

This design document is the rationale + decision record. The CLAUDE.md entry is the operational cheat-sheet.

---

## Part 2: Performance redesign — `apple:knowledge:reclassify` rake task

### Principle

When the new fields a refactor introduces are **pure functions of data already in the store**, do not re-fetch the source. Recompute in-place.

For Bug C:

- `classify_kind(qual_type)` — pure on `qual_type` string
- `nullability_of(qual_type)` — pure on `qual_type` string
- `out_param?(qual_type, name, is_last_pointer)` — pure on `qual_type`, `name`, and the position-derivable `is_last_pointer` (the `parameters_json` array preserves order, so `is_last_pointer` is recomputable from existing data)

The existing `symbols.parameters_json` already holds `{name, type}` per parameter. That is sufficient input.

### Task contract

A new rake task in gem B (`rb-apple-sdk-knowledge`):

```
rake apple:knowledge:reclassify
```

Responsibilities:

1. **Read every `symbols` row** with non-null `parameters_json`.
2. **Recompute** `kind` / `is_out_param` / `nullability` on each parameter using the canonical helpers. The helpers currently in `HeaderParser` (`classify_kind`, `out_param?`, `nullability_of`) are extracted into a public module `AppleSDKKnowledge::Importer::Kind`. `HeaderParser` continues to use them internally; the reclassify task calls them through the public module. This extraction is part of T9 scope.
3. **Write back** the enriched `parameters_json` for that row.
4. **Emit two output streams:**
   - Standard log (stdout → `tmp/longrun/<name>.log`): progress lines and the screen-pattern `DONE:` sentinel
   - Structured action queue (`tmp/longrun/<name>-unsupported.jsonl`): one JSON-line per unsupported parameter, plus a final summary line — **designed for Claude Code in a later session to read and act on without re-deriving context**
5. **Be idempotent.** Pure functions; running twice produces the same result. Safe to re-run after extending `classify_kind`.

### Safety mechanisms

The task is invasive (mutates `parameters_json` in-place). Safeguards:

1. **Backup before start.** The task makes a side-by-side copy:
   ```
   data/sdk_knowledge_<v>.sqlite → data/sdk_knowledge_<v>.sqlite.bak
   ```
   The backup is rotated (single slot — overwritten on next run) so the most recent prior state is always restorable. If history of backups is needed (e.g. across recovery-loop iterations), the operator (Claude or user) can `cp` a labelled copy before the next run. Restore on failure = `mv data/sdk_knowledge_<v>.sqlite.bak data/sdk_knowledge_<v>.sqlite`.
2. **Single SQL transaction** wraps all UPDATE statements. SQLite guarantees all-or-nothing on COMMIT/ROLLBACK; mid-run kill rolls back, leaving the DB on its prior state.
3. **Idempotency** is the third safeguard: re-running after an aborted run produces the same outcome. There is no "half-applied schema" risk because the columns being updated are JSON content, not schema.
4. **Verification step** at the end of a successful run (after COMMIT): scan all rows, confirm every parameter has non-null `kind`. If any param lacks `kind` (a programming bug, not an unsupported case — `unsupported` is still a valid `kind`), the task aborts with non-zero exit and the verification failure is logged.
5. **Concurrency note** logged at start: while reclassify is running, gem C (which reads the DB) should not be invoked. The screen log header reminds the operator.

### Failure log format (Claude-readable jsonl)

`tmp/longrun/<name>-unsupported.jsonl` — one entry per unsupported parameter:

```jsonl
{
  "qual_type": "CFTypeRef _Nullable",
  "desugared": "const void * _Nullable",
  "framework": "CoreFoundation",
  "symbol": "CFRetain",
  "signature": "CFTypeRef CFRetain(CFTypeRef cf)",
  "param_index": 0,
  "param_name": "cf",
  "is_last_pointer": false,
  "heuristics": {
    "looks_like_function_pointer": false,
    "looks_like_void_pointer": true,
    "matches_existing_kind_regex": null
  }
}
```

Final line: a single `_summary` JSON object that surfaces the action priorities:

```jsonl
{
  "_summary": {
    "ran_at": "2026-05-05T12:34:56Z",
    "schema_version": 2,
    "total_symbols": 51234,
    "total_params": 187543,
    "by_kind": {"string": 12000, "int": 30000, "bool": 1500, "float": 800, "opaque_ref": 5000, "unsupported": 2000},
    "unsupported_clusters": [
      {"qual_type": "CFTypeRef _Nullable", "count": 1234, "frameworks": ["CoreFoundation","Foundation"], "example_symbols": ["CFRetain","CFRelease"]},
      {"qual_type": "id _Nullable", "count": 870, "frameworks": ["Foundation"], "example_symbols": ["NSObject"]}
    ],
    "classify_kind_source": "lib/rb_apple_sdk_knowledge/importer/header_parser.rb:134",
    "kind_vocabulary": ["string","int","bool","float","opaque_ref","unsupported"],
    "next_action_hint": "extend classify_kind to handle top cluster (or explicitly accept it as unsupported), then re-run rake apple:knowledge:reclassify"
  }
}
```

The summary fields are deliberately curated for Claude's autonomous reasoning:

- `unsupported_clusters` (top-N by count) tells Claude where the ROI is — fix one cluster, eliminate hundreds of cases
- `classify_kind_source` (`file:line`) gives the exact patch site without re-grepping
- `kind_vocabulary` lists what kinds already exist so Claude knows whether the right fix is "extend an existing kind regex" vs "introduce a new kind" (the latter requires changes in `template_generator` too)
- `next_action_hint` is a one-line plain-language suggestion as a fallback if Claude's reasoning is uncertain
- `heuristics` per row pre-computes the easy distinctions (function-pointer? void*?) so Claude does not have to re-walk the clang AST

### Recovery loop (Claude-driven)

The reclassify task is expected to need multiple iterations as the unsupported clusters are addressed. The loop:

1. Backup DB (the task does this internally, but keeping the previous backup is also useful).
2. Launch reclassify in a screen session per the Part 1 template. End the Claude turn after launching.
3. In a later turn (driven by user "完了した?" or by Claude returning to the work), verify `DONE: exit=0` in the log.
4. Read the `_summary` block of the unsupported jsonl. If the unsupported total is acceptable (e.g. all remaining clusters are explicitly known/intended unsupported types), exit the loop.
5. Otherwise: pick the top cluster, extend `classify_kind` (and, if introducing a new `kind`, extend `template_generator`'s `KIND_DISPATCH` and `kind_vocabulary` too). Commit the change with a clear `feat: classify_kind handles <pattern>` message.
6. Go to 1.

The loop is bounded by the operator (Claude or user) deciding "remaining unsupported is acceptable." There is no automatic stop condition; this is a deliberate design choice — Apple SDK has long-tail typedefs and the loop should not auto-terminate prematurely.

---

## Bug C Task 9 (final form)

T9 in the Bug C plan is replaced by the following sequence:

1. **Pre-run state confirmation.** The reclassify task itself takes the rotating backup. The operator only needs to confirm no other writer is active:
   ```bash
   ls -la ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite*
   pgrep -fl 'rake apple:knowledge'   # should be empty
   ```
   No DB deletion is required; the reclassify task mutates in place under transaction.

2. **Launch reclassify** in a screen session:
   ```bash
   mkdir -p tmp/longrun
   screen -dmS bug-c-reclassify bash -c '
     cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
     bundle exec rake apple:knowledge:reclassify > tmp/longrun/bug-c-reclassify.log 2>&1
     echo "DONE: exit=$?" >> tmp/longrun/bug-c-reclassify.log
   '
   ```

3. **End the Claude turn.** The happy path may finish in seconds, but applying the screen template unconditionally keeps the operational shape uniform.

4. **In the next turn**, verify completion:
   ```bash
   grep "^DONE:" ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-reclassify.log
   ```
   Must show `DONE: exit=0`.

5. **Read the unsupported summary** and enter the recovery loop if needed:
   ```bash
   tail -1 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-reclassify-unsupported.jsonl | jq .
   ```
   If `unsupported_clusters` has high-value targets, extend `classify_kind` and re-run from step 1.

6. **SQL verification** (the original Task 9 Step 3): confirm `parameters_json` for `MIDIClientCreate` contains the new `kind` / `is_out_param` fields:
   ```bash
   sqlite3 ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/data/sdk_knowledge_26.2.sqlite \
     "SELECT s.parameters_json FROM symbols s JOIN frameworks f ON s.framework_id=f.id WHERE s.name='MIDIClientCreate' AND f.name='CoreMIDI';"
   ```
   Expected: `parameters_json` contains `"kind":"string"` for `name`, `"kind":"opaque_ref"` for `outClient`, and `"is_out_param":true` for `outClient`. (`notifyProc` and `notifyRefCon` may be `unsupported` — that is acceptable; the recovery loop addresses them only if needed for the smoke test.)

If killed mid-run, the SQL transaction rolls back and the DB is unchanged; restart from step 2. (No need to restore from backup unless something actually corrupted, which the transaction guarantee prevents.)

---

## Out of scope (explicitly)

- **Resumable / checkpointing rake tasks** at the wrapper layer. The reclassify task achieves equivalent safety through SQL transactions instead.
- **macOS notification on completion.** The user can `tail -f` or grep the log when they choose.
- **A homegrown `bin/longrun` Ruby/shell wrapper.** The screen template is short enough that wrapping it adds maintenance debt without saving keystrokes.
- **Performance tuning of the original `apple:knowledge:rebuild` task.** Reclassify makes that 4hr path unnecessary for Bug C. If a future change requires re-fetching headers, that can be optimized then (parallelism, content-hash skip, etc.) — but is not part of this spec.

---

## Memory rules (to be saved alongside this work)

1. **Long-batch execution rule.** When asked to run anything plausibly longer than 2 minutes (rake task, SDK ingest, large LLM call loop, etc.), do not invoke it inline via Bash and do not dispatch a subagent for it. Use the screen template above. End the turn after launching. Verify completion in a later turn.
2. **Pure-function recompute rule.** Before running a heavyweight rebuild, ask: "are the new fields a pure function of data already stored?" If yes, recompute in-place via a dedicated rake task; do not re-fetch.
3. **Failure-log structure rule.** When a long-batch can produce partial-success states (e.g. unsupported items mixed with successful ones), the failure log MUST be structured (jsonl per item + final `_summary`) and MUST include the source file/line of the function that needs extending, the current vocabulary, and a `next_action_hint`. The reader is Claude in a later session, not a human.
