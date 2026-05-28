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
| A12 | The dogfood extension (T270) runs spec 002's full interactive path against the OSH-INFRA workspace using a *second* sandbox consumer repo (NOT this repo, to avoid the FR-046 self-install guard). The validation artifact lands at `validation/dogfood-002.md` mirroring `validation/dogfood-001.md`. | FR-046 by design refuses to install into the bridge's own checkout; the dogfood must use a separate consumer repo. | yes |

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

**Independent test criteria**: with a fresh sandbox consumer repo and a seeded OSH-INFRA workspace, invoke `bash src/install.sh` (no flags) with a piped `LINEAR_API_KEY=<live-key>`, simulate operator picks via piped stdin, assert (a) zero UUIDs surfaced on stdout/stderr (SC-010), (b) `linear-config.yml` written with valid resolved UUIDs, (c) total wall-clock under 2 min (SC-009), (d) hook registration ran AFTER config write.

### Tests for User Story 1

- [ ] T221 [P] [US1] [3] `tests/unit/install_discovery.bats`: API key resolution — three `@test` blocks covering (a) `LINEAR_API_KEY` env var precedence, (b) `.env` line fallback, (c) interactive `read -s` fallback. Each asserts `INSTALL_SESSION_API_KEY` is populated and `api_key_source` is set correctly. Covers FR-037 resolution order
- [ ] T222 [P] [US1] [2] `tests/unit/install_discovery.bats`: API key `.env` save flow — asserts "Save to .env?" Y appends to `.env`, ensures `.env` is in `.gitignore` (appends if absent), and asserts N skips the write. Covers FR-037 + plan.md A5
- [ ] T223 [P] [US1] [2] `tests/unit/install_discovery.bats`: `.env` conflict triage — three `@test` blocks for `overwrite` / `keep` / `abort` per `install-prompts.md` §2.4 + spec.md Edge Case 8
- [ ] T224 [P] [US1] [2] `tests/unit/install_discovery.bats`: viewer query single-fire invariant — asserts that across one full install run, `graphql::query` is invoked with the viewer query exactly ONCE (FR-038 + FR-048). Uses the T220 stub's call counter
- [ ] T225 [P] [US1] [3] `tests/unit/install_discovery.bats`: team picker branches — auto-pick (T212 fixture), multi-pick (T213 fixture), zero-halt (T215 fixture), overflow-warn (T214 fixture). Each asserts the picker's stdout text + the resulting `selected_team_id` (internal — not the operator-visible surface). Covers FR-039 + SC-013
- [ ] T226 [P] [US1] [3] `tests/unit/install_discovery.bats`: project picker branches — empty-list "Create new only" (T216 fixture), multi-pick attach (T217 fixture), pick "Create new" tail option (T217 + N+1 choice). Covers FR-040 + plan.md A4
- [ ] T227 [P] [US1] [3] `tests/unit/install_discovery.bats`: `projectCreate` happy path + duplicate-name triage — uses T218 fixture for success, asserts `selected_project_url` populated; uses a synthetic duplicate-match response to exercise the `[create-anyway/pick-existing/rename]` prompt per `install-prompts.md` §5.3. Covers FR-041 + spec.md Edge Case 4
- [ ] T228 [P] [US1] [2] `tests/unit/install_discovery.bats`: `projectCreate` failure surface — uses T219 fixture; asserts exit code 1 and verbatim Linear error text. Covers FR-041 failure mode
- [ ] T229 [P] [US1] [2] `tests/unit/install_discovery.bats`: write-order invariant — asserts that on a successful run, `linear-config.yml` is written BEFORE any hook registration / git-hook install call fires. Uses a mock hook-install dispatcher that records call order. Covers FR-042 + FR-043
- [ ] T230 [P] [US1] [3] `tests/unit/install_discovery.bats`: SC-010 zero-UUID surface assertion — runs the full discovery flow with multi-team + multi-project fixtures, captures all stdout/stderr, asserts ZERO matches for the UUID regex `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`. Single load-bearing test for SC-010
- [ ] T231 [P] [US1] [3] `tests/integration/install_e2e_discovery.bats`: full interactive flow vs live OSH-INFRA (gated on `RUN_INTEGRATION_TESTS=1` + `LINEAR_API_KEY`) — pipes operator picks via stdin, asserts `linear-config.yml` lands with valid resolved UUIDs, `linear.operator.{user_id,name,email}` populated from viewer, `linear.workspace.{name,url_key}` populated from viewer's organization. Covers FR-037..FR-043 + FR-048 end-to-end

