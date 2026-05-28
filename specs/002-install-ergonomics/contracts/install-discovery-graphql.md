# Install Discovery — Linear GraphQL Contract

**Status**: Phase 1 contract for spec 002. Locks the four new
GraphQL operations the install ceremony issues during the
viewer-driven discovery flow (FR-037..FR-043, FR-048). Companion
to v0.1.0's [`linear-graphql-mutations.md`](../../001-spec-kit-linear-bridge/contracts/linear-graphql-mutations.md)
which remains the canonical contract for seed-time, reconcile-time,
and webhook-time mutations.

**Scope**: All four operations below are issued via direct GraphQL
HTTPS (`src/graphql.sh::graphql::query` / `graphql::mutate`)
against `https://api.linear.app/graphql`. No MCP path — install
runs before any MCP session is wired into the consumer repo.

**Authentication**: `LINEAR_API_KEY` from `.env` or
`LINEAR_API_KEY` environment variable. Wire header
`Authorization: <key>` (no `Bearer` prefix per Linear GraphQL
docs). The v0.1.0 `graphql::query` wrapper handles this.

**Idempotency posture**: Three of the four operations are **read
queries** — natively idempotent. The one mutation
(`projectCreate`) is invoked at most once per install run, on the
"Create new project" branch. Retries on network failure may
double-create; spec.md Edge Case bullet 5 (`network failure
mid-projectCreate`) instructs operator to pick the just-created
project from the picker on retry rather than auto-deduplicating.

---

## 1. `viewer` (query) — FR-038, FR-048

**Operation**: Verify the operator's API key and capture identity
in a single round trip. The same response feeds:

- The api-key-valid gate (FR-038 — `viewer == null` halts install).
- The `linear.operator.{user_id, name, email}` block in
  `linear-config.yml` (FR-034 — already shipped in v0.1.0).
- The `linear.workspace.{name, url_key}` block in
  `linear-config.yml` (informational; existing v0.1.0 schema).
- The team-list authorization (the same key authorizes the next
  `teams` query in §2).

**When called**: Step S2 of the discovery state machine. Exactly
once per install invocation per FR-048 — the same response is
cached in `INSTALL_SESSION_VIEWER_*` module globals and consumed
by every downstream step.

**Signature**:

```graphql
query InstallViewer {
  viewer {
    id
    name
    email
    organization {
      name
      urlKey
    }
  }
}
```

**Variables**: none.

**Expected response shape**:

```json
{
  "data": {
    "viewer": {
      "id": "11111111-2222-3333-4444-555555555555",
      "name": "Ash Brener",
      "email": "ash@example.com",
      "organization": {
        "name": "OSH Infra",
        "urlKey": "osh-infra"
      }
    }
  }
}
```

**Field-to-config mapping** (consumed by
`install::write_config`):

| GraphQL path | `linear-config.yml` path |
|---|---|
| `data.viewer.id` | `linear.operator.user_id` |
| `data.viewer.name` | `linear.operator.name` |
| `data.viewer.email` | `linear.operator.email` |
| `data.viewer.organization.name` | `linear.workspace.name` |
| `data.viewer.organization.urlKey` | `linear.workspace.url_key` |

**Failure modes**:

- **HTTP 401 / 403** (invalid or revoked key) → halt with exit 2.
  Verbatim message: `LINEAR_API_KEY invalid; create a new key at
  https://linear.app/settings/api`.
- **`data.viewer == null`** → halt with exit 2. Linear returns
  `viewer == null` on a syntactically-valid but rejected key.
  Same remediation as 401.
- **`errors[]` non-empty with `extensions.code ==
  "AUTHENTICATION_ERROR"`** → halt with exit 2. Same remediation.
- **HTTP 5xx / network failure** → halt with exit 3 (transport).
  Operator re-runs when connectivity returns.
- **Missing `viewer.id`** (well-formed response but no UUID) →
  halt with exit 2 + bug-report instruction (this should never
  happen against a healthy Linear).

**Performance budget**: < 3s wall-clock (single round trip, no
joins).

---

## 2. `teams` (query) — FR-039

**Operation**: List the teams the API key can read. Powers the
operator-facing team picker.

**When called**: Step S3 of the discovery state machine. Skipped
when `--team <UUID>` flag is passed (FR-044 fast path).

**Signature**:

```graphql
query InstallTeams {
  teams(first: 21) {
    nodes {
      id
      name
      key
    }
  }
}
```

