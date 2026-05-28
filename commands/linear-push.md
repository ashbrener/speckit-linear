---
name: speckit.linear.push
description: Reconcile filesystem spec state into Linear (FS → Linear, idempotent)
arguments:
  - name: spec
    description: feature number (e.g., 003) to sync only that spec; default behaviour is to sync all specs
    optional: true
  - name: dry-run
    description: log mutations without executing them
    optional: true
  - name: retroactive
    description: "DEPRECATED (Constitution Principle IV v2.0.0 / spec 003 FR-061) — first-time-adoption mode (FR-014); historically bypassed the FR-025 write-authority gate. Once spec 003 lands this becomes a no-op alias because writing from any branch is the default. Implies --all"
    optional: true
---

# `/speckit.linear.push`

## Summary

Reconcile every `specs/NNN-feature/` directory in the consumer repo
into Linear (filesystem → Linear, idempotent, write-authority-gated).

Reconcile the consumer repo's `specs/NNN-feature/` directories into
Linear. This is the load-bearing path that mirrors filesystem state
into Linear Issues, task-phase sub-issues, checklists, blocking
relations, clarify-session comments, and lifecycle-phase labels.

**Direction**: one-way, filesystem → Linear (Principle I).
**Semantics**: idempotent (Principle II — zero-churn on unchanged
state, SC-002).
**Authority**: drift-aware (Constitution Principle IV v2.0.0). Any
worktree may write a spec's Linear state; the filesystem is the
authority. On backward-drift (Linear ahead of disk) the bridge
surfaces a warning and lets the operator decide — it does not refuse
the write. Spec 003 (`003-drift-aware-authority`, FR-051..FR-064)
implements this and SUPERSEDES the v1.0.0 FR-025 branch-gate. Until
spec 003 lands, the shipped reconciler still applies the FR-025 gate
(use `retroactive` to bypass it for first-time adoption). FR-026's
surfacing obligation is retained throughout.
**Layer**: this command implements Layer D. The GitHub Action template
that ships with `/spec-kit-linear-install` implements Layer E and is
out of scope here.

The deterministic work happens in `src/reconcile.sh`; this command is
the AI-agent entry point that runs the shell and surfaces its output.
The formal API contract is `contracts/command-shapes.md` §1
(`speckit.linear.push`); the mutations issued are enumerated in
`contracts/linear-graphql-mutations.md` §4. Operators reading this
file are looking at the markdown the AI agent reads — the same
operations are available via `bash src/reconcile.sh` directly. For
the operator-facing end-to-end walkthrough see
[`quickstart.md`](../specs/001-spec-kit-linear-bridge/quickstart.md).

## Usage

| Argument | Default | Meaning |
|---|---|---|
| `spec` | (none — uses `--all`) | Feature number (e.g. `003`). Reconcile only this spec. |
| `dry-run` | false | Log every mutation that WOULD fire; issue none. Safe inspection mode. |
| `retroactive` | false | **DEPRECATED** (Constitution Principle IV v2.0.0 / spec 003 FR-061). First-time-adoption mode (FR-014 / User Story 5). In the shipped (pre-spec-003) reconciler it bypasses the FR-025 write-authority gate so every enumerated spec is reconciled regardless of the worktree's current branch — intended for the first reconcile after installing the bridge into a repo with existing specs. Implies `--all`; suppresses "skipped because non-authoritative" warnings and surfaces a single aggregate INFO row naming the bypass count. Once spec 003's drift-aware model lands, write-from-any-branch is the default and this flag becomes a no-op alias (it emits one deprecation INFO row and changes nothing); it is removed in a later release. |

Exactly one of `spec` or "all specs" is in effect — if `spec` is not
passed, the reconciler walks every `specs/NNN-*/` directory in the
consumer repo. If `retroactive` is set and `spec` is not, `--all` is
implied. `dry-run` is orthogonal to `retroactive` and `spec`.

### CLI shape

```text
speckit.linear.push [--spec NNN | --all] [--dry-run] [--retroactive]
```

Default: `--all`.

## Algorithm (what the AI agent executes)

1. **Verify prerequisites.** Refuse to proceed if any of these fail.
   - Bash 4 or newer is on `PATH`. Run `bash --version` and confirm
     the major version number is `≥ 4`. macOS ships bash 3.2 by
     default; the operator must `brew install bash` and ensure
     `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash`
     (Intel) is earlier on `PATH` than `/bin/bash`.
   - The consumer repo's config is present at
     `.specify/extensions/linear/linear-config.yml`. If absent,
     surface "run `/spec-kit-linear-install` first" and exit; do NOT
     attempt to run the reconciler.
   - `jq` is installed (`command -v jq`). `curl` is installed
     (`command -v curl`). `git` is installed and the working directory
     is inside a git working tree.

