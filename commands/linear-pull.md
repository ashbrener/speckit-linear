---
name: speckit.linear.pull
description: Cross-repo unified spec view from Linear (READ-ONLY; never mutates Linear)
arguments:
  - name: workspace-wide
    description: query every Project the operator's team owns, not just the locally bound Project
    optional: true
  - name: phase
    description: restrict to one lifecycle phase (e.g. implementing, ready_to_merge)
    optional: true
  - name: json
    description: emit a machine-readable JSON array on stdout instead of the human table
    optional: true
  - name: no-color
    description: force monochrome output (also honoured via the NO_COLOR environment variable)
    optional: true
---

# `/speckit.linear.pull`

## Summary

Linear-anchored cross-repo inventory of every spec Issue, grouped by
Project, never mutates Linear.

Cross-repo unified view of every spec Issue Linear knows about. The
partner to `/speckit.linear.status`: where `status` is filesystem-
anchored and drift-aware (one repo, comparing disk against Linear),
`pull` is Linear-anchored and inventory-aware (every spec across every
repo bound to the operator's workspace, grouped by Project).

**Direction**: read-only. Talks to Linear ONLY via `graphql::query`;
issues zero `issueCreate` / `issueUpdate` / `commentCreate` / any
other mutation. Even from a worktree that could write (under Principle
IV v2.0.0 any worktree can), this command MUST NOT write — it is an
inventory tool, full stop.
**Authority**: not gated. Runs from any worktree, on any branch
(detached HEAD included), and (in `--workspace-wide` mode) from any
directory inside the consumer repo. Reports Linear's view without
inspecting filesystem state.
**Layer**: out-of-band inspect command, not part of Layer D's write
cycle. Safe to run during a deploy, during a CI build, during a merge.

The deterministic work happens in `src/pull.sh`; this command is the
AI-agent entry point that runs the shell and surfaces its output. The
formal API contract is `contracts/command-shapes.md`
(`speckit.linear.pull` slice). Operators reading this file are looking
at the markdown the AI agent reads — the same operations are available
via `bash src/pull.sh` directly. For the operator-facing end-to-end
walkthrough see
[`quickstart.md`](../specs/001-spec-kit-linear-bridge/quickstart.md).

## Usage

| Argument | Default | Meaning |
|---|---|---|
| `workspace-wide` | false (implies `--repo`) | Query every Project the operator's team owns, not just the locally bound Project. Useful when running from a directory not bound to a Linear project, or for cross-repo coordination. |
| `phase` | (none — implies `--all-phases`) | Restrict to a single lifecycle phase (`specifying`, `clarifying`, `planning`, `tasking`, `red_team`, `implementing`, `analyzing`, `ready_to_merge`, `merged`). |
| `json` | false | Emit a machine-readable JSON array on stdout, one object per spec Issue. Default is the coloured human table grouped by Project. |
| `no-color` | false | Force monochrome output. Also honoured via the `NO_COLOR` env variable. |

`workspace-wide` and `phase` are orthogonal — every combination is
valid. `json` and `no-color` are orthogonal to scope and phase.

### CLI shape

```text
speckit.linear.pull [--repo | --workspace-wide]
                    [--phase PHASE | --all-phases]
                    [--json | --human] [--no-color]
```

Default: `--repo --all-phases --human`.

## Algorithm (what the AI agent executes)

1. **Verify prerequisites.** Refuse to proceed if any of these fail.
   - Bash 4 or newer is on `PATH`. macOS ships bash 3.2 by default;
     the operator must `brew install bash` and ensure
     `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash`
     (Intel) is earlier on `PATH` than `/bin/bash`.
   - The consumer repo's config is present at
     `.specify/extensions/linear/linear-config.yml`. If absent,
     surface "run `/spec-kit-linear-install` first" and exit 2; do NOT
     attempt to run the inspector.
   - `jq`, `curl`, and `git` are installed.

2. **Compose the invocation.** Translate the user-facing arguments
   into `src/pull.sh` flags:
   - `workspace-wide=true` → `--workspace-wide`
   - no `workspace-wide` → `--repo` (the default)
   - `phase=NAME` → `--phase NAME`
   - no `phase` → `--all-phases`
   - `json=true` → `--json`
   - `no-color=true` → `--no-color`

3. **Execute the inspector.** Shell out:

   ```bash
   bash src/pull.sh <flags>
   ```

   The script:
   - Loads + validates `linear-config.yml` (`src/config.sh`). Halts
     with exit 2 on missing / malformed UUIDs (FR-022).
   - Builds a single GraphQL `IssueFilter`:
     - `labels.name startsWith "speckit-spec:"` — the FR-004b workspace
       label family identifies every spec Issue regardless of repo.
     - `--repo`: AND `project.id eq <linear.project.id>`.
     - `--workspace-wide`: AND `team.id eq <linear.team.id>`.
     - `--phase X`: AND a second-clause `labels.name eq "phase:X"`
       under the top-level `and:` field so both label conditions can
       coexist.
   - Issues one `graphql::query` call returning every matching Issue
     (capped at 250 nodes per Linear's pagination default — sufficient
     for the bridge's design ceiling of a few dozen specs per team).
   - For each node, extracts: `identifier`, `feature_number` (parsed
     from the `speckit-spec:NNN` label), `title`, `project_name`,
     `state_name` + `state_type`, `phase_label` (parsed from the
     `phase:*` label), `branch` + `worktree` (parsed from the
     description's memory block, if present), `last_activity`
     (Linear's `updatedAt`), `assignee_name` (FR-034), `estimate`
     (FR-035 rollup), and `url` (composed from
     `linear.workspace.url_key` + identifier).
   - Sorts by Project name, then lifecycle phase (using the canonical
     spec-kit order: specifying → clarifying → planning → tasking →
     red_team → implementing → analyzing → ready_to_merge → merged),
     then last_activity descending.
   - Renders the report on stdout (JSON array or Project-grouped human
     table) and the structured summary on stderr.

4. **Render the report.** Two output shapes:

   - `--human` (default) — Project-grouped coloured table on stdout:

     ```text
     ▼ spec-kit-linear
     ID      NNN  PHASE         STATE         EST  ASSIGNEE  LAST ACTIVITY         TITLE
     OSH-13  005  implementing  Implementing  46   ash       2026-05-28T11:50:00Z  005-some-spec
     OSH-12  002  tasking       Tasking        6   ash       2026-05-27T09:21:00Z  002-multi-phase
     OSH-5   001  merged        Done          40   ash       2026-05-25T16:00:00Z  001-spec-kit-linear-bridge

     ▼ another-repo
     ID      NNN  PHASE     STATE     EST  ASSIGNEE  LAST ACTIVITY         TITLE
     OSH-22  003  planning  Planning   8   ash       2026-05-28T08:00:00Z  003-feature-x
     ```

     `PHASE` cell is yellow for early phases, blue for mid-lifecycle,
     green for late / merged. Honours `NO_COLOR` and `--no-color`.

   - `--json` — JSON array on stdout, one object per spec Issue,
     sorted Project → phase → last_activity:

     ```json
     [
       {
         "identifier": "OSH-13",
         "feature_number": "005",
         "title": "005-some-spec",
         "project_id": "...",
         "project_name": "spec-kit-linear",
         "state_name": "Implementing",
         "state_type": "started",
         "phase_label": "implementing",
         "branch": "005-some-spec",
         "worktree": "/path/to/wt",
         "last_activity": "2026-05-28T11:50:00Z",
         "assignee_name": "ash",
         "estimate": 46,
         "url": "https://linear.app/osh-infra/issue/OSH-13"
       }
     ]
     ```

5. **Handle the exit code.**
   - `0` — success (possibly with warnings). The inventory is authoritative.
   - `1` — partial failure: a sub-query failed but other rows surfaced.
     Recommend re-running once network connectivity is restored.
   - `2` — workspace config error (missing/malformed `linear-config.yml`).
     The script halted before any query. Surface the remediation the
     script printed (typically: run `/spec-kit-linear-install`).
   - `3` — transport failure. Linear was unreachable; no rows surfaced.

## When this command fires

- **Operator-driven** — `/speckit.linear.pull` from the AI agent
  chat. Primary path for "what specs are in flight across my
  workspace?", cross-repo coordination, and Project-level inventory
  checks before a release.
- **Never auto-fired.** This is NOT wired into any `after_*` hook or
  any git hook by `/spec-kit-linear-install`. Operator-invoked only.

## Output channel discipline

- `stdout` carries the per-Issue inventory (JSON array or human
  table). This is the contract: pipe it to `jq` or `column` confidently.
- `stderr` carries:
  - per-step log lines (the scope + phase + format being applied)
  - the final structured `summary::emit` block (always)
- No filesystem writes (Principle I). No Linear writes (Principle I +
  FR-026). The inspector reads Linear and prints; everything else is
  operator action.

## Failure surface

Each failure mode is surfaced as a named warning in the summary
(Principle VIII):

- `config load failed: PATH` — `linear-config.yml` absent. Exit 2.
- `config validation failed` — malformed UUIDs or missing fields. Exit 2.
- `linear.project.id missing for --repo scope` — operator tried
  `--repo` against a workspace-wide-only config. Suggest
  `--workspace-wide` or running `/spec-kit-linear-install` to bind a
  Project. Exit 2.
- `linear.team.id missing for --workspace-wide scope` — config has no
  team UUID. Exit 2.
- `Linear query failed; no rows surfaced` — transport / GraphQL
  failure. Exit 3.
- `no spec Issues matched the requested filter` — empty inventory.
  Exit 0; the report shows the active scope + phase filter so the
  operator can verify the empty result is intentional.

## Related commands

- `/speckit.linear.status` — disk-vs-Linear drift report for the
  current repo. Use this for "is THIS repo in sync?"; use `pull` for
  "what's in flight across EVERY repo?".
- `/speckit.linear.push` — write path. Reconciles filesystem state
  into Linear. Use `/speckit.linear.status` or `/speckit.linear.pull`
  first to see what WOULD change.
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

- **FR-004b** — `speckit-spec:NNN` workspace label as the cross-repo
  spec-Issue lookup key.
- **FR-022** — config-load halt with operator-actionable remediation.
- **FR-023** — structured `summary::emit` block on stderr.
- **FR-026 / FR-060** — read-only direction; the bridge never writes
  from this command, from any worktree (Principle IV v2.0.0).
- **FR-034** — operator assignee surfaced in the inventory.
- **FR-035** — Fibonacci `[N]` estimate rollup surfaced in the inventory.