**Variables**: none.

**Why `first: 21`** (not 20 or 50): per `research.md` §1 — 21 is
the smallest fetch that lets the bridge detect overflow without a
second `pageInfo` query. The picker displays the first 20; if a
21st node is present, the picker appends a warning row
instructing the operator to pass `--team <UUID>` (spec 002
Clarifications Q2 + spec.md Edge Case bullet 2).

**Expected response shape**:

```json
{
  "data": {
    "teams": {
      "nodes": [
        {
          "id": "6ab43461-6d22-4f02-bb1e-0be9859c7997",
          "name": "OSH",
          "key": "OSH"
        },
        {
          "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
          "name": "Engineering",
          "key": "ENG"
        }
      ]
    }
  }
}
```

**Picker emission format** (FR-039 verbatim):

```text
  1) OSH      — OSH
  2) ENG      — Engineering
Pick a team [1-2]:
```

The `%-8s` width on `key` accommodates Linear's max 5-char team
key plus padding. The em-dash separator is locked per FR-039.

**Failure modes**:

- **`data.teams.nodes.length == 0`** → halt with exit 2.
  Verbatim message: `no teams accessible to this API key; check
  workspace settings at https://linear.app/<workspace>/settings/teams`.
  (spec.md Edge Case bullet 1.)
- **`data.teams.nodes.length == 1`** → auto-pick, no prompt. Emit
  surface row: `Found 1 team — using <key> (<name>) (auto)`.
  (FR-039 + spec.md acceptance scenario 2.)
- **`data.teams.nodes.length > 20`** → display first 20, append
  warning row: `+ <N-20> more teams not shown; pass --team <UUID>
  to install non-interactively`. Operator picks from the
  displayed set OR aborts and re-runs with the flag.
- **HTTP / GraphQL errors** → same envelope as §1.

**Performance budget**: < 3s wall-clock.

---

## 3. `team(id).projects` (query) — FR-040

**Operation**: List the existing projects in the operator's
selected team. Powers the project picker with the "Create new"
tail option.

**When called**: Step S4 of the discovery state machine. Skipped
when `--project <UUID>` flag is passed.

**Signature**:

```graphql
query InstallTeamProjects($teamId: String!) {
  team(id: $teamId) {
    id
    projects(first: 21) {
      nodes {
        id
        name
      }
    }
  }
}
```

**Variables**:

```json
{ "teamId": "6ab43461-6d22-4f02-bb1e-0be9859c7997" }
```

(`teamId` is the operator-selected team's UUID from §2's response.
The operator never sees this UUID; it's passed internally.)

**Expected response shape**:

```json
{
  "data": {
    "team": {
      "id": "6ab43461-6d22-4f02-bb1e-0be9859c7997",
      "projects": {
        "nodes": [
          {
            "id": "97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080",
            "name": "spec-kit-linear"
          },
          {
            "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "name": "acme-backend"
          }
        ]
      }
    }
  }
}
```

**Picker emission format** (FR-040 verbatim):

```text
Projects in OSH:
  1) spec-kit-linear
  2) acme-backend
  3) Create new project
Pick a project [1-3]:
```

The "Create new project" option is ALWAYS appended as the
**final** option (index `N+1` where `N` is `len(nodes)`).
Even when `len(nodes) == 0`, "Create new project" is option `1)`.

**Failure modes**:

- **`data.team == null`** → halt with exit 2. (Operator passed
  `--team <UUID>` for a team the key can't see — backwards-compat
  validation per FR-044.)
- **`data.team.projects.nodes.length == 0`** → picker shows
  "Create new project" as the only option; operator can pick it
  or quit. Surface row: `No existing projects in <team-key>`.
- **`data.team.projects.nodes.length > 20`** → display first 20 +
  "Create new project", append warning row: `+ <N-20> more
  projects not shown; pass --project <UUID> to install
  non-interactively`.
- **HTTP / GraphQL errors** → same envelope as §1.

**Performance budget**: < 3s wall-clock.

---

## 4. `projectCreate` (mutation) — FR-041

**Operation**: Create a new Linear Project in the operator's
selected team. Captures the new project's UUID + name + URL for
both the install summary and `linear-config.yml`.

**When called**: Step S5 of the discovery state machine. Only
when operator picked "Create new project" at step S4. At most
once per install invocation.

**Signature**:

```graphql
mutation InstallProjectCreate($input: ProjectCreateInput!) {
  projectCreate(input: $input) {
    success
    project {
      id
      name
      url
    }
  }
}
```

**Variables**:

```json
{
  "input": {
    "name": "spec-kit-linear",
    "teamIds": ["6ab43461-6d22-4f02-bb1e-0be9859c7997"],
    "description": "Auto-created by speckit.linear.install for spec-kit lifecycle mirroring."
  }
}
```

**Field details**:

- `name`: from operator input. Default is the consumer repo's
  directory basename per FR-041 (matches v0.1.0
  `install::_create_project` default at `src/install.sh:880`).
- `teamIds`: single-element array containing the operator-selected
  team's UUID. Required by Linear's `ProjectCreateInput`.
- `description`: fixed string for v0.1.1, byte-identical to
  v0.1.0's existing default (consistency with the v0.1.0
  `--auto-create` path).