### Implementation for User Story 1

- [ ] T232 [US1] [5] `src/install.sh`: wire S0 → S1 → S2 into `install::run` — call `install::detect_self_install` (FR-046) and `install::detect_vendored_git` (FR-049) at the top of `install::run`; then call `install::prompt_for_api_key` (FR-037); then move the existing `install::resolve_operator` viewer call (currently at `src/install.sh:1093`) to run IMMEDIATELY after key resolution per plan.md A1 so its captured viewer response feeds both FR-034 and the team picker (FR-048 single-fire invariant)
- [ ] T233 [US1] [3] `src/install.sh`: extend the existing viewer query (`install::resolve_operator`) field selection to add `organization { name urlKey }` per `install-discovery-graphql.md` §1 — the same response now populates `linear.workspace.{name,url_key}` in `install::write_config` (`src/install.sh:1145`) replacing whatever path v0.1.0 used. Audit + remove any duplicate viewer queries elsewhere in `install.sh` (FR-048)
- [ ] T234 [US1] [3] `src/install.sh`: implement S3 team-discovery call — issues `teams(first: 21)` per `install-discovery-graphql.md` §2, populates `INSTALL_SESSION_TEAMS_*` parallel arrays, delegates to `install::pick_team_interactively` (T206); when `--team <UUID>` flag is present, skip the query + picker entirely and use the flag verbatim (FR-044 fast path)
- [ ] T235 [US1] [3] `src/install.sh`: implement S4 project-discovery call — issues `team(id).projects(first: 21)` per `install-discovery-graphql.md` §3 with `selected_team_id` as the variable, populates `INSTALL_SESSION_PROJECTS_*`, delegates to `install::pick_project_interactively` (T207); when `--project <UUID>` flag is present, skip the query + picker entirely (FR-044 fast path)
- [ ] T236 [US1] [5] `src/install.sh`: implement S5 `projectCreate` branch — when `project_choice == "create"`, call `install::prompt_new_project_name` (T208), then issue `projectCreate(input)` per `install-discovery-graphql.md` §4 with `teamIds: [selected_team_id]` and the fixed `description` string; capture `project.id`, `project.name`, `project.url` into the InstallSession; on `success: false` halt with the verbatim error per FR-041 + `install-prompts.md` §5.6
- [ ] T237 [US1] [3] `src/install.sh`: implement S6 write-config gate — assert `selected_team_id` AND `selected_project_id` are non-empty BEFORE invoking `install::write_config` (FR-042); on quit-before-S6, exit cleanly with no filesystem writes to `.specify/extensions/linear/`. `linear-config.yml` write is the durable artifact; subsequent hook-registration failures do NOT roll it back
- [ ] T238 [US1] [3] `src/install.sh`: implement S7 ordering guard — verify hook registration (`install::register_after_hooks` per FR-031), local git-hook install (per FR-033), and the optional Action prompt (per FR-027) ALL execute AFTER `install::write_config` per FR-043. Refactor `install::run`'s control flow if v0.1.0 had any of these before config-write
- [ ] T239 [US1] [3] `src/install.sh`: extend the install summary block (`install::emit_summary`) to add the two new rows per `install-prompts.md` §7 — `Key sourced from: <api_key_source>` and `Open in Linear: <selected_project_url>`; preserve all v0.1.0 summary rows verbatim
- [ ] T240 [US1] [2] `commands/linear-install.md`: rewrite the algorithm section to walk the new S0–S7 state machine per `data-model.md` §4; cross-link `quickstart.md` Step 4–8 and the three contracts (graphql, prompts, flags); preserve v0.1.0's "operator's AI agent reads this verbatim" comment density

