---
name: speckit.linear.seed
description: One-shot seed of a Linear workspace — creates the 9 lifecycle workflow states, 18 workspace labels, captures every UUID into linear-config.yml
arguments:
  - name: team
    description: Linear team UUID. Optional — defaults to linear.team.id in linear-config.yml.
    optional: true
  - name: dry-run
    description: Log every mutation that WOULD fire; issue none.
    optional: true
  - name: workspace-only
    description: Run the Linear-side workspace mutations only; do NOT write captured UUIDs back to linear-config.yml.
    optional: true
---

# `/speckit.linear.seed`

## Summary

One-shot per-workspace seed — creates the nine lifecycle workflow
states and eighteen workspace labels, captures every UUID into
`linear-config.yml`.

One-shot workspace seed. Creates the Linear primitives the bridge relies
on that do NOT mint themselves lazily during reconcile: nine custom
lifecycle workflow states (one per spec-kit lifecycle phase) plus
eighteen workspace-scoped issue labels (`phase:*` and `task-phase:N`).
After the writes settle, captures every returned UUID and splices the
two resulting maps — `workflow_state_uuids` and `default_state_uuids` —
into the consumer repo's
`.specify/extensions/linear/linear-config.yml`.

**Cardinality**: one-shot per Linear workspace. Run it once when you
adopt the bridge in a fresh workspace; never wire it to a hook. Safe to
re-run any number of times — every Linear write is preceded by an
existence query, so a re-run against an already-seeded workspace
observably produces zero `created` events and the same
`linear-config.yml` byte-for-byte (Principle II — idempotency,
FR-021 — "MUST be safe to re-run").

**Direction**: filesystem-to-Linear writes only; the only filesystem
write is the `linear-config.yml` update, which is also bridge-owned
(Principle I — filesystem-is-truth holds: the operator never has to
hand-edit the UUIDs).

**Authority**: write-authority gate does NOT apply here — the seed is
workspace-level configuration, not per-spec mutation, so any worktree
that has the bridge installed can run it (Principle IV scopes only
spec-level writes).

The deterministic work happens in `src/seed.sh`; this command is the
AI-agent entry point that runs the shell and surfaces its output. The
formal API contract is `contracts/command-shapes.md` §4
(`speckit.linear.seed`); the mutations issued are enumerated in
`contracts/linear-graphql-mutations.md` §2. Operators reading this
file are looking at the markdown the AI agent reads — the same
operations are available via `bash src/seed.sh` directly. For the
operator-facing end-to-end walkthrough see
[`quickstart.md`](../specs/001-spec-kit-linear-bridge/quickstart.md).

## Why GraphQL, not MCP

The two seed-time write mutations — `workflowStateCreate` and
`issueLabelCreate` — go through direct GraphQL (via `src/graphql.sh`),
not the Linear MCP. Two load-bearing reasons:

1. **`workflowStateCreate` has no MCP equivalent.** The 2026-05-28
   runtime probe (`validation/linear-mcp-runtime-probe.md` §C Capability
   8) confirmed the live MCP exposes `list_issue_statuses` and
   `get_issue_status` for reads only; there is no `save_workflow_state`
   or `create_workflow_state` tool. GraphQL is the only viable path.

2. **Symmetry with the GitHub Action.** Per Principle VI
   (OAuth-first, keys-at-the-edges), the GitHub Action also speaks
   GraphQL with `LINEAR_API_TOKEN`. Keeping the seed step on the same
   wire format means the operator only has to provision a single token
   shape (their personal `LINEAR_API_KEY` in `.env` locally; the
   `LINEAR_API_TOKEN` repo secret remotely) and the contracts in
   `validation/github-action-mechanics.md` apply unchanged.

`issueLabelCreate` could in theory go through MCP's
`create_issue_label`, but `src/seed.sh` runs from contexts that do not
have an MCP session (hooks, CI, fresh checkouts), so the GraphQL path
is the load-bearing one. The behaviour is identical either way per
Principle II.

## Usage

| Argument | Default | Meaning |
|---|---|---|
| `team` | `linear.team.id` from `linear-config.yml` | UUID of the Linear team to seed. Required only when running before `/spec-kit-linear-install` has populated the per-repo config (e.g. first-time bootstrap, sibling-repo dogfood). |
| `dry-run` | false | Log every mutation that WOULD fire; issue none. Also skips the `linear-config.yml` write. Safe inspection mode. |
| `workspace-only` | false | Run the Linear-side workspace mutations only; do NOT write captured UUIDs back to `linear-config.yml`. Use this when you want to verify the workspace state from a non-bridge-installed context (e.g. dogfood from a sibling repo) without touching this repo's config. |