- `state`: deliberately omitted. Linear's workspace default
  (typically `Backlog` / `Planned`) wins; the reconciler flips it
  on its first run per v0.1.0 FR-002 / data-model §6.2.
- `id`: deliberately omitted. Spec 002 does NOT pass a
  deterministic UUIDv5 here. Rationale: the project name is
  operator-supplied at install time and may include characters
  unsafe for UUIDv5 namespace hashing. The non-deterministic ID is
  acceptable because (a) install is one-shot per repo, and (b)
  spec.md Edge Case bullet 5 explicitly handles the retry case via
  the project picker (operator sees the just-created project on
  re-run).

**Expected response shape**:

```json
{
  "data": {
    "projectCreate": {
      "success": true,
      "project": {
        "id": "97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080",
        "name": "spec-kit-linear",
        "url": "https://linear.app/osh-infra/project/spec-kit-linear-97bca3d5ede3"
      }
    }
  }
}
```

**Field-to-config mapping**:

| GraphQL path | `linear-config.yml` path | Notes |
|---|---|---|
| `data.projectCreate.project.id` | `linear.project.id` | The UUID the rest of the bridge uses for lookup. |
| `data.projectCreate.project.name` | `linear.project.name` | Informational. |
| `data.projectCreate.project.url` | (not persisted) | Surfaced in install summary's "open in Linear" link only. |

**Pre-mutation duplicate-name check**: per FR-041 + spec.md Edge
Case bullet 4, the install MUST first query
`team(id).projects(filter: { name: { eq: <name> } })` (a quick
exact-name match) before issuing `projectCreate`. If a project
with the chosen name already exists:

- Display: `a project named "<name>" already exists in this team`.
- Prompt: `[create-anyway/pick-existing/rename]
  (default: pick-existing):`
- On `create-anyway`: proceed with the mutation as written.
- On `pick-existing`: skip the mutation; set
  `selected_project_id` to the existing project's UUID; continue
  to S6.
- On `rename`: loop back to the name prompt.

This pre-check uses the same `team(id).projects` query shape as
§3 with an added `filter` clause:

```graphql
query InstallProjectByName($teamId: String!, $name: String!) {
  team(id: $teamId) {
    projects(filter: { name: { eq: $name } }, first: 5) {
      nodes { id name url }
    }
  }
}
```

(v0.1.0 already implements an exact-name lookup at
`src/install.sh:843` — `install::_find_existing_project`. Spec
002 reuses it.)

**Failure modes**:

- **`data.projectCreate.success == false`** → halt with exit 1
  (recoverable). Surface the verbatim Linear error from
  `data.projectCreate.errors[]` or `errors[]`. Operator can re-run.
- **Permission denied** (operator picked a team they don't have
  project-create permission in, per spec.md Edge Case bullet 3) →
  same as above; Linear returns `success: false` with a verbatim
  permission error.
- **Network failure mid-mutation** → halt with exit 1. On retry,
  spec.md Edge Case bullet 5 instructs the operator to look for
  the just-created project in the picker; the duplicate-name
  pre-check above is the safety net.
- **`projectCreate.project.id` missing** (well-formed response
  but no UUID) → halt with exit 1 + bug-report instruction.

**Performance budget**: < 5s wall-clock (single mutation).

---

## 5. Cross-cutting contracts

### 5.1 Wire format

- HTTP method: `POST`
- URL: `https://api.linear.app/graphql`
- Headers:
  - `Content-Type: application/json`
  - `Authorization: <LINEAR_API_KEY>` (no `Bearer` prefix per
    Linear GraphQL docs; matches v0.1.0
    `src/graphql.sh:210`).