**Checkpoint**: US1 complete and independently testable. A first-time operator with only an API key can complete `/speckit.linear.install` end-to-end in under 2 minutes; SC-009 + SC-010 + SC-013 testable from this point. CI / scripted install (US2) still validated against the legacy path — Phase 4 tightens the regression coverage.

## Phase 4: User Story 2 — CI / scripted install (P2)

**Story goal**: existing v0.1.0 invocations (`--team <UUID> --project <UUID> [--non-interactive]`) continue to install bit-for-bit identically in v0.1.1. The new `--non-interactive` strict rule (FR-045) halts with a clear remediation when sufficient flags are absent — never falls through to interactive prompts.

**Independent test criteria**: against the live OSH-INFRA workspace, invoke each of `install-flags.md` §5 rows 1–4 + 8 and assert each produces v0.1.0-identical outcomes (rows 1–4) or the FR-045 halt message (row 8). No prompts fire. Exit codes match `install-flags.md` §6.

### Tests for User Story 2

- [ ] T241 [P] [US2] [3] `tests/integration/install_e2e_backwards_compat.bats`: row 1 — `bash src/install.sh --team <UUID> --project <UUID>` against live workspace, asserts identical behavior to v0.1.0 (discovery flow short-circuits at S3+S4 via FR-044 fast path), `linear-config.yml` matches passed UUIDs. Covers SC-011 canonical regression
- [ ] T242 [P] [US2] [2] `tests/integration/install_e2e_backwards_compat.bats`: row 2 — same as T241 with `--non-interactive` added; asserts zero prompts fire (pipes `/dev/null` to stdin and asserts process completes). Covers FR-044 + FR-045 happy path
- [ ] T243 [P] [US2] [2] `tests/integration/install_e2e_backwards_compat.bats`: row 3+4 — `--team <UUID> --auto-create [--non-interactive]` produces identical behavior to v0.1.0 (`projectCreate` fires with repo basename name, no P3/P4 prompts). Covers `install-flags.md` §2 deprecation-but-functional guarantee
- [ ] T244 [P] [US2] [2] `tests/integration/install_e2e_backwards_compat.bats`: row 8 — `bash src/install.sh --non-interactive` (no UUID flags) MUST halt with exit 2 + the verbatim FR-045 message from `install-flags.md` §3.3. Covers FR-045 strict-rule tightening
- [ ] T245 [P] [US2] [3] `tests/unit/install_discovery.bats`: `install::quick_validate_binding` failure modes — three `@test` blocks for (a) `team == null`, (b) `project == null`, (c) project-team mismatch; each asserts exit 2 + verbatim error text. Covers FR-044 + `install-discovery-graphql.md` §5.5
- [ ] T246 [P] [US2] [2] `tests/unit/install_discovery.bats`: `--team <UUID>` alone (no `--project`) — asserts the discovery flow runs P3 (project picker) scoped to the passed team but skips P2 (team picker). Covers FR-044 + `install-flags.md` §5 row 5
- [ ] T247 [P] [US2] [2] `tests/unit/install_discovery.bats`: `--project <UUID>` alone (no `--team`) — asserts the discovery flow resolves the team from the project's `team { id }` field per FR-044 + `install-flags.md` §5 row 6; no team picker fires

### Implementation for User Story 2

- [ ] T248 [US2] [2] `src/install.sh`: wire `install::quick_validate_binding` (T209) into `install::run` — call it after S2 viewer succeeds and before S6 write-config when BOTH `--team` and `--project` are passed. On halt, no filesystem writes. Covers FR-044 §5.5
- [ ] T249 [US2] [2] `src/install.sh`: tighten `install::parse_args` (`src/install.sh:362-376`) to enforce the FR-045 strict rule — `--non-interactive` requires BOTH `--team` AND `--project` (or `--team` + `--auto-create` for v0.1.0-compat). Emit the verbatim error from `install-flags.md` §3.3 on violation. Preserve the v0.1.0 `--project` + `--auto-create` mutual-exclusion rule
- [ ] T250 [US2] [2] `src/install.sh`: ensure `--team <UUID>` alone (no `--project`) routes through P3 project picker scoped to the passed team — the team-flag short-circuits S3 entirely (no `teams` query) and feeds `selected_team_id` directly into S4. Covers FR-044 + `install-flags.md` §5 row 5
- [ ] T251 [US2] [2] `src/install.sh`: ensure `--project <UUID>` alone (no `--team`) resolves the team from `project.teams.nodes[0].id` per `install-discovery-graphql.md` §5.5; skip S3 and S4 entirely. Covers FR-044 + `install-flags.md` §5 row 6

