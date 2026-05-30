# Implementation Plan: Drift-Aware Write Authority

**Branch**: `003-drift-aware-authority` | **Date**: 2026-05-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-drift-aware-authority/spec.md`

**Target release**: v0.2.0 (minor release atop v0.1.1). Hard dependency: the **Constitution v2.0.0 amendment** (Principle IV redefinition) MUST land before or with this feature — it already landed on `main` and is merged into this branch (see Constitution Check below).

## Summary

Replace spec 001's hard branch-gate write-authority model (FR-025 enforcement: only the worktree on a spec's `NNN-feature` branch may write; every other worktree is read-only for that spec) with a **drift-aware model**: any worktree MAY write a spec's Linear state, and the bridge SURFACES backward-drift as a structured warning rather than blocking the write.

Backward-drift is computed per spec from two signals: **lifecycle-phase ordering** (Linear's recorded lifecycle phase is strictly further along than the phase the invoking worktree infers from disk) and **recency** (the spec directory's last git-commit time predates Linear's `updatedAt` beyond a clock-skew tolerance). Either signal fires the warning. On drift, an interactive session prompts proceed/abort; a non-interactive session proceeds-and-warns unless `--on-drift=abort` is passed. Forward movement and no-drift writes never warn.

Implementation extends two existing v0.1.0/v0.1.1 modules with NO new src files:

1. **`src/git_helpers.sh`** — add `git_helpers::spec_dir_last_commit <spec_dir>` (the `git log -1 --format=%cI -- <spec_dir>` recency key per FR-053), and `git_helpers::worktrees_touching_spec <feature_number>` (the multi-worktree ranking for FR-058/FR-059). Retain `git_helpers::is_authoritative_for_spec` only as a non-gating heuristic input (the branch-name "who has the latest" hint), no longer a write gate.
2. **`src/reconcile.sh`** — add a `reconcile::compute_drift <feature_number> <spec_dir> <linear_issue_json>` step (FR-052) that combines the disk-inferred lifecycle phase (already computed via `parser::lifecycle_phase`) against Linear's recorded phase + `updatedAt`; add the drift-disposition flow (interactive prompt FR-055 / non-interactive `--on-drift` FR-056); replace the `reconcile::read_only_display` early-return gate with always-attempt-write-after-drift-check (FR-051); deprecate `--retroactive` to a no-op alias emitting one INFO row (FR-061); retain FR-026 surfacing (FR-060).

The `--retroactive` bypass plumbing (`ARG_RETROACTIVE`, `_RECONCILE_RETROACTIVE_BYPASS_COUNT`) is reframed: because write-from-any-branch is now the default, the flag becomes a deprecation INFO alias, and the bypass-count accumulator is retired.

No new external dependencies. No new GraphQL operations (Linear's `updatedAt` is already read on the spec Issue — see `src/reconcile.sh` issue-lookup queries at lines 1401/1431, which already select `updatedAt`). No new contracts beyond the three documents under `specs/003-drift-aware-authority/contracts/`.

## Technical Context

**Language/Version**: Bash 4+ — same as v0.1.0/v0.1.1. The drift comparison uses only features already in play (`[[ ... ]]`, arithmetic comparison, `date -d`/`date -r` epoch conversion already used by `git_helpers::last_touched`, `jq` for parsing Linear's `updatedAt`). macOS Apple-bash 3.2 is refused at the existing dependency gate; no spec 003 change there.

**Primary Dependencies**: `git`, `jq`, `curl` — same as v0.1.0. Optional `gh` for merge detection (Layer D's existing `git_helpers::pr_state`). **NO new runtime deps.** Drift detection reads Linear's `updatedAt` through the existing `graphql::query` / official-MCP path that already fetches the spec Issue; the recency key is a local `git log` call.

**Storage**: Filesystem only — read-only for drift purposes. Spec 003 introduces **zero new on-disk state**: no sidecar file recording "what Linear last saw" (forbidden by Principle II), no per-repo drift-policy file (deferred per spec Out of Scope), no `~/.config/`. The drift signal is computed fresh on every reconcile from (a) the spec-dir git log and (b) the live Linear Issue. The three permitted state locations (consumer filesystem, Linear, Action environment) are unchanged.

**Testing**:

- **bats unit tests** under `tests/unit/drift_detection.bats` (new file) — exercise `git_helpers::spec_dir_last_commit` (commit-time extraction, empty-history fallback per Edge Case 1), `git_helpers::worktrees_touching_spec` (single vs multi-worktree ranking), and `reconcile::compute_drift` (phase-ordering-only fire, recency-only fire, both-fire, no-drift forward case, clock-skew tolerance boundary) against stubbed Linear Issue JSON and a temp git repo with synthesised spec-dir commit history.
- **bats unit tests** under `tests/unit/drift_disposition.bats` (new file) — exercise the disposition flow: interactive proceed/abort (FR-055) via a stubbed TTY/`read`, non-interactive proceed-and-warn default (FR-056), `--on-drift=abort` skip, `--on-drift=proceed` override, and the stdin-not-a-TTY default (Edge Case 6).
- **bats integration tests** under `tests/integration/drift_e2e.bats` (new file, gated on `RUN_INTEGRATION_TESTS=1` + Linear creds per v0.1.0 pattern) — the three user stories end to end against a real workspace: US1 merged-spec-from-main write with no flags + idempotent re-run (SC-014/SC-022); US2 retroactive first-reconcile + `--retroactive` deprecation INFO (SC-015/SC-021); US3 multi-worktree backward-drift warning + interactive abort leaves zero diff (SC-018/SC-020).
- **bats regression** — re-run the existing v0.1.1 reconcile suites to confirm the gate removal does not break idempotency (SC-022) or FR-026 surfacing (FR-060). The prior FR-025 read-only-skip assertions are UPDATED to assert write-attempt-with-drift-warning instead (the behavioral change spec 003 introduces).
- **shellcheck** clean on every modified `src/*.sh` per existing CI policy (`.github/workflows/ci.yml`).
- **markdownlint-cli2** clean on every new artifact under `specs/003-drift-aware-authority/` per the repo `.markdownlint-cli2.jsonc`.

**Target Platform**: Operator dev machines (macOS Intel + Apple Silicon, Linux) and the GitHub Action runner. No new platform surface. Layer E is exempt from drift detection (PR head ref already implies authority — Principle IV rule + FR-064).

**Project Type**: spec-kit extension. Same single-project layout as v0.1.0. No new directories.

**Performance Goals**:

- Drift computation adds at most **one `git log -1` call per spec** (sub-millisecond) plus parsing of an `updatedAt` field already present in the Linear Issue response — **zero additional network round trips**. The multi-worktree ranking (FR-058) runs `git worktree list` once per reconcile (already invoked by `git_helpers::list_worktrees` for the memory block), so no new process spawn in the common single-worktree case.
- **SC-019**: a non-interactive reconcile against a drifted spec MUST NOT hang — the TTY check (`[[ -t 0 ]]`) gates the prompt; absent a TTY the proceed-and-warn default (or `--on-drift`) is taken deterministically.

**Constraints**:

- Bash 4+, git, jq, curl only. Same as v0.1.0.
- **Recency MUST derive from `git log` commit time, never raw mtime** (FR-053). The existing `git_helpers::last_touched` (which uses `stat` mtime) is RETAINED for the FR-004 memory-block "last changed on disk" display — that is a human-facing informational field, not the drift signal — but it MUST NOT be used as the recency comparator. The new `git_helpers::spec_dir_last_commit` is the sole recency input to drift.
- **Branch name MUST NOT gate writes** (FR-051). `git_helpers::is_authoritative_for_spec` is demoted from a gate to a heuristic hint surfaced in the warning; the reconcile write path no longer early-returns on a non-authoritative branch.
- Drift comparison is **scoped per owning Linear Project** (consumer repo identity), never cross-repo (Edge Case 5 / spec 001 disambiguation).
- The prior reconcile's own write MUST NOT register as drift on the next run (Edge Case 3): the comparison is phase-ordering + spec-dir-commit-vs-`updatedAt`, and a no-drift second run writes nothing (idempotency, SC-022), so `updatedAt` does not advance past the spec-dir commit on a no-op.
- **Idempotency holds through the drift path** (FR-063 / SC-022): a no-drift second run produces zero label-modified timestamps, zero comment posts, zero relation rewrites.

**Scale/Scope**:

- Operator dimension: one consumer repo per reconcile. No change from v0.1.0.
- Spec dimension: dogfood evidence is ~11 specs per repo; drift is computed per spec, O(specs).
- Worktree dimension: typical 1-3 worktrees per repo; the multi-worktree ranking is O(worktrees) and only materially exercised when >1 worktree has the spec checked out (FR-058).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Constitution version read: v2.0.0** (`.specify/memory/constitution.md`, footer line "Version: 2.0.0 | Ratified: 2026-05-27 | Last Amended: 2026-05-28"). This is the AMENDED constitution carrying the redefined **Principle IV — Write-Authority Follows The Filesystem (Drift-Aware)**. The v2.0.0 amendment landed on `main` and is merged into this branch; this gate reads v2.0.0, NOT the superseded v1.0.0 branch-gate principle. If this gate read v1.0.0, spec 003's removal of the FR-025 enforcement would be a violation — under v2.0.0 it is the *intended implementation*.

Walked through all 8 principles. **All gates PASS.** No entries in Complexity Tracking.

### I. Filesystem Is The Single Source of Truth — **PASS**

Spec 003 *strengthens* Principle I. The whole feature reasserts that the filesystem state of the invoking worktree — not the branch name — is the authority for what Linear should reflect (FR-051). Drift detection reads Linear only to *compare* (`updatedAt`, recorded lifecycle phase) and warn; it never writes Linear → filesystem (FR-064 reaffirms zero reverse-sync). The write direction stays unidirectional FS → Linear. Backward-drift is precisely the case where the filesystem-truth principle and the branch-name heuristic disagree, and spec 003 resolves it in favour of the evidence (the filesystem) while surfacing the conflict to the operator.

### II. Reconcile, Never Event-Push — **PASS**

The drift signal is computed fresh from full filesystem + live Linear state on every invocation. Spec 003 adds **no per-event diff cache and no "what Linear last saw" sidecar** — explicitly forbidden by Principle II and reaffirmed in Technical Context → Storage. The recency key is the spec-dir git-commit timestamp (a filesystem-evident key per Principle II Rule 2), not a stored cursor. A no-drift re-run converges to zero churn (FR-063 / SC-022), preserving the reconciler-converges-from-any-state contract. Hook, manual, and CI paths share the one drift code path (FR-056 distinguishes only interactive vs non-interactive disposition, not the detection logic).

### III. Layered Idempotency (D + E) — **PASS**

Spec 003 operates entirely within **Layer D** (the synchronous reconcile path). **Layer E (the webhook Action) is untouched and explicitly exempt** from drift detection: the PR head ref already implies authority (Principle IV rule + spec Out of Scope + FR-064). No cross-layer write surface is added; Layer E still mutates only the spec Issue's workflow state. Either layer alone keeps Linear converging (SC-011 from spec 001 preserved). The drift path is wholly inside Layer D's existing write domain (labels, comments, sub-issues, description blocks, workflow state via reconcile).

### IV. Write-Authority Follows The Filesystem (Drift-Aware) — **PASS** *(the load-bearing gate)*

**Spec 003 IS the implementation of the amended Principle IV.** This is the gate that would FAIL under v1.0.0 and PASSES under v2.0.0, by design:

- **v1.0.0 (superseded)** made the branch-gate constitutional: "Reconcile MUST detect the active branch and gate spec-level mutations on the `<NNN>-...` match; non-authoritative worktrees read-only." Removing that gate WOULD have been a backward-incompatible principle violation — which is exactly why the constitution was amended to v2.0.0 *first*, as a separate PR, before this plan's gate runs (the amendment is spec 003's hard dependency, per the spec's `## Constitution Impact` and `## Dependencies`).
- **v2.0.0 (current)** redefines Principle IV to mandate the drift-aware model: "ANY worktree MAY write a spec's Linear state — the branch name is a HEURISTIC for 'who has the latest', not a gate … The bridge MUST detect backward-drift and SURFACE it, but MUST NOT block the write." The v2.0.0 Rules enumerate the implementation FRs directly: "Branch name MUST NOT gate spec-level writes … Implemented by spec 003 FR-051"; "The backward-drift signal MUST be computed per spec from (a) lifecycle-phase ordering and (b) recency … (FR-052)"; "Recency MUST derive from the spec-directory git-commit timestamp, never raw mtime (FR-053)"; "Backward-drift MUST be surfaced as a named WARNING row … (FR-054)"; "interactive prompts proceed/abort (FR-055); non-interactive proceeds-and-warns unless `--on-drift=abort` (FR-056)"; "An operator abort leaves Linear unchanged (FR-057)"; "FR-026's surfacing obligation is RETAINED … (FR-060)"; "`--retroactive` … is deprecated to a no-op alias once spec 003 lands (FR-061)."

Every FR-051..FR-064 maps 1:1 onto a v2.0.0 Principle IV rule. **The spec is the principle's implementation, so it cannot violate it — it satisfies it by construction.** PASS.

> **Quoted v2.0.0 Principle IV justification (the gate's load-bearing sentence):** *"ANY worktree MAY write a spec's Linear state — the branch name is a HEURISTIC for 'who has the latest', not a gate. … The bridge MUST detect backward-drift and SURFACE it, but MUST NOT block the write. … On backward-drift, an interactive session prompts the operator to proceed (overwrite Linear from disk) or abort; a non-interactive session proceeds-and-warns … unless an override flag selects abort. The operator decides — the bridge surfaces, it does not enforce (Principle VIII)."* Spec 003 FR-051..FR-061 implement exactly this. The constitution's own Rule explicitly names spec 003 as the implementer ("Implemented by spec 003 FR-051").

### V. UUID-Based Binding, Per-Repo Config — **PASS**

Spec 003 touches no binding resolution. It reads the spec Issue Linear's UUID-keyed lookups already produced. The drift comparison's "scoped per owning Linear Project" rule (Edge Case 5) reuses the existing per-repo Project UUID binding from `linear-config.yml`; no name-based lookup, no new config field, no per-operator global state. The optional per-repo drift-*policy* file is explicitly deferred (spec Out of Scope), so no config schema change.

### VI. OAuth-First, Keys-At-The-Edges — **PASS**

Drift detection reads Linear's `updatedAt` + lifecycle phase through the **same official Linear MCP / OAuth path** the interactive reconcile already uses (Principle VI Rule 1). No new API-key surface is introduced. The recency input is a purely local `git log` call (no auth at all). The GitHub Action edge is untouched (Layer E exempt). No `~/.config/`, no new key location.

### VII. Memory-Just-Works, Escape Hatches Beside It — **PASS**

Spec 003 *improves* "memory just works": the non-interactive default is **proceed-and-warn** (FR-056), so hook-fired reconciles keep converging Linear without an operator present — the gate-removal means hooks no longer silently skip non-authoritative specs (the v0.1.0 behavior that made merged specs stick). No hook-registration change. On-demand `speckit.linear.status` retains its FR-026 surfacing (FR-060) and gains the drift/worktree-pointer surface as a recovery/inspection aid, not a primary path. Quickstart still presents auto-sync first.

### VIII. Surface, Don't Enforce — Observable Failure — **PASS** *(poster child)*

Spec 003 is the canonical expression of Principle VIII. The spec itself frames the old FR-025 enforcement as "a Principle VIII violation hiding inside Principle IV": the bridge unilaterally *refused to write* rather than surfacing the risk and letting the operator decide. The redesign replaces enforcement with a **named WARNING row** (FR-054) carrying spec, disk phase, Linear phase, and which signal(s) fired — then prompts (interactive) or proceeds-and-warns (non-interactive). The bridge never silently skips: an aborted spec is recorded as skipped-by-operator (FR-057), and the `--retroactive` deprecation emits a one-line INFO row (FR-061) rather than silently ignoring the flag. Vocabulary stays canonical ("lifecycle phase" vs "task phase" disambiguated, `phase:*`/`task-phase:N` labels, `Phase N — <Name>` titles, never "wave").

**Verdict: All 8 gates GREEN against constitution v2.0.0.** Principle IV — the one gate that matters — PASSES because spec 003 IS the amended principle's implementation (the amendment is its landed hard dependency). No constitutional violations; Complexity Tracking is empty. Phase 0 research may proceed, and the post-Phase-1 re-check confirms no new violations were introduced by the design artifacts.

**Post-Phase-1 re-check**: research.md, data-model.md, and the three contracts introduce no new src module, no new state location, no new GraphQL operation, and no new auth surface. The re-check is GREEN — identical verdict to the pre-research gate.

## Project Structure

### Documentation (this feature)

```text
specs/003-drift-aware-authority/
├── spec.md                          # locked spec (FR-051..FR-064, SC-014..SC-022, 3 user stories)
├── plan.md                          # this file
├── research.md                      # Phase 0 output — 4 decisions
├── data-model.md                    # Phase 1 — drift-signal entity + worktree-recency + disposition state machine
├── quickstart.md                    # Phase 1 — operator walkthrough (write from any branch; backward-drift warning)
├── contracts/                       # Phase 1 — drift surface contracts
│   ├── drift-warning-surface.md     # the named WARNING/INFO rows the operator sees + summary block format
│   ├── recency-comparison.md        # the git-commit-time vs Linear updatedAt comparison + clock-skew tolerance
│   └── drift-detection-graphql.md   # the Linear read surface (updatedAt + lifecycle phase) — already available, no new ops
├── checklists/
│   └── requirements.md              # validation checklist (carry-over from /speckit-specify)
└── tasks.md                         # Phase 2 — generated by /speckit-tasks, NOT by /speckit-plan
```

### Source Code (repository root)

Spec 003 adds NO new directories. It introduces three new test files under existing `tests/` directories and modifies two existing scripts (`src/reconcile.sh`, `src/git_helpers.sh`). On-demand `src/status.sh` gains the drift/worktree-pointer surface (FR-060). The README and command docs receive forward-facing wording updates (already pre-propagated by the v2.0.0 amendment's Sync Impact Report — see constitution.md header; this plan only notes them).

```text
src/
├── reconcile.sh                     # MODIFIED — add reconcile::compute_drift + disposition flow (FR-052,
│                                    #            FR-054..FR-057); remove the FR-025 write-gate early-return,
│                                    #            always-attempt-write-after-drift-check (FR-051); deprecate
│                                    #            --retroactive to no-op INFO alias (FR-061); retire the
│                                    #            _RECONCILE_RETROACTIVE_BYPASS_COUNT accumulator.
├── git_helpers.sh                   # MODIFIED — add git_helpers::spec_dir_last_commit (FR-053 recency key)
│                                    #            and git_helpers::worktrees_touching_spec (FR-058/FR-059
│                                    #            multi-worktree ranking). is_authoritative_for_spec demoted
│                                    #            to a non-gating heuristic hint.
├── status.sh                        # MODIFIED — surface drift + most-recent-commit worktree pointer (FR-060)
├── config.sh                        # unchanged
├── graphql.sh                       # unchanged — updatedAt already selectable on the issue query
├── parser.sh                        # unchanged — parser::lifecycle_phase reused as the disk-inferred phase input
├── seed.sh                          # unchanged
├── install.sh                       # unchanged
├── pull.sh                          # unchanged
└── summary.sh                       # MODIFIED (light) — ensure WARNING/INFO/skipped-by-operator rows render
                                     #            per the drift-warning-surface contract

tests/
├── unit/
│   ├── drift_detection.bats         # NEW — spec_dir_last_commit, worktrees_touching_spec, compute_drift
│   ├── drift_disposition.bats       # NEW — interactive prompt, non-interactive default, --on-drift override
│   └── (existing v0.1.x *.bats)     # unchanged
├── integration/
│   ├── drift_e2e.bats               # NEW — US1/US2/US3 end-to-end vs real workspace
│   └── (existing v0.1.x *.bats)     # UPDATED where they asserted FR-025 read-only skips → now assert
│                                    #         write-attempt + drift warning (the behavioral change)
└── fixtures/
    └── linear_responses/            # EXTENDED — add spec-Issue fixtures carrying updatedAt + recorded
                                     #            lifecycle phase for the drift unit tests

README.md                            # forward-facing wording (pre-propagated by v2.0.0 Sync Impact Report)
commands/linear-push.md              # forward-facing wording (gate→drift-warn; --retroactive deprecated)
commands/linear-status.md            # forward-facing wording (authority status → drift status)
CHANGELOG.md                         # v0.2.0 entry referencing spec 003
```

**Structure Decision**: Same single-project layout as v0.1.0/v0.1.1. Spec 003 is a strict extension of the existing Layer D reconcile path (`src/reconcile.sh` + `src/git_helpers.sh`), not a re-architecture. No new src module, no new directory, no new external dependency, no new GraphQL operation. The behavioral surface change (gate-removal → drift-warn) is concentrated in the reconcile write path and surfaced through the existing summary block.

## Assumptions Made During Planning

These are judgment calls made during /speckit-plan that the spec did not explicitly mandate. Each is reviewer-surface before /speckit-tasks.

| # | Assumption | Rationale | Reviewable? |
|---|---|---|---|
| A1 | Clock-skew tolerance is a fixed **120 seconds (2 minutes)** hard-coded as `RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS=120`. | Spec `## Assumptions` says "a few minutes" and "exact value is a planning detail". 120s comfortably absorbs commit-time vs server-time skew without masking a genuine human edit (which advances `updatedAt` by far more). | yes |
| A2 | The recency key is `git log -1 --format=%cI -- <spec_dir>` (committer date, ISO-8601 strict) parsed to epoch for comparison, matching the spec's `git log -1 -- specs/NNN/` phrasing. Committer date (not author date) is used because it reflects when the commit landed in this worktree's history. | `%cI` is the filesystem-evident, clone/checkout-stable key FR-053 mandates; committer date survives rebase/cherry-pick better than author date for "who has the latest" semantics. | yes |
| A3 | Empty spec-dir git history (Edge Case 1, uncommitted brand-new spec) → recency signal is treated as **unavailable**, drift falls back to phase-ordering alone, and absence of recency is NOT fabricated into a warning. | Matches spec Edge Case 1 literally. | yes |
| A4 | Lifecycle-phase ordering uses the existing canonical order `clarifying < specifying < planning < tasking < implementing < ready_to_merge < merged` (derived from `parser::lifecycle_phase` + the spec-001 phase map). "Strictly further along" = Linear's phase has a higher ordinal than the disk-inferred phase. | Reuses spec-001 phase inference unchanged (spec `## Assumptions` bullet 1). The ordinal table is the minimal new artifact (lives in data-model.md). | yes |
| A5 | The disposition prompt (FR-055) reads from the controlling TTY via `[[ -t 0 ]]` to decide interactive vs non-interactive; a non-TTY stdin with no `--on-drift` takes proceed-and-warn (Edge Case 6). The prompt accepts `p`/`proceed` and `a`/`abort`, defaulting to abort on empty input in interactive mode (the safe choice — don't overwrite a more-advanced Linear without an affirmative keystroke). | Spec FR-055/FR-056 + Edge Case 6. Defaulting the *interactive* empty-enter to abort is the conservative reading of "the genuinely risky case … a deliberate operator choice" (Clarifications Q2). | yes |
| A6 | `--on-drift` accepts exactly `abort` and `proceed`; any other value is a usage error surfaced at arg-parse time (consistent with existing `reconcile.sh` arg handling). The flag has no effect when no drift is detected. | Matches FR-056 enumerated values; fail-loud on bad input (Principle VIII). | yes |
| A7 | The merge-detection gap (OSH-5: merged spec stuck "Implementing" from `main` because `gh pr view <deleted-branch>` fails) is **resolved as a side effect** of US1's write-from-main, NOT by a new merge-detection mechanism in this spec. The drift check confirms Linear (Implementing) is NOT ahead of disk-inferred Merged once `parser::lifecycle_phase` infers Merged — but inferring Merged from `main` still depends on `git_helpers::pr_state` answering "merged" for a deleted branch. See research.md §3: this plan RECOMMENDS a small companion `pr_state` hardening (squash-merge / deleted-branch detection) tracked SEPARATELY, because it is a distinct FR-013 concern, not part of FR-051..FR-064. | The branch-gate removal (FR-051) lets `main` *write*, but does not itself make `main` *infer Merged*. Conflating the two would scope-creep spec 003. See Report + research §3. | yes — flagged for reviewer decision |

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

No violations to track. All 8 constitutional principles PASS against constitution v2.0.0. Principle IV — the gate that would have failed under the superseded v1.0.0 branch-gate rule — passes because spec 003 is the amended Principle IV's own implementation, and the amendment landed as this feature's hard dependency before the gate ran. No Complexity Tracking entries.

## Cross-references

- Spec: [`spec.md`](./spec.md) — FR-051..FR-064 (14 functional requirements), SC-014..SC-022 (9 success criteria), 3 user stories.
- Phase 0 research: [`research.md`](./research.md) — 4 design decisions (drift mechanism, phase-ordering comparison, merge-detection gap, `--retroactive` deprecation path).
- Phase 1 data model: [`data-model.md`](./data-model.md) — backward-drift signal, disk/Linear lifecycle phases, spec-dir recency, worktree-recency comparison, drift disposition; plus the warn-not-block decision state machine.
- Phase 1 contracts:
  - [`contracts/drift-warning-surface.md`](./contracts/drift-warning-surface.md)
  - [`contracts/recency-comparison.md`](./contracts/recency-comparison.md)
  - [`contracts/drift-detection-graphql.md`](./contracts/drift-detection-graphql.md)
- Phase 1 quickstart: [`quickstart.md`](./quickstart.md) — operator walkthrough of write-from-any-branch + the backward-drift warning.
- v0.1.0 baseline: [`specs/001-spec-kit-linear-bridge/`](../001-spec-kit-linear-bridge/) — the reconcile path, phase inference, memory block, summary block, and the FR-025/FR-026/FR-014 behaviors spec 003 supersedes/amends.
- Constitution: [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) — **v2.0.0**, 8 principles, amended Principle IV (Write-Authority Follows The Filesystem, Drift-Aware) — spec 003's hard dependency.
