# tooling/

Maintainer-only Ruby modules and Rake tasks for the human-in-the-loop (HITL) emitter improvement workflow: adding emitters for frequently inferred APIs and trimming redundant marshallers. Nothing here is part of a released gem.

## Layout

```
tooling/
├── README.md
└── lib/
    ├── emitter_dev/
    │   ├── branch_ops.rb
    │   ├── worktree_ops.rb
    │   ├── source_compile_history.rb
    │   ├── redundancy_scanner.rb
    │   ├── candidate_ranker.rb
    │   └── fact_bundler.rb
    └── tasks/
        └── emitter.rake
```

The tests live in `test/tooling/emitter_dev/` and run with the repository's `rake test`.

## Modules

| Module | Role |
| --- | --- |
| `EmitterDev::BranchOps` | Derives a branch name such as `emitter/add-NSString-stringWithUTF8String` from a candidate, and runs the checkout, `--no-ff` merge, and branch deletion. |
| `EmitterDev::WorktreeOps` | Creates a `git worktree` for a candidate, symlinks `knowledge`, `sources`, and `lib` from `.rb-apple-sdk-mac/<sdk_version>/`, and copies `cache.sqlite`. |
| `EmitterDev::Sources::CompileHistory` | Aggregates the `compile_history` table of `.rb-apple-sdk-mac/<sdk_version>/cache.sqlite` per API. Returns `[]` when the table does not exist. |
| `EmitterDev::RedundancyScanner` | Parses `marshallers.rb` with Prism and reports twin helpers (similar method bodies across classes) and class pairs that share two or more method names. |
| `EmitterDev::CandidateRanker` | Ranks compile-history rows and scanner findings for `add`, `trim`, or `all` mode. |
| `EmitterDev::FactBundler` | Composes the markdown bundle for the review gate from `git log`, `git diff --stat`, and the `tmp/emitter/*_<slug>.*` artifacts, with a `<missing: path>` placeholder for each absent artifact. |

## Rake tasks

`tooling/lib/tasks/emitter.rake` defines the `apple:emitter:` tasks; the repository `Rakefile` loads it.

| Task | Purpose |
| --- | --- |
| `apple:emitter:candidates` | `MODE=add\|trim\|all TOP=N` writes ranked candidates to `tmp/emitter/candidates.json`. |
| `apple:emitter:worktree_create` | `CANDIDATE_ID=N BASE=<branch>` creates the worktree and branch for a candidate. |
| `apple:emitter:fact_bundle` | `BRANCH=... BASE=...` writes the fact bundle to `tmp/emitter/fact_<slug>.md`. |
| `apple:emitter:merge` | `BRANCH=... BASE=... WORKTREE_PATH=...` merges the branch with `--no-ff`, removes the worktree, and deletes the branch. |

```bash
bundle exec rake apple:emitter:candidates MODE=add TOP=5
bundle exec rake apple:emitter:worktree_create CANDIDATE_ID=1 BASE=main
bundle exec rake apple:emitter:fact_bundle BRANCH=emitter/add-... BASE=main
bundle exec rake apple:emitter:merge BRANCH=emitter/add-... BASE=main WORKTREE_PATH=...
```

The slug of a branch is `branch.tr("/", "_")`, for example `emitter/add-foo` → `emitter_add-foo`.

## Slash command and agent

- `.claude/skills/rb-apple-sdk-mac-improve-emitter/SKILL.md`: `/rb-apple-sdk-mac-improve-emitter [--mode=add|trim|all] [--top=N]` runs candidates → user pick → worktree → implementer agent → fact bundle → user approval → merge.
- `.claude/agents/emitter-implementer.md`: implements one candidate inside its worktree with RED → GREEN → REFACTOR and returns the raw test results and diff.

## Fact bundle sections

| Section | Source |
| --- | --- |
| header | branch and base names |
| branch & commits | `git log --oneline base..branch` |
| diff stat | `git diff --stat base..branch` |
| design | `tmp/emitter/design_<slug>.md` |
| regression | `tmp/emitter/regression_<slug>.txt` |
| individual verification | `tmp/emitter/verify_<slug>.txt` |
| compile_history delta | `tmp/emitter/compile_history_<slug>.txt` |