**Checkpoint**: US2 complete. SC-011 regression suite GREEN — every v0.1.0 CI invocation pattern works bit-for-bit in v0.1.1. `--non-interactive` strict-rule fail-loud per FR-045. Backwards-compat contract from `install-flags.md` §5 enforceable in CI.

## Phase 5: User Story 3 — Operator docs match operator reality (P3)

**Story goal**: a developer following the README's Install section succeeds on the first command they run. The archive-URL form is the documented path (no `BadZipFile`). The `--dev` self-install case halts with a clear safety message instead of corrupting the filesystem. The vendored `.git/` warning surfaces with operator-actionable remediation.

**Independent test criteria**: in a sandbox, copy-paste each command from the README's Install section and assert success; explicitly invoke `bash src/install.sh --dev` from inside the bridge's own source tree and assert exit 2 + FR-046 message + zero filesystem mutation; install via `--dev` from a path that has a `.git/` directory and assert the FR-049 warning surfaces with remediation.

### Tests for User Story 3

- [ ] T252 [P] [US3] [2] `tests/integration/install_e2e_discovery.bats`: SC-012 README walkthrough — exercises the exact `specify extension add --from <archive-URL>` command from README's Install section (per FR-047), asserts the extension installs without `BadZipFile`. Manual test for `specify` CLI behavior; sandbox auto-rolls back
- [ ] T253 [P] [US3] [3] `tests/integration/install_e2e_discovery.bats`: FR-046 self-install guard — invokes `bash src/install.sh --dev <bridge-source-path>` from inside the bridge's own checkout (target == source), asserts exit 2 + verbatim message from `install-flags.md` §4 + zero filesystem mutations under the target's `.specify/extensions/linear/`
- [ ] T254 [P] [US3] [2] `tests/integration/install_e2e_discovery.bats`: FR-049 vendored `.git/` warning — sets up a sandbox where the source has a `.git/` directory and runs `--dev` install into a DIFFERENT consumer repo; asserts the FR-049 warning row surfaces in the dependency report and the install summary's "next steps" section
- [ ] T255 [P] [US3] [1] `tests/unit/install_discovery.bats`: `install::detect_self_install` direct unit test — three `@test` blocks for (a) source != target → exit 0, (b) source == target → exit 2, (c) source == target via different path representations (one absolute, one with trailing slash) — verifies `pwd -P` canonicalization works per plan.md A7
- [ ] T256 [P] [US3] [1] `tests/unit/install_discovery.bats`: `install::detect_vendored_git` direct unit test — two `@test` blocks for (a) no `.git/` present → no warning emitted, (b) `.git/` present → exactly one `summary::add warned` call with the remediation string

### Implementation for User Story 3

- [ ] T257 [US3] [3] `README.md`: update the Install section per FR-047 — document the working `--from <archive-zip-URL>` form (`https://github.com/<owner>/<repo>/archive/refs/heads/main.zip`) as the primary install path; document the working `--dev <path>` form for local development; explicitly warn against the plain `--from <repo-url>` form which errors with `BadZipFile`. Note: this task assumes PR #2 (referenced in the task brief) handled the bulk; this task fills in the residual gaps for `--dev <path>` and the source-equals-target warning callout
- [ ] T258 [US3] [2] `src/install.sh`: wire `install::detect_self_install` (T203) into the START of `install::run` (S0) — runs BEFORE the existing FR-018b dependency-check report so the operator sees the self-install halt before any other work. Halt with exit 2 per FR-046 + `install-flags.md` §4
- [ ] T259 [US3] [2] `src/install.sh`: wire `install::detect_vendored_git` (T204) into `install::run_dependency_report` (`src/install.sh:702`) per plan.md A8 — emits a `[warn]` row in the dependency report; install continues. Add a matching row to the install summary's "next steps" section per `install-prompts.md` §7
- [ ] T260 [US3] [1] `commands/linear-install.md`: cross-link the README Install section (FR-047) and call out the FR-046 / FR-049 guard rows in the operator-facing algorithm — the AI agent reading this must understand the self-install halt and the vendored `.git/` remediation