2. **Compose the invocation.** Translate the user-facing arguments
   into `src/reconcile.sh` flags:
   - `spec=NNN` → `--spec NNN`
   - no `spec` and no `retroactive` → `--all`
   - `dry-run=true` → `--dry-run`
   - `retroactive=true` → `--retroactive`
   - Always pass `--quiet` UNLESS the user has explicitly asked for
     verbose output, since the structured summary is the
     operator-visible contract per FR-023.

3. **Execute the reconciler.** Shell out:

   ```bash
   bash src/reconcile.sh <flags>
   ```

   The script:
   - Loads + validates `linear-config.yml` (`src/config.sh`). On
     missing/malformed UUIDs it halts with exit 2 and an
     operator-actionable diagnostic (Principle VIII).
   - Enumerates the requested specs and processes each:
     - Applies write authority per Constitution Principle IV. Under
       v2.0.0 (drift-aware, spec 003) any worktree may write; the
       bridge computes a backward-drift signal and surfaces a warning
       when Linear is ahead, but does not refuse the write. Until spec
       003 lands, the shipped reconciler still gates writes on the
       worktree's branch matching `<NNN>-…` (legacy FR-025), with
       non-authoritative invocations taking a read-only display path;
       `--retroactive` bypasses that legacy gate. Either way the
       spec's current Linear state is surfaced (FR-026 / FR-060).
     - Infers the lifecycle phase from artifacts on disk
       (`spec.md` → `clarifying` → `planning` → `tasking` →
       `red_team` → `implementing` → `analyzing` → `ready_to_merge` →
       `merged`) per FR-012, with PR-state hints from
       `git_helpers::pr_state` (gh CLI → git-only branch-reachability
       fallback per FR-030) for the terminal `ready_to_merge` and
       `merged` states.
     - Find-or-creates the spec Issue by `speckit-spec:NNN` label
       scoped to the configured Project (FR-004b). On race
       (>1 match) keeps the most-recently-updated and surfaces the
       others as warnings. On retroactive sync sets `stateId`
       directly to the inferred end-state (FR-014).
     - Rewrites the spec Issue's description in canonical order
       (overview → memory block → diagrams) per FR-004. The bridge
       fully owns the description body; any prior content is
       discarded. Operator annotations belong in Linear comments per
       FR-008 (the canonical escape hatch the bridge never touches).
       The memory block surfaces lifecycle phase, current task phase,
       branch, worktree path(s), last-touched timestamp, the GitHub
       source link, operator assignee (FR-034), and the Fibonacci
       estimate rollup (FR-035).
     - Reconciles task-phase sub-issues per `## Phase N: <Name>`
       header in `tasks.md` (FR-005). Each sub-issue carries a
       checklist mirror with a read-only header (FR-006). Workflow
       state is Todo / In Progress / Done based on checklist
       completion ratio.
     - Wires inter-task-phase blocking relations (FR-007) by reading
       "Phase N depends on Phase M" hints from `plan.md` /
       `tasks.md`. Native `save_issue.blocks` per the MCP runtime
       probe; pre-queries existing relations to avoid duplicate-add.
     - Mirrors each `### Session YYYY-MM-DD` clarify block under
       `## Clarifications` to a Linear Issue comment, idempotent via
       a deterministic comment marker (FR-008 + FR-015).
     - Ensures the spec Issue carries `phase:<current>` and
       `speckit-spec:NNN` labels; strips stale `phase:*` labels.
       When phase is `merged`, no `phase:*` label is set (FR-013).
       FR-036 agent labels — see spec for stamping rules.

4. **Render the structured summary.** The script emits a block to
   stderr at the end of every invocation (FR-023). The block looks
   like:

   ```text
   ===== speckit.linear summary =====
   speckit.linear reconcile — spec 003
   Created: 1   Updated: 4   Archived: 0
   Skipped: 0   Warned: 1     Errors: 0
   ----- warnings -----
   - spec 003: 2 task line(s) outside any ## Phase header
   ==================================
   ```

   Surface this verbatim to the operator. The block IS the
   operator-visible result of the command per Principle VIII Rule 1.

5. **Handle the exit code.** Per `contracts/command-shapes.md` §1.6:
   - `0` — success (possibly with warnings). Report success; include
     the summary block verbatim.
   - `1` — partial failure. Some specs failed; others succeeded.
     Surface the warnings from the summary and recommend re-running
     `/speckit.linear.push spec=<NNN>` for any spec named in the
     warnings list.
   - `2` — workspace config error (per FR-022). The script halted
     before any mutation. Surface the exact remediation the script
     printed (typically: run `/spec-kit-linear-install` or
     `/spec-kit-linear-seed`). Do NOT retry automatically.
   - `3` — transport failure. Linear was unreachable; nothing was
     written. Recommend re-running once network connectivity is
     restored.

