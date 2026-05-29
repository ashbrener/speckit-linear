# Constitution v2.0.0 Re-Check — Spec 003 (Drift-Aware Write-Authority) — T354

**Date**: 2026-05-29
**Scope**: spec 003 (drift-aware write-authority) as-built, against `.specify/memory/constitution.md` **v2.0.0** (8 principles, amended Principle IV).
**Verdict**: **8 Conform / 0 Drift.** Cleared for the v0.2.0 release (pending the T353 downstream dogfood + CI green).

## Summary

Spec 003 IS the implementation of v2.0.0's amended Principle IV. The plan-time Constitution Check (PASS) holds as-built: the FR-025 branch-gate has been removed from the write path, backward-drift is detected and surfaced (never blocks), and the operator decides. This is the canonical realization of "Write-Authority Follows The Filesystem (Drift-Aware)" + Principle VIII (Surface, Don't Enforce).

| Principle | Verdict |
|---|---|
| I. Filesystem Is The Single Source of Truth | Conforms — strengthened |
| II. Reconcile, Never Event-Push | Conforms |
| III. Layered Idempotency (D + E) | Conforms |
| IV. Write-Authority Follows The Filesystem (Drift-Aware) | **Conforms — this spec implements it** |
| V. UUID-Based Binding, Per-Repo Config | Conforms (untouched) |
| VI. OAuth-First, Keys-At-The-Edges | Conforms (untouched) |
| VII. Memory-Just-Works, Escape Hatches Beside It | Conforms — extended |
| VIII. Surface, Don't Enforce — Observable Failure | **Conforms — poster child** |

## Per-principle

### I. Filesystem Is The Single Source of Truth — Conforms (strengthened)

Spec 003 makes the filesystem *more* authoritative, not less: write-authority now follows the filesystem state of the invoking worktree (most-recent commit touching `specs/NNN/`), rather than a branch-name heuristic. The recency comparator (`git_helpers::spec_dir_last_commit`, `git log -1 --format=%cI`) reads commit time, never mtime — survives clone/checkout/worktree. Sync stays unidirectional (disk → Linear); drift detection READS Linear's `updatedAt` to decide whether to warn, never to write back to disk.

### II. Reconcile, Never Event-Push — Conforms

The drift comparator + disposition run inside the existing reconcile loop; no event-push introduced. `compute_drift` is a pure function (no side effects). Idempotency preserved: a no-op reconcile with no drift writes nothing and warns nothing.

### III. Layered Idempotency (D + E) — Conforms

Spec 003 touches Layer D (reconcile) only. Layer E (webhook) is unchanged and remains exempt from authority gating (PR head ref implies authority). No double-write surface.

### IV. Write-Authority Follows The Filesystem (Drift-Aware) — Conforms (this spec implements it)

This is the load-bearing check. v2.0.0 amended Principle IV to: "ANY worktree MAY write; the branch is a heuristic not a gate; the bridge MUST detect backward-drift and SURFACE it, MUST NOT block; the operator decides." Spec 003 as-built:

- **Gate removed**: the `if ! is_authoritative_for_spec → read_only_display → return` block is gone from the write path (`process_spec`). Any worktree writes (FR-051). Verified: `git_helpers::is_authoritative_for_spec` survives, used only as a non-gating display hint by `status.sh` (FR-026/FR-060).
- **Backward-drift surfaced, not blocked**: `compute_drift` flags Linear-ahead-of-disk (phase ordinal) or Linear-newer (updatedAt vs commit time, ±120s skew). `_drift_disposition` proceeds by default (warn-and-write); `--on-drift=abort` or interactive empty-enter aborts the single drifted spec (surfaced, not a hard error).
- **Operator decides**: interactive `/dev/tty` prompt + `--on-drift` flag.

The constitution's own Principle IV rules name spec 003's FR-051..FR-064 as their implementation, so the principle is satisfied by construction.

### V. UUID-Based Binding — Conforms

Untouched. No change to UUID resolution or per-repo config.

### VI. OAuth-First, Keys-At-The-Edges — Conforms

Untouched. Drift detection uses already-available Linear fields (`updatedAt`); no new key surface.

### VII. Memory-Just-Works, Escape Hatches Beside It — Conforms (extended)

Memory block extended with the most-recent-commit-touching-spec pointer (FR-058) — more "just works" signal. Escape hatches beside it: `--on-drift=abort|proceed`, the interactive prompt, and the (deprecated, no-op) `--retroactive` alias for one release.

### VIII. Surface, Don't Enforce — Observable Failure — Conforms (poster child)

Spec 003 is the clearest expression of Principle VIII in the codebase. The old FR-025 branch-gate ENFORCED (silently skipped writes from non-feature worktrees). Spec 003 replaces enforcement with surfacing: backward-drift produces a visible WARNING (recorded in the structured summary), and the write proceeds unless the operator opts out. Failure is observable; the bridge informs, it does not police.

## Architectural constraints — no drift

No new runtimes. Spec 003 adds zero dependencies: bash 4+ / curl / jq / gh / git. Drift detection uses `git log` (already a dependency) + Linear's existing `updatedAt` field.

## Verdict

**8 Conform / 0 Drift.** Spec 003 is constitutionally clean as-built and is itself the implementation of v2.0.0's amended Principle IV. Cleared for v0.2.0 — the release tag (T355) gates on the T353 downstream dogfood (live, operator-run) + CI green.
