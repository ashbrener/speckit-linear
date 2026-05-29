# Data Model (Spec 002 — Install Discovery)

**Feature**: `002-install-ergonomics`
**Phase**: 1 (design)
**Companions**: [spec.md](./spec.md) · [plan.md](./plan.md) · [research.md](./research.md)
**Extends**: [v0.1.0 data-model.md](../001-spec-kit-linear-bridge/data-model.md) — the canonical filesystem ↔ Linear mapping. Spec 002 does NOT modify any v0.1.0 entity; it adds three in-memory install-time entities and one state machine.

## 1. Overview

Spec 002 introduces NO persistent entities. The committed
`linear-config.yml` schema is unchanged from v0.1.0
(`specs/001-spec-kit-linear-bridge/contracts/config-schema.json`).
The new entities below are **in-memory state during the install
ceremony** — they live in module-level bash variables inside
`src/install.sh`, are populated by the discovery flow, and are
consumed by the existing `install::write_config`
(`src/install.sh:1145`) to produce the same v0.1.0
`linear-config.yml` artifact.

The discovery state machine in §4 is the contract for HOW the
install resolves the operator's binding; the committed config
schema is the contract for WHAT lands on disk. Spec 002 changes
the former, not the latter.

## 2. New in-memory entities

### 2.1 InstallSession

A single struct (a set of `INSTALL_SESSION_*` module globals in
bash) tracking the operator's progress through the discovery
flow. Lives for the duration of one `bash src/install.sh`
invocation and is discarded on exit.

| Field | Type | Source | Populated at | Notes |
|---|---|---|---|---|
| `api_key` | string (secret) | env / `.env` / `read -s` | step 1 (FR-037) | Never printed; never logged; passed via `Authorization` header only. NOT persisted to InstallSession beyond the `viewer` query — the `graphql::query` wrapper reads it from `LINEAR_API_KEY` env var each time. |
| `api_key_source` | enum: `env_var` \| `dotenv` \| `interactive` \| `interactive_saved` | derived | step 1 | Drives the install summary's "key sourced from" row. `interactive_saved` means operator confirmed write to `.env`. |
| `viewer_id` | UUID | Linear `viewer { id }` | step 2 (FR-038) | Reused for FR-048 — feeds `linear.operator.user_id`. |
| `viewer_name` | string | Linear `viewer { name }` | step 2 | Informational; feeds `linear.operator.name` + install summary. |
| `viewer_email` | string | Linear `viewer { email }` | step 2 | Informational; feeds `linear.operator.email` + install summary. |
| `available_teams[]` | AvailableTeam[] | Linear `teams(first: 21) { nodes }` | step 3 (FR-039) | At most 21 elements; >20 triggers overflow warning. See §2.2. |
| `selected_team_id` | UUID | derived: auto-pick if `len==1`, otherwise operator pick | step 3 | Operator never sees this UUID per SC-010. |
| `selected_team_key` | string | derived from `available_teams[selected].key` | step 3 | Surfaced in install summary's "team" row. |
| `selected_team_name` | string | derived from `available_teams[selected].name` | step 3 | Surfaced in install summary's "team" row. |
| `available_projects[]` | AvailableProject[] | Linear `team(id).projects(first: 21) { nodes }` | step 4 (FR-040) | At most 21 elements; >20 triggers overflow warning. See §2.3. |
| `project_choice` | enum: `attach` \| `create` | derived from operator pick | step 4 | `attach` → use `selected_project_id` from existing; `create` → drive `projectCreate` per FR-041. |
| `new_project_name` | string | operator input (default: repo basename) | step 5 (FR-041) | Only populated on `project_choice == "create"`. |
| `selected_project_id` | UUID | Linear: existing `id` or `projectCreate.project.id` | step 5 / step 6 | Feeds `linear.project.id` on config write. |
| `selected_project_name` | string | matches `selected_project_id` | step 5 / step 6 | Feeds `linear.project.name`. |
| `selected_project_url` | string (URL) | `projectCreate.project.url` if created; existing `project.url` if attached | step 5 / step 6 | Surfaced in install summary's "open in Linear" link. |
| `quit_before_commit` | boolean | derived from operator action | any step before 7 | If true, install exits without writing `linear-config.yml` (FR-042). |

**Invariants**:

- `selected_team_id` MUST be present before `available_projects` is
  queried (FR-040 — project picker is scoped to the picked team).
- `selected_project_id` MUST be present before
  `linear-config.yml` is written (FR-042 — config write is the
  final discovery step).
