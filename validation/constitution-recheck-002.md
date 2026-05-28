# Constitution v1.0.0 Re-Check — Spec 002 (Install Ergonomics) — T270

**Date**: 2026-05-28
**Scope**: spec 002 (install-ergonomics redesign) as-built, against `.specify/memory/constitution.md` v1.0.0 (8 principles).
**Verdict**: **8 Conform / 0 Drift.** Cleared for v0.1.1 release.

## Summary

Spec 002 changes the install ceremony (`src/install.sh`) only — it adds viewer-driven discovery, two safety guards, and backwards-compat hardening. It does not touch the reconcile loop's data model, the write-authority gate, or the Linear wire format. The one principle that warranted scrutiny at plan time — **VI (OAuth-First, Keys-At-The-Edges)**, because the API key becomes a load-bearing operator input — re-checks clean: the key is still confined to the sanctioned edges. No principle amendment required.

| Principle | Verdict |
|---|---|
| I. Filesystem Is The Single Source of Truth | Conforms |
| II. Reconcile, Never Event-Push | Conforms (install is one-shot bootstrap, not in the reconcile path) |
| III. Layered Idempotency (D + E) | Conforms (install untouched by D/E; re-runnable) |
| IV. Write-Authority Follows The Worktree | Conforms (install is workspace-level, not per-spec write) |
| V. UUID-Based Binding, Per-Repo Config | Conforms — strengthened |
| VI. OAuth-First, Keys-At-The-Edges | Conforms with justification (see below) |
| VII. Memory-Just-Works, Escape Hatches Beside It | Conforms |
| VIII. Surface, Don't Enforce — Observable Failure | Conforms — exemplified by FR-046/FR-049 |

## Per-principle

### I. Filesystem Is The Single Source of Truth — Conforms

Install writes `linear-config.yml` from Linear-discovered identity (team/project UUIDs, operator). This is a **one-shot bootstrap**, not reverse-sync: it establishes the binding the filesystem then owns. Every subsequent reconcile still reads `linear-config.yml` as truth and pushes disk → Linear unidirectionally. The discovery flow runs only at install, never during reconcile.

### II. Reconcile, Never Event-Push — Conforms

Install is an event-style ceremony (runs once on operator action), explicitly outside the reconcile loop. The reconcile path (`src/reconcile.sh`) is unchanged by spec 002. Boundary is clean.

### III. Layered Idempotency (D + E) — Conforms

Install does not participate in Layer D (reconcile) or Layer E (webhook). It is re-runnable: the discovery flow re-prompts; `quick_validate_binding` re-validates; writing `linear-config.yml` is overwrite-idempotent. No double-write surface introduced.

### IV. Write-Authority Follows The Worktree — Conforms

Install is workspace-level configuration (team/project resolution + hook registration), not a per-spec Linear mutation. The FR-025 write-authority gate scopes only spec-level writes during reconcile; install is correctly out of its scope (consistent with how `seed` is treated).

### V. UUID-Based Binding, Per-Repo Config — Conforms (strengthened)

Spec 002 **increases** UUID-binding rigor: the operator never sees or types a UUID, yet the resolved `team_id` / `project_id` / `operator.user_id` written to `linear-config.yml` are still real UUIDs (resolved by the install from `viewer` / `teams` / `projects` / `projectCreate`). Lookup remains UUID-keyed. The ergonomic layer is purely operator-facing; the persisted binding is UUID-pure.

### VI. OAuth-First, Keys-At-The-Edges — Conforms (justified)

Spec 002 makes `LINEAR_API_KEY` a load-bearing operator input at install time. Re-check confirms the key stays at the sanctioned edges:

- The key is read only in `src/graphql.sh` (the GraphQL boundary), `src/install.sh`, `src/seed.sh`, and `src/status.sh` (the four edge scripts that legitimately talk to Linear directly) — grep-confirmed; never in the reconcile data-model code.
- FR-037 writes the key to `.env` (gitignored) — the canonical edge store — never to a committed file.
- The install is the **bootstrap that establishes** the `.env` edge; runtime reconciles from agent sessions still route through the official MCP per Principle VI Rule 1.
- The `.env` write surface is additive to v0.1.0's three existing sanctioned edges (seed, git hooks, GitHub Action).

No amendment required — the plan-time justification holds in the as-built.

### VII. Memory-Just-Works, Escape Hatches Beside It — Conforms

Install's "memory just works" default: API key auto-detected from `.env`/env, team auto-picked when singular, project pickable or creatable inline — minimal operator friction. Escape hatches beside it: `--team`/`--project` flags (FR-044), `--non-interactive` (FR-045), `--dev` local install. Both halves present.

### VIII. Surface, Don't Enforce — Observable Failure — Conforms (exemplified)

FR-046 (self-install) and FR-049 (vendored `.git/`) are textbook applications: FR-046 surfaces a clear exit-2 error before any filesystem write (observable failure, no silent corruption); FR-049 **warns and proceeds** rather than auto-deleting the operator's `.git/` (surface, don't enforce — operator consent required). 98 surfacing sites in `install.sh` confirm the structured-report discipline.

## Architectural constraints — no drift

No new runtimes. Spec 002 adds zero dependencies: still bash 4+ / curl / jq / gh / git. The discovery flow uses the existing `graphql::query` / `graphql::mutate` surface — no new HTTP client, no new external tool.

## Verdict

**8 Conform / 0 Drift.** Spec 002 is constitutionally clean as-built. The Principle VI expansion (API key load-bearing at install) was anticipated at plan time and re-checks clean. Cleared for the v0.1.1 release tag (T271).