## When this command fires

- **Operator-driven.** `/speckit.linear.push` from the AI agent
  chat — the primary on-demand path for recovery from missed hooks
  and ad-hoc reconcile.
- **Auto-fired hooks** (post-install via `/spec-kit-linear-install`).
  Every `/speckit-*` lifecycle command in `.specify/extensions.yml`
  is wired to invoke this command per FR-031.
- **Local git hooks** (`post-checkout`, `post-commit`, `post-merge`)
  invoke `src/reconcile.sh` directly per FR-033, bypassing this
  markdown and skipping the prerequisite re-verification.

All three paths converge on `src/reconcile.sh` (FR-011 — same
outcome regardless of trigger).

## Output channel discipline

- `stdout` of `src/reconcile.sh` is reserved for future
  structured-output modes (none in v1) — it stays empty during a
  normal reconcile.
- `stderr` carries:
  - per-mutation log lines (suppressed by `--quiet`)
  - the final structured summary block (always, unless
    `sync.emit_summary: false` is set in `linear-config.yml`)
- No filesystem writes (Principle I + FR-016). The reconciler reads
  the spec directories, the config, and the git state; everything
  else flows out over the Linear API.

## Failure surface

Each failure mode is surfaced as a named warning in the summary
(Principle VIII) so the operator can act on it without trawling
logs:

- `spec NNN: spec.md missing or empty; skipping` — edge case from
  spec § 1. Reconcile continues with the next spec.
- `spec NNN: N task line(s) outside any ## Phase header` — FR-024.
  Tasks lacking a phase grouping are still flagged and the rest of
  the spec syncs.
- `duplicate spec Issues with label speckit-spec:NNN: kept <id>,
  archiving N loser(s)` — FR-004b race resolution. The most-recently
  -updated wins; losers are flagged for archival.
- `clarify-session DATE: existing comment body diverges from
  spec.md; not overwriting` — FR-015 + contracts §9. Hand-edits to
  comments are preserved; the reconciler does not silently overwrite.
- `non-authoritative worktree (current branch '<branch>'); read-only
  mode` — legacy FR-025 (shipped, pre-spec-003) behaviour from `main`
  or an unrelated branch; the operator switches worktrees or passes
  `retroactive=true` to bypass the gate (`retroactive: <N> spec(s)
  reconciled despite non-authoritative worktree …`). Under Principle
  IV v2.0.0 (drift-aware, spec 003) this is REPLACED by a
  `backward-drift for spec NNN — Linear is ahead` WARNING row that
  surfaces the drift but does not block the write; the operator
  decides (interactive prompt, or `--on-drift` non-interactively).
- `linear-config.yml not found at <path>; run
  /spec-kit-linear-install` — FR-022 halt. Exit code 2.

## Related commands

- `/speckit.linear.pull` — read-only inspect Linear's current view
  (works from any worktree, never mutates).
- `/speckit.linear.status` — drift report (filesystem vs Linear)
  without actually issuing mutations.
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

- **FR-001 / FR-011** — convergent reconcile across hook and manual paths.
- **FR-004** — bridge-owned spec Issue description (overview → memory → diagrams; no fence markers).
- **FR-004b** — `speckit-spec:NNN` workspace label as the stable lookup key.
- **FR-005 / FR-006** — task-phase sub-issues with mirrored checklists.
- **FR-007** — inter-task-phase blocking relations.
- **FR-008 / FR-015** — clarify-session comments (operator escape hatch).
- **FR-012 / FR-013** — lifecycle-phase inference and `phase:*` label hygiene.
- **FR-014** — retroactive first-time-adoption mode (deprecated to a no-op alias by spec 003 FR-061).
- **FR-016 / FR-017** — unidirectional sync; no PR mutations.
- **FR-022** — halt with operator-actionable diagnostic on unseeded workspace.
- **FR-023 / FR-024** — structured summary block; named warnings.
- **FR-025 / FR-026** — write authority. v1.0.0 per-spec branch-gate (FR-025) SUPERSEDED by Constitution Principle IV v2.0.0 / spec 003 drift-aware model (FR-051..FR-060); FR-026's current-state surfacing is retained (FR-060).
- **FR-030** — gh CLI primary / git-only fallback for PR-state hints.
- **FR-031 / FR-033** — auto-fire from `after_*` hooks and local git hooks.
- **FR-034** — operator assignee captured into the memory block.
- **FR-035** — Fibonacci `[N]` estimate rollup.
- **FR-036** — agent labels — see spec for stamping rules.
