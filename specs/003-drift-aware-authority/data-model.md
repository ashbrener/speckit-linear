# Data Model (Spec 003 — Drift-Aware Write Authority)

**Feature**: `003-drift-aware-authority`
**Phase**: 1 (design)
**Companions**: [spec.md](./spec.md) · [plan.md](./plan.md) · [research.md](./research.md)
**Extends**: [v0.1.0 data-model.md](../001-spec-kit-linear-bridge/data-model.md) — the canonical filesystem ↔ Linear mapping. Spec 003 modifies NO persistent entity; it adds in-memory drift-computation entities and one decision state machine, all transient within a single `reconcile.sh` invocation.

## 1. Overview

Spec 003 introduces **NO persistent entities and NO new on-disk state** (Principle II — no "what Linear last saw" sidecar; plan Technical Context → Storage). Every entity below is **in-memory state during one reconcile pass**, computed fresh per spec from (a) the spec-dir git log and (b) the live Linear Issue, then discarded. The committed `linear-config.yml` schema is unchanged from v0.1.0.

The drift entities feed the **warn-not-block decision flow** (§5), which is the heart of the amended Principle IV: surface the drift, let the operator decide, never refuse the write unilaterally.

## 2. The lifecycle-phase ladder (the one new lookup table)

The single genuinely new artifact. A fixed ordinal map used for the phase-ordering drift signal (research §2). It does NOT change how a phase is inferred — `parser::lifecycle_phase` (spec 001) is reused unchanged; this table only orders the phases it already emits.

| Phase token | Ordinal | `phase:*` label | Notes |
|---|---|---|---|
| `clarifying` | 0 | `phase:clarifying` | earliest |
| `specifying` | 1 | `phase:specifying` | |
| `planning` | 2 | `phase:planning` | |
| `tasking` | 3 | `phase:tasking` | |
| `implementing` | 4 | `phase:implementing` | |
| `ready_to_merge` | 5 | `phase:ready_to_merge` | PR open + ready |
| `merged` | 6 | *(none — FR-013)* | terminal; no phase label |

**Invariants**:

- The ladder is total and strictly ordered; every phase `parser::lifecycle_phase` can emit has exactly one ordinal.
- `merged` is the top ordinal and carries NO `phase:*` label (FR-013 / `src/reconcile.sh:1936`). Linear-recorded "merged" is detected by workflow state, not a label.
- Forward movement = `ordinal(disk) >= ordinal(linear)`. Backward-drift (phase signal) = `ordinal(linear) > ordinal(disk)` strictly.

## 3. In-memory drift entities

### 3.1 SpecDirRecency

The filesystem-evident recency key for one spec, replacing mtime (FR-053).

| Field | Type | Source | Notes |
|---|---|---|---|
| `commit_epoch` | integer \| unavailable | `git log -1 --format=%cI -- <spec_dir>` → epoch | `unavailable` when git history is empty (Edge Case 1, uncommitted spec). |
| `commit_iso` | ISO-8601 string \| empty | same `git log` | Human-display form for the warning row. |
| `worktree_path` | absolute path | invoking worktree | Which worktree this recency was computed in. |

**Type notes**: produced by the new `git_helpers::spec_dir_last_commit <spec_dir>`. `unavailable` is a distinct state from "old" — it disables the recency signal rather than firing it (research §1, Edge Case 1).

### 3.2 LinearRecordedState

What Linear currently holds for the spec Issue, read (not written) during drift computation.

| Field | Type | Source | Notes |
|---|---|---|---|
| `phase_ordinal` | integer (§2) | workflow state + `phase:*` label | Derived from the already-fetched issue. |
| `phase_token` | phase string | same | For the warning row's "Linear phase" cell. |
| `updated_at_epoch` | integer | issue `updatedAt` → epoch | Already selected at `src/reconcile.sh:1401`/`:1431`. |

### 3.3 BackwardDriftSignal

The per-spec drift verdict (FR-052). A struct combining the two inputs.

| Field | Type | Source | Notes |
|---|---|---|---|
| `phase_drift` | bool | `linear.phase_ordinal > disk.phase_ordinal` | Primary signal (research §2). |
| `recency_drift` | bool | `linear.updated_at_epoch - disk.commit_epoch > SKEW` | Secondary; `false` when recency `unavailable`. `SKEW = 120s` (plan A1). |
| `fired` | bool | `phase_drift OR recency_drift` | The overall backward-drift verdict (FR-052). |
| `signals` | set: `{phase_ordering, recency}` | which inputs fired | Named in the warning (FR-054). |
| `disk_phase_token` | phase string | disk-inferred (`parser::lifecycle_phase`) | Warning cell. |
| `linear_phase_token` | phase string | LinearRecordedState | Warning cell. |

**Invariants**:

- `fired == false` on every forward-movement and equal-phase write (SC-017 — zero false positives on the normal path).
- When `disk` phase is uninferrable (malformed artifacts), `phase_drift` is skipped and `fired = recency_drift` alone (Edge Case "phase cannot be inferred").
- A bridge self-write does not set `phase_drift` (it never advances Linear *ahead* of disk) and, on a no-drift re-run, does not set `recency_drift` because no new write advances `updatedAt` (idempotency, Edge Case 3).

### 3.4 WorktreeRecencyComparison

The multi-worktree ranking for the canonical-right-now pointer (FR-058/FR-059).

