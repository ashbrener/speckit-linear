# Changelog

All notable changes to **spec-kit-linear** are recorded here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing landed yet for v0.1.3. Add entries here as they merge._

## [0.1.2] — 2026-05-29

Two reconcile/install bug fixes surfaced by downstream dogfood, plus the governance groundwork for the v0.2.0 drift-aware authority work.

### Fixed

- **Worktree-safe git hooks path (FR-033, #14)** — `install.sh` hardcoded `.git/hooks`, which is wrong in a git **worktree** (where `.git` is a file and hooks live elsewhere). FR-033's local-hook install silently wrote to a path git never reads for any worktree-based operator. Now resolves the hooks directory via `git rev-parse --git-path hooks` (worktree-safe, honors `core.hooksPath`), with a `.git/hooks` fallback and `mkdir -p`.
- **Detect merged specs from any branch (FR-013/FR-030, #15)** — a merged spec's Linear Issue stayed stuck at its pre-merge lifecycle state when reconciled from a non-feature branch. Root cause: `git_helpers::pr_state` queried `gh pr view --json merged`, but `merged` is not a valid `gh` JSON field — the call always errored and fell through to a git-only branch-reachability probe that can't resolve a deleted/non-local feature branch. Now uses `gh pr list --head <branch> --state all` (resolves by HEAD ref via the API regardless of checked-out branch); lifecycle correctly resolves to `merged` from any worktree.

### Changed — Governance

- **Constitution amended to v2.0.0 (#13)** — Principle IV redefined from "Write-Authority Follows The Worktree" (branch-gate enforcement) to **"Write-Authority Follows The Filesystem (Drift-Aware)"**: any worktree may write; the bridge surfaces backward-drift but does not block (Principle VIII). This is a backward-incompatible _governance_ change (hence the constitution's MAJOR bump) that enables spec 003; it does **not** alter extension runtime behavior in this release — the drift-aware reconcile logic ships when spec 003 is implemented. The extension version line (0.1.2) and the constitution version line (2.0.0) are independent.

### Added — Tooling & docs

- **Dogfood-script interactive-flow block + `linear-install.md` vocab pass (#12)** — `scripts/dogfood.sh --interactive-flow` exercises spec 002's discovery install against a throwaway sandbox repo.
- **Community-catalog submission draft (#10)** — `validation/community-catalog-submission.md` with the ready-to-paste catalog entry + submission checklist.
- **Open design-questions parking lot (#18)** — `validation/design-questions.md` (inert, DO-NOT-IMPLEMENT) capturing the spec→Project question (tracking issue #17).

### Housekeeping

- Scrubbed private project names + local filesystem paths from public docs (#16).

## [0.1.1] — 2026-05-28

Install ergonomics redesign (spec 002) plus three dogfood-surfaced reconcile hotfixes. The headline change: the Linear API key is now the only thing an operator brings to install — team and project are discovered interactively, no UUIDs surfaced.

### Added — Install ergonomics redesign (spec 002)

- **Viewer-driven install discovery flow (FR-037..FR-043)** — the API key is now the only thing the operator brings. `/speckit.linear.install` resolves the key from `.env` (or env var, or interactive prompt), verifies via Linear's `viewer` query, then presents:
  - A numbered team picker (auto-picked silently when the workspace has one team); operator never sees a UUID.
  - A numbered project picker with a final "Create new project" option; if chosen, install issues `projectCreate` with the project name (defaults to repo dir) and surfaces the new project's Linear URL in the summary.
- **Backwards-compat preserved (FR-044, FR-045)** — `bash src/install.sh --team <UUID> --project <UUID>` still works bit-for-bit for CI / scripted installs. `--non-interactive` strictness tightened: now halts with a clear error rather than falling through to interactive prompts when flags are missing.
- **Self-install safety guard (FR-046)** — `install.sh` detects the `source == target` case (operator runs `specify extension add /path/to/spec-kit-linear --dev` from inside `/path/to/spec-kit-linear` itself) and exits with exit code 2 + a clear remediation message. Prevents the recursive `.specify/extensions/linear/.specify/extensions/linear/...` directory mess that hit macOS filename length limits during the first community-style dogfood.
- **Vendored `.git/` detection (FR-049)** — `install.sh` detects a vendored `.git/` directory at `.specify/extensions/linear/.git/` (caused by the spec-kit CLI's `--dev` install vendoring the source's full git tree) and surfaces a warning row in the dependency-verification report. Operator-actionable workaround documented in the install summary; no auto-delete (operator's filesystem).
- **README install commands corrected (FR-047)** — `--from` flag now requires the GitHub archive ZIP URL (`/archive/refs/heads/main.zip`), not the repo URL; bare repo URLs error with `BadZipFile`. The catalog form `specify extension add linear` documented as "once it's listed". `--dev <path>` documented as the local-development install. Operator-facing instructions now work on the first command they run.

### Fixed — Reconcile hotfixes (dogfood-surfaced)

- **`--retroactive` actually bypasses FR-025's write-authority gate (PR #3)** — v0.1.0 only suppressed the per-spec "non-authoritative worktree" warning row; the underlying gate in `sync_spec_issue` still fired and returned 0 without writing. Result: an operator with many existing specs ran `bash src/reconcile.sh --all --retroactive` from a non-`NNN-feature` branch and got ZERO mutations — breaking FR-014's promise that "first reconcile after install backfills every spec". The gate is now genuinely bypass-able when `--retroactive` is set; aggregated INFO row recorded once after the per-spec loop. Two new integration tests in `tests/integration/us5-retroactive-bypass-authority.bats` regression-pin both the bypass and the FR-025-default behavior.
- **Lazy-create `task-phase:N` labels for specs with 10+ phases (PR #4)** — `src/seed.sh` bootstraps `task-phase:1..9`; specs with 10+ task phases silently dropped their overflow sub-issues because the bridge couldn't resolve `task-phase:10+`. Reconcile now lazy-creates `task-phase:N` on first encounter (mirrors the `speckit-spec:NNN` / `agent:*` lazy-create precedent), so a spec with any number of phases mirrors completely. Regression test: `tests/integration/us1-task-phase-overflow.bats` (12-phase fixture).
- **Guard null `relations`/`labels` in the blocks-lookup path (PR #6)** — four `jq` `.nodes[]` iterations crashed with `Cannot iterate over null` when Linear returned `relations`/`labels` as `null` (a legitimate empty set) rather than `{nodes: []}`. Guarded with `(.nodes // [])[]` at all four sites; empty relation/label sets are now treated correctly as empty.

### Changed

- **`specs/001-spec-kit-linear-bridge/spec.md` FR-014** — added a clarifying note that `--retroactive` is the operator-facing flag delivering FR-014's contract; without it, FR-025 gates per-branch.
- **`commands/linear-push.md` `--retroactive` description** — now clearly states "bypasses FR-025 write-authority gate; intended for first-time adoption only".

### Validation

- **Constitution v1.0.0 re-check (T270)** — 8 Conform / 0 Drift; the Principle VI expansion (API key load-bearing at install) re-checks clean. See `validation/constitution-recheck-002.md`.
- **Dogfooded live** — spec 002 itself mirrored to the OSH-INFRA Linear workspace (parent Issue + 6 task-phase sub-issues) during development.

### Acknowledgements

The install-ergonomics redesign and all three reconcile hotfixes were surfaced by the first real-operator dogfood of v0.1.0 into a downstream consumer repo. Real users surface real bugs; ship more.

## [0.1.0] — 2026-05-28

First public release. Mirror every spec on disk into a Linear Issue, kept in sync by spec-kit's own `after_*` hooks plus local git hooks plus a GitHub Actions webhook.

### Added — Commands

- **`/speckit.linear.install`** — interactive install ceremony. Resolves Linear Team / Project / operator UUIDs, captures operator identity via `viewer` query (FR-034), writes `.specify/extensions/linear/linear-config.yml`, registers `after_*` hooks in `.specify/extensions.yml` (FR-031), installs local git hooks (FR-033), optionally installs the GitHub Action layer with copy-paste `gh secret set LINEAR_API_TOKEN` instructions (FR-027 / FR-029). Verifies every external dependency it touches and surfaces a structured status report (FR-018b). Detects seeded-state and prompts to run seed inline (T063). Dogfood-safe install mode via `SPECKIT_LINEAR_DOGFOOD_SAFE=1` (FR-033b).
- **`/speckit.linear.seed`** — one-shot workspace setup. Creates 9 lifecycle workflow states (`Specifying`, `Clarifying`, `Planning`, `Tasking`, `Red-team`, `Implementing`, `Analyzing`, `Ready-to-merge`, `Merged`) and the `phase:*` + `task-phase:1..9` label families. Captures every UUID at creation and writes them back into `linear-config.yml.workflow_state_uuids` so renames in Linear's UI never break the bridge (FR-032). Idempotent.
- **`/speckit.linear.push`** — the reconciler. Fires automatically on every `/speckit.*` lifecycle command via auto-registered `after_*` hooks; also invokable on demand. Reconciles every `specs/NNN-feature/` directory in the consumer repo into the Linear Project. Idempotent: re-running on unchanged state produces zero churn (SC-002).
- **`/speckit.linear.status`** — read-only drift inspector. Per spec, flags mismatches between disk and Linear: lifecycle phase, current branch, last-touched timestamp, task-phase completion ratio. Surfaces the authority status (FR-025 — is the current worktree authoritative for each spec?). `--human` table or `--json`. Never writes.
- **`/speckit.linear.pull`** — read-only cross-repo unified view. `--repo` (default) shows every spec Issue in this repo's Project; `--workspace-wide` shows every spec Issue across every Project bound to the operator's team. Useful for the "what's everyone's spec status" question from any directory.

### Added — Architecture

- **Layer D (reconciler)** + **Layer E (GitHub Action webhook)** — both independently idempotent. Either alone keeps Linear converging; both together cover live commits and retroactive sync. Layer E flips Issues to `Ready-to-merge` and `Merged` in real time on PR events.
- **Workspace label** `speckit-spec:NNN` as the stable lookup key for every spec Issue (FR-004b). Duplicate-resolution: most-recent activity wins, others archived.
- **Memory block** — auto-managed markdown table on every spec Issue's description carrying current lifecycle phase, branch, worktree(s), last-touched timestamp, GitHub source link. Fully bridge-owned: rewritten on every reconcile. Operator annotations belong in Linear comments (FR-008), which the bridge never touches.
- **Local git hooks** (`post-checkout`, `post-commit`, `post-merge`) — fire the reconciler on branch switches, commits, and merges, so Linear stays in sync without re-running a spec-kit command (FR-033). No daemons, no crons, no filesystem watchers.
- **Write-authority gate** (FR-025 / FR-026) — only the worktree on a spec's feature branch may mutate that spec's Linear Issue. Other worktrees' syncs are read-only for that spec; current Linear state still surfaces for inspection.
- **Operator identity captured at install** via Linear's `viewer` query (FR-034). `assigneeId` stamped on every `issueCreate` (single-write-on-create — manual reassignment in Linear's UI persists across reconciles).
- **Fibonacci `[N]` story-point markers** on task lines (FR-035). Per-phase sum → sub-issue `estimate`; spec-level sum → spec Issue `estimate`. Tolerant: malformed markers ignored, no-marker omits `estimate` from the mutation (operator-set Linear value remains sticky). Graceful degrade when computed value exceeds the team's Linear estimation cap.
- **Agent identity stamping** (FR-036). Workspace label from the `agent:*` family (`agent:claude`, `agent:codex`) added to every Issue the bridge writes — sticky, never removed, allows kanban filtering by which AI agent worked on what. `Last reconciled by:` row in the memory block records the full model identifier + ISO timestamp.

### Added — Toolchain

- 5 bash modules under `src/`: `config.sh`, `graphql.sh`, `git_helpers.sh`, `summary.sh`, `parser.sh` — each independently unit-tested.
- Full bats matrix in CI: ubuntu × bash 4.4 + 5.2, macOS × bash 5.2 (macOS × bash 4.4 excluded — bash 4.4 source doesn't compile against Xcode 16.4 SDK; documented inline).
- Perf harness at `tests/perf/` — synthetic-fixture generator + threshold gate. N=10 cold 0.992s vs ≤30s target (30× SC-007 headroom); hot 0.840s vs ≤5s target (6× SC-008).
- Constitution v1.0.0 audit clean (7 Conform / 1 caveat / 0 Drift) — see `validation/constitution-recheck-2026-05-28.md`.
- Coverage measurement (T079) — pure-logic modules at ~80% effective coverage; GraphQL-talking modules validated end-to-end via 16 integration scenarios (gated on `RUN_INTEGRATION_TESTS=1`).

### Added — Documentation

- `README.md` in spec-kit community-extension catalog style.
- `CONTRIBUTING.md` with full lifecycle walkthrough for changes that add or amend FRs.
- `BRIEF.md` capturing the original architectural decisions from an internal planning session.
- Five validation artifacts under `validation/` feeding `/speckit-plan`'s research bundle.
- Full spec.md (36 FRs), plan.md (Constitution Check + Phase 0/1/2), tasks.md (84 tasks across 8 phases), data-model.md (Filesystem + Linear-side schemas), contracts/, quickstart.md.

### Reconcile-time behavior

- Lifecycle phase inferred entirely from filesystem state (FR-012): artifact presence ladder + task completion ratio + PR state.
- Retroactive sync converges to the right end-state in one reconcile without producing intermediate-phase artifacts in Linear's activity log (FR-014).
- 16 integration scenarios cover fresh-reconcile, idempotent-rerun, task-added, clarify-mirror, retroactive-sync, install-action, seed-fresh, seed-idempotent, seed-prompt, unseeded-halts, after-hook-fires, git-hook-fires, non-authoritative-worktree, status-staleness, pull-cross-repo.

[Unreleased]: https://github.com/ashbrener/spec-kit-linear/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/ashbrener/spec-kit-linear/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ashbrener/spec-kit-linear/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ashbrener/spec-kit-linear/releases/tag/v0.1.0