`dry-run` and `workspace-only` are orthogonal. Both default off.

### CLI shape

```text
speckit.linear.seed [--team UUID] [--dry-run] [--workspace-only]
```

Default: read team from `linear-config.yml`; full write path.

> FR-036 agent labels: this seed step creates the canonical
> `agent:claude` and `agent:codex` workspace labels at seed time and
> captures their UUIDs into `linear-config.yml.linear.agent_label_uuids`.
> Non-canonical agent families (e.g. `agent:gemini`) are lazy-created
> by reconcile on first encounter. See spec FR-036 for the full
> stamping semantics (sticky labels, never removed; cross-agent
> provenance preserved).

## Algorithm (what the AI agent executes)

1. **Verify prerequisites.** Refuse to proceed if any of these fail.
   - Bash 4 or newer is on `PATH`. Run `bash --version` and confirm
     the major version number is `≥ 4`. macOS ships bash 3.2 by
     default; the operator must `brew install bash` and ensure
     `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash`
     (Intel) is earlier on `PATH` than `/bin/bash`.
   - `jq` is installed (`command -v jq`). `curl` is installed
     (`command -v curl`).
   - Either `--team UUID` was passed OR the consumer repo's config is
     present at `.specify/extensions/linear/linear-config.yml` with
     a populated `linear.team.id`. If both are missing, surface
     "Run `/spec-kit-linear-install` first, or pass `--team <UUID>`"
     and exit without invoking the seed.
   - `LINEAR_API_KEY` is set in `.env` or the shell environment. The
     seed step is one of the two paths in the bridge that legitimately
     uses a long-lived key per Principle VI.

2. **Compose the invocation.** Translate the user-facing arguments
   into `src/seed.sh` flags:
   - `team=UUID` → `--team UUID`
   - `dry-run=true` → `--dry-run`
   - `workspace-only=true` → `--workspace-only`

3. **Execute the seeder.** Shell out:

   ```bash
   bash src/seed.sh <flags>
   ```

   The script:
   - Loads `linear-config.yml` (`src/config.sh`) when no `--team`
     override is supplied. On missing config the script halts with
     exit 2 and the actionable diagnostic "no --team UUID supplied
     and .specify/extensions/linear/linear-config.yml not found".
   - For each of the nine canonical lifecycle workflow states
     (per the table below), queries
     `workflowStates(filter: { team, name })`:
     - 0 matches → `workflowStateCreate` with the bridge-locked
       (name, type, color, position) tuple. Capture the returned UUID.
     - 1 match → capture the existing UUID and skip the mutation
       (idempotency — Principle II).
     - 2+ matches → surface a warning naming the duplicates and skip
       (per the contract, "never auto-pick on ambiguity").
   - Queries the team's stock workflow states via
     `team(id) { states { nodes { id name type } } }` and matches
     each of Todo / In Progress / Done by exact name + type, falling
     back to the first state whose type matches when the operator has
     renamed the stock states. The captured UUIDs go into the
     `default_state_uuids` map (per `contracts/linear-graphql-mutations.md`
     §4.3 — required for task-phase sub-issue states).
   - For each of the eighteen workspace-scoped labels (nine `phase:*`
     plus nine `task-phase:N` covering up to 9 task phases per spec),
     queries `issueLabels(filter: { name })` and `issueLabelCreate`s
     on a 0-match. Same idempotency semantics as workflow states.
     The `speckit-spec:NNN` labels are NOT seeded — those are minted
     lazily per spec by `src/reconcile.sh` (FR-004b).
   - Splices the two captured UUID maps into
     `.specify/extensions/linear/linear-config.yml` under
     `linear.workflow_state_uuids` (9 keys) and
     `linear.default_state_uuids` (3 keys), preserving every other
     field in the file verbatim. When the file doesn't yet exist
     (fresh consumer repo, pre-install), the script copies
     `config-template.yml` into place first and warns the operator
     to run `/spec-kit-linear-install` next to fill in
     `linear.team.id` and `linear.project.id`.