**Checkpoint**: US3 complete. SC-012 satisfied — README install commands work on first paste, self-install halts safely, vendored `.git/` surfaces actionable warning. Operator-facing footguns from the first dogfood are closed.

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: docs, performance verification, dogfood, repo-wide sweep, release.

- [ ] T261 [P] [3] `CHANGELOG.md`: add `[0.1.1] - 2026-MM-DD` entry summarising spec 002's surface — 13 new FRs (FR-037..FR-049), 5 new SCs (SC-009..SC-013), the new interactive default flow, the FR-044 + FR-045 backwards-compat tightening, the FR-046 + FR-049 safety guards, and the FR-047 README documentation. Cross-link `specs/002-install-ergonomics/spec.md`
- [ ] T262 [P] [3] Extend `scripts/dogfood.sh` to exercise spec 002's new flow — adds a second invocation block that drives the interactive discovery path (with piped stdin operator picks) against a sandbox consumer repo separate from the bridge's own checkout per plan.md A12 + this tasks file's A12
- [ ] T263 [P] [2] `commands/linear-install.md`: vocabulary + operator-facing-clarity pass per spec 001's T078 precedent — canonical vocab (`task phase`, `Phase N — <Name>`, never `wave`), fence cleanup, FR cross-refs verified against `spec.md`'s FR-037..FR-049
- [ ] T264 [P] [2] Repo-wide markdownlint sweep — `markdownlint-cli2 specs/002-install-ergonomics/**/*.md README.md CHANGELOG.md commands/linear-install.md` must be 0 errors against `.markdownlint-cli2.jsonc`
- [ ] T265 [P] [2] Repo-wide shellcheck sweep — `shellcheck --shell=bash --severity=style --external-sources src/install.sh` must be 0 warnings. Any intentional suppressions documented inline with justification per spec 001's T081 precedent
- [ ] T266 [P] [3] `tests/perf/`: add a `install-discovery.sh` perf harness measuring the full interactive install wall-clock against fixture-mocked `graphql::query` — asserts SC-009's <2 min budget on a typical multi-team + "Create new" flow, records timings in `tests/perf/baselines.json` under a new `install_discovery` key. Cold/hot delta should match plan.md's "human-time dominates" expectation (>80% of wall-clock is operator reading + typing)
- [ ] T267 [P] [2] `tests/unit/install_discovery.bats`: SC-013 disambiguation regression — assert that for the T213 multi-team fixture, the picker output contains ENOUGH information (team key + name) to disambiguate two same-named teams; if a synthetic collision fixture produces identical key + name, assert the picker surfaces the warning row pointing at `--team <UUID>` per `data-model.md` §2.2 invariants
- [ ] T268 [P] [1] Verify `RUN_INTEGRATION_TESTS=1` CI matrix gating works for the two new integration bats files — `tests/integration/install_e2e_discovery.bats` and `tests/integration/install_e2e_backwards_compat.bats`. Confirms T202's matrix audit landed
- [ ] T269 [2] `validation/dogfood-002.md`: stand up a fresh sandbox consumer repo (NOT the bridge's own checkout per A12), run the v0.1.1 interactive install end-to-end, capture timings against SC-009's 2-min budget, capture the full operator-visible output and confirm SC-010 zero-UUID surface, record any rough edges. Mirrors spec 001's `validation/dogfood-001.md` artifact
- [ ] T270 [3] Constitution Re-Check — walk through all 8 principles in `.specify/memory/constitution.md` (v1.0.0) against spec 002's as-built; confirm the plan-time Constitution Check verdict (all 8 GREEN, Principle VI's "OAuth-first at edges" expansion justified) still holds. Land at `validation/constitution-recheck-002.md`
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