- Body: standard GraphQL JSON envelope `{ "query": "<query>",
  "variables": { ... } }`.

### 5.2 Rate limits

Per v0.1.0 contracts/linear-graphql-mutations.md §7.2 — 5,000
req/hr/user, 2,000,000 complexity points/hr, no `Retry-After`.
The four operations in this contract sum to at most 4 queries
+ 1 mutation per install run; nowhere near rate-limit pressure.
No special handling beyond v0.1.0's `graphql::query` retry
logic.

### 5.3 Operator-facing UUID exposure

Per **SC-010** (zero UUIDs surfaced), no GraphQL response field
containing a UUID is ever printed to the operator. The install
prints:

- Team `key` + `name` (numbered picker, single-team auto-pick row).
- Project `name` (numbered picker, "Create new" prompt default).
- Project `url` (install summary's "open in Linear" link — URL
  contains the project's URL slug, NOT its UUID).

UUIDs are internal-only: stored in `INSTALL_SESSION_*` bash
variables, written to `linear-config.yml`, never displayed.

### 5.4 What this contract does NOT cover

- The post-discovery hook registration (FR-043) and Action install
  (FR-027) — unchanged from v0.1.0; covered by
  v0.1.0 contracts/extension-manifest.md and command-shapes.md.
- Workflow-state UUID seeding (FR-021) — runs at `speckit.linear.seed`
  AFTER install; covered by v0.1.0 contracts/linear-graphql-mutations.md
  §2.
- Backwards-compat UUID validation when `--team` / `--project` are
  passed — covered by [`install-flags.md`](./install-flags.md) §3.

### 5.5 Backwards-compat validation query (FR-044)

When the operator passes both `--team <UUID>` and `--project
<UUID>` (or `--non-interactive` with both), the install MUST
quick-validate both UUIDs in a single round trip before writing
`linear-config.yml`. This avoids writing a config that points at
deleted Linear resources.

```graphql
query InstallValidateBinding($teamId: String!, $projectId: String!) {
  team(id: $teamId) {
    id
    name
    key
  }
  project(id: $projectId) {
    id
    name
    url
    teams { nodes { id } }
  }
}
```

**Validation**:

- `data.team == null` → halt: `--team <UUID> not accessible to this
  API key`.
- `data.project == null` → halt: `--project <UUID> not accessible
  to this API key`.
- `data.project.teams.nodes[].id` does NOT contain
  `data.team.id` → halt: `--project does not belong to --team`.

When only `--project <UUID>` is passed (FR-044), the install
resolves the team from `data.project.teams.nodes[0].id` rather
than requiring `--team`. The same query above is used; the team
ID is read from the project's `teams` connection.

---

## 6. Operation index (for reviewers)

| # | Operation | Type | When | FR |
|---|---|---|---|---|
| 1 | `viewer { id name email organization }` | Query | Step S2 (always; reused for FR-034) | FR-038, FR-048 |
| 2 | `teams(first: 21) { nodes }` | Query | Step S3 (skipped if `--team`) | FR-039 |
| 3 | `team(id).projects(first: 21) { nodes }` | Query | Step S4 (skipped if `--project`) | FR-040 |
| 4 | `projectCreate(input)` | Mutation | Step S5 ("Create new" branch only) | FR-041 |
| 5 | `team(id) { ... } project(id) { ... }` | Query | Step S0/S6 (only when both UUID flags passed) | FR-044 |
| 5b | `team(id).projects(filter: name)` pre-check | Query | Before S5 mutation (duplicate-name check) | FR-041 / spec.md Edge Case 4 |

**Total new operations: 6** (5 queries + 1 mutation). All flow
through the existing `src/graphql.sh` wrappers; no new HTTP
client surface.

---

## Cross-references

- [v0.1.0 contracts/linear-graphql-mutations.md](../../001-spec-kit-linear-bridge/contracts/linear-graphql-mutations.md)
  — full GraphQL contract for the rest of the bridge.
- [data-model.md §4](./data-model.md) — discovery state machine
  that drives these operations.
- [install-prompts.md](./install-prompts.md) — operator-facing
  prompt contracts for steps S1, S3, S4, S5.
- [install-flags.md](./install-flags.md) — CLI flags that
  short-circuit individual operations.
- [research.md §1](./research.md) — rationale for `first: 21`
  pagination probe.
- [research.md §2](./research.md) — rationale for `projectCreate`
  field choices.