4. **Render the structured summary.** `src/seed.sh` emits a block to
   stderr at the end of every invocation per Principle VIII /
   FR-023. The block looks like:

   ```text
   ===== speckit.linear summary =====
   speckit.linear seed
   Created: 27   Updated: 0   Archived: 0
   Skipped: 0    Warned: 0    Errors: 0
   ==================================
   ```

   On a re-run against an already-seeded workspace, every count flips:
   `Created: 0`, `Skipped: 27`. That delta IS the proof the seed step
   is idempotent (SC-002 analogue for the workspace level).

5. **Handle the exit code.** Per `contracts/command-shapes.md` §4.6:
   - `0` — seed completed; config updated. Surface the captured
     `workflow_state_uuids` and `default_state_uuids` maps to the
     operator (see "Output" below).
   - `1` — Linear API transient failure. Some states may have been
     created, some not; the captured UUIDs for the successful
     creates were written to the config. Re-run the seed to complete.
   - `2` — workspace-level config error (no team resolvable,
     `linear-config.yml` missing AND no `--team`). The script halted
     before any Linear mutation. Surface the exact remediation it
     printed and do NOT auto-retry.
   - `3` — transport failure across the board. Linear was unreachable;
     no mutations issued. Recommend re-running once connectivity is
     restored.

## Workflow state schema (locked)

The seed creates exactly these nine workflow states on the target
team. Names, types, colors, and positions are the operator-facing
contract — Linear's UI lets the operator recolor or reorder them
later without breaking the bridge (lookups are by UUID per Principle
V), but the bridge's default seed values are:

| Position | Name | Type | Color | Lifecycle key (UUID map) |
|---|---|---|---|---|
| 1 | Specifying     | `unstarted` | `#6B7280` | `specifying`     |
| 2 | Clarifying     | `started`   | `#F59E0B` | `clarifying`     |
| 3 | Planning       | `started`   | `#3B82F6` | `planning`       |
| 4 | Tasking        | `started`   | `#8B5CF6` | `tasking`        |
| 5 | Red-team       | `started`   | `#EF4444` | `red_team`       |
| 6 | Implementing   | `started`   | `#10B981` | `implementing`   |
| 7 | Analyzing      | `started`   | `#06B6D4` | `analyzing`      |
| 8 | Ready-to-merge | `started`   | `#84CC16` | `ready_to_merge` |
| 9 | Merged         | `completed` | `#22C55E` | `merged`         |

The eighteen workspace labels are the two families:

- `phase:specifying`, `phase:clarifying`, `phase:planning`,
  `phase:tasking`, `phase:red_team`, `phase:implementing`,
  `phase:analyzing`, `phase:ready_to_merge`, `phase:merged` — the
  filter-by-phase aids that mirror each spec Issue's workflow state.
- `task-phase:1` … `task-phase:9` — the per-task-phase tags
  attached to each `## Phase N: <Name>` sub-issue. Nine entries
  covers the bridge's hard ceiling of nine task phases per spec.

Default-state capture (FR-005 / contracts §4.3) reads — but never
creates — three additional UUIDs from the team's stock workflow:

- `default_state_uuids.todo`        ← matches name "Todo",        type `unstarted`
- `default_state_uuids.in_progress` ← matches name "In Progress", type `started`
- `default_state_uuids.done`        ← matches name "Done",        type `completed`

If any stock state has been renamed, the seed falls back to the
first state whose type matches and surfaces a warning naming the
match.

## Output

Beyond the structured summary block, surface the captured UUID maps
back to the operator after a successful run. The script writes them
to `linear-config.yml`; the agent reads the file and prints a tidy
view like:

```text
Workflow state UUIDs (written to .specify/extensions/linear/linear-config.yml):
  specifying:     a1b2c3d4-…
  clarifying:     b2c3d4e5-…
  planning:       c3d4e5f6-…
  tasking:        d4e5f6a7-…
  red_team:       e5f6a7b8-…
  implementing:   f6a7b8c9-…
  analyzing:      a7b8c9d0-…
  ready_to_merge: b8c9d0e1-…
  merged:         c9d0e1f2-…

Default state UUIDs (Todo / In Progress / Done from the team's stock states):
  todo:           d0e1f2a3-…
  in_progress:    e1f2a3b4-…
  done:           f2a3b4c5-…
```

This view is the load-bearing handoff between seed and reconcile:
the next `/spec-kit-linear-push` reads these UUIDs from
`linear-config.yml` and never queries Linear by state name (FR-032 /
Principle V).

## When this command fires

- **Operator-driven.** `/spec-kit-linear-seed` from the AI agent
  chat — the canonical adoption path, run once per Linear workspace
  immediately after `/spec-kit-linear-install`.
