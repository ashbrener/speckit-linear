# Dogfood 003 — Drift-Aware Write-Authority (spec 003)

**Status: OPERATOR-PENDING.** The live run requires the downstream multi-spec consumer repo (the one that motivated this spec) + its Linear workspace, which is not reconcilable from the bridge's own repo (FR-046 self-install guard; and it's a separate operator-owned repo). This file is the dogfood **plan + acceptance checklist**; the operator runs it from the consumer repo and records results below.

## Why this dogfood

Spec 003 was motivated by a live finding: a **merged spec** (feature branch deleted) stayed stuck at its pre-merge lifecycle state because the v1.0.0 FR-025 branch-gate refused to write from `main`. Spec 003 removes that gate (FR-051) and replaces it with drift-aware surfacing. This dogfood confirms the fix end-to-end against the original failing scenario.

## Pre-requisites

- The downstream consumer repo with multiple specs (several merged) and its `linear-config.yml` bound to a Linear workspace.
- The bridge re-vendored at the spec-003 build (or v0.2.0 once tagged): `specify extension add linear --from https://github.com/ashbrener/spec-kit-linear/archive/refs/tags/v0.2.0.zip` (use the branch archive until v0.2.0 is tagged).
- `LINEAR_API_KEY` resolvable (env var recommended — operator-global, propagates across worktrees; see design-questions.md Q2 / issue #20).

## Acceptance checklist (the SCs this dogfood proves)

- [ ] **SC-014** — every merged spec reconciles to `Merged` **from `main` with zero flags**. Run `bash src/reconcile.sh --all` from `main`; confirm each merged spec's Linear Issue flips to Merged (no `--retroactive` needed). _Note: also depends on the v0.1.2 merge-detection fix (#15) so `pr_state` resolves merged from any branch._
- [ ] **SC-015** — the retroactive first-reconcile converges 100% of specs without spurious intermediate-phase artifacts (FR-014).
- [ ] **SC-017** — no spurious backward-drift warnings fire on a forward/clean reconcile (specs whose disk state is at-or-ahead of Linear write silently).
- [ ] **Backward-drift path** — artificially make Linear ahead of disk for one spec (e.g. advance its Linear state), reconcile from `main`: confirm a WARNING surfaces and (a) interactively prompts proceed/abort, (b) `--on-drift=abort` skips that spec, (c) `--on-drift=proceed` writes + warns.
- [ ] **`--retroactive` deprecation (FR-061)** — confirm `--retroactive` still runs but emits one deprecation INFO row and otherwise behaves as the default.
- [ ] **Multi-worktree pointer (FR-058)** — with the spec checked out in two worktrees, confirm the memory block records the most-recent-commit-touching-spec pointer.

## Results (operator fills in)

| Field | Value |
|---|---|
| Date | _pending_ |
| Consumer repo / spec count | _pending_ |
| Bridge version | _pending_ |
| SC-014 (merged-from-main, zero flags) | _pending_ |
| SC-015 (retroactive converges) | _pending_ |
| SC-017 (no spurious drift warnings) | _pending_ |
| Backward-drift prompt + `--on-drift` arms | _pending_ |
| Rough edges | _pending_ |

## Gate

The v0.2.0 release tag (T355) is gated on this dogfood passing SC-014 / SC-015 / SC-017 + CI green on the spec 003 PR. Until the operator records a passing run here, v0.2.0 stays untagged; the spec 003 PR can still be reviewed/merged to `main` on the strength of the 274 unit tests + the constitution re-check, with the tag following the live confirmation.
