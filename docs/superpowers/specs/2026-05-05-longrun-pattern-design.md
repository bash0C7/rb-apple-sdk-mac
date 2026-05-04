# Long-Batch Execution Pattern (screen-based)

**Date:** 2026-05-05
**Status:** approved
**Supersedes:** Bug C plan Task 9 (`docs/superpowers/specs/2026-05-05-bug-c-template-runtime-integration-design.md`'s "DB rebuild ~4hr" step)
**Scope:** All long-running batch jobs across `~/dev/src/github.com/bash0C7/{rb-apple-sdk-knowledge,rb-apple-sdk-mac,swift_gem,...}` and any future sibling projects under `~/dev/src/`.

## Motivation

Several jobs in this project family run longer than is comfortable for a Claude Code synchronous Bash invocation:

- `rake apple:knowledge:rebuild` — full Apple SDK ingestion (~4 hours)
- Future LLM-based glue regeneration
- Any other rake task or script that may exceed Claude Code's 2-minute Bash timeout

Earlier attempts to drive these via Agent dispatch (general-purpose subagent) hung mid-run and produced no result, costing a full day. Hand-rolled `bin/longrun` scripts were rejected as duplicating well-known process supervision.

We need a documented convention that uses an existing tool, with no install footprint.

## Design

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

- `<name>` — short identifier unique to the job (e.g. `bug-c-rebuild`, `apple-sdk-26-2-ingest`)
- `<command>` — the actual work (rake task, ruby script, etc.); env activation (`. ~/.swiftly/env.sh` etc.) goes inside the heredoc
- `tmp/longrun/<name>.log` — per-job log, written under whichever repo's cwd you run the command from

### Stability dimensions covered

| Dimension                | Mechanism                                                                |
|--------------------------|--------------------------------------------------------------------------|
| **A: Process isolation** | `screen -dmS` detaches; Claude Code session restart cannot kill the job |
| **B: Progress visibility** | Shell redirection to log file; `tail -f` streams live                 |
| **C: Completion detection** | `DONE: exit=N` sentinel appended after the command exits             |
| **D: Resumability**      | Out of scope. Killed jobs restart from scratch (the rake task author may add idempotency separately, but the wrapper does not provide it) |
| **E: Idempotency**       | Out of scope. Job-author responsibility                                 |
| **F: Native notification** | Not implemented. Detection is via log poll                            |

### Observation commands

```bash
screen -ls                                    # list live sessions
tail -f tmp/longrun/<name>.log                # follow log
grep "^DONE:" tmp/longrun/<name>.log          # 0 lines = running, 1 line = done (with exit code)
screen -X -S <name> quit                      # force-kill if needed (acknowledges D-loss)
```

## Documentation locus

The pattern is documented in `~/dev/src/CLAUDE.md` under a new "ロングバッチ実行パターン" section. That CLAUDE.md is the parent for all sub-repos under `~/dev/src/`, so any Claude session entering one of those repos picks up the convention without per-repo duplication.

This design document (this file) is the rationale + decision record. The CLAUDE.md entry is the operational cheat-sheet.

## Application to Bug C Task 9

Bug C plan Task 9 originally read:

> Step 2: Delete old DB and rebuild (~4 hours, run in background)
> ```bash
> bundle exec rake apple:knowledge:rebuild
> ```

It is replaced by:

1. Ask user for explicit authorization to delete `data/sdk_knowledge_26.2.sqlite`. Then:
   ```bash
   cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
   rm -f data/sdk_knowledge_26.2.sqlite data/sdk_knowledge_26.2.sqlite-wal data/sdk_knowledge_26.2.sqlite-shm
   ```
2. Start the rebuild in a detached screen session per the template:
   ```bash
   mkdir -p tmp/longrun
   screen -dmS bug-c-rebuild bash -c '
     cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge
     bundle exec rake apple:knowledge:rebuild > tmp/longrun/bug-c-rebuild.log 2>&1
     echo "DONE: exit=$?" >> tmp/longrun/bug-c-rebuild.log
   '
   ```
3. End the Claude turn. Do not block on the 4-hour wait.
4. When the user signals completion (or in a later turn driven by the user), verify:
   ```bash
   grep "^DONE:" ~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/tmp/longrun/bug-c-rebuild.log
   ```
   Must show `DONE: exit=0`. If non-zero, inspect the log for the failing framework and address.
5. Run the SQL verification (unchanged from original Task 9 Step 3): confirm `parameters_json` for `MIDIClientCreate` contains the new `kind` / `is_out_param` fields.

If killed mid-run, restart from Step 1. (D is out of scope.)

## Out of scope (explicitly)

- Resumable / checkpointing rake tasks. If the project later grows a need for this, add a separate spec; do not graft it onto the screen wrapper.
- macOS notification on completion. The user can `tail -f` or grep the log when they choose.
- A homegrown `bin/longrun` Ruby/shell wrapper. The screen template is short enough that wrapping it adds maintenance debt without saving keystrokes.
- Performance tuning of the long-batch jobs themselves (e.g. making the 4hr rebuild faster). That is a separate concern, deliberately deferred per user priority order.

## Memory rule (to be saved alongside this work)

When asked to run anything plausibly longer than 2 minutes (rake task, SDK ingest, large LLM call loop, etc.), do not invoke it inline via Bash and do not dispatch a subagent for it. Use the screen template above. End the turn after launching. Verify completion in a later turn driven by user.
