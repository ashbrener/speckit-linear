---
name: speckit.linear.status
description: Per-spec drift report — disk vs Linear (READ-ONLY; never mutates Linear)
arguments:
  - name: spec
    description: feature number (e.g., 003) to inspect only that spec; default behaviour is to inspect all specs
    optional: true
  - name: json
    description: emit machine-readable JSON array on stdout instead of the human table
    optional: true
  - name: no-color
    description: force monochrome output (also honoured via the NO_COLOR environment variable)
    optional: true
---

# `/speckit.linear.status`

## Summary

Per-spec drift inspector — disk vs Linear, every spec in the consumer
repo, never mutates Linear.

Inspect, do not mutate. For each `specs/NNN-feature/` in the consumer
repo, surface the disk-side facts, the Linear-side facts, the drift
between them, and the write-authority / drift posture for that spec.
(Under Constitution Principle IV v2.0.0 — drift-aware, spec 003 — the
relevant signal is backward-drift, not the legacy FR-025 branch-gate;
see the Authority status field below.)

**Direction**: read-only. Talks to Linear ONLY via `graphql::query`;
issues zero `issueCreate` / `issueUpdate` / `commentCreate` / any other
mutation. Even from an authoritative worktree, this command MUST NOT
write — it is an inspect tool, full stop.
**Authority**: not gated. Runs from any worktree, on any branch
(detached HEAD included). Reports the per-spec drift posture so the
operator knows whether a subsequent `/speckit.linear.push` from the
current worktree would write cleanly or hit a backward-drift warning
(Principle IV v2.0.0 / spec 003). Current Linear state is always
surfaced (FR-026 / FR-060).
**Layer**: out-of-band inspect command, not part of Layer D's write
cycle. Safe to run during a deploy, during a CI build, during a merge.

The deterministic work happens in `src/status.sh`; this command is the
AI-agent entry point that runs the shell and surfaces its output. The
formal API contract is `contracts/command-shapes.md` (`speckit.linear.status`
slice). Operators reading this file are looking at the markdown the AI
agent reads — the same operations are available via
`bash src/status.sh` directly. For the operator-facing end-to-end
walkthrough see
[`quickstart.md`](../specs/001-spec-kit-linear-bridge/quickstart.md).

## Usage

| Argument | Default | Meaning |
|---|---|---|
| `spec` | (none — implies `--all`) | Feature number (e.g. `003`). Inspect only this spec. |
| `json` | false | Emit a machine-readable JSON array on stdout, one object per spec. Default is the coloured human table. |
| `no-color` | false | Force monochrome output. Also honoured via the `NO_COLOR` env variable. |

Exactly one of `spec` or "all specs" is in effect. When `spec` is not
passed, the report walks every `specs/NNN-*/` directory in the consumer
repo. `json` and `no-color` are orthogonal to `spec`.

### CLI shape

```text
speckit.linear.status [--spec NNN | --all] [--json | --human] [--no-color]
```

Default: `--all --human`.

## Algorithm (what the AI agent executes)

1. **Verify prerequisites.** Refuse to proceed if any of these fail.
   - Bash 4 or newer is on `PATH`. macOS ships bash 3.2 by default; the
     operator must `brew install bash` and ensure
     `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash`
     (Intel) is earlier on `PATH` than `/bin/bash`.
   - The consumer repo's config is present at
     `.specify/extensions/linear/linear-config.yml`. If absent,
     surface "run `/spec-kit-linear-install` first" and exit 2; do NOT
     attempt to run the inspector.
   - `jq`, `curl`, and `git` are installed.

2. **Compose the invocation.** Translate the user-facing arguments
   into `src/status.sh` flags:
   - `spec=NNN` → `--spec NNN`
   - no `spec` → `--all`
   - `json=true` → `--json`
   - `no-color=true` → `--no-color`

3. **Execute the inspector.** Shell out:

   ```bash
   bash src/status.sh <flags>
   ```

   The script:
   - Loads + validates `linear-config.yml` (`src/config.sh`). Halts
     with exit 2 on missing / malformed UUIDs (FR-022).
   - Enumerates the requested specs in numeric order.
   - For each spec, gathers:
     - **Disk-side facts** — feature number, short name, lifecycle
       phase (per `parser::lifecycle_phase`), current branch (per
       `git_helpers::current_branch`), worktree(s) hosting that
       branch (per `git_helpers::list_worktrees`), last-touched
       timestamp (per `git_helpers::last_touched`), task-phase
       completion ratio computed from `tasks.md` checklists.
     - **Linear-side facts** — spec Issue's workflow state, `phase:*`
       label, sub-issue completion counts, last activity timestamp.
       Queried via `graphql::query` using the `speckit-spec:NNN` label
       scoped to the configured Project UUID (FR-004b).
     - **Drift signals** — bullet list of mismatches: lifecycle phase
       differs, branch differs from the memory block, last-touched is
       older than Linear's last activity (FR-026 "Linear knows
       something disk doesn't"), task checklist count differs.
     - **Drift status** — the backward-drift posture per Principle IV
       v2.0.0 (spec 003): reports whether writing this spec from the
       current worktree would be a clean forward write or trigger a
       backward-drift warning (Linear ahead of disk). This is a
       NON-GATING display hint — the FR-025 branch-gate is removed
       (FR-051); reconcile writes from any worktree and only SURFACES
       drift, never refuses (FR-060). The legacy
       `git_helpers::is_authoritative_for_spec` flag is retained ONLY as
       an informational "is this the canonical feature-branch worktree?"
       cue, never a write decision.
     - **Canonical-right-now worktree** — when more than one worktree
       has `specs/NNN-feature/` checked out, the report names the
       worktree holding the MOST RECENT commit touching the spec dir
       (per `git_helpers::worktrees_touching_spec`, FR-058/FR-059). The
       ranking uses spec-dir git-commit time, NEVER branch name or
       mtime, so the pointer agrees with the drift signal. The
       single-worktree case omits this field. See
       [`recency-comparison.md`](../specs/003-drift-aware-authority/contracts/recency-comparison.md)
       for the recency-key contract.
   - Renders the per-spec report on stdout (JSON array or human
     table) and the structured summary on stderr.

