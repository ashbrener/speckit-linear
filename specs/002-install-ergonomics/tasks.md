# Tasks: Install Ergonomics Redesign

**Branch**: `002-install-ergonomics` | **Date**: 2026-05-28 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

**Input**: Design documents under `/specs/002-install-ergonomics/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md).

## Format: `[ID] [P?] [Story?] Description`

- **[P]** — parallelizable with other [P] tasks (different files, no dependencies on incomplete tasks)
- **[USn]** — applies only to user-story phase tasks (User Story 1..3 from spec.md)
- **[N]** — Fibonacci story-point estimate per FR-035 (optional; only when confidently sized)
- Path Conventions per `plan.md` §Project Structure (single-project layout; spec 002 is a strict extension of existing files, no new `src/` modules)
- Task IDs start at `T200` to remain monotonic and disjoint from spec 001's `T001..T084`

## Path Conventions

- Bridge implementation: `src/install.sh` only (extended in place — spec 002 adds ~400 lines per `plan.md` §Project Structure)
- AI-invoked commands: `commands/linear-install.md` (operator-facing algorithm — modified for the new flow)
- Tests: `tests/unit/install_discovery.bats`, `tests/integration/install_e2e_discovery.bats`, `tests/integration/install_e2e_backwards_compat.bats`
- Test fixtures: `tests/fixtures/linear_responses/*.json` (new subdirectory — the only new path spec 002 introduces)
- Operator-facing docs: `README.md` (Install section per FR-047), `CHANGELOG.md` (v0.1.1 entry)
- Dogfood / perf: `scripts/dogfood.sh` (extended), `tests/perf/` (re-used)
- Spec-kit lifecycle: `specs/002-install-ergonomics/*`

## Assumptions Made During /speckit-tasks

These extend `plan.md`'s A1–A8. Each is a judgment call the spec did not explicitly mandate; surface-area for the reviewer.

| # | Assumption | Rationale | Reviewable? |
|---|---|---|---|
| A9 | The discovery flow lands as a single sequential block inside `install::run` rather than as 5 independent state-machine functions. Helper functions (`install::pick_team_interactively`, `install::pick_project_interactively`, `install::prompt_for_api_key`, `install::detect_self_install`, `install::detect_vendored_git`, `install::quick_validate_binding`) are extracted for testability, but the orchestration stays inline so the existing `install::run` audit trail (FR-018b status report → seed-check → Action prompt → summary) remains readable. | Matches plan.md's "~400 added lines to install.sh" budget and the FR-048 single-viewer invariant which is easier to enforce inline than across modules. | yes |
| A10 | `tests/fixtures/linear_responses/` JSON fixtures double as the contract examples in `install-discovery-graphql.md` §1–§4. The bats unit suite asserts byte-equality between fixture inputs and the contract's "Expected response shape" blocks (a one-line `diff` per fixture). | Keeps the contract documents and the test inputs from drifting; matches v0.1.0's `tests/fixtures/specs/` pattern (fixtures-as-contract-examples). | yes |
| A11 | The `--non-interactive` strict-rule regression test (SC-011) lives under `tests/integration/install_e2e_backwards_compat.bats` as a single bats file that exercises rows 1–4 + 8 of `install-flags.md` §5's compat table. We do NOT split it into per-row bats files; one suite, multiple `@test` blocks. | Mirrors spec 001's `tests/integration/us2-*.bats` convention (one bats file per concern); easier for `RUN_INTEGRATION_TESTS=1` gating. | yes |
| A12 | The dogfood extension (T270) runs spec 002's full interactive path against the ACME workspace using a *second* sandbox consumer repo (NOT this repo, to avoid the FR-046 self-install guard). The validation artifact lands at `validation/dogfood-002.md` mirroring `validation/dogfood-001.md`. | FR-046 by design refuses to install into the bridge's own checkout; the dogfood must use a separate consumer repo. | yes |
| A13 | T231's integration test body (live ACME round-trip via piped stdin) lands as a `skip`-gated scaffold during Phase 3 and is wired with the full piped-operator-pick simulation alongside T269's dogfood-002 harness (Phase 6). Rationale: Phase 3's MVP scope is "demoable via fixture-mocked bats unit tests"; the live network round trip is dogfood gating, not US1 testing. The 11 Phase 3 unit tests (T221..T230 + T231 placeholder) cover SC-009 / SC-010 / SC-013 via the fixture-replay path with byte-identical assertions to what the live test would surface. | Keeps the Phase 3 commit's scope tight (no live-network CI churn) while still landing the FR-037..FR-043 + FR-048 end-to-end coverage required by the US1 acceptance scenarios. | yes |
| A14 | The discovery-flow dispatch lives in `install::_should_use_discovery_flow` — a one-line predicate that returns true when none of `--team`, `--project`, `--auto-create` are set. The new viewer-driven path (`install::run_discovery_flow`) runs only when that predicate is true; otherwise the v0.1.0 path (`install::resolve_team_uuid` → `install::resolve_project_uuid` → `install::resolve_operator`) runs bit-for-bit identical to v0.1.0 (SC-011 regression contract). Phase 4 will collapse most legacy paths into discovery-flow fast-path branches via `install::quick_validate_binding`; for Phase 3 the simpler "any v0.1.0 flag triggers v0.1.0 behaviour" rule is the conservative MVP guard. | Keeps the SC-011 backwards-compat regression suite GREEN-by-construction during Phase 3 (no behavioural change to flag-driven paths). | yes |
| A15 | `install::pick_team_interactively` and friends read stdin via `read -r` inside the function body, which means callers MUST redirect via process substitution (`func < <(printf '…')`) NOT pipe (`printf '…' \| func`) — pipes run the function in a subshell, losing the `INSTALL_SESSION_*` state mutations. The bats Phase 3 tests use process substitution throughout. The interactive operator path is unaffected (terminal stdin already works). | The alternative (passing input as args) would have meant duplicating the prompt logic for tests vs operators; process substitution is the bash-3.2-compatible idiom that lets one helper serve both surfaces. | yes |
| A16 | Phase 4 (T248) collapses `install::quick_validate_binding` into a single helper that handles BOTH the `--team --project` (canonical CI) and `--project`-alone (`install-flags.md` §5 row 6) fast paths via a `team_uuid=""` polymorphic call. The §5 row 6 path is implemented inside the same helper rather than as a separate `install::resolve_team_from_project` so the two FR-044 fast paths share one GraphQL query (`team(id) project(id){teams{nodes{id name key}}}`) and one halt-vocab. The companion dispatch (`install::_should_use_discovery_flow`) flips during Phase 4 from "any v0.1.0 flag triggers legacy" (A14's MVP guard) to "only `--auto-create` triggers legacy" so the three `--team`/`--project` combinations all route through the discovery flow's fast-path branches per the install-flags.md §8 truth table. Side-effect: the Phase 2 "T209 stub" bats test (`install_discovery.bats:324`) still expects the stub's no-network behaviour and now fails under the real GraphQL-driven helper — the test agent's Phase 4 T245 coverage supersedes it semantically (same UUIDs-stored assertion plus the three failure modes) and the stub test should be removed or rewritten to mock `graphql::query` in a follow-up. The impl agent intentionally leaves the test file untouched per the Phase 4 brief's no-touch-tests scope. | The single-helper shape avoids two near-identical query bodies and matches install-discovery-graphql.md §5.5's "the same query" guidance; the dispatch flip is the cleanest way to make `--team`-only and `--project`-only route through discovery (which already has the FR-044 short-circuits) without duplicating S5+S6 wiring on the legacy path. | yes |
| A17 | The Phase 4 US2 test tasks T245..T247 land in a NEW unit-level bats file `tests/unit/install_backwards_compat.bats` rather than appending to the existing `tests/unit/install_discovery.bats` (which the original task descriptions point at). Rationale: the test-agent's Phase 4 brief explicitly carved scope as "ONE new bats file with multiple `@test` blocks" (matching A11's framing for the integration suite); keeping the US2 unit tests in their own file mirrors that one-file-per-concern convention and avoids further bloating `install_discovery.bats` (already 67 tests covering Phase 2 + Phase 3 US1). The harness (graphql::query stub + INSTALL_TEST_FIXTURE_DIR + call-count log) is duplicated verbatim across both unit bats files so they remain independently runnable; a follow-up may extract the harness into `tests/unit/_install_helpers.bash` if a third unit file lands. The T241..T244 integration suite still lands at `tests/integration/install_e2e_backwards_compat.bats` per A11 — the file split (unit vs integration) tracks the gating model (always-on vs `RUN_INTEGRATION_TESTS=1`-gated), not the FR group. | Matches A11's "one bats file, multiple @test blocks" cadence and keeps each test file's harness setup readable; the modest harness duplication is a deliberate tradeoff for independence. | yes |
| A18 | The Phase 5 T254 (FR-049 vendored `.git/` warning integration test) invokes the install via `--dev --team <fake-UUID> --project <fake-UUID> --non-interactive` rather than driving the discovery flow to completion. Rationale: the FR-049 row is emitted inside `install::run_dependency_report`, which runs AFTER `install::parse_args`. A plain `--dev` invocation against an `--non-interactive` flagless target reaches the dependency report, but the test must avoid making live GraphQL calls (no `LINEAR_API_KEY`); passing UUID-shaped fake values lets parse_args succeed (FR-045 strict-rule), reaches the dependency report (where T259's FR-049 check surfaces the warning), and the run then exits non-zero on the downstream `quick_validate_binding` call against the fake UUIDs — which is fine, since the assertions cover only the FR-049 surface in `$output` that has already been emitted. The test is no-network and runs at every push. T253 (FR-046) does NOT need this dodge because the self-install guard fires BEFORE parse_args' dependency-report stage. | Keeps the integration test always-on and hermetic without requiring `RUN_INTEGRATION_TESTS=1` or a live key; the alternative (mocking graphql::query inside a bats integration harness) would have duplicated the discovery-test harness from `tests/unit/install_discovery.bats` into the integration tier and broken the bats-tier separation (unit = mocked, integration = live-or-skip). | yes |

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: minimal scaffolding for spec 002. Spec 001 already shipped the repo skeleton, CI matrix, markdownlint config, bats harness, and `tests/fixtures/specs/`. The only setup spec 002 adds is the `tests/fixtures/linear_responses/` directory plus a branch-validation sanity check.

- [x] T200 [1] Confirm working tree is on `002-install-ergonomics` and `.specify/extensions.yml` is unchanged from `main` baseline; abort if either drifted (operator safety — surface state before any test/code edits)
- [x] T201 [P] [1] Create `tests/fixtures/linear_responses/` directory with `.gitkeep` so it survives `git add` before fixtures land in Phase 2
- [x] T202 [P] [1] Extend `.github/workflows/ci.yml` matrix (if not already covered) to ensure `tests/unit/install_discovery.bats` runs on every push and `tests/integration/install_e2e_*.bats` runs when `RUN_INTEGRATION_TESTS=1` — verify the existing matrix rows from T080 already cover spec 002's new bats files (no change expected; confirm-only task)

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: new helper functions inside `src/install.sh`, the seven JSON fixtures, and a `graphql::query` stub used by the unit tests. Every task here is independent of every user-story phase; they MUST land before Phase 3 because the helpers ARE the discovery flow's building blocks. All `[P]` tasks may run in parallel — they touch new code paths (no edits to existing `install::run` orchestration yet).

- [x] T203 [P] [2] `src/install.sh`: add helper `install::detect_self_install` per FR-046 + plan.md A7 — uses `cd "<src>" && pwd -P` and `cd "<target>" && pwd -P` (NO `realpath` dependency) to compare canonical paths; returns 0 when paths differ, 2 with verbatim message from `install-flags.md` §4 when equal. NO filesystem writes on the equal branch
- [x] T204 [P] [2] `src/install.sh`: add helper `install::detect_vendored_git` per FR-049 — checks for `<target>/.specify/extensions/linear/.git/`; on hit emits a `summary::add warned` row with the `rm -rf …` remediation and continues (does NOT halt; does NOT auto-delete — operator consent per Principle VIII)
- [x] T205 [P] [3] `src/install.sh`: add helper `install::prompt_for_api_key` per FR-037 + `install-prompts.md` §2 — implements resolution order (1) `LINEAR_API_KEY` env var, (2) `.env` line, (3) `read -r -s` interactive prompt (echo suppressed). Includes the "Save to .env?" follow-up (§2.3), the `.env` conflict sub-prompt (§2.4 + spec.md Edge Case 8), and EOF handling (§2.5). Halts with exit 2 under `--non-interactive` when (1)+(2) both miss
- [x] T206 [P] [3] `src/install.sh`: add helper `install::pick_team_interactively` per FR-039 + `install-prompts.md` §3 — consumes `INSTALL_SESSION_TEAMS_*` parallel arrays; auto-picks on `len==1` with surface row; halts on `len==0`; renders the `%2d) %-8s — %s` numbered list on `len>=2`; appends overflow warning row on `len>20`; range-validates input and re-prompts on invalid; honors EOF/Ctrl-C halt per §3.6
- [x] T207 [P] [3] `src/install.sh`: add helper `install::pick_project_interactively` per FR-040 + `install-prompts.md` §4 — same numbered-list rendering as T206; appends "Create new project" as the **final** option (index `N+1`) per plan.md A4; handles the `len==0` "Create new is the only option" case; appends overflow warning on `len>20`; sets `project_choice ∈ {attach, create}` from the operator's pick
- [x] T208 [P] [3] `src/install.sh`: add helper `install::prompt_new_project_name` per FR-041 + `install-prompts.md` §5 — default = `basename "$(git rev-parse --show-toplevel)"` per plan.md A6; runs the duplicate-name pre-check query (reuses existing `install::_find_existing_project` at `src/install.sh:843`) and renders the `[create-anyway/pick-existing/rename]` triage prompt per §5.3; loops on `rename`
- [x] T209 [P] [2] `src/install.sh`: add helper `install::quick_validate_binding` per FR-044 + `install-discovery-graphql.md` §5.5 — issues a single combined `team(id){...} project(id){... teams{nodes{id}}}` query when both `--team` and `--project` are passed; halts with exit 2 on null team / null project / team-mismatch
- [x] T210 [P] [1] `src/install.sh`: extend `install::parse_args` (`src/install.sh:284`) to update `--help` text per `install-flags.md` §9 and to log the soft-deprecation notice for `--auto-create` when used interactively per `install-flags.md` §2 (no behavioral change to the flag itself — preserved bit-for-bit)
- [x] T211 [P] [1] `tests/fixtures/linear_responses/viewer.json` — sample `viewer { id name email organization { name urlKey } }` response per `install-discovery-graphql.md` §1; double-duty as contract example per plan.md A10
- [x] T212 [P] [1] `tests/fixtures/linear_responses/teams_single.json` — single-team fixture for FR-039 auto-pick branch
- [x] T213 [P] [1] `tests/fixtures/linear_responses/teams_multi.json` — three-team fixture for FR-039 numbered-list branch
- [x] T214 [P] [1] `tests/fixtures/linear_responses/teams_overflow.json` — 21-team fixture for FR-039 overflow warning branch (Clarifications Q2 + spec.md Edge Case 2)
- [x] T215 [P] [1] `tests/fixtures/linear_responses/teams_zero.json` — zero-team fixture for FR-039 halt branch (spec.md Edge Case 1)
- [x] T216 [P] [1] `tests/fixtures/linear_responses/projects_empty.json` — zero-project fixture for FR-040 "Create new is the only option" branch
- [x] T217 [P] [1] `tests/fixtures/linear_responses/projects_multi.json` — multi-project fixture for FR-040 numbered-list branch
- [x] T218 [P] [1] `tests/fixtures/linear_responses/projectCreate_ok.json` — successful `projectCreate` response fixture for FR-041 (includes `project.url` for the install-summary "open in Linear" row)
- [x] T219 [P] [1] `tests/fixtures/linear_responses/projectCreate_fail.json` — `projectCreate.success: false` fixture for FR-041 failure path (verbatim Linear permission error)
- [x] T220 [P] [2] `tests/unit/install_discovery.bats`: scaffold a `graphql::query` stub that reads `INSTALL_TEST_FIXTURE_PATH` and emits the named JSON fixture from T211–T219; covers the four discovery operations (viewer, teams, team.projects, projectCreate). NO live network access — pure fixture replay

**Checkpoint**: helpers and fixtures land; `bats tests/unit/install_discovery.bats` is empty-pass (no tests yet); `shellcheck src/install.sh` clean. The discovery state machine's building blocks exist but are not wired into `install::run` yet.

## Phase 3: User Story 1 — Interactive install (P1)

**Story goal**: a first-time operator with only a Linear API key runs `/speckit.linear.install` and completes the install in under 2 minutes without ever seeing a UUID — the install discovers team + project + operator identity by querying Linear with the operator's key.

**Independent test criteria**: with a fresh sandbox consumer repo and a seeded ACME workspace, invoke `bash src/install.sh` (no flags) with a piped `LINEAR_API_KEY=<live-key>`, simulate operator picks via piped stdin, assert (a) zero UUIDs surfaced on stdout/stderr (SC-010), (b) `linear-config.yml` written with valid resolved UUIDs, (c) total wall-clock under 2 min (SC-009), (d) hook registration ran AFTER config write.

### Tests for User Story 1

- [x] T221 [P] [US1] [3] `tests/unit/install_discovery.bats`: API key resolution — three `@test` blocks covering (a) `LINEAR_API_KEY` env var precedence, (b) `.env` line fallback, (c) interactive `read -s` fallback. Each asserts `INSTALL_SESSION_API_KEY` is populated and `api_key_source` is set correctly. Covers FR-037 resolution order
- [x] T222 [P] [US1] [2] `tests/unit/install_discovery.bats`: API key `.env` save flow — asserts "Save to .env?" Y appends to `.env`, ensures `.env` is in `.gitignore` (appends if absent), and asserts N skips the write. Covers FR-037 + plan.md A5
- [x] T223 [P] [US1] [2] `tests/unit/install_discovery.bats`: `.env` conflict triage — three `@test` blocks for `overwrite` / `keep` / `abort` per `install-prompts.md` §2.4 + spec.md Edge Case 8
- [x] T224 [P] [US1] [2] `tests/unit/install_discovery.bats`: viewer query single-fire invariant — asserts that across one full install run, `graphql::query` is invoked with the viewer query exactly ONCE (FR-038 + FR-048). Uses the T220 stub's call counter
- [x] T225 [P] [US1] [3] `tests/unit/install_discovery.bats`: team picker branches — auto-pick (T212 fixture), multi-pick (T213 fixture), zero-halt (T215 fixture), overflow-warn (T214 fixture). Each asserts the picker's stdout text + the resulting `selected_team_id` (internal — not the operator-visible surface). Covers FR-039 + SC-013
- [x] T226 [P] [US1] [3] `tests/unit/install_discovery.bats`: project picker branches — empty-list "Create new only" (T216 fixture), multi-pick attach (T217 fixture), pick "Create new" tail option (T217 + N+1 choice). Covers FR-040 + plan.md A4
- [x] T227 [P] [US1] [3] `tests/unit/install_discovery.bats`: `projectCreate` happy path + duplicate-name triage — uses T218 fixture for success, asserts `selected_project_url` populated; uses a synthetic duplicate-match response to exercise the `[create-anyway/pick-existing/rename]` prompt per `install-prompts.md` §5.3. Covers FR-041 + spec.md Edge Case 4
- [x] T228 [P] [US1] [2] `tests/unit/install_discovery.bats`: `projectCreate` failure surface — uses T219 fixture; asserts exit code 1 and verbatim Linear error text. Covers FR-041 failure mode
- [x] T229 [P] [US1] [2] `tests/unit/install_discovery.bats`: write-order invariant — asserts that on a successful run, `linear-config.yml` is written BEFORE any hook registration / git-hook install call fires. Uses a mock hook-install dispatcher that records call order. Covers FR-042 + FR-043
- [x] T230 [P] [US1] [3] `tests/unit/install_discovery.bats`: SC-010 zero-UUID surface assertion — runs the full discovery flow with multi-team + multi-project fixtures, captures all stdout/stderr, asserts ZERO matches for the UUID regex `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`. Single load-bearing test for SC-010
- [x] T231 [P] [US1] [3] `tests/integration/install_e2e_discovery.bats`: full interactive flow vs live ACME (gated on `RUN_INTEGRATION_TESTS=1` + `LINEAR_API_KEY`) — pipes operator picks via stdin, asserts `linear-config.yml` lands with valid resolved UUIDs, `linear.operator.{user_id,name,email}` populated from viewer, `linear.workspace.{name,url_key}` populated from viewer's organization. Covers FR-037..FR-043 + FR-048 end-to-end. **Phase 3 lands the scaffold + skip-gated placeholder**; full live-network body lands with T269 dogfood-002 harness per A13

### Implementation for User Story 1

- [x] T232 [US1] [5] `src/install.sh`: wire S0 → S1 → S2 into `install::run` — `install::main` now dispatches via `install::_should_use_discovery_flow` to `install::run_discovery_flow` (the new spec-002 path) or the legacy v0.1.0 path (`install::resolve_team_uuid` → `install::resolve_project_uuid` → `install::resolve_operator`). The discovery path calls `install::prompt_for_api_key` (FR-037) → `install::resolve_operator` (FR-038 + FR-048) → `install::discover_teams` → `install::pick_team_interactively` → `install::discover_projects` → `install::pick_project_interactively` → `install::run_create_project_branch` (when choice=create). Self-install + vendored-`.git/` guards stay in their Phase 5 wiring slots (T258 + T259) so Phase 3 doesn't entangle US3
- [x] T233 [US1] [3] `src/install.sh`: extended the viewer query (`install::resolve_operator`) field selection to `viewer { id name email organization { name urlKey } }` per `install-discovery-graphql.md` §1 — the same single-fire response populates `INSTALL_SESSION_VIEWER_*` (FR-048) and feeds `install::_write_workspace_block`, `install::_write_team_block`, `install::_write_project_block` for `linear.{workspace,team,project}` fields in `linear-config.yml`. `install::_write_operator_block` now reads `INSTALL_SESSION_VIEWER_*` as preferred source (falls back to v0.1.0 `INSTALL_OPERATOR_*` globals for the legacy path)
- [x] T234 [US1] [3] `src/install.sh`: implemented `install::discover_teams` — issues `teams(first: 21)` per `install-discovery-graphql.md` §2, populates `INSTALL_SESSION_TEAMS_*` parallel arrays; `--team <UUID>` short-circuits the query+picker entirely per FR-044. `install::pick_team_interactively` rewritten with `%2d) %-8s — %s` numbered list, range-validated prompt loop, overflow warning row at >20 teams, EOF halt
- [x] T235 [US1] [3] `src/install.sh`: implemented `install::discover_projects` — issues `team(id).projects(first: 21)` per `install-discovery-graphql.md` §3 with `selected_team_id` variable; `--project <UUID>` short-circuits per FR-044. `install::pick_project_interactively` rewritten with "Create new project" ALWAYS appended as final option (N+1), range validation, overflow warning at >20 projects
- [x] T236 [US1] [5] `src/install.sh`: implemented `install::create_linear_project` — issues `projectCreate(input)` per `install-discovery-graphql.md` §4 with `teamIds: [selected_team_id]` and the fixed description string; captures `project.id/name/url` into `INSTALL_SESSION_SELECTED_PROJECT_*`; on `success: false` halts exit 1 with verbatim Linear error per FR-041 / install-prompts.md §5.6. `install::run_create_project_branch` orchestrates the name prompt → duplicate-name pre-check (`install::_handle_duplicate_name` with `[create-anyway/pick-existing/rename]` triage) → confirm prompt → mutation, with rename-looping per §5.3 / §5.4. `install::prompt_new_project_name` rewritten with full `read -r` prompt + repo-basename default
- [x] T237 [US1] [3] `src/install.sh`: implemented the S6 write-config gate inside `install::main` — asserts both `team_uuid` and `project_uuid` are non-empty BEFORE invoking `install::write_config` (FR-042). On any earlier halt, no filesystem writes to `.specify/extensions/linear/` per data-model.md §4 quit-before-S6 invariant
- [x] T238 [US1] [3] `src/install.sh`: S7 ordering guard in place — `install::register_after_hooks` (FR-031), `install::install_git_hooks` (FR-033), and `install::maybe_prompt_action` + `install::install_github_action` (FR-027) ALL run AFTER `install::write_config` per FR-043. v0.1.0 was already correct here; Phase 3 preserves the order through both the discovery and legacy code paths
- [x] T239 [US1] [3] `src/install.sh`: extended the install summary block — added `Key sourced from: <INSTALL_SESSION_API_KEY_SOURCE>` row (env / dotenv / prompt / interactive_saved) and `Open in Linear: <INSTALL_SESSION_SELECTED_PROJECT_URL>` row per `install-prompts.md` §7. Legacy v0.1.0 `Project resolved: <URL>` row preserved but SC-010-tightened (UUID print removed)
- [x] T240 [US1] [2] `commands/linear-install.md`: rewrote the algorithm section to walk the S0–S7 state machine per `data-model.md` §4 — cross-linked the three contracts (graphql, prompts, flags) and called out --auto-create's soft-deprecation. v0.1.0's "operator's AI agent reads this verbatim" comment density preserved

**Checkpoint**: US1 complete and independently testable. A first-time operator with only an API key can complete `/speckit.linear.install` end-to-end in under 2 minutes; SC-009 + SC-010 + SC-013 testable from this point. CI / scripted install (US2) still validated against the legacy path — Phase 4 tightens the regression coverage.

## Phase 4: User Story 2 — CI / scripted install (P2)

**Story goal**: existing v0.1.0 invocations (`--team <UUID> --project <UUID> [--non-interactive]`) continue to install bit-for-bit identically in v0.1.1. The new `--non-interactive` strict rule (FR-045) halts with a clear remediation when sufficient flags are absent — never falls through to interactive prompts.

**Independent test criteria**: against the live ACME workspace, invoke each of `install-flags.md` §5 rows 1–4 + 8 and assert each produces v0.1.0-identical outcomes (rows 1–4) or the FR-045 halt message (row 8). No prompts fire. Exit codes match `install-flags.md` §6.

### Tests for User Story 2

- [x] T241 [P] [US2] [3] `tests/integration/install_e2e_backwards_compat.bats`: row 1 — `bash src/install.sh --team <UUID> --project <UUID>` against live workspace, asserts identical behavior to v0.1.0 (discovery flow short-circuits at S3+S4 via FR-044 fast path), `linear-config.yml` matches passed UUIDs. Covers SC-011 canonical regression ✓ 2026-05-28
- [x] T242 [P] [US2] [2] `tests/integration/install_e2e_backwards_compat.bats`: row 2 — same as T241 with `--non-interactive` added; asserts zero prompts fire (pipes `/dev/null` to stdin and asserts process completes). Covers FR-044 + FR-045 happy path ✓ 2026-05-28
- [x] T243 [P] [US2] [2] `tests/integration/install_e2e_backwards_compat.bats`: row 3+4 — `--team <UUID> --auto-create [--non-interactive]` produces identical behavior to v0.1.0 (`projectCreate` fires with repo basename name, no P3/P4 prompts). Covers `install-flags.md` §2 deprecation-but-functional guarantee ✓ 2026-05-28
- [x] T244 [P] [US2] [2] `tests/integration/install_e2e_backwards_compat.bats`: row 8 — `bash src/install.sh --non-interactive` (no UUID flags) MUST halt with exit 2 + the verbatim FR-045 message from `install-flags.md` §3.3. Covers FR-045 strict-rule tightening ✓ 2026-05-28
- [x] T245 [P] [US2] [3] `tests/unit/install_backwards_compat.bats` (new file per A17): `install::quick_validate_binding` failure modes — three `@test` blocks for (a) `team == null`, (b) `project == null`, (c) project-team mismatch; each asserts exit 2 + verbatim error text. Covers FR-044 + `install-discovery-graphql.md` §5.5 ✓ 2026-05-28
- [x] T246 [P] [US2] [2] `tests/unit/install_backwards_compat.bats` (new file per A17): `--team <UUID>` alone (no `--project`) — asserts the discovery flow runs P3 (project picker) scoped to the passed team but skips P2 (team picker). Covers FR-044 + `install-flags.md` §5 row 5 ✓ 2026-05-28
- [x] T247 [P] [US2] [2] `tests/unit/install_backwards_compat.bats` (new file per A17): `--project <UUID>` alone (no `--team`) — asserts the discovery flow resolves the team from the project's `team { id }` field per FR-044 + `install-flags.md` §5 row 6; no team picker fires ✓ 2026-05-28

### Implementation for User Story 2

- [x] T248 [US2] [2] `src/install.sh`: wire `install::quick_validate_binding` (T209) into `install::run` — call it after S2 viewer succeeds and before S6 write-config when BOTH `--team` and `--project` are passed. On halt, no filesystem writes. Covers FR-044 §5.5 ✓ 2026-05-28
- [x] T249 [US2] [2] `src/install.sh`: tighten `install::parse_args` (`src/install.sh:362-376`) to enforce the FR-045 strict rule — `--non-interactive` requires BOTH `--team` AND `--project` (or `--team` + `--auto-create` for v0.1.0-compat). Emit the verbatim error from `install-flags.md` §3.3 on violation. Preserve the v0.1.0 `--project` + `--auto-create` mutual-exclusion rule ✓ 2026-05-28
- [x] T250 [US2] [2] `src/install.sh`: ensure `--team <UUID>` alone (no `--project`) routes through P3 project picker scoped to the passed team — the team-flag short-circuits S3 entirely (no `teams` query) and feeds `selected_team_id` directly into S4. Covers FR-044 + `install-flags.md` §5 row 5 ✓ 2026-05-28
- [x] T251 [US2] [2] `src/install.sh`: ensure `--project <UUID>` alone (no `--team`) resolves the team from `project.teams.nodes[0].id` per `install-discovery-graphql.md` §5.5; skip S3 and S4 entirely. Covers FR-044 + `install-flags.md` §5 row 6 ✓ 2026-05-28

**Checkpoint**: US2 complete. SC-011 regression suite GREEN — every v0.1.0 CI invocation pattern works bit-for-bit in v0.1.1. `--non-interactive` strict-rule fail-loud per FR-045. Backwards-compat contract from `install-flags.md` §5 enforceable in CI.

## Phase 5: User Story 3 — Operator docs match operator reality (P3)

**Story goal**: a developer following the README's Install section succeeds on the first command they run. The archive-URL form is the documented path (no `BadZipFile`). The `--dev` self-install case halts with a clear safety message instead of corrupting the filesystem. The vendored `.git/` warning surfaces with operator-actionable remediation.

**Independent test criteria**: in a sandbox, copy-paste each command from the README's Install section and assert success; explicitly invoke `bash src/install.sh --dev` from inside the bridge's own source tree and assert exit 2 + FR-046 message + zero filesystem mutation; install via `--dev` from a path that has a `.git/` directory and assert the FR-049 warning surfaces with remediation.

### Tests for User Story 3

- [x] T252 [P] [US3] [2] `tests/integration/install_e2e_discovery.bats`: SC-012 README walkthrough — exercises the exact `specify extension add --from <archive-URL>` command from README's Install section (per FR-047), asserts the extension installs without `BadZipFile`. Manual test for `specify` CLI behavior; sandbox auto-rolls back ✓ 2026-05-28
- [x] T253 [P] [US3] [3] `tests/integration/install_e2e_discovery.bats`: FR-046 self-install guard — invokes `bash src/install.sh --dev <bridge-source-path>` from inside the bridge's own checkout (target == source), asserts exit 2 + verbatim message from `install-flags.md` §4 + zero filesystem mutations under the target's `.specify/extensions/linear/` ✓ 2026-05-28
- [x] T254 [P] [US3] [2] `tests/integration/install_e2e_discovery.bats`: FR-049 vendored `.git/` warning — sets up a sandbox where the source has a `.git/` directory and runs `--dev` install into a DIFFERENT consumer repo; asserts the FR-049 warning row surfaces in the dependency report and the install summary's "next steps" section ✓ 2026-05-28
- [x] T255 [P] [US3] [1] `tests/unit/install_discovery.bats`: `install::detect_self_install` direct unit test — three `@test` blocks for (a) source != target → exit 0, (b) source == target → exit 2, (c) source == target via different path representations (one absolute, one with trailing slash) — verifies `pwd -P` canonicalization works per plan.md A7 ✓ 2026-05-28
- [x] T256 [P] [US3] [1] `tests/unit/install_discovery.bats`: `install::detect_vendored_git` direct unit test — two `@test` blocks for (a) no `.git/` present → no warning emitted, (b) `.git/` present → exactly one `summary::add warned` call with the remediation string ✓ 2026-05-28

### Implementation for User Story 3

- [x] T257 [US3] [3] `README.md`: update the Install section per FR-047 — document the working `--from <archive-zip-URL>` form (`https://github.com/<owner>/<repo>/archive/refs/heads/main.zip`) as the primary install path; document the working `--dev <path>` form for local development; explicitly warn against the plain `--from <repo-url>` form which errors with `BadZipFile`. Note: this task assumes PR #2 (referenced in the task brief) handled the bulk; this task fills in the residual gaps for `--dev <path>` and the source-equals-target warning callout ✓ 2026-05-28
- [x] T258 [US3] [2] `src/install.sh`: wire `install::detect_self_install` (T203) into the START of `install::run` (S0) — runs BEFORE the existing FR-018b dependency-check report so the operator sees the self-install halt before any other work. Halt with exit 2 per FR-046 + `install-flags.md` §4 ✓ 2026-05-28
- [x] T259 [US3] [2] `src/install.sh`: wire `install::detect_vendored_git` (T204) into `install::run_dependency_report` (`src/install.sh:702`) per plan.md A8 — emits a `[warn]` row in the dependency report; install continues. Add a matching row to the install summary's "next steps" section per `install-prompts.md` §7 ✓ 2026-05-28
- [x] T260 [US3] [1] `commands/linear-install.md`: cross-link the README Install section (FR-047) and call out the FR-046 / FR-049 guard rows in the operator-facing algorithm — the AI agent reading this must understand the self-install halt and the vendored `.git/` remediation ✓ 2026-05-28

**Checkpoint**: US3 complete. SC-012 satisfied — README install commands work on first paste, self-install halts safely, vendored `.git/` surfaces actionable warning. Operator-facing footguns from the first dogfood are closed.

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: docs, performance verification, dogfood, repo-wide sweep, release.

- [ ] T261 [P] [3] `CHANGELOG.md`: add `[0.1.1] - 2026-MM-DD` entry summarising spec 002's surface — 13 new FRs (FR-037..FR-049), 5 new SCs (SC-009..SC-013), the new interactive default flow, the FR-044 + FR-045 backwards-compat tightening, the FR-046 + FR-049 safety guards, and the FR-047 README documentation. Cross-link `specs/002-install-ergonomics/spec.md`
- [x] T262 [P] [3] Extend `scripts/dogfood.sh` to exercise spec 002's new flow — adds a second invocation block that drives the interactive discovery path (with piped stdin operator picks) against a sandbox consumer repo separate from the bridge's own checkout per plan.md A12 + this tasks file's A12 ✓ 2026-05-28
- [x] T263 [P] [2] `commands/linear-install.md`: vocabulary + operator-facing-clarity pass per spec 001's T078 precedent — canonical vocab (`task phase`, `Phase N — <Name>`, never `wave`), fence cleanup, FR cross-refs verified against `spec.md`'s FR-037..FR-049 ✓ 2026-05-28
- [ ] T264 [P] [2] Repo-wide markdownlint sweep — `markdownlint-cli2 specs/002-install-ergonomics/**/*.md README.md CHANGELOG.md commands/linear-install.md` must be 0 errors against `.markdownlint-cli2.jsonc`
- [ ] T265 [P] [2] Repo-wide shellcheck sweep — `shellcheck --shell=bash --severity=style --external-sources src/install.sh` must be 0 warnings. Any intentional suppressions documented inline with justification per spec 001's T081 precedent
- [ ] T266 [P] [3] `tests/perf/`: add a `install-discovery.sh` perf harness measuring the full interactive install wall-clock against fixture-mocked `graphql::query` — asserts SC-009's <2 min budget on a typical multi-team + "Create new" flow, records timings in `tests/perf/baselines.json` under a new `install_discovery` key. Cold/hot delta should match plan.md's "human-time dominates" expectation (>80% of wall-clock is operator reading + typing)
- [ ] T267 [P] [2] `tests/unit/install_discovery.bats`: SC-013 disambiguation regression — assert that for the T213 multi-team fixture, the picker output contains ENOUGH information (team key + name) to disambiguate two same-named teams; if a synthetic collision fixture produces identical key + name, assert the picker surfaces the warning row pointing at `--team <UUID>` per `data-model.md` §2.2 invariants
- [ ] T268 [P] [1] Verify `RUN_INTEGRATION_TESTS=1` CI matrix gating works for the two new integration bats files — `tests/integration/install_e2e_discovery.bats` and `tests/integration/install_e2e_backwards_compat.bats`. Confirms T202's matrix audit landed
- [ ] T269 [2] `validation/dogfood-002.md`: stand up a fresh sandbox consumer repo (NOT the bridge's own checkout per A12), run the v0.1.1 interactive install end-to-end, capture timings against SC-009's 2-min budget, capture the full operator-visible output and confirm SC-010 zero-UUID surface, record any rough edges. Mirrors spec 001's `validation/dogfood-001.md` artifact
- [x] T270 [3] Constitution Re-Check — walk through all 8 principles in `.specify/memory/constitution.md` (v1.0.0) against spec 002's as-built; confirm the plan-time Constitution Check verdict (all 8 GREEN, Principle VI's "OAuth-first at edges" expansion justified) still holds. Land at `validation/constitution-recheck-002.md`
- [ ] T271 [P] [1] Tag the release: `git tag v0.1.1 -m "Install ergonomics redesign (spec 002)"` + GitHub Release (use `gh release create`) referencing the T261 CHANGELOG entry. Gate on T269 dogfood + T270 re-check + all CI green

---

## Dependencies

**Cross-phase dependency rules:**

- **Phase 1 → Phase 2**: setup must land first — `tests/fixtures/linear_responses/` directory exists before Phase 2 fixtures (T211–T219) can land. CI matrix audit (T202) confirms Phase 3 integration tests will run when gated.
- **Phase 2 → Phase 3 + Phase 4 + Phase 5**: every helper function (T203–T210), every JSON fixture (T211–T219), and the `graphql::query` stub (T220) MUST land before any user-story test or implementation task. The helpers ARE the discovery flow's building blocks; the fixtures define the mocked GraphQL responses every unit test depends on.
- **Phase 3 (US1) → Phase 4 (US2)**: US1's S0–S7 wiring (T232–T239) is the orchestration spine. US2's backwards-compat shim (T248–T251) layers on top — `install::quick_validate_binding` runs INSIDE the same `install::run` flow US1 wired. US2 cannot be implemented before US1's discovery-flow orchestration exists.
- **Phase 3 (US1) → Phase 5 (US3)**: US3's safety guards (T258 + T259) wire INTO `install::run`'s S0 and `install::run_dependency_report`. US3 cannot be wired before US1's orchestration spine exists. (Note: US3's README-only task T257 can land in parallel with US1.)
- **Phase 4 + Phase 5 (tails) → Phase 6 (Polish)**: most Phase 6 tasks are independent (CHANGELOG, markdownlint, shellcheck, perf, vocab pass) and may run in parallel with the tail of Phase 5. The dogfood (T269) and constitution re-check (T270) gate the release tag (T271) and MUST come after every other task lands.

**Within-phase parallelism**: every task marked `[P]` may run in parallel with other `[P]` tasks in the same phase. Sequential (no `[P]`) tasks within a phase depend on earlier tasks in that phase:

- Phase 3 implementation tasks T232–T239 are intentionally sequential (no `[P]`) — they all edit `install::run`'s orchestration body inside `src/install.sh`. Concurrent edits would conflict.
- Phase 4 implementation tasks T248–T251 are similarly sequential — same `install::parse_args` + `install::run` edit surface.
- Phase 5 implementation tasks T257 (README — different file) is independent of T258–T260 (which sequence on `install.sh` edits).

**Cross-phase: bats fixtures (Phase 2) block integration tests (Phase 3)**: T211–T220 must land before T221–T231 can run; the unit tests in particular use the fixtures via the T220 stub.

**Story-level independence after Phase 2**: once Phase 2 lands, US1 must come before US2 + US3 implementations (orchestration spine), but US2 and US3 implementations may proceed in parallel after US1's checkpoint.

## Parallel Execution Examples

### Phase 2 (Foundational) — helpers + fixtures + stub all at once

```text
T203 [install::detect_self_install]            ──┐
T204 [install::detect_vendored_git]            ──┤
T205 [install::prompt_for_api_key]             ──┤
T206 [install::pick_team_interactively]        ──┤── all start in parallel
T207 [install::pick_project_interactively]     ──┤   (separate functions; no
T208 [install::prompt_new_project_name]        ──┤    cross-deps; no edit to
T209 [install::quick_validate_binding]         ──┤    install::run yet)
T210 [install::parse_args extensions]          ──┤
T211–T219 [tests/fixtures/linear_responses/*]  ──┤
T220 [graphql::query stub]                     ──┘
```

### Phase 3 (US1) — tests in parallel; implementations sequential

```text
T221, T222, T223, T224, T225, T226, T227,        ──┐  parallel — all separate
T228, T229, T230 (unit tests)                      │  @test blocks in bats
T231 (integration test — gated on                  ─┘  files; no edit conflicts
     RUN_INTEGRATION_TESTS=1)

T232 → T233 → T234 → T235 → T236 → T237 →            sequential — all edit
T238 → T239 → T240 (implementations)                 install::run body
```

### Phase 6 (Polish) — almost all parallel

T261, T262, T263, T264, T265, T266, T267, T268 are independent and can land in any order. T269 (dogfood) → T270 (constitution re-check) → T271 (tag release) is a strict tail sequence.

## Implementation Strategy

**MVP scope (ship-ready end of Phase 3)**: Phase 1 + Phase 2 + Phase 3 (US1) only. At this point the v0.1.1 interactive discovery flow works end-to-end against live Linear; SC-009 + SC-010 + SC-013 are measurable. The v0.1.0 CI path still works (it wasn't broken), but the SC-011 regression suite isn't strict yet. This is the demoable slice that proves the new ergonomics.

**Incremental delivery cadence after MVP**:

1. **MVP** (T200–T240) → demoable interactive install with viewer-driven discovery; SC-009 + SC-010 + SC-013 satisfied.
2. **+ CI regression strictness** (T241–T251, US2) → SC-011 enforceable; FR-044 + FR-045 backwards-compat contract gated in CI.
3. **+ Safety guards + README** (T252–T260, US3) → SC-012 satisfied; first-dogfood footguns closed.
4. **Polish** (T261–T271) → CHANGELOG, vocab pass, markdownlint/shellcheck sweeps, perf harness, dogfood, constitution re-check, release tag.

**Dogfood gate**: T269 is the v0.1.1 moment of truth. Until the bridge has successfully driven its own interactive install end-to-end against a fresh sandbox consumer repo and SC-009 + SC-010 + SC-013 measure GREEN, v0.1.1 should NOT tag.

## Format Validation

All 72 tasks above follow the strict format `- [ ] T2NN [P?] [USn?] [N?] Description with file path`. Spot checks:

- T200 — `- [ ] T200 [1] Confirm working tree is on …` ✅ no `[P]`, no `[USn]` (Setup), estimate `[1]`
- T203 — `- [ ] T203 [P] [2] src/install.sh: add helper install::detect_self_install …` ✅ `[P]`, no `[USn]` (Phase 2 Foundational), estimate `[2]`, file path
- T221 — `- [ ] T221 [P] [US1] [3] tests/unit/install_discovery.bats: API key resolution …` ✅ `[P]` + `[US1]`, estimate `[3]`, file path
- T232 — `- [ ] T232 [US1] [5] src/install.sh: wire S0 → S1 → S2 into install::run …` ✅ no `[P]` (sequential within US1's orchestration spine), `[US1]`, estimate `[5]`, file path
- T271 — `- [ ] T271 [P] [1] Tag the release: …` ✅ no `[USn]` (Polish), `[P]`, estimate `[1]`, explicit action

## FR / SC coverage map

Every functional requirement and every success criterion from `spec.md` maps to ≥1 task below:

| FR / SC | Task(s) | Notes |
|---|---|---|
| FR-037 (API key resolution + `.env` save) | T205, T221, T222, T223 | helper + 3 unit tests across resolution order + save + conflict |
| FR-038 (viewer verification) | T232, T233, T224 | wired into S2 with single-fire invariant test |
| FR-039 (team picker) | T206, T212, T213, T214, T215, T225, T234 | helper + 4 fixtures + branch tests + S3 wiring |
| FR-040 (project picker + Create new tail) | T207, T216, T217, T226, T235 | helper + 2 fixtures + branch tests + S4 wiring |
| FR-041 (projectCreate + duplicate-name pre-check) | T208, T218, T219, T227, T228, T236 | name prompt + 2 fixtures + happy/sad tests + S5 wiring |
| FR-042 (write order — config before hooks) | T229, T237 | order-asserting unit test + S6 gate |
| FR-043 (hook registration after confirmed picks) | T229, T238 | same order test + S7 ordering refactor |
| FR-044 (backwards-compat fast paths) | T209, T245, T246, T247, T248, T250, T251 | quick-validate helper + flag-combination tests + wiring for `--team`-only and `--project`-only |
| FR-045 (`--non-interactive` strict rule) | T244, T249 | regression test + parse_args tightening |
| FR-046 (self-install detection via `pwd -P`) | T203, T253, T255, T258 | helper + integration test + unit test + S0 wiring |
| FR-047 (README docs — archive-URL form + `--dev`) | T257, T252 | README edits + SC-012 walkthrough test |
| FR-048 (single viewer query feeds 3 uses) | T224, T232, T233 | single-fire invariant test + S2 wiring + organization field selection |
| FR-049 (vendored `.git/` detection + warning) | T204, T254, T256, T259 | helper + integration test + unit test + dependency-report wiring |
| SC-009 (< 2 min install) | T231, T266, T269 | integration test wall-clock + perf harness + dogfood |
| SC-010 (zero UUIDs surfaced) | T230 | dedicated regex-based unit test |
| SC-011 (v0.1.0 non-interactive regression) | T241, T242, T243 | integration suite covering compat-table rows 1–4 |
| SC-012 (README install commands succeed first try) | T252, T253, T254 | walkthrough + safety-guard tests |
| SC-013 (operator disambiguates team from key+name alone) | T225, T267 | picker test + dedicated SC-013 disambiguation regression |

Every FR-037..FR-049 appears in ≥1 task; every SC-009..SC-013 appears in ≥1 test task. Verified by `grep -c "FR-0[34][0-9]" tasks.md` and `grep -c "SC-0[01][0-9]" tasks.md`.