- **On-demand shell.** `bash src/seed.sh [flags]` — same outcome
  per Principle II / FR-011.
- **NOT hook-wired.** Seed is one-shot per workspace and must not
  fire on every lifecycle transition — wiring it to a hook would
  waste 27 queries per `/speckit-*` invocation without any
  functional benefit.

If the operator runs `/spec-kit-linear-push` against a workspace that
has never been seeded, the reconciler halts with exit 2 and
"Run `/spec-kit-linear-seed` first" (FR-022). Re-running the seed in
that case completes the missing state and lets the next reconcile
proceed.

## Output channel discipline

- `stdout` of `src/seed.sh` is reserved for future structured-output
  modes (none in v1) — it stays empty during a normal seed.
- `stderr` carries:
  - per-mutation log lines (always on; the seed is short)
  - the final structured summary block per FR-023
- Filesystem writes are limited to `linear-config.yml` (and creating
  the parent directory on a fresh consumer repo). No other path is
  touched.

## Failure surface

Each failure mode is surfaced as a named warning or error in the
summary (Principle VIII) so the operator can act on it without
trawling logs:

- `no --team UUID supplied and .specify/extensions/linear/linear-config.yml
  not found` — exit 2. The seed halts before any Linear mutation;
  the operator runs `/spec-kit-linear-install` (or passes `--team`).
- `workflowStates query returned N matches for name='<name>' on team
  <team>; skipping create — operator must disambiguate manually` —
  an operator has manually created a duplicate workflow state with
  one of the bridge's canonical names. The seed never auto-picks
  per `contracts/linear-graphql-mutations.md` §2.1 — the operator
  deletes the rogue duplicate in Linear's UI and re-runs the seed.
- `workflowStateCreate <name> failed (transport)` — Linear 5xx after
  retry. Re-run the seed; whatever did succeed is captured in the
  config and the second run only fills the gaps.
- `default state '<key>': expected name='<expected>' type=<type>;
  matched '<other>' by type only` — the operator's team has renamed
  one of the stock workflow states (e.g. Todo → Backlog). The seed
  still captures the UUID by type-match and surfaces the rename so
  the operator knows their team is non-standard.
- `default state '<key>' not found on team <team>; task-phase
  sub-issues will fail until this state exists` — the operator has
  deleted one of the stock workflow states entirely. The seed skips
  the missing key, leaving the existing value in `linear-config.yml`
  untouched (or the placeholder zero-UUID if this is a first run).
  The operator restores the stock state in Linear or manually
  populates the UUID in the config.
- `<path> was missing; copied from <template>. Run
  /spec-kit-linear-install to fill in linear.team.id and
  linear.project.id.` — fresh-consumer-repo bootstrap. The seed
  emits the captured workflow-state and default-state UUIDs into the
  copied template, but the operator still has to run
  `/spec-kit-linear-install` to populate the team + project UUIDs
  before `/spec-kit-linear-push` will work.

## Related commands

- `/speckit.linear.install` — per-repo install ceremony. Run once
  per consumer repo BEFORE the first seed; populates
  `linear.team.id` and `linear.project.id` so the seed knows which
  team to mutate.
- `/speckit.linear.push` — the reconcile entry point. Requires the
  seed to have run at least once per workspace; halts with FR-022
  otherwise.
- `/speckit.linear.pull` — read-only Linear inspector. Works after
  install + seed even before the first push.
- `/speckit.linear.status` — drift report. Same prereq.

See `contracts/command-shapes.md` for the formal contract on each
and
[`quickstart.md`](../specs/001-spec-kit-linear-bridge/quickstart.md)
for the end-to-end operator walkthrough.

## FRs surfaced

This command implements (in whole or in part):

- **FR-005 / contracts §4.3** — captures `default_state_uuids` (Todo
  / In Progress / Done) for task-phase sub-issue states.
- **FR-021** — workspace seed operation; idempotent re-runs (a
  re-run against an already-seeded workspace produces `Created: 0`
  / `Skipped: 27`).
- **FR-022** — reconcile halts until the seed has run at least
  once; this command is that one-shot.
- **FR-023** — structured `summary::emit` block on stderr.
- **FR-032** — every Linear workflow state reference goes through
  the captured UUIDs (Principle V — UUID binding).
- **Principle VI** — direct GraphQL with `LINEAR_API_KEY`, matching
  the GitHub Action's wire format for symmetry across local + CI.