4. **Render the report.** Two output shapes:

   - `--human` (default) — coloured table on stdout:

     ```text
     NNN  NAME            DISK PHASE  DISK TASKS  AUTH  LINEAR ID  LINEAR STATE         DRIFT
     001  multi-phase     tasking     0/3         Yes   ACM-12     Tasking (tasking)    —
     002  multi-phase     tasking     0/3         No    ACM-14     Implementing (impl…) lifecycle phase: disk=tasking linear=implementing
     ```

     `AUTH` cell is green (Yes) / yellow (No). `DRIFT` cell is green
     (`—`) / red (any signal). Honours `NO_COLOR` and `--no-color`.

   - `--json` — JSON array on stdout, one object per spec:

     ```json
     [
       {
         "feature_number": "002",
         "short_name": "multi-phase",
         "disk": {
           "lifecycle_phase": "tasking",
           "current_branch": "002-multi-phase",
           "worktree": "/path/to/wt",
           "worktree_count": 1,
           "last_touched": "2026-05-28T12:00:00Z",
           "task_phase_completion": "0/3"
         },
         "authority": "Yes",
         "linear": {
           "present": true,
           "fetch_failed": false,
           "identifier": "ACM-12",
           "title": "002-multi-phase",
           "state_name": "Tasking",
           "state_type": "started",
           "phase_label": "tasking",
           "sub_issue_completion": "0/3",
           "last_activity": "2026-05-28T11:50:00Z"
         },
         "drift": []
       }
     ]
     ```

5. **Handle the exit code.**
   - `0` — success (possibly with warnings). The report is authoritative.
   - `1` — partial failure. At least one spec's Linear-side fetch
     failed; the disk-side row still appears with `linear.fetch_failed: true`.
     Recommend re-running once network connectivity is restored.
   - `2` — workspace config error (missing/malformed `linear-config.yml`).
     The script halted before any query. Surface the remediation the
     script printed (typically: run `/spec-kit-linear-install`).
   - `3` — transport failure. Linear was unreachable; the disk-side
     report still emits, but every Linear cell is empty.

## When this command fires

- **Operator-driven** — `/speckit.linear.status` from the AI agent
  chat. Primary path for "what's the state of this repo?" inspections,
  multi-repo coordination, and pre-push drift checks.
- **Never auto-fired.** This is NOT wired into any `after_*` hook or
  any git hook by `/spec-kit-linear-install` — running it on every
  lifecycle command would add latency to every spec edit without
  changing observable state. Operator-invoked only.

## Output channel discipline

- `stdout` carries the per-spec report (JSON array or human table).
  This is the contract: pipe it to `jq` or `column` confidently.
- `stderr` carries:
  - per-step log lines (the spec being inspected, the Linear query
    being issued)
  - the final structured `summary::emit` block (always)
- No filesystem writes (Principle I). No Linear writes (Principle I +
  FR-026). The inspector reads disk + Linear and prints; everything
  else is operator action.

## Failure surface

Each failure mode is surfaced as a named warning in the summary
(Principle VIII):

- `spec NNN: spec.md missing or empty; phase unknown` — partial
  inspection continues; the spec appears with `disk.lifecycle_phase: "unknown"`.
- `spec NNN: Linear query failed; surfacing disk-side facts only` —
  per-spec transport blip. The disk-side row still appears with
  `linear.fetch_failed: true`. Exit code promotes to 1.
- `no spec directory matched --spec NNN` — operator typo; report empty.
- `no specs/NNN-*/ directories found` — repo has no specs yet; report
  empty with this warning so the operator knows the empty output is
  intentional rather than a bug.

## Related commands

- `/speckit.linear.push` — write path. Reconciles filesystem state
  into Linear. Use `/speckit.linear.status` first to see what WOULD
  change.
- `/speckit.linear.pull` — read-only inspect of Linear's current
  view (no disk-side comparison).
- `/speckit.linear.seed` — one-shot workspace setup. Run once per
  Linear workspace before the first push.
- `/speckit.linear.install` — per-repo install ceremony. Run once
  per consumer repo before the first push.

See `contracts/command-shapes.md` for the formal contract on each
and
[`quickstart.md`](../specs/001-spec-kit-linear-bridge/quickstart.md)
for the end-to-end operator walkthrough.

## FRs surfaced

This command implements (in whole or in part):

- **FR-022** — config-load halt with operator-actionable remediation.
- **FR-023** — structured `summary::emit` block on stderr.
- **FR-025** — per-spec write-authority status surfaced in the report (the v1.0.0 branch-gate is SUPERSEDED by Constitution Principle IV v2.0.0 / spec 003 drift-aware signal, FR-051..FR-060).
- **FR-026 / FR-060** — read-only inspection; current Linear state and drift surfaced without any write attempt.
- **FR-058 / FR-059** — the canonical-right-now worktree pointer (most-recent spec-dir commit across worktrees, ranked by git-commit time) surfaced when >1 worktree touches the spec.
- **FR-004b** — `speckit-spec:NNN` label is the lookup key for the Linear-side fetch.
