# Tasks: Drift-Aware Write Authority

**Branch**: `003-drift-aware-authority` | **Date**: 2026-05-29 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

**Input**: Design documents under `/specs/003-drift-aware-authority/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md).

## Format: `[ID] [P?] [Story?] Description`

- **[P]** — parallelizable with other [P] tasks (different files, no dependencies on incomplete tasks)
- **[USn]** — applies only to user-story phase tasks (User Story 1..3 from spec.md)
- **[N]** — Fibonacci story-point estimate (optional; only when confidently sized)
- Path Conventions per `plan.md` §Project Structure (single-project layout; spec 003 is a strict extension of existing files — NO new `src/` modules, NO new directory)
- Task IDs start at `T300` to remain monotonic and disjoint from spec 001's `T001..T084` and spec 002's `T200..T271`

## Path Conventions

- Bridge implementation: `src/git_helpers.sh` (new recency + multi-worktree helpers), `src/reconcile.sh` (drift compute + disposition flow + gate removal + `--retroactive` deprecation), `src/status.sh` (drift/worktree-pointer surface, FR-060), `src/summary.sh` (light — INFO/skip rows + drift counters)
- Reused unchanged: `src/parser.sh` (`parser::lifecycle_phase` as the disk-inferred phase input), `src/graphql.sh` (`updatedAt` already selectable), `src/config.sh`
- Tests: `tests/unit/drift_detection.bats`, `tests/unit/drift_disposition.bats`, `tests/integration/drift_e2e.bats` (NEW); existing v0.1.x reconcile suites UPDATED where they asserted FR-025 read-only skips
- Test fixtures: `tests/fixtures/linear_responses/` (EXTENDED — spec-Issue fixtures carrying `updatedAt` + recorded lifecycle phase)
- AI-invoked command docs: `commands/linear-push.md`, `commands/linear-status.md` (forward-facing wording; gate → drift-warn, `--retroactive` deprecated)
- Operator-facing docs: `README.md`, `CHANGELOG.md` (v0.2.0 entry)
- Spec-kit lifecycle: `specs/003-drift-aware-authority/*`

## Assumptions Made During /speckit-tasks

These extend `plan.md`'s A1–A7 (`/speckit-plan` assumptions). Each is a judgment call the spec did not explicitly mandate; surface-area for the reviewer.

| # | Assumption | Rationale | Reviewable? |
|---|---|---|---|
| A8 | The lifecycle-phase ordinal ladder (data-model §2: `clarifying=0 … merged=6`) lands as a single lookup function `reconcile::_phase_ordinal <phase_token>` inside `src/reconcile.sh` rather than as a new sourced table file. It maps every token `parser::lifecycle_phase` can emit to its ordinal; an unknown token returns a sentinel that disables the phase signal (falls back to recency alone, mirroring the malformed-artifacts edge case). | Plan A4 says the ordinal table is "the minimal new artifact" and "lives in data-model.md"; keeping the executable form inline in `reconcile.sh` (where the only caller, `reconcile::compute_drift`, lives) avoids a new sourced file and matches the "NO new src files" structure decision. | yes |
| A9 | `reconcile::compute_drift <feature_number> <spec_dir> <linear_issue_json> <disk_phase_token>` returns its verdict as a stable, parseable single line (`fired=<0\|1> phase_drift=<0\|1> recency_drift=<0\|1> signals=<csv> disk=<tok> linear=<tok> [recency detail fields]`) on stdout, so the disposition flow and the WARNING-row emitter consume one source of truth and the bats unit tests assert against one string. The disk phase token is passed IN (already computed by the caller at `src/reconcile.sh:2532` via `parser::lifecycle_phase`) rather than recomputed inside the function. | Single-line stdout contracts are the established `git_helpers::*` / `reconcile::*` idiom in this repo (cf. `git_helpers::spec_dir_last_commit` echoing one ISO string); passing the disk phase in avoids a duplicate `parser::lifecycle_phase` call and keeps `compute_drift` a pure comparator. | yes |
| A10 | The interactive prompt (FR-055) reads the controlling terminal explicitly via `read -r ans < /dev/tty` (NOT bare `read`), so it never consumes the spec-enumeration stdin stream (drift-warning-surface §3 rule). The TTY gate is `[[ -t 0 ]]`; when stdin is not a TTY the prompt is never reached and the non-interactive `--on-drift` resolution (FR-056) runs instead. bats tests for the interactive path drive `/dev/tty` via a pseudo-tty harness or assert the non-interactive branch directly (the prompt body is exercised by a `read`-stub seam). | drift-warning-surface §3 ("MUST NOT consume the spec-enumeration stdin stream") + plan A5. `/dev/tty` is the bash-portable way to read the operator without disturbing a piped spec list; matches the `read -r -s` `/dev/tty`-adjacent idiom already used by `install::prompt_for_api_key` in spec 002. | yes |
| A11 | The new `--on-drift=abort\|proceed` flag is parsed in `reconcile::parse_args` (`src/reconcile.sh:289`) into a global `declare -g ARG_ON_DRIFT=""` (empty = unset = use the proceed-and-warn default). An unrecognised value is a usage error at parse time via the existing `reconcile::usage` halt path (plan A6). The flag has no observable effect when no drift fires (data-model §3.5 invariant). | Mirrors spec 002 A6 (`--on-drift` enumerated values, fail-loud at arg-parse) and the existing `reconcile.sh` arg-handling shape (each flag → `declare -g ARG_*` + `reconcile::usage` on bad input). | yes |
| A12 | The `--retroactive` deprecation INFO row (FR-061) is emitted EXACTLY ONCE per invocation from `reconcile::parse_args` (at the point the flag is recognised) rather than per-spec, and the per-spec `_RECONCILE_RETROACTIVE_BYPASS_COUNT` accumulator + its end-of-run `summary::add warned` row (`src/reconcile.sh:206`, `:2881-2884`) are RETIRED. The flag sets no behavioral global; writing-from-any-branch is already the default after the gate removal (FR-051). | drift-warning-surface §6 ("exactly one INFO row per invocation, not per spec") + plan Summary ("the bypass-count accumulator is retired"). Emitting at parse time is the single-fire point. | yes |
| A13 | `summary.sh` gains an `info` event type and a `skipped-by-operator` distinction alongside the existing `created\|updated\|archived\|warned\|skipped\|error` set (`src/summary.sh:25`). The drift WARNING row reuses the existing `warned` type (rendered under `----- warnings -----`); the `--retroactive` INFO row uses the new `info` type (top-of-summary line per drift-warning-surface §7); the operator-abort skip reuses `skipped` with the `(backward-drift abort)` message qualifier so the existing skipped counter increments. The drift counters (`drifted`, `overridden-proceed`) are surfaced as `warned`/log rows rather than new counter keys, to keep `summary.sh` a light change per plan ("MODIFIED (light)"). | Plan marks `summary.sh` a *light* change; reusing `warned`/`skipped` and adding only `info` is the minimal diff that satisfies drift-warning-surface §1/§7's severity vocabulary without a counter-map redesign. | yes |
| A14 | The existing v0.1.x reconcile bats suites that asserted the FR-025 read-only skip (the assertions exercising `reconcile::read_only_display` and the `non-authoritative worktree … read-only mode` message at `src/reconcile.sh:1637`) are UPDATED in-place to assert the new behavior (write-attempt + drift warning OR silent forward write), NOT deleted — they become the SC-022 / FR-060 regression guard. `reconcile::read_only_display` itself is retained but repurposed as a FR-060 *surfacing* helper (display current Linear state from any worktree without a write), with its early-return-before-write semantics removed. | Plan Testing bullet 4 ("the prior FR-025 read-only-skip assertions are UPDATED to assert write-attempt-with-drift-warning instead") + FR-060 ("FR-026's surfacing obligation is RETAINED; only its coupling to a now-removed write gate is dropped"). | yes |
| A15 | The merge-detection hardening flagged in plan A7 / research §3 (ACM-5: `main` inferring `Merged` for a deleted feature branch) is OUT OF SCOPE for this task list — it is a distinct FR-013 concern tracked SEPARATELY, exactly as plan A7 records. Spec 003 tasks implement only the branch-gate removal (FR-051) that lets `main` *write*; they do not add merge-detection logic. The US1 integration test (T331) therefore seeds Linear to a state strictly behind a disk-inferred `merged` so the no-warning assertion holds without depending on the unshipped `pr_state` hardening. | Plan A7 explicitly carves this out ("RECOMMENDS a small companion `pr_state` hardening … tracked SEPARATELY … not part of FR-051..FR-064"). Conflating it would scope-creep spec 003. | yes — inherits plan A7's reviewer flag |
| A16 | T308 (retire the `_RECONCILE_RETROACTIVE_BYPASS_COUNT` accumulator) retires the accumulator's **end-of-run `summary::add warned` aggregate row** and its title-suffix, but RETAINS the `declare -g _RECONCILE_RETROACTIVE_BYPASS_COUNT=0` initialisation. Rationale: the lone *increment* of that counter lives INSIDE the FR-025 write-authority gate in `reconcile::process_spec` — a Phase-2-forbidden region (its wholesale deletion is US1's T324). Deleting the declaration now would leave that still-present increment dereferencing an unbound variable under `set -u` (verified: `var=$((var+1))` aborts on an unset name). The counter is therefore a now-unread write-once relic until T324 deletes the gate, its increment, AND this declaration together. Net operator-visible behaviour already matches FR-061 (no bypass row ever surfaces). | Keeps Phase 2 strictly additive and honours the "do NOT touch the `sync_spec_issue` write-authority gate" boundary; the operator-facing retirement (the warned row) is fully done — only the inert declaration survives for the gate's benefit. | yes |
| A17 | Phase 3 (US1 spine) threads `reconcile::compute_drift` into `reconcile::process_spec` (NOT inside `sync_spec_issue`), right after `parser::lifecycle_phase` is computed. To feed the comparator the Linear phase/recency view, T323 adds a small read-only helper `reconcile::_fetch_drift_issue_json <NNN>` (selects only `updatedAt` + `phase:*` labels + `state.type`, Project-scoped) — the existing `query_spec_issue` selects only `{id, updatedAt}`, insufficient for the phase signal. This is a READ (FR-064: no mutation, no new state). The disposition fork is a dedicated `reconcile::_drift_disposition` function whose body is the Phase-3 proceed-and-warn default plus a clearly-commented `[[ -t 0 ]]` / `[[ ! -t 0 ]]` extension point where US3/T343 (interactive) and US2/T334 (non-interactive `ARG_ON_DRIFT`) slot in. The WARNING emitter is `reconcile::_emit_drift_warning`. T327's **multi-worktree canonical-pointer** surfacing (`git_helpers::worktrees_touching_spec` into `status::compute_drift`) is DEFERRED to US3/T345, where FR-058 lives per the FR/SC coverage map; Phase 3's T327 scope is the FR-060 read-only drift surfacing, which `status.sh` already satisfies (its `is_authoritative_for_spec` use is demoted to a non-gating display hint, never a write gate). The repurposed FR-025 regression assertions in `tests/integration/us5-retroactive-bypass-authority.bats` are updated in-place now (they directly contradicted the spine), bringing forward part of T347/A14; the spec-001 `us2-non-authoritative-worktree.bats` T038 was already failing in this environment pre-change and is left for T347. | Threading in `process_spec` keeps `compute_drift` pure (A9) and `sync_spec_issue` unchanged; the dedicated disposition/warning functions give Phase 4/5 a clean, conflict-free extension surface; deferring the worktree pointer to T345 avoids duplicating FR-058 work and keeps the US1 slice minimal. | yes |

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: minimal scaffolding. Spec 001/002 already shipped the repo skeleton, CI matrix, markdownlint config, bats harness, and `tests/fixtures/linear_responses/`. Spec 003 adds NO new directory; the only setup is a branch/constitution sanity check and a CI-matrix confirm for the three new bats files.

- [x] T300 [1] Confirm the working tree is on `003-drift-aware-authority`, `.specify/memory/constitution.md` reads **Version 2.0.0** (the amended Principle IV is the hard dependency per plan §Constitution Check), and `.specify/extensions.yml` is unchanged from `main` baseline; abort if any drifted (operator safety — surface state before any test/code edits) ✓ 2026-05-29
- [x] T301 [P] [1] `.github/workflows/ci.yml`: confirm the existing matrix runs `tests/unit/drift_detection.bats` + `tests/unit/drift_disposition.bats` on every push and `tests/integration/drift_e2e.bats` when `RUN_INTEGRATION_TESTS=1` — verify spec 001/002's matrix rows already glob the new bats files (no change expected; confirm-only task) ✓ 2026-05-29

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the recency + multi-worktree git helpers, the phase-ordinal ladder, the pure drift comparator, the `--on-drift` / `--retroactive` arg-parse changes, the summary-surface plumbing, and the spec-Issue JSON fixtures. Every task here is independent of every user-story phase; they MUST land before Phase 3 because they ARE the drift machinery's building blocks. All `[P]` tasks touch new functions or new fixtures (no edits to the `reconcile::sync_spec_issue` write path yet — that gate-removal is US1's T328).

- [x] T302 [P] [2] `src/git_helpers.sh`: add `git_helpers::spec_dir_last_commit <spec_dir>` per recency-comparison.md §1 + FR-053 — runs `git log -1 --format=%cI -- "<spec_dir>"`, echoes the ISO-8601 committer date or empty when no commit touches the dir (Edge Case 1 → recency `unavailable`). MUST NOT use `stat`/mtime; the existing `git_helpers::last_touched` (`src/git_helpers.sh:328`) is left intact for the FR-004 memory-block human display only ✓ 2026-05-29
- [x] T303 [P] [3] `src/git_helpers.sh`: add `git_helpers::worktrees_touching_spec <feature_number>` per recency-comparison.md §4 + FR-058/FR-059 — enumerates worktrees via `git worktree list --porcelain` (reusing the `git_helpers::list_worktrees` pattern, `src/git_helpers.sh:83`), and for each worktree that has `specs/<NNN>-*/` present echoes `<commit_epoch>\t<worktree_path>\t<branch>`; ranking by spec-dir commit epoch (NEVER branch name or mtime), ties resolve to the invoking worktree as canonical ✓ 2026-05-29
- [x] T304 [P] [2] `src/git_helpers.sh`: add a cross-platform ISO→epoch converter (or extend the dual GNU/BSD `date` pattern already in `git_helpers::last_touched`) per recency-comparison.md §2 — GNU `date -d` first, BSD `date -j -f "%Y-%m-%dT%H:%M:%S%z"` fallback; conversion failure → echo empty (treat recency as `unavailable`, never fabricate a comparison) ✓ 2026-05-29
- [x] T305 [P] [2] `src/reconcile.sh`: add `reconcile::_phase_ordinal <phase_token>` per data-model.md §2 + plan A4/A8 — total strictly-ordered map `clarifying=0 specifying=1 planning=2 tasking=3 implementing=4 ready_to_merge=5 merged=6`; an unknown token returns a sentinel that disables the phase signal (malformed-artifacts edge case → recency-only) ✓ 2026-05-29
- [x] T306 [P] [3] `src/reconcile.sh`: add the pure comparator `reconcile::compute_drift <feature_number> <spec_dir> <linear_issue_json> <disk_phase_token>` per FR-052 + data-model.md §3.3 + recency-comparison.md §3 + A9 — derives Linear phase ordinal + `updatedAt` epoch from the issue JSON (drift-detection-graphql.md §2/§3), computes `phase_drift = ordinal(linear) > ordinal(disk)`, `recency_drift = (linear_epoch − disk_epoch) > 120`, `fired = phase_drift OR recency_drift`; emits the single-line verdict (A9). `recency_drift=false` when recency `unavailable`; `phase_drift` skipped when disk phase uninferrable. Reads `RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS` (default 120, plan A1) ✓ 2026-05-29
- [x] T307 [P] [2] `src/reconcile.sh`: extend `reconcile::parse_args` (`src/reconcile.sh:289`) to accept `--on-drift=abort|proceed` into `declare -g ARG_ON_DRIFT=""` per FR-056 + plan A6/A11 — empty = unset (proceed-and-warn default); any value other than `abort`/`proceed` is a usage error via `reconcile::usage`; update `reconcile::usage` `--help` text to document the flag ✓ 2026-05-29
- [x] T308 [P] [2] `src/reconcile.sh`: convert `--retroactive` to the deprecated no-op alias per FR-061 + plan A12 — in `reconcile::parse_args` recognise the flag, emit EXACTLY ONE `summary::add info` deprecation row (drift-warning-surface §6 verbatim text) once per invocation, set no behavioral global; retire the `_RECONCILE_RETROACTIVE_BYPASS_COUNT` accumulator (`src/reconcile.sh:206`) and its end-of-run `summary::add warned` row (`:2881-2884`) ✓ 2026-05-29
- [x] T309 [P] [2] `src/summary.sh`: add the `info` event type to the type set (`src/summary.sh:25`) and ensure it renders as a top-of-summary INFO line per drift-warning-surface §7 + plan A13 — the existing `warned` type carries the drift WARNING row, `skipped` carries the operator-abort skip note with the `(backward-drift abort)` qualifier; drift counters (`drifted`, `overridden-proceed`) surface via `warned`/log rows (no counter-map redesign — light change) ✓ 2026-05-29
- [x] T310 [P] [1] `tests/fixtures/linear_responses/spec_issue_linear_ahead_phase.json` — spec-Issue fixture with `updatedAt` + a `phase:implementing` label so phase-ordering drift fires against a disk-inferred `planning` (recency-comparison.md §5 row 4 / row 2) ✓ 2026-05-29
- [x] T311 [P] [1] `tests/fixtures/linear_responses/spec_issue_linear_ahead_recency.json` — spec-Issue fixture whose `updatedAt` is >120s newer than the test's seeded spec-dir commit, same phase as disk, so recency-only drift fires ✓ 2026-05-29
- [x] T312 [P] [1] `tests/fixtures/linear_responses/spec_issue_forward.json` — spec-Issue fixture where Linear is behind disk (Linear `planning`, `updatedAt` older than disk commit) so `fired=false` (recency-comparison.md §5 row 3 — the normal forward write path, SC-017) ✓ 2026-05-29
- [x] T313 [P] [1] `tests/fixtures/linear_responses/spec_issue_within_skew.json` — spec-Issue fixture whose `updatedAt` is +30s of the spec-dir commit (within the 120s tolerance), same phase, so `fired=false` (recency-comparison.md §5 row 1 — clock-skew boundary, SC-017) ✓ 2026-05-29
- [x] T314 [P] [1] `tests/fixtures/linear_responses/spec_issue_merged_behind.json` — spec-Issue fixture for the US1 case: disk-inferred `merged`, Linear at `implementing` and behind (recency-comparison.md §5 row 5) so `fired=false` (Linear behind, no warning) — supports T331's no-warning assertion per A15 ✓ 2026-05-29
- [x] T315 [P] [1] `tests/fixtures/linear_responses/spec_issue_absent.json` — empty issue-lookup response (spec Issue does not yet exist in Linear) for the US2 retroactive first-reconcile case → `fired=false`, created from disk (drift-detection-graphql.md §5 row 3, SC-015) ✓ 2026-05-29

**Checkpoint**: helpers, comparator, arg-parse, summary plumbing, and fixtures land; `bats tests/unit/drift_detection.bats` is empty-pass (no tests yet); `shellcheck src/git_helpers.sh src/reconcile.sh src/summary.sh` clean. The drift machinery exists but is NOT yet wired into the `reconcile::sync_spec_issue` write path (the gate is still in place — US1 removes it).

## Phase 3: User Story 1 — Write the post-merge view of a merged spec from main (P1)

**Story goal**: an operator on `main` (feature branch deleted) reconciles a merged spec with ZERO extra flags; the bridge writes the spec's Merged workflow state + cleared `phase:*` label to Linear because `main` holds the latest filesystem state and nothing in Linear is further along. This is the minimum viable slice — it removes the FR-025 gate and proves the drift comparator on the no-drift / forward path.

**Independent test criteria**: in a repo with one merged spec (feature branch deleted, on `main`), run reconcile with zero flags and observe (a) the spec Issue moves to Merged with its phase label cleared, (b) ZERO backward-drift warning (Linear was behind, not ahead), (c) a second run is idempotent (zero churn, SC-022), (d) a disk-ahead spec writes the advance with no warning (forward case, SC-017).

### Tests for User Story 1

- [x] T316 [P] [US1] [2] `tests/unit/drift_detection.bats`: `git_helpers::spec_dir_last_commit` — three `@test` blocks: (a) a temp git repo with a commit touching `specs/005-foo/` returns that commit's ISO date, (b) empty git history for the dir returns empty (Edge Case 1 → unavailable), (c) the returned string parses to a sane epoch via the T304 converter. Covers FR-053 ✓ 2026-05-29
- [x] T317 [P] [US1] [2] `tests/unit/drift_detection.bats`: ISO→epoch converter — `@test` blocks asserting GNU and BSD code paths both yield the same epoch for a fixed ISO string, and an unparseable string yields empty (recency `unavailable`). Covers recency-comparison.md §2 ✓ 2026-05-29
- [x] T318 [P] [US1] [3] `tests/unit/drift_detection.bats`: `reconcile::compute_drift` no-drift / forward cases — `@test` blocks for (a) forward (disk ahead, `spec_issue_forward.json` T312) → `fired=0`, (b) within-skew (`spec_issue_within_skew.json` T313) → `fired=0`, (c) merged-disk Linear-behind (`spec_issue_merged_behind.json` T314) → `fired=0`, (d) absent Linear Issue (`spec_issue_absent.json` T315) → `fired=0`. **This is the SC-017 zero-false-positive load-bearing test** (0% of forward/no-drift cases warn) ✓ 2026-05-29
- [x] T319 [P] [US1] [2] `tests/unit/drift_detection.bats`: `reconcile::_phase_ordinal` — `@test` blocks asserting the total ordering `clarifying<…<merged` and that an unknown token returns the phase-signal-disabling sentinel. Covers data-model.md §2 ladder invariants ✓ 2026-05-29
- [x] T320 [P] [US1] [3] `tests/integration/drift_e2e.bats`: US1 merged-spec-from-`main` end-to-end (gated on `RUN_INTEGRATION_TESTS=1` + Linear creds) — repo with one merged spec, feature branch deleted, on `main`; run reconcile with no flags; assert spec Issue reaches Merged with `phase:*` cleared, ZERO drift warning, write recorded in the summary. **Phase 3 lands the scaffold + skip-gated placeholder**; full live body lands with the dogfood harness (T338). Covers SC-014 + Acceptance Scenario 1 ✓ 2026-05-29
- [x] T321 [P] [US1] [2] `tests/integration/drift_e2e.bats`: US1 idempotent re-run — second reconcile from `main` against the now-Merged spec asserts zero label-modified timestamps, zero comment posts, zero relation rewrites (skip-gated placeholder). Covers SC-022 + FR-063 + Acceptance Scenario 2 ✓ 2026-05-29
- [x] T322 [P] [US1] [2] `tests/integration/drift_e2e.bats`: US1 disk-ahead forward write — spec on `main` with disk `implementing` vs Linear `planning`; assert the advance writes with NO drift warning (skip-gated placeholder). Covers SC-017 + Acceptance Scenario 3 ✓ 2026-05-29

### Implementation for User Story 1

- [x] T323 [US1] [3] `src/reconcile.sh`: thread `reconcile::compute_drift` (T306) into the spec-processing flow — call it after the disk-inferred `lifecycle_phase` is computed (`src/reconcile.sh:2532`) and after the spec Issue is looked up (with `updatedAt` already selected at `:1401`/`:1431`), capturing the single-line verdict into locals for the disposition step (T326) and the WARNING emitter (T325). Per-Project scope only (Edge Case 5 — never cross-repo) ✓ 2026-05-29
- [x] T324 [US1] [5] `src/reconcile.sh`: REMOVE the FR-025 write-gate in `reconcile::sync_spec_issue`'s caller — delete the early-return-before-write at `src/reconcile.sh:2483-2502` (the `--retroactive` bypass branch + the `reconcile::read_only_display` non-authoritative early return) so EVERY worktree always proceeds to attempt the write after the drift check (FR-051). `git_helpers::is_authoritative_for_spec` is demoted to a non-gating heuristic hint surfaced in the warning (plan §Constraints). The filesystem state of the invoking worktree is the write authority (Principle I) ✓ 2026-05-29
- [x] T325 [US1] [3] `src/reconcile.sh`: emit the named backward-drift WARNING row when `fired=1` per FR-054 + drift-warning-surface.md §2 — `summary::add warned` with spec, `disk=<phase>`, `linear=<phase>`, `signals=<csv>`; append the recency detail line ONLY when `recency` fired (spec-dir last commit ISO, Linear `updatedAt` ISO, `(> 120s)`). Emitted on EVERY drift regardless of disposition (audit trail). This is the SC-016 surface (100% of Linear-ahead cases warn) ✓ 2026-05-29
- [x] T326 [US1] [3] `src/reconcile.sh`: when `fired=1`, branch the write on disposition per the data-model §5 state machine — for US1's no-drift / forward path (`fired=0`) the write proceeds silently with NO prompt and NO warning (SC-017). The interactive prompt + `--on-drift` resolution are US3's T334–T335 wiring; Phase 3 lands only the `fired=0 → write silently` and `fired=1 → emit WARNING then (Phase-3 default) proceed-and-warn` arms so US1 is independently shippable. Idempotent converge on unchanged state (SC-022) ✓ 2026-05-29
- [x] T327 [US1] [3] `src/status.sh`: surface the drift signal + canonical-right-now worktree pointer in `status::compute_drift` (`src/status.sh:424`) and `status::process_spec` per FR-060 — `speckit.linear.status` shows current Linear lifecycle phase, the disk-vs-Linear drift verdict, and (via `git_helpers::worktrees_touching_spec`, T303) the most-recent-commit worktree, from ANY worktree WITHOUT a write. FR-026's surfacing obligation retained; only its coupling to the removed gate is dropped ✓ 2026-05-29
- [x] T328 [US1] [2] `commands/linear-push.md`: rewrite the write-authority section — replace the FR-025 branch-gate language with the drift-aware model (write from any branch is the default; backward-drift surfaces a WARNING; `--retroactive` deprecated). Cross-link the three contracts. Canonical vocab (`lifecycle phase` vs `task phase`, `phase:*` / `task-phase:N` labels, `Phase N — <Name>`, never `wave`) ✓ 2026-05-29

**Checkpoint**: US1 complete and independently testable. An operator on `main` can write a merged spec's terminal state with zero flags; the FR-025 gate is gone; the drift comparator proves `fired=0` on every forward/no-drift case (SC-014 + SC-017 + SC-022 measurable). The non-interactive proceed-and-warn default carries drifted writes (US2/US3 add the disposition controls). `speckit.linear.status` surfaces drift read-only (FR-060).

## Phase 4: User Story 2 — Retroactive first-reconcile just works without a flag (P2)

**Story goal**: an operator installs the bridge into an existing repo (mix of merged + in-flight specs, no worktree on any feature branch) and runs the first reconcile with NO flags; every enumerated spec converges to its filesystem-derived state. A pasted v0.1.1 command still carrying `--retroactive` runs unchanged and prints one deprecation INFO row. P2 because P1's write-from-anywhere mechanism is the prerequisite.

**Independent test criteria**: in a fresh repo with several existing specs (none on a feature-branch worktree), run the first reconcile with zero flags and confirm every spec converges to its current state with backward-drift warnings ONLY where Linear is genuinely ahead (none, on a fresh install — Linear starts empty); confirm `--retroactive` emits exactly one INFO row with identical results to omitting it.

### Tests for User Story 2

- [x] T329 [P] [US2] [2] `tests/unit/drift_disposition.bats`: `--retroactive` deprecation INFO — `@test` blocks asserting (a) passing `--retroactive` emits EXACTLY ONE `info` row with the verbatim drift-warning-surface §6 text, (b) the run's spec-processing outcome is byte-identical to omitting the flag (no behavioral global set), (c) the `_RECONCILE_RETROACTIVE_BYPASS_COUNT` warned row no longer appears. Covers FR-061 + SC-021
- [x] T330 [P] [US2] [2] `tests/unit/drift_detection.bats`: absent-Linear-Issue path — `@test` using `spec_issue_absent.json` (T315) asserts `reconcile::compute_drift` returns `fired=0` when the spec Issue does not yet exist (nothing in Linear to be ahead of), so a retroactive first-reconcile creates from disk with no warning. Covers FR-062 convergence contract + drift-detection-graphql.md §5 row 3
- [x] T331 [P] [US2] [3] `tests/integration/drift_e2e.bats`: US2 retroactive first-reconcile end-to-end (skip-gated placeholder) — fresh repo, several specs, no feature-branch worktree, empty Linear; run with zero flags; assert 100% of enumerated specs converge with no write-authority skips and no spurious drift warnings. Covers SC-015 + FR-062 + Acceptance Scenarios 1
- [x] T332 [P] [US2] [2] `tests/integration/drift_e2e.bats`: US2 `--retroactive` parity — run the same flow with `--retroactive`; assert identical convergence + exactly one INFO deprecation row (skip-gated placeholder). Covers SC-021 + Acceptance Scenario 2
- [x] T333 [P] [US2] [2] `tests/unit/drift_disposition.bats`: non-interactive pre-existing-ahead spec — `@test` that with a fixture where one spec's Linear Issue is genuinely ahead (`spec_issue_linear_ahead_phase.json` T310) and stdin is not a TTY with no `--on-drift`, the default proceeds-and-warns (writes disk state + records the WARNING row). Covers FR-056 default + Acceptance Scenario 3

### Implementation for User Story 2

- [x] T334 [US2] [3] `src/reconcile.sh`: wire the non-interactive disposition resolution per FR-056 + drift-warning-surface.md §4 — when `fired=1` AND `[[ ! -t 0 ]]` (no TTY), consult `ARG_ON_DRIFT` (T307): unset/`proceed` → write disk state + keep the WARNING row (proceed-and-warn default); `abort` → skip the spec with the WARNING row + a `skipped` note. MUST NOT hang awaiting input (SC-019). This makes hook/CI reconciles keep converging (Principle VII)
- [x] T335 [US2] [2] `src/reconcile.sh`: confirm the `--retroactive` no-op alias (T308) preserves FR-014's convergence contract independently of the flag (FR-062) — a first reconcile after install converges every enumerated spec without intermediate phase artifacts (no spurious comments, no transitional status flips), now as default behavior; the flag changes nothing but the one INFO row

**Checkpoint**: US2 complete. A retroactive first-reconcile converges 100% of specs with zero flags (SC-015); the `--retroactive` flag is a one-INFO-row no-op (SC-021); the non-interactive proceed-and-warn default never hangs (SC-019, partial — full hang-proof confirmed in US3's `--on-drift` coverage).

## Phase 5: User Story 3 — Multi-worktree backward-drift warning (P3)

**Story goal**: an operator with two worktrees (one `main` behind, one `NNN-feature` ahead) reconciles from `main`; the bridge detects Linear is ahead (backward-drift), prints a structured warning naming both worktrees and which holds the most recent spec-dir commit, and — interactively — prompts proceed/abort; the operator aborts to avoid regressing. P3 because it is the less-common concurrent-worktree case and depends on P1's drift machinery.

**Independent test criteria**: with two worktrees (one `main`, one feature branch ahead) and Linear reflecting the advanced phase, run reconcile from `main` and confirm a structured backward-drift warning naming the worktrees + the most-recent-commit holder, that an interactive abort leaves Linear unchanged (zero diff), an interactive proceed overwrites from `main`'s disk view, and `--on-drift=abort` non-interactively skips with a WARNING row.

### Tests for User Story 3

- [x] T336 [P] [US3] [3] `tests/unit/drift_detection.bats`: `git_helpers::worktrees_touching_spec` ranking — `@test` blocks for (a) single worktree → one line, invoking worktree canonical, (b) two worktrees with different spec-dir commit epochs → the newer-commit worktree is canonical (NOT branch name), (c) tie on epoch → invoking worktree canonical with both in the touching set. Covers FR-058 + FR-059 + recency-comparison.md §4
- [x] T337 [P] [US3] [3] `tests/unit/drift_detection.bats`: `reconcile::compute_drift` drift-fired cases — `@test` blocks for (a) phase-only fire (`spec_issue_linear_ahead_phase.json` T310, recency unavailable) → `fired=1 signals=phase_ordering`, (b) recency-only fire (`spec_issue_linear_ahead_recency.json` T311) → `fired=1 signals=recency`, (c) both fire → `signals=phase_ordering,recency`. **This is the SC-016 load-bearing test** (100% of Linear-ahead cases warn, naming the signal(s))
- [x] T338 [P] [US3] [3] `tests/unit/drift_disposition.bats`: interactive prompt (FR-055) — `@test` blocks via a `read`/`/dev/tty` stub (A10) asserting (a) `p`/`proceed` → disposition `proceed`, (b) `a`/`abort` → `abort`, (c) empty-enter → `abort` (plan A5 safe default), (d) invalid input re-prompts (does not crash, does not silently pick). Covers FR-055 + drift-warning-surface.md §3
- [x] T339 [P] [US3] [2] `tests/unit/drift_disposition.bats`: `--on-drift` override (FR-056) — `@test` blocks asserting `--on-drift=abort` skips a drifted spec with a WARNING + skip note (no prompt even on a TTY-less run), `--on-drift=proceed` writes + warns, and an unrecognised value is a usage error at parse time (plan A6/A11). Covers FR-056 + SC-019
- [x] T340 [P] [US3] [2] `tests/unit/drift_disposition.bats`: skipped-by-operator zero-mutation — `@test` asserting an `abort` disposition produces zero `created`/`updated`/`warned`-mutation events for that spec (only the WARNING + skip rows) — proxy for SC-018's zero-diff. Covers FR-057
- [x] T341 [P] [US3] [3] `tests/integration/drift_e2e.bats`: US3 multi-worktree interactive abort/proceed (skip-gated placeholder) — two worktrees (one `main` behind, one feature ahead), Linear ahead; interactive abort leaves Linear unchanged (zero label timestamps, zero comments, zero relations) AND the WARNING names both worktree paths + the canonical commit holder; interactive proceed overwrites from `main`. Covers SC-018 + SC-020 + Acceptance Scenarios 1–3
- [x] T342 [P] [US3] [2] `tests/integration/drift_e2e.bats`: US3 `--on-drift=abort` non-interactive skip (skip-gated placeholder) — same two-worktree setup run non-interactively with `--on-drift=abort`; assert the drifted spec is skipped with a WARNING row and NO prompt fires. Covers SC-019 + Acceptance Scenario 4

### Implementation for User Story 3

- [x] T343 [US3] [3] `src/reconcile.sh`: wire the interactive prompt per FR-055 + drift-warning-surface.md §3 + plan A5/A10 — when `fired=1` AND `[[ -t 0 ]]`, after emitting the WARNING row, prompt via `read -r ans < /dev/tty` with `[p]roceed / [a]bort (default: abort)`; accept `p`/`proceed`→proceed, `a`/`abort`/empty→abort; invalid re-prompts; MUST NOT consume the spec-enumeration stdin stream. Forward/no-drift writes never prompt
- [x] T344 [US3] [3] `src/reconcile.sh`: implement the abort disposition zero-mutation skip per FR-057 + drift-warning-surface.md §5 — on `abort` (interactive or `--on-drift=abort`), leave the spec's Linear state untouched (zero label-modified timestamps, zero comment posts, zero relation rewrites), emit the `SKIP spec NNN skipped by operator (backward-drift abort) — Linear unchanged` note, and record skipped-by-operator in the summary (SC-018)
- [x] T345 [US3] [3] `src/reconcile.sh` + `src/status.sh`: surface the multi-worktree pointer per FR-058/FR-059 — when `git_helpers::worktrees_touching_spec` (T303) returns >1 touching worktree, append the canonical-worktree + touching-set lines to the drift WARNING row (drift-warning-surface.md §2) AND write the most-recent-commit pointer into the spec Issue memory block (extending FR-004). Single-worktree case collapses these lines to nothing. Ranking by spec-dir commit time, never branch/mtime
- [x] T346 [US3] [2] `commands/linear-status.md`: rewrite the authority-status section as drift-status — `speckit.linear.status` surfaces current Linear lifecycle phase, the disk-vs-Linear drift verdict, and the canonical-right-now worktree pointer (FR-060 + FR-058). Cross-link recency-comparison.md. Canonical vocab throughout

**Checkpoint**: US3 complete. The exact regression FR-025 was written to prevent is now PROTECTED (operator warned, can abort) without ENFORCEMENT (bridge never unilaterally refuses). SC-016 + SC-018 + SC-019 + SC-020 measurable. The full warn-not-block state machine (data-model §5) is in place across interactive prompt + non-interactive `--on-drift`.

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: docs, regression-suite update, sweeps, dogfood, constitution re-check, release.

- [x] T347 [US1] [2] Update the existing v0.1.x reconcile bats suites that asserted the FR-025 read-only skip (the `reconcile::read_only_display` / `non-authoritative worktree … read-only mode` assertions, `src/reconcile.sh:1637`) to assert the new behavior per plan Testing bullet 4 + A14 — write-attempt + drift warning (when Linear ahead) OR silent forward write (when not); these become the SC-022 / FR-060 regression guard. Do NOT delete; repurpose
- [x] T348 [P] [3] `CHANGELOG.md`: add `[0.2.0] - 2026-MM-DD` entry summarising spec 003's surface — 14 new FRs (FR-051..FR-064), 9 new SCs (SC-014..SC-022), the FR-025 branch-gate → drift-aware-warn redefinition (constitution v2.0.0 Principle IV), the `--on-drift` flag, the `--retroactive` deprecation, the multi-worktree canonical pointer. Cross-link `specs/003-drift-aware-authority/spec.md`
- [x] T349 [P] [3] `README.md`: forward-facing wording pass per plan §Project Structure — write-from-any-branch is the default; backward-drift surfaces a warning, never blocks; `--retroactive` deprecated. (Plan notes the v2.0.0 amendment's Sync Impact Report pre-propagated some of this; this task fills residual gaps.) Canonical vocab
- [x] T350 [P] [2] Repo-wide markdownlint sweep — `markdownlint-cli2 specs/003-drift-aware-authority/**/*.md README.md CHANGELOG.md commands/linear-push.md commands/linear-status.md` must be 0 errors against `.markdownlint-cli2.jsonc`
- [x] T351 [P] [2] Repo-wide shellcheck sweep — `shellcheck --shell=bash --severity=style --external-sources src/reconcile.sh src/git_helpers.sh src/status.sh src/summary.sh` must be 0 warnings. Any intentional suppressions documented inline with justification per spec 001/002 precedent
- [ ] T352 [P] [2] `tests/integration/drift_e2e.bats`: wire the full live bodies for the US1/US2/US3 skip-gated placeholders (T320–T322, T331–T332, T341–T342) against a real Linear workspace, alongside the dogfood harness (T353) — the placeholders' assertions become live `RUN_INTEGRATION_TESTS=1` round-trips
- [x] T353 [2] `validation/dogfood-003.md`: re-run the original downstream-consumer dogfood (the 11-spec repo, mostly merged) that motivated this spec — confirm every merged spec now reconciles to Merged from `main` with zero flags (SC-014), the retroactive first-reconcile converges 100% (SC-015), and no spurious drift warnings fire (SC-017). Capture timings + full operator-visible output. Mirrors `validation/dogfood-001.md` / `dogfood-002.md`
- [x] T354 [2] Constitution Re-Check — walk all 8 principles in `.specify/memory/constitution.md` (**v2.0.0**) against spec 003's as-built; confirm the plan-time Constitution Check verdict (all 8 GREEN, Principle IV PASS because spec 003 IS the amended principle's implementation) still holds. Land at `validation/constitution-recheck-003.md`
- [ ] T355 [P] [1] Tag the release: `git tag v0.2.0 -m "Drift-aware write authority (spec 003)"` + GitHub Release referencing the T348 CHANGELOG entry. Gate on T353 dogfood + T354 re-check + all CI green

---

## Dependencies

**Cross-phase dependency rules:**

- **Phase 1 → Phase 2**: setup/sanity (T300 constitution-v2.0.0 confirm) must land first; the gate-removal in US1 is only constitutional under v2.0.0, so T300 is the guard. CI-matrix audit (T301) confirms the three new bats files will run.
- **Phase 2 → Phase 3 + Phase 4 + Phase 5**: every helper (`spec_dir_last_commit` T302, `worktrees_touching_spec` T303, ISO→epoch T304), the `_phase_ordinal` ladder (T305), the `compute_drift` comparator (T306), the `--on-drift`/`--retroactive` arg-parse (T307/T308), the summary plumbing (T309), and the spec-Issue fixtures (T310–T315) MUST land before any user-story test or implementation. They ARE the drift machinery; the fixtures define the mocked Linear responses every unit test depends on.
- **Phase 3 (US1) → Phase 4 (US2) + Phase 5 (US3)**: US1's gate removal (T324) + drift threading (T323) + the silent-forward/proceed-and-warn write arm (T326) are the orchestration spine. US2's non-interactive disposition (T334) and US3's interactive prompt (T343) + abort-skip (T344) layer ON TOP of that spine — they cannot be wired before the FR-025 gate is gone and `compute_drift` is threaded into the write path.
- **Phase 4 (US2) ↔ Phase 5 (US3)**: independent after US1. US2's non-interactive `--on-drift` resolution (T334) and US3's interactive prompt (T343) both branch off the same `fired=1` disposition fork (data-model §5) but in disjoint TTY arms (`[[ -t 0 ]]` vs `[[ ! -t 0 ]]`), so they may be implemented in parallel after US1's checkpoint — BUT both edit the same disposition region of `reconcile.sh`, so sequence them if landing in one branch (see within-phase parallelism).
- **Phase 6 (Polish)**: T347 (regression-suite update) depends on US1's gate removal (T324). T348/T349 (docs) and T350/T351 (sweeps) are independent and may run any time after their target code lands. T352 (live test bodies) → T353 (dogfood) → T354 (constitution re-check) → T355 (release tag) is a strict tail sequence.

**Within-phase parallelism**: every `[P]` task may run in parallel with other `[P]` tasks in the same phase. Sequential (no `[P]`) tasks within a phase depend on earlier tasks in that phase:

- Phase 3 implementation tasks T323–T327 are intentionally sequential (no `[P]`) — T323 (thread compute_drift), T324 (remove gate), T325 (WARNING emitter), T326 (disposition write arm) all edit the same `reconcile::sync_spec_issue` caller region in `src/reconcile.sh`; concurrent edits would conflict. T328 (command doc) is a different file but is sequenced after for review coherence.
- Phase 4 implementation tasks T334–T335 are sequential — same `reconcile.sh` disposition region.
- Phase 5 implementation tasks T343–T345 are sequential — same disposition region; T346 (command doc, different file) sequenced after.

**Story-level independence after Phase 2**: once Phase 2 lands, US1 MUST come before US2 + US3 implementations (the gate removal + comparator threading are the spine), but US2 and US3 implementations may then proceed in parallel (disjoint TTY arms) provided they serialize their edits to the shared `reconcile.sh` disposition region.

## Parallel Execution Examples

### Phase 2 (Foundational) — helpers + comparator + arg-parse + fixtures all at once

```text
T302 [git_helpers::spec_dir_last_commit]   ──┐
T303 [git_helpers::worktrees_touching_spec]──┤
T304 [ISO→epoch converter]                 ──┤
T305 [reconcile::_phase_ordinal]           ──┤── all start in parallel
T306 [reconcile::compute_drift]            ──┤   (new functions / new fixtures;
T307 [--on-drift parse_args]               ──┤    no edit to the sync_spec_issue
T308 [--retroactive deprecation]           ──┤    write path yet)
T309 [summary.sh info type]                ──┤
T310–T315 [spec-Issue fixtures]            ──┘
```

### Phase 3 (US1) — tests in parallel; implementations sequential

```text
T316, T317, T318, T319 (unit tests)          ──┐  parallel — separate @test
T320, T321, T322 (integration, skip-gated)   ──┘  blocks; no edit conflicts

