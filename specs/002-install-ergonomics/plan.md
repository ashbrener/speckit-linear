# Implementation Plan: Install Ergonomics Redesign

**Branch**: `002-install-ergonomics` | **Date**: 2026-05-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-install-ergonomics/spec.md`

**Target release**: v0.1.1 (patch release atop the v0.1.0 main merge `c789a13`).

## Summary

Redesign the `speckit.linear.install` ceremony so the operator only
ever supplies a Linear API key, and the install ceremony discovers
the team, project, and operator identity by querying Linear with
that key. Replaces v0.1.0's UUID-first install flow (`--team <UUID>
--project <UUID>` or `--auto-create`) with a viewer-driven
discovery state machine: API key → `viewer` → `teams` picker →
`team(id).projects` picker (with "Create new" option) →
`projectCreate` (when chosen) → write `linear-config.yml` →
register hooks, install git hooks, optionally drop the Action.

Implementation extends `src/install.sh` (the v0.1.0 entry point —
~2087 lines, all the dependency-verification, hook-registration,
git-hook installation, and `--with-action` plumbing already lands
unchanged) with three new module sections:

1. **Discovery flow** (FR-037..FR-043 + FR-048) — API key
   resolution, viewer verification, numbered team/project pickers,
   `projectCreate`. The existing `install::resolve_operator`
   (`src/install.sh:1093`) already runs the `viewer { id name
   email }` query for FR-034; spec 002 *reuses* that response to
   satisfy FR-038 + FR-048 without firing a second viewer query.
   The existing `install::_create_project` (`src/install.sh:880`)
   and `install::_find_existing_project` (`src/install.sh:843`)
   already issue `projectCreate` + project lookup mutations and
   become the new discovery flow's callees.
2. **Backwards-compatibility shim** (FR-044 + FR-045) — the
   `INSTALL_FLAG_TEAM` / `INSTALL_FLAG_PROJECT` /
   `INSTALL_FLAG_NON_INTERACTIVE` flag plumbing in
   `install::parse_args` (`src/install.sh:284`) stays
   wire-compatible. The discovery flow short-circuits when both
   `--team` and `--project` are passed. `--non-interactive` without
   both flags halts with a clear error pointing at the v0.1.1
   ergonomics path (spec FR-045).
3. **Safety guards** (FR-046, FR-047, FR-049) — two new pre-flight
   checks added to `install::run_dependency_report`
   (`src/install.sh:702`): self-install detection (FR-046) and
   vendored `.git/` detection (FR-049). FR-047 is a README-only
   change.

No new external dependencies. No new src modules. No new contracts
beyond the four documents under `specs/002-install-ergonomics/contracts/`.

## Technical Context

**Language/Version**: Bash 4+ — same as v0.1.0. The new picker
logic uses bash 4 features already in play (`mapfile`, `read -s`,
`printf -v`, parameter expansion). macOS Apple-bash 3.2 is refused
at the existing FR-018b dependency gate (`install::check_bash`,
`src/install.sh:448`); no spec 002 change there.

**Primary Dependencies**: `curl`, `jq`, `git` — same as v0.1.0.
Optional `gh` for Layer E provisioning. **NO new runtime deps.**
The four GraphQL operations spec 002 adds (`viewer`, `teams`,
`team(id).projects`, `projectCreate`) all flow through
`graphql::query` / `graphql::mutate` (`src/graphql.sh`) which
already handles `LINEAR_API_KEY` loading, retry, and structured
error surfacing.

**Storage**: Filesystem only. Per consumer repo:

- `.env` (gitignored) — operator's Linear API key. FR-037
  introduces the optional "save to .env?" interactive write path.
- `.specify/extensions/linear/linear-config.yml` — unchanged
  schema from v0.1.0 (`contracts/config-schema.json`). The
  `linear.operator` block (FR-034) and `linear.team` + `linear.project`
  UUIDs (FR-002) are the same fields; spec 002 only changes HOW the
  install resolves them.
- `.specify/extensions.yml` — unchanged hook registration path.
- `.git/hooks/post-{checkout,commit,merge}` — unchanged.
- `.github/workflows/spec-kit-linear-sync.yml` — unchanged Layer E
  template.

No new on-disk state, no sidecar files, no `~/.config/`.

**Testing**:

- **bats unit tests** under `tests/unit/install_discovery.bats`
  (new file) — exercise each picker (single-team auto-pick, multi-team
  numbered prompt, project picker with "Create new" tail, EOF
  handling, invalid input retry) against fixture GraphQL responses
  stubbed via a `graphql::query` shim.
- **bats integration tests** under
  `tests/integration/install_e2e_discovery.bats` (new file, gated
  on `RUN_INTEGRATION_TESTS=1` + `LINEAR_API_KEY` present per
  v0.1.0 pattern) — exercise the full flow against a real Linear
  workspace: prompts → viewer → teams → projects → projectCreate →
  config write. Uses the existing `OSH-INFRA` test workspace. The
  same suite exercises SC-012's README-walkthrough scenarios: the
  `--from <archive-zip-URL>` form succeeds, and the `--dev` form
  from a path other than the bridge's own source installs cleanly
  (with the FR-049 warning surfacing when applicable).
- **bats regression tests** under
  `tests/integration/install_e2e_backwards_compat.bats` (new file)
  — re-runs the v0.1.0 `--team <UUID> --project <UUID>
  --non-interactive` path to verify SC-011 (CI install path
  unchanged).
- **shellcheck** clean on every modified `src/*.sh` per existing
  CI policy (`.github/workflows/ci.yml`).
- **markdownlint-cli2** clean on every new artifact under
  `specs/002-install-ergonomics/` per existing `.markdownlint-cli2.jsonc`.

**Target Platform**: Operator dev machines (macOS Intel + Apple
Silicon, Linux). No new platform surface beyond v0.1.0.

**Project Type**: spec-kit extension. Same single-project layout as
v0.1.0. No new directories.

**Performance Goals**:

- **SC-009**: full interactive install completes under 2 minutes
  (operator-perceived) for a first-time operator. Budget breakdown:
  ~10s dependency checks (existing), ~3s viewer query, ~3s teams
  query, ~1-90s operator team pick (human time), ~3s projects
  query, ~1-90s operator project pick + name input (human time),
  ~5s projectCreate (when chosen), ~5s write config + register
  hooks + install git hooks, ~5s optional Action install. Linear
  API ceiling is well under 30s wall-clock; the remaining 90s is
  human reading + typing.
- **SC-011 (regression)**: non-interactive `--team --project
  --non-interactive` install matches v0.1.0 wall-clock — no
  regression. The discovery flow short-circuits on both UUIDs
  present.

**Constraints**:

- Bash 4+, curl, jq, git only. Same as v0.1.0.
- Zero UUIDs surfaced to the operator at any prompt or status line
  (SC-010). All UUID handling is internal; operator sees team key +
  team name + project name only.
- The four new GraphQL operations MUST flow through the existing
  `graphql::query` / `graphql::mutate` wrappers — no new HTTP
  client surface.
- The `viewer` query is run EXACTLY ONCE per install (FR-048). The
  existing `install::resolve_operator` path is the canonical
  caller; the new discovery flow consumes its captured response
  (`INSTALL_OPERATOR_*` module globals).
- All writes to `linear-config.yml` happen AFTER the operator
  confirms team + project (FR-042 + FR-043). Quit before
  confirmation → no config written, retry starts clean.
- `--non-interactive` MUST NOT prompt for an API key (FR-037
  resolution order stops at `.env`/env-var; falling through to the
  interactive `read -s` is forbidden in CI mode).

**Scale/Scope**:

- Operator dimension: one consumer repo per `speckit.linear.install`
  invocation. No change from v0.1.0.
- Team picker dimension: typical 1-5 teams visible per API key;
  display threshold = 20 (per spec 002 Clarifications Q2). >20 →
  warn + instruct `--team <UUID>`. Pagination is v0.2.0 scope.
- Project picker dimension: same 20-item threshold; typical 0-10
  projects per team for greenfield repos.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1
design.*

Walked through all 8 principles in `.specify/memory/constitution.md`
(v1.0.0). All gates pass without amendment. Justifications below;
no entries in Complexity Tracking.

### I. Filesystem Is The Single Source of Truth — **PASS**

Spec 002 writes `linear-config.yml` from Linear-discovered UUIDs
during install. This is NOT a Linear → filesystem reverse-sync
because (a) install is a one-shot bootstrap that runs exactly
once per consumer repo to establish the binding, and (b) every
subsequent reconcile is still unidirectional FS → Linear per
Principle I — the bridge reads `linear-config.yml` as its truth,
not Linear. The discovery flow is the *establishment* of the
binding, not its *maintenance*. Once `linear-config.yml` is
committed, the operator's filesystem is canonical and Linear
ceases to be a read source for any sync code path. (FR-042
explicitly forbids re-querying Linear for the binding after the
install commits — every reconcile reads from the committed
`linear-config.yml`.) v0.1.0's install ceremony already had the
same shape (operator-supplied UUIDs → config write → unidirectional
reconcile); spec 002 only changes WHERE the install resolves the
UUIDs from (Linear API instead of operator typing).

### II. Reconcile, Never Event-Push — **PASS**

Install is an event-style flow (operator → prompts → API calls →
config write → exit) by necessity — it runs once at bootstrap, not
repeatedly. Principle II governs *sync*, not *install*. The
discovery flow is bounded: every query reads Linear state at one
instant in time and the operator picks. No per-event diff cache, no
"what Linear last saw" sidecar, no replay. If the install crashes
mid-flow before FR-042 commits `linear-config.yml`, the next
invocation starts from scratch — converges from any state. The
v0.1.0 reconcile pathway (`src/reconcile.sh`) is untouched by spec
002 and remains the canonical reconciler.

### III. Layered Idempotency (D + E) — **PASS**

Spec 002 touches Layer D's install entry point only. Layer E (the
GitHub Action) is unchanged — `templates/github-action.yml` and
its single `issueUpdate(input: { stateId })` mutation stay
constitutional. The new discovery flow is part of the install
ceremony, which is neither Layer D nor Layer E (it's the bootstrap
that wires both). No cross-layer mutation surface added.

### IV. Write-Authority Follows The Worktree — **PASS**

Install runs from any worktree (it's pre-spec). No
spec-feature-branch authority gate applies. The discovery flow
writes only to `linear-config.yml` (a per-repo config), not to any
spec-Issue Linear state. Authority for downstream reconciles
remains gated by `src/reconcile.sh`'s existing
`git_helpers::current_branch` check (FR-025), unchanged by spec
002.

### V. UUID-Based Binding, Per-Repo Config — **PASS**

Spec 002 *strengthens* UUID-based binding rather than weakening
it. The operator never sees a UUID (SC-010), but UUIDs remain the
lookup keys in `linear-config.yml` — both team UUID and project
UUID are still resolved from Linear's GraphQL response (`viewer.id`,
`teams.nodes[].id`, `projects.nodes[].id`, `projectCreate.project.id`)
and written verbatim into the committed config. v0.1.0's
`config-schema.json` (`specs/001-spec-kit-linear-bridge/contracts/config-schema.json`)
UUID patterns are unchanged. The discovery flow's role is to
*resolve* operator-visible names (team key, team name, project
name) into the UUIDs the bridge already requires; name-based
runtime lookup is still forbidden per Principle V Rules. No
per-operator global config introduced; the `.env` key write (FR-037)
is per-repo and gitignored, matching v0.1.0's pattern.

### VI. OAuth-First, Keys-At-The-Edges — **PASS**

Spec 002 makes the Linear API key load-bearing at install time —
this requires explicit justification against Principle VI's
"OAuth-first" mandate. The justification:

- Principle VI Rule 1 mandates OAuth for **interactive sync**
  (`speckit.linear.*` commands and `/speckit-*` hooks). Install is
  neither — it is the bootstrap step that *establishes* the OAuth
  / key edges for sync to use.
- The install ceremony has no MCP session to lean on (it runs
  before the consumer repo has wired the official Linear MCP into
  the operator's coding agent). A direct GraphQL path is the only
  way the install can verify the operator's identity and query
  Linear state.
- The API key lives at `.env` — exactly the gitignored, per-repo
  edge Principle VI Rule 3 already sanctions for the seed step and
  git hooks. Spec 002 adds the install ceremony to that same edge
  list, expanding the "three edges" sanctioned by Principle VI
  (seed, git hooks, GitHub Action) to four (seed, git hooks,
  GitHub Action, install). All four are read-only consumers of
  the same `LINEAR_API_KEY` value in the same gitignored `.env`.
- Once install completes, every subsequent reconcile from a
  coding-agent session continues to use the official MCP / OAuth
  per Principle VI Rule 1. The key is the bootstrap input only.
- The interactive `read -s` prompt (FR-037) echoes nothing and
  optionally writes to `.env` only with operator consent. No
  global state, no `~/.config/`, no environment variable other
  than the operator's own shell.

This expansion of the "edges" list is not a Principle VI
amendment — Principle VI already enumerates the seed step + git
hooks + Action as edges, all of which take `LINEAR_API_KEY` from
`.env`. Spec 002 adds install to the same list with identical
semantics. If a future amendment tightens Principle VI to forbid
install-time keys entirely, the install ceremony would need an
OAuth device-code flow against the official Linear MCP — out of
scope for v0.1.1.

### VII. Memory-Just-Works, Escape Hatches Beside It — **PASS**

Spec 002 does not change hook auto-registration. The existing
`install::register_after_hooks` (`src/install.sh`) still
auto-registers all six `after_*` hooks with `optional: false` per
FR-031 / Principle VII Rule 1. The on-demand commands
(`speckit.linear.push`, `.pull`, `.status`) are unchanged.
Quickstart still presents the auto-sync flow first; the new
interactive install ceremony is documented as the primary path,
not as a recovery surface. (The reverse — making the install an
"escape hatch" beside an auto-installer — is not in scope for spec
002 and would be an architectural shift requiring a separate
spec.)

### VIII. Surface, Don't Enforce — Observable Failure — **PASS**

FR-049 is the clearest expression of this principle: when a
vendored `.git/` directory is detected at
`.specify/extensions/linear/.git/`, the install **surfaces a
warning row** in the dependency-verification report instructing the
operator to delete it manually. The install MUST NOT auto-delete
the nested `.git/` — the operator's filesystem is their own
business. The warning row, the install summary's "next steps"
block, and the structured error format all conform to Principle
VIII Rule 1. FR-046 (self-install detection) and FR-047 (README
edits) follow the same pattern: detect, surface, refuse to
proceed silently, never mutate. Vocabulary in the new code paths,
prompts, and contracts matches canonical spec-kit terms (`task
phase`, `Phase N — <Name>`, never `wave`).

**Verdict**: All 8 gates GREEN. No constitutional violations to
track in Complexity Tracking. Phase 0 research may proceed.

## Project Structure

### Documentation (this feature)

```text
specs/002-install-ergonomics/
├── spec.md                              # locked clarification-clean spec (13 FRs, 5 SCs)
├── plan.md                              # this file
├── research.md                          # Phase 0 output — 6 decisions
├── data-model.md                        # Phase 1 — InstallSession + AvailableTeam + AvailableProject
├── quickstart.md                        # Phase 1 — 8-step interactive install walkthrough
├── contracts/                           # Phase 1 — install ceremony contracts
│   ├── install-discovery-graphql.md     # the four new GraphQL operations
│   ├── install-prompts.md               # the interactive prompt contract
│   └── install-flags.md                 # CLI flag surface + v0.1.0 → v0.1.1 backcompat table
├── checklists/
│   └── requirements.md                  # validation checklist (carry-over from /speckit-specify)
└── tasks.md                             # Phase 2 — generated by /speckit-tasks, NOT by /speckit-plan
```

### Source Code (repository root)

Spec 002 adds NO new directories. It introduces two new test files
under existing `tests/` directories and modifies one existing
script (`src/install.sh`). The README receives one section update.

```text
src/
├── install.sh                       # MODIFIED — adds discovery flow (FR-037..FR-043, FR-048),
│                                    #            backwards-compat shim (FR-044, FR-045), and
│                                    #            safety guards (FR-046, FR-049). ~400 added lines
│                                    #            estimated; existing structure preserved.
├── reconcile.sh                     # unchanged
├── seed.sh                          # unchanged
├── config.sh                        # unchanged
├── graphql.sh                       # unchanged — already exposes graphql::query / graphql::mutate
├── git_helpers.sh                   # unchanged
├── parser.sh                        # unchanged
└── summary.sh                       # unchanged

tests/
├── unit/
│   ├── install_discovery.bats       # NEW — picker + EOF + retry tests with stubbed graphql::
│   └── (existing v0.1.0 *.bats)     # unchanged
├── integration/
│   ├── install_e2e_discovery.bats   # NEW — full interactive flow vs real OSH-INFRA
│   ├── install_e2e_backwards_compat.bats # NEW — SC-011 regression for --team --project --non-interactive
│   └── (existing v0.1.0 *.bats)     # unchanged
└── fixtures/
    └── linear_responses/            # NEW — stubbed Linear GraphQL responses for unit tests
        ├── viewer.json              # viewer.{id, name, email} sample
        ├── teams_single.json        # one-team auto-pick fixture
        ├── teams_multi.json         # multi-team picker fixture
        ├── teams_overflow.json      # >20 teams (FR-039 warning fixture)
        ├── projects_empty.json      # zero projects (Create new is the only path)
        ├── projects_multi.json      # multi-project picker fixture
        └── projectCreate_ok.json    # successful projectCreate response

README.md                            # MODIFIED — Install section per FR-047 (archive-URL form documented)
CHANGELOG.md                         # MODIFIED — v0.1.1 entry referencing spec 002

commands/
└── linear-install.md                # MODIFIED — operator-facing algorithm reflects new flow
```

**Structure Decision**: Same single-project layout as v0.1.0. Spec
002 is a strict extension of `src/install.sh`, not a re-architect.
The `tests/fixtures/linear_responses/` subdirectory is the only
new path; everything else is in-place modification of existing
files. Total estimated changeset: ~400 added lines to
`src/install.sh`, 2 new bats files, 1 new bats fixture dir with
~7 JSON fixtures, 1 README section update, 1 CHANGELOG entry,
plus the 5 documentation artifacts under
`specs/002-install-ergonomics/`.

## Assumptions Made During Planning

These are judgment calls made during /speckit-plan that the spec
did not explicitly mandate. Each is surface-area for the reviewer
to challenge before /speckit-tasks.

| # | Assumption | Rationale | Reviewable? |
|---|---|---|---|
| A1 | The new discovery flow REUSES `install::resolve_operator`'s viewer call (FR-048) rather than splitting it; the existing path becomes the canonical viewer caller and the team-list query consumes its result. | Avoids two viewer queries (spec FR-048 mandate). v0.1.0's resolve_operator runs at install step 2b; spec 002 moves it earlier so its captured viewer feeds the teams picker too. | yes |
| A2 | `--from <archive-zip-URL>` is documented in README under FR-047 but no install-time validation is added — the spec-kit CLI's BadZipFile error is sufficient surfaced failure. | Spec FR-047 mandates README documentation only; no install.sh change is needed for the URL-form guidance. | yes |
| A3 | Display threshold (Clarifications Q2) of 20 teams + 20 projects is hard-coded as `INSTALL_PICKER_DISPLAY_THRESHOLD=20` in install.sh. Operator-configurable thresholds + pagination are v0.2.0 scope per spec.md `## Out of scope`. | Matches spec.md `## Assumptions` bullet 3. | yes |
| A4 | "Create new" appears as the LAST option in the project picker (FR-040), not first. Numbering is `1) <existing>` … `N) <existing>` `N+1) Create new project`. | Matches FR-040's "with a final 'Create new project' option" phrasing literally. Operator's eye scans existing names first. | yes |
| A5 | When the operator confirms "save to .env?" per FR-037, the install **appends** `LINEAR_API_KEY=…` to `.env` (creating the file if absent) and ensures `.env` is in `.gitignore` (appending if absent). It does NOT replace an existing `LINEAR_API_KEY=…` line in `.env` without an explicit confirm prompt (Edge Cases bullet 8 — `.env` conflict). | Matches FR-037 wording ("MUST append the key to .env") and Edge Cases conflict handling. | yes |
| A6 | The "Create new" project name default is the consumer repo's directory basename (matches v0.1.0 `install::resolve_project_uuid`'s existing default for `--auto-create`). The interactive confirm prompt is "Project name [<repo-basename>]:" allowing edit before `projectCreate`. | Matches FR-041 wording ("default: the consumer repo's directory name"). | yes |
| A7 | FR-046 self-install detection uses `cd "<path>" && pwd -P` on both source and target paths (no GNU `realpath` dependency; matches v0.1.0's path-handling style). | Bash-4 portable, no new runtime dep, works on macOS BSD-userland. | yes |
| A8 | FR-049 vendored `.git/` warning is emitted from `install::run_dependency_report` (existing dispatcher), keeping the structured `[ok / warn / err]` row format consistent with v0.1.0's FR-018b report. | Operator already reads this report at install start; adding the vendored `.git/` row there is the surface-don't-enforce-compliant spot. | yes |

## Complexity Tracking

*Filled ONLY if Constitution Check has violations that must be
justified.*

No violations to track. All 8 constitutional principles pass
without exception. Principle VI's "OAuth-first" mandate was
examined carefully (spec 002 makes the API key load-bearing at
install time) and resolved as conformance, not deviation: the
install ceremony is the bootstrap mechanism that establishes the
sanctioned "key-at-the-edges" location (`.env`), and every
subsequent sync still flows through the OAuth-first MCP per
Principle VI Rule 1. See Constitution Check §VI above for the
detailed justification.

## Cross-references

- Spec: [`spec.md`](./spec.md) — 13 functional requirements
  (FR-037..FR-049), 5 success criteria (SC-009..SC-013), 3
  user stories.
- Phase 0 research: [`research.md`](./research.md) — 6 design
  decisions, all with citations.
- Phase 1 data model: [`data-model.md`](./data-model.md) —
  InstallSession + AvailableTeam + AvailableProject entities, plus
  the resolution-flow state machine.
- Phase 1 contracts:
  - [`contracts/install-discovery-graphql.md`](./contracts/install-discovery-graphql.md)
  - [`contracts/install-prompts.md`](./contracts/install-prompts.md)
  - [`contracts/install-flags.md`](./contracts/install-flags.md)
- Phase 1 quickstart: [`quickstart.md`](./quickstart.md) — 8-step
  walkthrough mirroring the v0.1.0 quickstart's tone.
- v0.1.0 baseline: [`specs/001-spec-kit-linear-bridge/`](../001-spec-kit-linear-bridge/)
  for the full data model + config schema + GraphQL contract spec
  002 extends.
- Constitution: [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md)
  v1.0.0, 8 principles.