| Field | Type | Source | Notes |
|---|---|---|---|
| `touching_worktrees` | list of `{path, commit_epoch, branch}` | `git worktree list` × `spec_dir_last_commit` per worktree | Only worktrees that have the spec dir checked out. |
| `canonical_worktree` | path | max(`commit_epoch`) | The single worktree holding the most-recent spec-dir commit. |

**Type notes**: produced by the new `git_helpers::worktrees_touching_spec <feature_number>`. Ranking uses the spec-dir git-commit time (FR-059), NEVER branch name or mtime. Surfaced in the drift warning AND the spec Issue memory block (FR-058, extending FR-004). In the common single-worktree case the list has one entry and `canonical_worktree` is the invoking worktree.

### 3.5 DriftDisposition

The outcome chosen for a drifted spec.

| Value | Chosen by | Effect |
|---|---|---|
| `proceed` | interactive prompt (operator) OR non-interactive default OR `--on-drift=proceed` | Overwrite Linear from disk; record an override note in the summary. |
| `abort` | interactive prompt (operator) OR `--on-drift=abort` | Skip the spec, leave Linear unchanged (FR-057); record skipped-by-operator. |

**Invariants**:

- Disposition is only consulted when `BackwardDriftSignal.fired == true`. No-drift and forward writes never reach a disposition decision (write proceeds silently).
- An `abort` disposition produces ZERO Linear mutation for that spec — zero label-modified timestamps, zero comment posts, zero relation rewrites (FR-057 / SC-018).

## 4. Relationship to v0.1.0 entities (unchanged)

| v0.1.0 entity | Spec 003 interaction | Mutated? |
|---|---|---|
| `linear-config.yml` (Project/Team/state UUIDs) | read for per-Project drift scoping (Edge Case 5) | NO |
| Spec Issue (workflow state + `phase:*` label) | read for `LinearRecordedState`; written on `proceed` exactly as v0.1.0 reconcile writes it | written only on proceed/forward, as before |
| Memory block (FR-004, worktree paths + last-touched) | EXTENDED — gains the canonical-right-now worktree pointer (FR-058) | additive field |
| Summary block (FR-022, counts + warnings) | EXTENDED — gains drift WARNING rows, skipped-by-operator rows, `--retroactive` INFO row | additive rows |

## 5. The warn-not-block decision flow (state machine)

The core control flow per spec, replacing the v1.0.0 branch-gate early-return. This is the amended Principle IV in executable form.

```text
                         ┌─────────────────────────────┐
                         │  reconcile a spec NNN         │
                         │  (from ANY branch — FR-051)   │
                         └──────────────┬──────────────┘
                                        │
                        compute disk-inferred phase
                        (parser::lifecycle_phase, reused)
                                        │
                        read LinearRecordedState
                        (phase + updatedAt — already fetched)
                                        │
                        compute BackwardDriftSignal (§3.3)
                        phase_drift OR recency_drift
                                        │
                 ┌──────────────────────┴───────────────────────┐
                 │ fired == false                                │ fired == true
                 │ (forward / equal / no-drift)                  │ (Linear is ahead)
                 ▼                                               ▼
        ┌─────────────────┐                          emit named WARNING row (FR-054):
        │ WRITE silently   │                          spec, disk phase, Linear phase,
        │ (normal path)    │                          signal(s), worktree comparison (FR-058)
        │ no prompt, no    │                                       │
        │ warning (SC-017) │                       ┌───────────────┴────────────────┐
        └────────┬────────┘                        │ interactive ([[ -t 0 ]])        │ non-interactive
                 │                                  ▼                                 ▼
                 │                        prompt proceed/abort              consult --on-drift
                 │                        (FR-055; empty=abort, A5)          (default: proceed-and-warn;
                 │                                  │                         FR-056; abort skips)
                 │                        ┌─────────┴─────────┐                       │
                 │                        ▼                   ▼              ┌─────────┴─────────┐
                 │                   DriftDisposition     DriftDisposition   ▼                   ▼
                 │                    = proceed            = abort        proceed             abort
                 │                        │                   │              │                   │
                 ▼                        ▼                   ▼              ▼                   ▼
         idempotent converge   WRITE (overwrite Linear   SKIP spec,    WRITE + WARNING     SKIP spec,
         (zero churn if         from disk) + record       leave Linear  row (auditable)     leave Linear
         unchanged — SC-022)    override in summary       unchanged     (SC-019 no hang)    unchanged
                                                          (FR-057/SC-018)                   (FR-057)
```

**State-machine invariants**:

- **Never blocks**: every path either writes or is an explicit operator/flag-chosen skip. The bridge never refuses a write of its own accord (the deleted v1.0.0 behavior). This is the Principle VIII correction.
- **No hang (SC-019)**: the interactive branch is gated on `[[ -t 0 ]]`; a non-TTY stdin always takes the non-interactive branch and resolves deterministically via `--on-drift` (default proceed-and-warn, Edge Case 6).
- **Idempotent (SC-022 / FR-063)**: the `fired == false` write path is the existing v0.1.0 converge logic; a second unchanged run produces zero observable churn, including through the drift check (the check is read-only).
- **Per-Project scope (Edge Case 5)**: drift is computed within one owning Linear Project; the same feature number in another consumer repo is never compared cross-repo.