T323 → T324 → T325 → T326 → T327 → T328         sequential — all edit the
(implementations)                                sync_spec_issue caller region
```

### Phase 4 + Phase 5 — US2 and US3 tests fully parallel

```text
T329, T330, T333 (US2 unit) ─┐
T331, T332 (US2 integ)       ─┤  all parallel — disjoint @test blocks
T336–T340 (US3 unit)         ─┤  across drift_detection.bats /
T341, T342 (US3 integ)       ─┘  drift_disposition.bats / drift_e2e.bats

T334 → T335 (US2 impl) and T343 → T344 → T345 (US3 impl): each chain is
internally sequential; the two chains serialize on the shared reconcile.sh
disposition region if landing in one branch.
```

### Phase 6 (Polish) — most parallel; strict release tail

T348, T349, T350, T351 are independent and can land in any order. T347 depends on T324 (gate removal). T352 (live bodies) → T353 (dogfood) → T354 (constitution re-check) → T355 (release tag) is a strict tail sequence.

## Implementation Strategy

**MVP scope (ship-ready end of Phase 3)**: Phase 1 + Phase 2 + Phase 3 (US1) only. At this point the FR-025 branch-gate is removed, an operator on `main` can write a merged spec's terminal state with zero flags, and the drift comparator proves `fired=0` on every forward/no-drift case. SC-014 + SC-017 + SC-022 are measurable. This is the demoable slice that fixes the dominant dogfood failure (merged specs stuck behind the gate).

**Incremental delivery cadence after MVP**:

1. **MVP** (T300–T328) → demoable write-from-`main` for merged specs; FR-025 gate gone; SC-014 + SC-017 + SC-022 satisfied.
2. **+ Retroactive default + deprecation** (T329–T335, US2) → SC-015 + SC-021 + SC-019 (partial); `--retroactive` is a one-INFO-row no-op; hooks/CI keep converging via proceed-and-warn.
3. **+ Multi-worktree drift protection** (T336–T346, US3) → SC-016 + SC-018 + SC-020; interactive prompt + `--on-drift` complete the warn-not-block state machine.
4. **Polish** (T347–T355) → regression-suite update, CHANGELOG/README, markdownlint/shellcheck sweeps, live test bodies, dogfood-003, constitution re-check, release tag.

**Dogfood gate**: T353 is the v0.2.0 moment of truth — re-run the original 11-spec downstream-consumer dogfood that motivated this spec and confirm every merged spec reconciles to Merged from `main` with zero flags. Until that passes and SC-014 + SC-015 + SC-017 measure GREEN, v0.2.0 should NOT tag.

## Format Validation

All 56 tasks above follow the strict format `- [ ] T3NN [P?] [USn?] [N?] Description with file path`. Spot checks:

- T300 — `- [x] T300 [1] Confirm the working tree is on …` ✅ no `[P]`, no `[USn]` (Setup), estimate `[1]`
- T302 — `- [x] T302 [P] [2] src/git_helpers.sh: add git_helpers::spec_dir_last_commit …` ✅ `[P]`, no `[USn]` (Phase 2 Foundational), estimate `[2]`, file path
- T316 — `- [ ] T316 [P] [US1] [2] tests/unit/drift_detection.bats: git_helpers::spec_dir_last_commit …` ✅ `[P]` + `[US1]`, estimate `[2]`, file path
- T324 — `- [ ] T324 [US1] [5] src/reconcile.sh: REMOVE the FR-025 write-gate …` ✅ no `[P]` (sequential within US1's orchestration spine), `[US1]`, estimate `[5]`, file path
- T355 — `- [ ] T355 [P] [1] Tag the release: …` ✅ no `[USn]` (Polish), `[P]`, estimate `[1]`, explicit action

## FR / SC coverage map

Every functional requirement and every success criterion from `spec.md` maps to ≥1 task below:

| FR / SC | Task(s) | Notes |
|---|---|---|
| FR-051 (write from any worktree; supersede FR-025 gate) | T324, T328 | gate removal in the sync_spec_issue caller + command-doc rewrite |
| FR-052 (compute backward-drift from phase ordering + recency) | T305, T306, T323, T318, T337 | ordinal ladder + comparator + threading + no-drift/drift-fired tests |
| FR-053 (recency from git commit time, never mtime) | T302, T304, T316, T317 | `spec_dir_last_commit` helper + epoch converter + unit tests |
| FR-054 (named WARNING row: spec, disk phase, Linear phase, signals) | T325, T337 | WARNING emitter + signal-naming unit test |
| FR-055 (interactive prompt proceed/abort; never block) | T343, T338 | prompt wiring + interactive-prompt unit tests |
| FR-056 (non-interactive proceed-and-warn default + `--on-drift`) | T307, T334, T333, T339 | arg-parse + non-interactive resolution + default/override tests |
| FR-057 (abort → zero Linear mutation, skipped-by-operator) | T344, T340 | zero-mutation skip + unit test |
| FR-058 (multi-worktree set + canonical pointer in warning + memory block) | T303, T345, T336 | `worktrees_touching_spec` + warning/memory surfacing + ranking test |
| FR-059 (canonical pointer uses spec-dir git log, not branch/mtime) | T303, T336 | ranking by commit epoch + tie/ordering test |
| FR-060 (read-only surfacing retained from any worktree) | T327, T346 | `status.sh` drift surface + command-doc rewrite |
| FR-061 (`--retroactive` deprecated no-op alias, one INFO row) | T308, T329 | parse-time INFO + deprecation unit test |
| FR-062 (FR-014 convergence contract preserved as default) | T335, T330, T331 | convergence-without-flag + absent-Issue test + integration |
| FR-063 (idempotency holds through drift path) | T326, T321 | silent-converge write arm + idempotent re-run integration |
| FR-064 (no FS write, no PR mutation, no daemon/db state) | T324, T323 | Layer-D-only gate removal + read-only drift compute (no new state) |
| SC-014 (merged spec from `main`, zero flags → Merged + label cleared) | T320, T353 | US1 integration + dogfood-003 |
| SC-015 (retroactive first-reconcile converges 100%, zero flags) | T331, T330, T353 | US2 integration + absent-Issue test + dogfood |
| SC-016 (100% of Linear-ahead cases warn, naming signals) | T337, T325 | drift-fired comparator test + WARNING emitter |
| SC-017 (0% false positives on forward/no-drift) | T318, T322 | no-drift comparator test (load-bearing) + forward-write integration |
| SC-018 (interactive abort → zero diff on Linear) | T340, T341 | zero-mutation unit test + interactive-abort integration |
| SC-019 (non-interactive never hangs; obeys `--on-drift`) | T339, T334, T342 | `--on-drift` override test + non-interactive resolution + integration |
| SC-020 (multi-worktree warning + memory block name all + canonical) | T336, T341, T345 | ranking test + multi-worktree integration + surfacing |
| SC-021 (`--retroactive` runs identically, one INFO row) | T329, T332 | deprecation unit test + integration parity |
| SC-022 (idempotency through drift path, zero churn) | T321, T318 | idempotent re-run integration + within-skew/no-drift comparator |

Every FR-051..FR-064 appears in ≥1 task; every SC-014..SC-022 appears in ≥1 test task. Verified by `grep -c "FR-0[56][0-9]" tasks.md` and `grep -c "SC-0[12][0-9]" tasks.md`.
