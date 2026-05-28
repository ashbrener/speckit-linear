# Tasks: spec-kit ↔ Linear Bridge

**Branch**: `001-spec-kit-linear-bridge` | **Date**: 2026-05-28 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

**Input**: Design documents under `/specs/001-spec-kit-linear-bridge/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md).

## Format: `[ID] [P?] [Story?] Description`

- **[P]** — parallelizable with other [P] tasks (different files, no dependencies on incomplete tasks)
- **[USn]** — applies only to user-story phase tasks (User Story 1..5 from spec.md)
- Path Conventions per `plan.md` §Project Structure (single-project layout, parallel `commands/` AI markdown + `src/` bash)

## Path Conventions

- Bridge implementation: `src/*.sh` (bash 4+)
- AI-invoked commands: `commands/*.md` (algorithmic markdown)
- Templates shipped to consumer repos: `templates/`
- Tests: `tests/unit/*.bats`, `tests/integration/*.bats`, `tests/fixtures/specs/*`
- Manifests: `extension.yml`, `config-template.yml` (already present, drafted during /speckit-plan)
- Spec-kit lifecycle: `specs/001-spec-kit-linear-bridge/*`

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 [3] Create the bridge's source-tree skeleton: `src/`, `commands/`, `templates/git-hooks/`, `tests/unit/`, `tests/integration/`, `tests/fixtures/specs/` per `plan.md` §Project Structure ✓ 2026-05-28
- [x] T002 [P] [1] Apply markdown-lint CI fix per `validation/ci-markdownlint-diagnosis.md`: write `.markdownlint-cli2.jsonc` at repo root, edit `.github/workflows/ci.yml` to drop the broken inline `--config '{...}'` flag (so the linter discovers the config file via auto-discovery), confirm CI goes green on next push ✓ Applied by markdown-lint fix agent on 2026-05-28.
- [x] T003 [P] [1] Document local dev install in `CONTRIBUTING.md` §Code style: `bash 4+` (macOS `brew install bash`), `bats-core 1.11.0`, `shellcheck`, `jq 1.6+`, `markdownlint-cli2`. Cross-link to CI workflow file ✓ 2026-05-28
- [x] T004 [P] [1] Add `tests/unit/.gitkeep`, `tests/integration/.gitkeep`, `tests/fixtures/specs/.gitkeep` so empty directories survive `git add` ✓ 2026-05-28

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: shared bash modules every user story depends on. Each module is self-contained — within this phase, all `[P]` tasks may run in parallel (separate files, no dependencies between modules).

- [x] T005 [P] Implement `src/config.sh` — loads and validates `.specify/extensions/linear/linear-config.yml` per `contracts/config-schema.json`. Exposes `config::load`, `config::get_team_id`, `config::get_project_id`, `config::get_workflow_state_uuid <lifecycle_phase>`. Validates every UUID present + well-formed; fails loud on missing fields per Principle VIII ✓ 2026-05-28
- [x] T006 [P] Implement `src/graphql.sh` — curl-based Linear GraphQL client. Exposes `graphql::query <query> <vars-json>` and `graphql::mutate <mutation> <vars-json>`. Reads `LINEAR_API_KEY` from `.env`. Handles HTTP 4xx (auth, halt), 5xx (retry once with backoff), and GraphQL `errors[]` (surface and halt). Returns response JSON on stdout ✓ 2026-05-28
- [x] T007 [P] Implement `src/git_helpers.sh` — `git_helpers::current_branch`, `git_helpers::list_worktrees`, `git_helpers::worktree_for_branch <branch>`, `git_helpers::is_authoritative_for_spec <NNN>` (returns 0 iff current branch matches `<NNN>-*`), `git_helpers::pr_state <branch>` (uses `gh pr view --json` when available, falls back to `git merge-base --is-ancestor origin/main <branch>` per FR-030) ✓ 2026-05-28
- [x] T008 [P] Implement `src/summary.sh` — structured summary emitter per Principle VIII. `summary::start`, `summary::add <type> <message>` (where type ∈ created|updated|archived|warned|skipped|error), `summary::emit` (prints final structured block to stderr). Suppresses ANSI when stderr is not a tty ✓ 2026-05-28
- [x] T009 [P] Implement `src/parser.sh` — markdown parser for spec-kit artifacts. `parser::feature_number <spec_dir>`, `parser::lifecycle_phase <spec_dir>` (infers from artifact presence per spec FR-012), `parser::task_phases <tasks_md_path>` (parses `## Phase N: <Name>` headers), `parser::tasks_in_phase <tasks_md_path> <N>` (extracts checklist items), `parser::clarify_sessions <spec_md_path>` (extracts `### Session YYYY-MM-DD` blocks) ✓ 2026-05-28
- [x] T010 [P] tests/unit/config.bats — unit tests for `src/config.sh` (valid config, missing field, malformed UUID, missing file) ✓ 2026-05-28
- [x] T011 [P] tests/unit/graphql.bats — unit tests for `src/graphql.sh` against a local HTTP fixture (no live Linear) ✓ 2026-05-28
- [x] T012 [P] tests/unit/git_helpers.bats — unit tests for `src/git_helpers.sh` using temp git repos with multiple worktrees ✓ 2026-05-28
- [x] T013 [P] tests/unit/summary.bats — unit tests for `src/summary.sh` (counts, ordering, tty detection) ✓ 2026-05-28
- [x] T014 [P] tests/unit/parser.bats — unit tests for `src/parser.sh` against `tests/fixtures/specs/*` ✓ 2026-05-28
- [x] T015 [P] tests/fixtures/specs/001-minimal/ — synthetic spec with `spec.md` only (Specifying phase) ✓ 2026-05-28
- [x] T016 [P] tests/fixtures/specs/002-multi-phase/ — synthetic spec with `spec.md`, `plan.md`, `tasks.md` containing 3 task phases and inter-phase deps (Tasking phase) ✓ 2026-05-28
- [x] T017 [P] tests/fixtures/specs/003-malformed-tasks/ — `tasks.md` with task lines outside any `## Phase` header (parser warning case) ✓ 2026-05-28
- [x] T018 [P] tests/fixtures/specs/004-already-merged/ — fully-complete spec with `spec.md`, `plan.md`, `tasks.md`, `analyze*.md`, plus a fixture `gh` PR-state mock returning `merged: true` (retroactive sync target) ✓ 2026-05-28
- [x] T019 [P] tests/fixtures/specs/005-clarify-sessions/ — `spec.md` with three `### Session YYYY-MM-DD` clarify blocks (comment-mirroring target) ✓ 2026-05-28

**Checkpoint**: All foundational tasks GREEN under `bats tests/unit/` + `shellcheck src/*.sh`. CI workflow passes on push. Implementation phases (US1–US5) may begin.

## Phase 3: User Story 1 — Filesystem-to-Linear reconciliation (P1) 🎯 MVP

**Story goal**: Given any consumer repo with `specs/NNN-feature/` directories and a seeded Linear workspace, running the reconciler produces a faithful Linear mirror (Project + spec Issues + task-phase sub-issues + checklists + clarify-comment thread). Re-running with no filesystem changes produces zero churn.

**Independent test criteria**: place a synthetic `specs/NNN-feature/` (fixture from T016 or T019) into a sandbox consumer repo bound to a sandbox Linear workspace, invoke the reconciler, verify Linear matches; re-invoke and confirm zero observable change.

### Tests for User Story 1

- [x] T020 [P] [US1] tests/integration/us1-fresh-reconcile.bats — given fixture 002, run reconciler from a clean Linear state, assert (a) one Project exists with right name + status, (b) one Issue exists with title + `phase:tasking` label + memory block, (c) three sub-issues exist with checklists matching the fixture's `## Phase N` blocks, (d) blocking relations between sub-issues match inter-phase deps ✓ 2026-05-28
- [x] T021 [P] [US1] tests/integration/us1-idempotent-rerun.bats — same as T020 but invoke reconciler twice and assert the second run mutates nothing in Linear (zero label-modified timestamps, zero new comments) ✓ 2026-05-28
- [x] T022 [P] [US1] tests/integration/us1-task-added.bats — start from a synced fixture, add one task to one phase's `tasks.md`, re-invoke, assert exactly one checklist line changes in exactly one sub-issue and nothing else ✓ 2026-05-28
- [x] T023 [P] [US1] tests/integration/us1-clarify-mirror.bats — given fixture 005, run reconciler, assert three Issue comments appear in chronological order matching the three `### Session YYYY-MM-DD` blocks ✓ 2026-05-28

### Implementation for User Story 1

- [x] T024 [US1] Implement `src/reconcile.sh` skeleton: argument parsing (`--spec NNN`, `--all`, `--dry-run`), config loading, MCP-or-GraphQL routing (sources `config.sh`, `graphql.sh`, `summary.sh`, `git_helpers.sh`, `parser.sh`) ✓ 2026-05-28
- [x] T025 [US1] `src/reconcile.sh`: per-spec reconcile loop body — for each `specs/NNN-feature/`, call `parser::lifecycle_phase`, `parser::task_phases`, then the find-or-create/update flow for the spec Issue (looked up by workspace label `speckit-spec:NNN` within the repo's Project per FR-004b) ✓ 2026-05-28
- [x] T026 [US1] `src/reconcile.sh`: memory block computation — branch (`git_helpers::current_branch`), worktree list (`git_helpers::list_worktrees`), current task pointer (parsed from `tasks.md`), last-touched timestamp (file mtime of spec dir), inserted into the spec Issue's description as a structured block per spec FR-004 ✓ 2026-05-28
- [x] T027 [US1] `src/reconcile.sh`: task-phase sub-issue reconcile — for each `## Phase N: <Name>` heading, find-or-create sub-issue titled `Phase N — <Name>` under the spec Issue, set workflow state per checklist completion ratio (`Done` if all ticked, `In Progress` for the current phase, `Todo` otherwise per FR-005), write checklist into sub-issue description (with read-only header per FR-006) ✓ 2026-05-28
- [x] T028 [US1] `src/reconcile.sh`: inter-phase blocking relations — for each declared inter-phase dependency in `tasks.md`/`plan.md`, set Linear blocking relation between sub-issues using `save_issue.blocks` / `.blockedBy` per the MCP probe finding; idempotent (no duplicate relations) ✓ 2026-05-28
- [x] T029 [US1] `src/reconcile.sh`: clarify-session comment mirroring — for each `### Session YYYY-MM-DD` block under `## Clarifications` in `spec.md`, post one comment on the spec Issue (idempotent — body match dedupes; first body wins on collision) ✓ 2026-05-28
- [x] T030 [US1] `src/reconcile.sh`: write-authority gate per Principle IV / FR-025 — if `git_helpers::is_authoritative_for_spec <NNN>` returns false, skip all writes for that spec; emit `summary::add skipped "non-authoritative worktree"` and still show Linear's current state per FR-026 ✓ 2026-05-28
- [x] T031 [US1] `src/reconcile.sh`: idempotency probe — before every mutation, query existing Linear state, hash computed vs current; skip mutation if identical (zero-churn per Principle II / SC-002) ✓ 2026-05-28
- [x] T032 [US1] `src/reconcile.sh`: duplicate Issue auto-resolve per FR-004b — if `>1` Issue matches `speckit-spec:NNN` in the same Project, keep the one with most recent activity and archive the others; emit warning ✓ 2026-05-28
- [x] T033 [US1] `commands/linear-push.md` — AI-invoked command markdown: documents `speckit.linear.push [--spec NNN | --all]` semantics, references `contracts/command-shapes.md`, shells out to `src/reconcile.sh`. Heavily commented for the operator's AI agent to follow ✓ 2026-05-28
- [x] T034 [US1] Update `src/reconcile.sh` to emit final `summary::emit` block per Principle VIII Rule 1 ✓ 2026-05-28

**Checkpoint**: US1 complete and independently testable. MVP shippable here — the bridge can mirror any consumer repo's specs into Linear via on-demand `speckit.linear.push` invocation.

## Phase 4: User Story 2 — Automatic sync on lifecycle transitions (P1)

**Story goal**: After install, every `/speckit-*` lifecycle command automatically updates Linear without operator intervention; local git operations (branch switch, commit, merge) also keep Linear current.

**Independent test criteria**: install bridge in a sandbox consumer repo, run `/speckit-specify`/`/speckit-plan`/etc., observe the corresponding `after_*` hook fires `speckit.linear.push`. Switch worktrees; observe `post-checkout` hook re-syncs. All without manual invocation.

### Tests for User Story 2

- [x] T035 [P] [US2] tests/integration/us2-after-hook-fires.bats ✓ 2026-05-28 — install bridge in a sandbox repo, simulate a spec-kit `/speckit-clarify` invocation, assert the `after_clarify` hook in `.specify/extensions.yml` invokes `speckit.linear.push` (mocked) once
- [x] T036 [P] [US2] tests/integration/us2-git-hook-fires.bats ✓ 2026-05-28 — install bridge in a sandbox repo with multiple worktrees, switch one to a feature branch, assert `post-checkout` hook fires `src/reconcile.sh`
- [x] T037 [P] [US2] tests/integration/us2-disabled-hook-respected.bats ✓ 2026-05-28 — set `enabled: false` on one `after_*` hook in `.specify/extensions.yml`, run the corresponding spec-kit command, assert reconciler does NOT fire
- [x] T038 [P] [US2] tests/integration/us2-non-authoritative-worktree.bats ✓ 2026-05-28 — invoke reconciler from worktree on `main`, assert no Linear writes happen and a read-only view is surfaced (per FR-025/FR-026)

### Implementation for User Story 2

- [x] T039 [US2] ✓ 2026-05-28 Implement `src/install.sh` skeleton: argument parsing (`--project <UUID>`, `--team <UUID>`, `--auto-create`, `--non-interactive`), dependency verification per FR-018b, exit codes per `contracts/command-shapes.md`
- [x] T040 [US2] ✓ 2026-05-28 `src/install.sh`: dependency verification — checks bash 4+, curl, jq, git, gh (optional), MCP wiring in consumer's `.mcp.json`, OAuth status, `.env` presence. Each failure prints copy-paste remediation per Principle VIII Rule 2
- [x] T041 [US2] ✓ 2026-05-28 `src/install.sh`: interactive Project + Team picker — auto-detects single-team workspaces (skips prompt), prompts otherwise with the smart-default flow from Q1/Q4 clarifications. Writes resolved UUIDs to `.specify/extensions/linear/linear-config.yml`
- [x] T042 [US2] ✓ 2026-05-28 `src/install.sh`: register `after_*` hooks into consumer's `.specify/extensions.yml` per FR-031 (`after_specify`, `after_clarify`, `after_plan`, `after_tasks`, `after_implement`, `after_analyze`), each `optional: false` and pointing at `speckit.linear.push`. Honour any pre-existing `enabled: false` per Principle VII Rules
- [x] T043 [US2] ✓ 2026-05-28 `src/install.sh`: install local git hooks per FR-033 — copy `templates/git-hooks/{post-checkout,post-commit,post-merge}` into consumer's `.git/hooks/`. Detect pre-existing hooks; chain rather than overwrite (append a `# spec-kit-linear hook` block); idempotent on re-install
- [x] T044 [P] [US2] ✓ 2026-05-28 templates/git-hooks/post-checkout — shell script invoking `src/reconcile.sh --spec $(parse_branch_for_NNN)` (no-op for non-feature branches); silent on success, warning on Linear API error (per Principle VIII)
- [x] T045 [P] [US2] ✓ 2026-05-28 templates/git-hooks/post-commit — shell script invoking `src/reconcile.sh --spec $(parse_branch_for_NNN)` to update memory block + checklist completion
- [x] T046 [P] [US2] ✓ 2026-05-28 templates/git-hooks/post-merge — shell script invoking `src/reconcile.sh --all` (merge may have brought in changes to multiple specs)
- [x] T047 [US2] ✓ 2026-05-28 `commands/linear-install.md` — AI-invoked install ceremony: documents argument matrix, calls `src/install.sh`, displays the per-step status report (Principle VIII)
- [x] T048 [US2] ✓ 2026-05-28 Update `.specify/extensions.yml` registration logic in `src/install.sh` to detect this bridge's own dogfood path (when installing into the spec-kit-linear repo itself, the registrations are recursive — guard against infinite hook loops)

**Checkpoint**: US2 complete. Operator never has to manually invoke sync — every lifecycle command and every git operation surfaces in Linear automatically.

## Phase 5: User Story 3 — Cross-repo unified view (P2)

**Story goal**: With the bridge installed in multiple consumer repos, the operator can see and filter all in-flight specs across all repos from one Linear view (e.g. filter by `phase:implementing`).

**Independent test criteria**: install bridge in two sandbox repos bound to the same Linear workspace, drive each spec to a different lifecycle phase, assert workspace-level filters return correct cross-Project results.

### Tests for User Story 3

- [ ] T049 [P] [US3] tests/integration/us3-cross-repo-filter.bats — set up two sandbox repos with bridge installed, drive spec 001 in repo-A to `Implementing` and spec 001 in repo-B to `Planning`. Issue Linear workspace-level filter by `phase:implementing` label; assert repo-A's spec returns and repo-B's doesn't
- [ ] T050 [P] [US3] tests/integration/us3-no-cross-pollination.bats — same setup as T049, but assert each repo's Project owns ONLY its own spec Issues (no orphan cross-references)

### Implementation for User Story 3

- [ ] T051 [US3] `commands/linear-status.md` — AI-invoked: surfaces current sync status for the current consumer repo and all its specs (lifecycle phase, worktree authority, last sync timestamp). Shells out to `src/reconcile.sh --dry-run --all`
- [ ] T052 [US3] `commands/linear-pull.md` — AI-invoked: queries Linear for the current state of all spec Issues in this repo's Project and prints them locally (read-only operation; never mutates). Useful for "what's the canonical state?" inspection from any worktree
- [ ] T053 [P] [US3] `src/reconcile.sh`: ensure `--all` mode handles repo-level filtering — when invoked without `--spec`, iterate every `specs/NNN-feature/` and reconcile each, scoped to the repo's Project UUID from config (no cross-Project bleed)

**Checkpoint**: US3 complete. Cross-repo workspace view works as expected without additional implementation beyond US1+US2; commands surface it.

## Phase 6: User Story 4 — One-shot install and workspace seed (P2)

**Story goal**: An operator adopting the bridge in a new repo or new Linear workspace can run two commands (`specify extension add linear` + `speckit.linear.seed`) and get a fully wired, ready-to-sync setup in under 10 minutes.

**Independent test criteria**: from a fresh sandbox consumer repo and a fresh Linear workspace, run the documented install sequence and verify the workspace has all required workflow states + labels and the repo has all required config + hooks + Action.

### Tests for User Story 4

- [x] T054 [P] [US4] [3] ✓ 2026-05-28 tests/integration/us4-seed-fresh-workspace.bats — given a fresh sandbox Linear workspace, run `src/seed.sh`, assert 9 workflow states created with correct type mappings, all `phase:*` and `task-phase:*` labels created, `workflow_state_uuids` map written into `linear-config.yml`
- [x] T055 [P] [US4] [2] ✓ 2026-05-28 tests/integration/us4-seed-idempotent.bats — run seed twice in a row, assert second run creates nothing new and emits "already seeded" summary
- [x] T056 [P] [US4] [3] ✓ 2026-05-28 tests/integration/us4-install-action.bats — accept the Action installation prompt during install, assert `.github/workflows/spec-kit-linear-sync.yml` exists with correct triggers and the install step printed `LINEAR_API_TOKEN` provisioning instructions per FR-029
- [x] T057 [P] [US4] [2] ✓ 2026-05-28 tests/integration/us4-unseeded-halts.bats — invoke reconciler against an UNSEEDED workspace, assert it halts with a clear error pointing at `speckit.linear.seed` (FR-022)

### Implementation for User Story 4

- [x] T058 [US4] [8] ✓ 2026-05-28 Implement `src/seed.sh` — creates the 9 required workflow states via `workflowStateCreate` GraphQL mutation (the only hot-path mutation that needs direct GraphQL per the MCP probe). State definitions: Specifying (unstarted), Clarifying (started), Planning (started), Tasking (started), Red-team (started), Implementing (started), Analyzing (started), Ready-to-merge (started), Merged (completed). Captures each UUID at creation and writes the `workflow_state_uuids` map into `linear-config.yml`
- [x] T059 [US4] [5] ✓ 2026-05-28 `src/seed.sh`: label creation — workspace-scoped labels `phase:specifying`, `phase:clarifying`, …, `phase:merged`, plus `task-phase:1`..`task-phase:9` (covers up to 9 task phases per spec; expandable). The `speckit-spec:NNN` label is auto-stamped per spec by reconcile, not seeded
- [x] T060 [US4] [3] ✓ 2026-05-28 `src/seed.sh`: idempotency — query existing workflow states + labels by name, skip creation for any that already exist; capture UUIDs of existing matches and write to config
- [x] T061 [US4] [2] ✓ 2026-05-28 `commands/linear-seed.md` — AI-invoked seed command, calls `src/seed.sh`. Documents the one-shot per-workspace nature and the workflow state schema being created
- [x] T062 [US4] [5] ✓ 2026-05-28 templates/github-action.yml — Layer E webhook workflow per `contracts/webhook-action.md` and `validation/github-action-mechanics.md`. Triggers on `pull_request: [opened, ready_for_review, closed]`, `permissions: contents: read`, single `issueUpdate` mutation flipping `stateId` only (no labels, no comments — Principle III)
- [ ] T063 [US4] [3] Update `src/install.sh` to detect Linear workspace seeded-state on first install — query `workflow_state_uuids` presence; if absent and operator has just resolved Team UUID, prompt to run `speckit.linear.seed` immediately or defer
- [ ] T064 [US4] [3] Update `src/install.sh` to interactively offer Action installation per FR-027 — opt-in prompt, copies `templates/github-action.yml` into `.github/workflows/spec-kit-linear-sync.yml`, prints `gh secret set LINEAR_API_TOKEN` instructions per FR-029
- [ ] T065 [US4] [1] `commands/linear-install.md`: document the full install ceremony walkthrough end-to-end per `quickstart.md` (referencing operator-facing prose, not duplicating it)

**Checkpoint**: US4 complete. Fresh install path validated end-to-end; an operator following `quickstart.md` reaches first-successful-sync in under 10 minutes.

## Phase 7: User Story 5 — Retroactive sync of already-complete specs (P3)

**Story goal**: An operator adopting the bridge against a repo with existing in-flight AND already-merged specs sees Linear correctly reflect each spec's current state on first reconcile — without intermediate-phase artifacts cluttering Linear's activity log.

**Independent test criteria**: against a sandbox repo containing one in-progress spec + one merged spec, run reconciler once from clean Linear; assert both Projects/Issues appear in correct end-states with no intermediate phase transitions logged.

### Tests for User Story 5

- [ ] T066 [P] [US5] tests/integration/us5-merged-spec-direct.bats — given fixture 004 (already-merged spec), run reconciler from clean Linear, assert spec Issue created directly in `Merged` workflow state (no transitions through Specifying → Clarifying → … logged)
- [ ] T067 [P] [US5] tests/integration/us5-mixed-state-repo.bats — sandbox repo with three specs in different phases (Tasking, Implementing, Merged), reconciler once, assert all three Issues correctly placed
- [ ] T068 [P] [US5] tests/integration/us5-no-pr-state.bats — spec with feature branch but no open PR and no merge into main — assert spec Issue lands in the highest-confidence phase the bridge can infer from artifacts alone (likely Implementing or Analyzing)

### Implementation for User Story 5

- [ ] T069 [US5] `src/parser.sh`: enhance `parser::lifecycle_phase` to handle every phase signal per spec FR-012 — artifact presence ladder (spec.md → +clarify session → +plan.md → +tasks.md → +red-team*.md → +analyze*.md), PR state (via `git_helpers::pr_state`), and the special case of `tasks.md` checklist completion ratio for distinguishing `Implementing` vs `Analyzing`
- [ ] T070 [US5] `src/reconcile.sh`: ensure first-pass Issue creation sets `stateId` directly to the inferred end-state (single `save_issue` call), bypassing intermediate Linear workflow-state mutations — per FR-014
- [ ] T071 [US5] `src/reconcile.sh`: special handling for the `phase:*` label set on first-time creation — apply the correct phase label in the same `save_issue` call, not as a follow-up label-add (avoids intermediate-state artifact in Linear's activity log). If T077 dogfood reveals `save_issue` cannot set the phase label in the same call (i.e. needs a separate `labelAdd` mutation), refactor to a single GraphQL transaction so the operator never sees an intermediate-state artifact.
- [ ] T072 [US5] Add `--retroactive` flag to `commands/linear-push.md` documenting the explicit invocation for first-time adoption of an existing repo (semantics: same as `--all` but with an extra-quiet summary mode that suppresses "skipped because non-authoritative" warnings for currently-checked-out branches that aren't the latest worktree)

**Checkpoint**: US5 complete. Bridge can be adopted mid-flight against any existing repo.

## Phase 8: Polish & Cross-Cutting Concerns

- [ ] T073 [P] Update `README.md` install section once `speckit.linear.install` is implemented — replace the "placeholder" status note with the real `specify extension add linear` invocation + a brief example session
- [ ] T074 [P] Update `CHANGELOG.md` with a `[0.1.0] - 2026-MM-DD` entry summarising the v1 shipping surface (5 commands, 6 after_* hooks auto-registered, 3 git hooks, Layer E Action template, workspace seed)
- [ ] T075 [P] Add `.markdownlint-cli2.jsonc` IF NOT ALREADY ADDED in T002 (defensive — T002 may have been deferred)
- [ ] T076 [P] Performance harness: run `time` against the full reconcile of a synthetic 10-spec / 30-task-per-spec repo; record actual hot vs cold reconcile latency in `validation/performance-baseline.md`; flag regressions vs `plan.md` Performance Goals. Fail CI when cold reconcile of the fixture exceeds 30s or hot reconcile exceeds 5s (matches plan.md Performance Goals); record both timings in `validation/performance-baseline.md`.
- [ ] T077 [P] Dogfood — install bridge into this repo itself (`specify extension add --dev /Users/ashbrener/Code/AI/spec-kit-linear`), seed the OSH-INFRA workspace, retroactively sync spec 001 (this spec). Verify the Linear UI matches expectations end-to-end. Record any rough edges in `validation/dogfood-001.md`
- [ ] T078 [P] Documentation pass — review `commands/*.md` for operator-facing clarity; cross-link to `quickstart.md` and the constitution; check vocabulary consistency (`task phase`, `Phase N — <Name>`, no `wave`)
- [ ] T079 [P] Verify all `tests/unit/*.bats` and `tests/integration/*.bats` pass; aim for ≥80% coverage of `src/*.sh`; add bats coverage report to CI workflow
- [ ] T080 [P] Add `bats` matrix to `.github/workflows/ci.yml` triggers — confirm CI runs the integration suite when `RUN_INTEGRATION_TESTS=1` is set (probably via `workflow_dispatch` + repo variable; per agent's earlier flag)
- [ ] T081 [P] Final shellcheck pass — zero warnings on every `src/*.sh`; document any intentional suppressions inline with justification
- [ ] T082 Constitution Re-Check — walk through all 8 principles against the shipped implementation and confirm no drift between plan-time check and as-built. Update `validation/` with a post-implementation constitution-compliance report
- [x] T083 Update `specs/001-spec-kit-linear-bridge/quickstart.md` to resolve the 3 TBD markers flagged by the Phase 1 agent (concrete UX strings for the install ceremony, exact MCP OAuth message, exact troubleshooting commands) ✓ Resolved on 2026-05-28 by TBD-remediation agent; concurrent sweep also resolved TBDs in data-model.md and contracts/{linear-graphql-mutations,webhook-action}.md.
- [ ] T084 [P] Tag the release: `git tag v0.1.0 -m "Initial v1 release"` + GitHub Release (use `gh release create`) referencing CHANGELOG entry from T074

---

## Dependencies

**Cross-phase dependency rules:**

- **Phase 1 → Phase 2**: scaffolding must exist before module work begins.
- **Phase 2 → Phase 3-7**: every story phase depends on `src/config.sh`, `src/graphql.sh`, `src/git_helpers.sh`, `src/summary.sh`, `src/parser.sh` and their unit tests being green.
- **Phase 3 (US1) → Phase 4 (US2)**: install ceremony needs the reconciler to exist (`speckit.linear.push` is what the auto-registered hooks call).
- **Phase 4 (US2) → Phase 5 (US3)**: cross-repo view assumes bridge is installable per-repo.
- **Phase 5 / 6 / 7 (US3 / US4 / US5)**: independent of each other after US1+US2; can be developed in parallel.
- **Phase 8 (Polish) → everything else**: runs last; T077 (dogfood) requires US4 (`speckit.linear.seed` available) AND US5 (retroactive sync logic).

**Within-phase parallelism**: every task marked `[P]` may run in parallel with other `[P]` tasks in the same phase. Sequential (no `[P]`) tasks within a phase depend on earlier tasks in that phase.

**Story-level independence**: US3, US4, US5 each satisfy their independent test criteria without the others — once US1+US2 are done, they may be implemented + tested in any order.

## Parallel Execution Examples

### Phase 2 (Foundational) — five modules at once

```
T005 [src/config.sh]     ──┐
T006 [src/graphql.sh]    ──┤
T007 [src/git_helpers.sh]──┼── all start in parallel; bats unit tests follow
T008 [src/summary.sh]    ──┤
T009 [src/parser.sh]     ──┘
```

### Phase 6 (US4) — Action template + seed + install enhancements

```
T062 [templates/github-action.yml] ─┐
T058 [src/seed.sh core]             ├── parallel; T059/T060 sequential within seed.sh
T059 [src/seed.sh labels]
T060 [src/seed.sh idempotency]      │
T063 [src/install.sh seed-check]    ┘   sequential — touches install.sh
```

### Phase 8 (Polish) — almost all parallel

T073, T074, T075, T076, T078, T079, T080, T081, T084 are independent and can land in any order. T077 (dogfood) and T082 (constitution re-check) must come AFTER the others; T083 may run any time.

## Implementation Strategy

**MVP scope (ship-ready end of Phase 3)**: Phase 1 + Phase 2 + Phase 3 (US1) only. At this point the bridge can mirror any consumer repo's specs into Linear on-demand via `speckit.linear.push`. No auto-firing yet, no install ceremony, no Action, no seed automation — operator manually sets up Linear workspace + config.yml and invokes the reconciler from their AI agent. This is the demoable slice that proves the architecture.

**Incremental delivery cadence after MVP**:

1. **MVP** (T001–T034) → demoable manual-reconcile bridge.
2. **+ Auto-sync** (T035–T048, US2) → install ceremony + hooks; operator-friendly default UX.
3. **+ Seed automation + Action** (T054–T065, US4) → reduces install friction; enables Layer E.
4. **+ Cross-repo** (T049–T053, US3) → multi-repo workspace coherence (mostly emergent).
5. **+ Retroactive** (T066–T072, US5) → mid-flight adoption of existing repos.
6. **Polish** (T073–T084) → docs, dogfood, performance, release.

Stories 3, 4, 5 may be parallelised across contributors after MVP — they don't depend on each other.

**Dogfood gate**: T077 is the moment of truth. Until the bridge has successfully retroactively-synced its own spec 001 into the OSH-INFRA workspace and the operator has driven a subsequent spec entirely through the auto-fire chain, v0.1.0 should NOT tag.

## Format Validation

All 84 tasks above follow the strict format `- [ ] T### [P?] [USn?] Description with file path`. Spot checks:

- T001 — `- [ ] T001 Create the bridge's source-tree skeleton: ...` ✅ no [P], no [USn] (Setup)
- T005 — `- [ ] T005 [P] Implement src/config.sh — ...` ✅ [P], no [USn], file path
- T024 — `- [ ] T024 [US1] Implement src/reconcile.sh skeleton: ...` ✅ no [P] (sequential within US1), [US1] label, file path
- T044 — `- [ ] T044 [P] [US2] templates/git-hooks/post-checkout — ...` ✅ [P] + [US2], file path
- T084 — `- [ ] T084 [P] Tag the release: ...` ✅ no [USn] (Polish), [P], explicit action