- `viewer_id` MUST be captured in step 2 BEFORE step 3 (FR-038 +
  FR-048 — single viewer query feeds both operator stamp and
  team-list authorization).

**Lifetime**: process-bounded. No serialization. No
`/tmp` artifacts. Killing the install at any step before
`install::write_config` produces zero filesystem effects on the
consumer repo (FR-042).

### 2.2 AvailableTeam

One element per row in the operator-facing team picker.
Represented in bash as a parallel-array tuple
(`INSTALL_SESSION_TEAMS_ID[i]`, `INSTALL_SESSION_TEAMS_KEY[i]`,
`INSTALL_SESSION_TEAMS_NAME[i]`).

| Field | Type | Source | Notes |
|---|---|---|---|
| `id` | UUID | Linear `Team.id` | Lookup key. Operator never sees this (SC-010). |
| `key` | string | Linear `Team.key` | The visible team key (`ENG`, `OPS`, `ACM`). Displayed in picker. |
| `name` | string | Linear `Team.name` | Display name. Displayed in picker (after the em-dash separator per FR-039). |

**Invariants**:

- `key` MUST be present (Linear's `Team.key` is non-nullable).
- `name` MUST be present (Linear's `Team.name` is non-nullable).
- Operator MUST be able to disambiguate two teams using `key` +
  `name` alone (SC-013). If two teams share both, the picker
  surfaces a warning row pointing at `--team <UUID>` for explicit
  selection.

### 2.3 AvailableProject

One element per row in the operator-facing project picker for the
selected team. Same parallel-array shape as AvailableTeam.

| Field | Type | Source | Notes |
|---|---|---|---|
| `id` | UUID | Linear `Project.id` | Lookup key. Operator never sees this (SC-010). |
| `name` | string | Linear `Project.name` | Display name. Displayed in picker. |

**Invariants**:

- `name` MUST be present (Linear's `Project.name` is non-nullable).
- The "Create new project" tail option is NOT an AvailableProject
  — it is rendered as a distinct option at index `N+1` where `N`
  is `len(available_projects)`.

## 3. Mapping: InstallSession → `linear-config.yml`

Field-by-field assignment performed by the modified
`install::write_config` (`src/install.sh:1145`) at step 7 of the
discovery flow. All UUIDs flow through unchanged from Linear's
GraphQL response; no string transformation, no name-based
lookup at write time.

| InstallSession field | `linear-config.yml` path | v0.1.0 schema reference |
|---|---|---|
| `viewer_id` | `linear.operator.user_id` | FR-034 / config-schema §`linear.operator.user_id` |
| `viewer_name` | `linear.operator.name` | FR-034 / config-schema §`linear.operator.name` |
| `viewer_email` | `linear.operator.email` | FR-034 / config-schema §`linear.operator.email` |
| `selected_team_id` | `linear.team.id` | Principle V / FR-002 / config-schema §`linear.team.id` |
| `selected_team_key` | `linear.team.key` | config-schema §`linear.team.key` (informational) |
| `selected_team_name` | `linear.team.name` | config-schema §`linear.team.name` (informational) |
| `selected_project_id` | `linear.project.id` | Principle V / FR-002 / config-schema §`linear.project.id` |
| `selected_project_name` | `linear.project.name` | config-schema §`linear.project.name` (informational) |

The `linear.workspace.{name,url_key}` block is populated by the
existing v0.1.0 `install::write_config` from a separate
`viewer { organization { name urlKey } }` field selection. Spec
002 extends the FR-038 viewer query to include `organization { name
urlKey }` so this block is also populated from the same single
query (FR-048 — one viewer query, multiple consumers).

The `linear.workflow_state_uuids` and `linear.default_state_uuids`
maps are still populated by `speckit.linear.seed` (FR-021) AFTER
install completes — unchanged by spec 002. Install writes the
placeholder zero UUIDs per v0.1.0 behavior; the seed step fills
them.

## 4. Discovery state machine

The new state machine spec 002 introduces. Implemented across
new functions in `src/install.sh` (estimated names below; final
names land in `tasks.md`).

```text
                          ┌─────────────────────────┐
                          │ S0: pre-flight guards   │
                          │  (FR-046, FR-049)       │
                          └──────────┬──────────────┘
                                     │
                                     ▼
                          ┌─────────────────────────┐
                          │ S1: resolve API key     │
                          │  (FR-037)               │
                          └──────────┬──────────────┘
                                     │
                ┌────────────────────┤
                │                    │
        ENV / .env present      no key present
                │                    │
                │                    ├── non-interactive ──► EXIT 2 (FR-037, FR-045)
                │                    │
                │                    └── interactive ──► read -s → optional .env save
                │                                                   │
                ▼                                                   │
                ◄──────────────────────────────────────────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │ S2: viewer query        │
   │  (FR-038, FR-048)       │
   │  → viewer_id+name+email │
   │  → organization.{name,  │
   │     urlKey}             │
   └──────────┬──────────────┘
              │
              │── auth fail / viewer == null ──► EXIT 2 (FR-038)
              │
              ▼
   ┌─────────────────────────┐
   │ S3: teams query         │
   │  (FR-039)               │
   │  → available_teams[]    │
   └──────────┬──────────────┘
              │
              ├── len == 0 ──► EXIT 2 ("no teams accessible")
              ├── len == 1 ──► auto-pick (no prompt) ──┐
              └── len >= 2 ──► numbered list prompt ───┤
                                                        │
                                                        ▼
                                            ┌─────────────────────────┐
                                            │ selected_team_id        │
                                            └──────────┬──────────────┘
                                                        │
                                                        ▼
                                          ┌─────────────────────────┐
                                          │ S4: projects query      │
                                          │  (FR-040)               │
                                          │  → available_projects[] │
                                          └──────────┬──────────────┘
                                                        │
                                                        ├── operator picks existing ──► project_choice=attach
                                                        │                                  │
                                                        │                                  ▼
                                                        │                       selected_project_id
                                                        │                                  │
                                                        └── operator picks "Create new" ───┤
                                                                                            │
                                                                                            ▼
                                                                            ┌─────────────────────────┐
                                                                            │ S5: projectCreate       │
                                                                            │  (FR-041)               │
                                                                            │  prompt for name        │
                                                                            │  duplicate-name warn    │
                                                                            │  call mutation          │
                                                                            │  → selected_project_id  │
                                                                            │  → selected_project_url │
                                                                            └──────────┬──────────────┘
                                                                                        │
                                                                                        ▼
                                                                          ┌─────────────────────────┐
                                                                          │ S6: write_config        │
                                                                          │  (FR-042)               │
                                                                          │  ← all v0.1.0 fields    │
                                                                          │  ← linear.operator.*    │
                                                                          │  ← linear.team.*        │
                                                                          │  ← linear.project.*     │
                                                                          └──────────┬──────────────┘
                                                                                      │
                                                                                      ▼
                                                                          ┌─────────────────────────┐
                                                                          │ S7: hook registration   │
                                                                          │  (FR-043) — UNCHANGED   │
                                                                          │  ← .specify/            │
                                                                          │    extensions.yml      │
                                                                          │  ← .git/hooks/         │
                                                                          │  ← optional Action      │
                                                                          └──────────┬──────────────┘
                                                                                      │
                                                                                      ▼
                                                                                  EXIT 0
```

**State transition rules**:

- **S0 → S1**: pre-flight guards must pass with no `err` rows.
  `warn` rows (e.g. vendored `.git/`) do NOT halt; they surface and
  continue.
- **S1 → S2**: API key must resolve to a non-empty string from one
  of the three FR-037 sources, OR `--non-interactive` halts with
  exit 2 before reaching S2.
- **S2 → S3**: viewer query must return non-null
  `viewer { id, name, email, organization { name urlKey } }`. Any
  GraphQL error (`errors[]` non-empty), `viewer == null`, or
  missing `id` halts with exit 2 + remediation link (FR-038).
- **S3 → S4**: exactly one team selected. If `--team <UUID>` was
  passed AND `len(available_teams) == 0` matches the flag, S3 is
  short-circuited entirely (backwards-compat per FR-044).
- **S4 → S5 OR S4 → S6**: branch on `project_choice`. `attach`
  jumps to S6 directly (skip S5). `create` enters S5. If
  `--project <UUID>` was passed, S4 is short-circuited (FR-044).
- **S5 → S6**: `projectCreate.success` must be `true`. On
  `success: false`, the install halts with the verbatim Linear
  error (FR-041); operator may retry by re-running install.
- **S6 → S7**: `linear-config.yml` write must succeed. On disk
  error (read-only, no space, etc.), the install halts and the
  operator can re-run without losing prior progress (nothing was
  written).
- **Any S* → quit**: operator interrupts (Ctrl-C or EOF on a
  prompt) trigger exit. If interrupt occurs BEFORE S6,
  `linear-config.yml` is NOT written; retried install starts
  clean (FR-042 invariant).

**Backwards-compat fast paths** (FR-044, FR-045):

- `--team <UUID> --project <UUID> [--non-interactive]`: S3 + S4
  + S5 all skipped. The install runs S0 → S1 → S2 (viewer query
  still issued to populate `linear.operator`) → S6 → S7. Both
  UUIDs are quick-validated by a single GraphQL query (a single
  `team(id) { id } project(id) { id team { id } }` combined query
  per FR-044) before write.
- `--team <UUID>` only: S3 skipped (use the flag's UUID as
  `selected_team_id`); S4 runs scoped to that team.
- `--project <UUID>` only: S4 skipped; S3 resolves team from the
  project's `team { id }` field per FR-044.
- `--non-interactive` without `--team` AND `--project`: halts at
  S0 with FR-045's mandated error pointing at the v0.1.1
  ergonomics path.

## 5. Failure modes (per state)

| State | Failure | Exit code | Operator-facing message | Source FR |
|---|---|---|---|---|
| S0 | Self-install detected | 2 | `source path equals target path; install into a different consumer repo, or use \`specify extension add linear\`` | FR-046 |
| S0 | Vendored `.git/` present | 0 (warn, continues) | warning row + remediation `rm -rf .specify/extensions/linear/.git/` | FR-049 |
| S1 | `--non-interactive` and no key | 2 | `LINEAR_API_KEY required; set in .env or export before re-running` | FR-037, FR-045 |
| S2 | Auth failure (HTTP 401) | 2 | `LINEAR_API_KEY invalid; create a new key at https://linear.app/settings/api` | FR-038 |
| S2 | `viewer == null` | 2 | same as above (Linear's response to invalid keys) | FR-038 |
| S3 | Zero teams accessible | 2 | `no teams accessible to this API key; check workspace settings at https://linear.app/<workspace>/settings/teams` | FR-039 (spec.md Edge Case bullet 1) |
| S3 | Multi-team picker, invalid input | 0 (loops, no halt) | `invalid choice "<input>"; pick a number between 1 and <N>` | FR-039 |
| S4 | Operator picks team without project-create permission | 0 (continues; permission error surfaces at S5) | per S5 | spec.md Edge Case bullet 3 |
| S5 | `projectCreate.success == false` | 1 (recoverable) | verbatim Linear error + "retry by re-running install or picking an existing project" | FR-041 |
| S5 | Network failure mid-mutation | 1 | "projectCreate timeout; on retry, your new project may already exist — pick it from the list" | spec.md Edge Case bullet 5 |
| S6 | `linear-config.yml` write fails | 2 | filesystem error verbatim | FR-042 |

## 6. Cross-references to v0.1.0 entities (unchanged)

Spec 002 does NOT modify any of the v0.1.0 entities below. They are
listed here to make explicit which sections of the v0.1.0
data-model are touched by the install ceremony but left intact by
spec 002:

- v0.1.0 data-model §2.1 (Consumer repository) — invariants
  unchanged.
- v0.1.0 data-model §2.5 (`linear-config.yml`) — schema unchanged.
  Spec 002 writes to the same `linear.team.id`, `linear.project.id`,
  `linear.operator.*` paths.
- v0.1.0 data-model §3 (Linear-side entities) — Linear `Team`,
  `Project`, `Issue`, `Workflow State`, etc. all unchanged. Spec
  002 only reads from `Team` + `Project` (and creates new `Project`
  via FR-041).
- v0.1.0 contracts/config-schema.json — UUID patterns and required
  fields unchanged.

## Cross-references

- Spec 002: [`spec.md`](./spec.md) — 13 FRs, 5 SCs, 3 user stories.
- Plan: [`plan.md`](./plan.md) — Technical Context + Constitution
  Check.
- Research: [`research.md`](./research.md) — 6 design decisions.
- Contracts: [`contracts/install-discovery-graphql.md`](./contracts/install-discovery-graphql.md),
  [`contracts/install-prompts.md`](./contracts/install-prompts.md),
  [`contracts/install-flags.md`](./contracts/install-flags.md).
- v0.1.0 data-model: [`specs/001-spec-kit-linear-bridge/data-model.md`](../001-spec-kit-linear-bridge/data-model.md).
- v0.1.0 config schema: [`specs/001-spec-kit-linear-bridge/contracts/config-schema.json`](../001-spec-kit-linear-bridge/contracts/config-schema.json).
