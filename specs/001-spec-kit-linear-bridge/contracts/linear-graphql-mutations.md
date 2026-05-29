# Linear GraphQL Mutations — Bridge Contract

**Status**: Phase 1 contract. Locks the exact set of Linear write
operations the bridge issues, by lifecycle phase, with idempotency
and error-handling rules.

**Scope**: Every mutation enumerated here is one of two flavours:

- **GraphQL (direct HTTPS)** — issued by `src/graphql.sh` (a `curl`
  wrapper) from git hooks, the seed step, the GitHub Action, or
  anywhere no MCP session is available. These speak raw GraphQL
  against `https://api.linear.app/graphql`.
- **Linear MCP tool call** — issued by AI-invoked commands
  (`commands/linear-*.md`) over the operator's MCP-host session.
  These call the official Linear MCP at `https://mcp.linear.app/mcp`
  and resolve to one or more underlying GraphQL mutations
  server-side. Tool names taken from
  `validation/linear-mcp-runtime-probe.md` §3 (live `tools/list`
  output, 2026-05-28).

Per **Principle VI** (OAuth-first, keys-at-the-edges) AI paths use
the MCP (OAuth); the direct-GraphQL paths use a token (`.env`
`LINEAR_API_KEY` locally, `LINEAR_API_TOKEN` GitHub secret remotely).
Both paths converge on the same reconciler logic; this file documents
both so contracts can be reviewed regardless of edge.

The wire-format header for direct GraphQL is `Authorization: <token>`
**without** the `Bearer` prefix, per Linear's GraphQL docs (confirmed
in `validation/github-action-mechanics.md` §2).

---

## 1. Lifecycle phases (when mutations fire)

| Phase | Trigger | Authoring path |
|---|---|---|
| **Seed-time** | `speckit.linear.seed` (one-shot, per workspace) | GraphQL (workflow states), MCP (labels) |
| **Install-time** | `speckit.linear.install` (one-shot, per consumer repo) | MCP (Project create-or-attach), GraphQL (project label create if needed) |
| **Reconcile-time** | `speckit.linear.push`, every `after_*` hook, every git hook | MCP for AI-invoked; GraphQL for git hooks (no session) |
| **Webhook-time** | GitHub Action on `pull_request: [opened, ready_for_review, closed]` | GraphQL only (Action has no MCP session) |

---

## 2. Seed-time mutations

### 2.1 `workflowStateCreate` (GraphQL, ×9)

**Operation**: Create the nine canonical lifecycle workflow states
in the consumer's Linear Team, one per FR-032 key (`specifying`,
`clarifying`, `planning`, `tasking`, `red_team`, `implementing`,
`analyzing`, `ready_to_merge`, `merged`).

**When called**: Once per Team, at `speckit.linear.seed`. Re-running
seed against a Team that already has matching states is a no-op
(idempotency below).

**Why GraphQL not MCP**: The live Linear MCP exposes no
`save_workflow_state` / `create_workflow_state` tool
(`linear-mcp-runtime-probe.md` §C Capability 8 — "still a gap").

**Signature**:

```graphql
mutation SeedWorkflowState($input: WorkflowStateCreateInput!) {
  workflowStateCreate(input: $input) {
    success
    workflowState {
      id
      name
      type
      team { id }
    }
  }
}

# input WorkflowStateCreateInput {
#   id:          String      # optional UUIDv4 — pass deterministic for idempotency
#   name:        String!     # e.g. "Specifying", "Ready-to-merge", "Merged"
#   color:       String!     # hex, required by Linear
#   type:        String!     # backlog|unstarted|started|completed|canceled
#   teamId:      String!     # workflow states are TEAM-scoped (probe §5)
#   description: String
#   position:    Float
# }
```

**Type mapping** (bridge enforces; informs Linear's filter UI):

| Lifecycle key | Linear `type` | Suggested name |
|---|---|---|
| `specifying`, `clarifying`, `planning`, `tasking`, `red_team` | `unstarted` | "Specifying", "Clarifying", … |
| `implementing`, `analyzing` | `started` | "Implementing", "Analyzing" |
| `ready_to_merge` | `started` | "Ready-to-merge" |
| `merged` | `completed` | "Merged" |

**Idempotency**: Before each call, the seed step queries
`workflowStates(filter: { team: { id: { eq: $teamId } }, name: { eq: $name } })`.
If exactly one match exists, capture its `id` into
`linear.workflow_state_uuids[<key>]` and skip the mutation. If zero
matches, call `workflowStateCreate` with a deterministic
`id = uuidv5(teamId + "::" + lifecycleKey, NS_SPECKIT_LINEAR)` so a
crash-retry produces the same UUID and Linear de-duplicates. If
multiple matches exist, surface a warning naming all candidates and
require operator selection — never auto-pick.

**Error handling**:

- **4xx auth (`AUTHENTICATION_ERROR`)**: abort seed; print the exact
  `gh secret set` / `.env` remediation. No partial state written to
  `linear-config.yml`.
- **5xx / network**: retry once with 2s backoff; on second failure
  abort with a warning. Seed is safe to re-run.
- **`VALIDATION` (`type` mismatch, illegal color)**: hard fail with
  the offending field and the full input echoed back. Bug in the
  bridge if hit; never the operator's fault.
- **State already exists race**: caught by the pre-query above. If
  the pre-query missed (interleaved seed runs), the post-create
  uniqueness constraint surfaces as `WORKFLOW_STATE_NAME_TAKEN` —
  re-query, capture the winner's UUID.

### 2.2 `issueLabelCreate` for `speckit-spec:*` / `phase:*` / `task-phase:*` (MCP)

**Operation**: Create the workspace label families the bridge uses
as stable identifiers (FR-004b) and filter aids (FR-003).

**When called**: At `speckit.linear.seed`. Re-runnable.

**Why MCP**: Issue labels are first-class in the live MCP catalogue
(`create_issue_label`, probe §6 Capability 6).

**MCP tool**:

```text
create_issue_label(
  name:        string,       # e.g. "phase:specifying"
  description: string?,
  color:       string?,      # hex
  teamId:      string?,      # null = workspace-scoped label
  parent:      string?,      # for grouping (probe doc)
  isGroup:     boolean?
) -> IssueLabel { id, name, color }
```

**Labels created**:

| Family | Names | Scope |
|---|---|---|
| `phase:*` | `phase:specifying`, `phase:clarifying`, `phase:planning`, `phase:tasking`, `phase:red_team`, `phase:implementing`, `phase:analyzing`, `phase:ready_to_merge` | Workspace (omit `teamId`) |
| `task-phase:*` (lazy) | `task-phase:1` … `task-phase:N` as needed | Workspace |
| `speckit-spec:NNN` (lazy) | Created on demand at reconcile-time when the bridge first stamps a spec Issue | Workspace |

**Idempotency**: Pre-query `list_issue_labels(name: <name>)`. If a
label by that exact name exists at the requested scope, capture its
ID and skip create. Linear treats label names case-sensitively;
seed normalises to lowercase.

**Error handling**: 4xx auth → abort + re-auth prompt. 5xx → retry
once + warn. Conflict (`NAME_TAKEN`) → re-query and capture winner.

### 2.3 `projectLabelCreate` — **deferred; not in v1**

`linear-mcp-runtime-probe.md` §3 Capability 6 notes the live MCP
exposes no `create_project_label`. The bridge's v1 reconciler does
**not** create project-scoped labels; the per-spec labels live on
Issues, not Projects. If a future version surfaces a need (e.g.
"all repos with active red-team flagged at the Project level"), add
the GraphQL fallback `projectLabelCreate(input: ProjectLabelCreateInput!)`
in its own seed pass.

---

## 3. Install-time mutations

### 3.1 `save_project` (MCP) — create-or-attach the consumer-repo Project

**Operation**: Resolve the Linear Project that represents this
consumer repo per FR-002. Two paths:

- **Attach to existing Project** — operator passes
  `--project <UUID>` or interactive picker selects an existing one.
  No mutation issued; UUID written straight to
  `linear.project.id`.
- **Create new Project** — operator passes `--auto-create` or
  accepts the interactive default. One `save_project` call.

**When called**: `speckit.linear.install`, exactly once per consumer
repo. Re-running install against a repo whose `linear-config.yml`
already names a Project re-queries it (`get_project`) and warns on
divergence; never re-creates.

**MCP tool** (probe §3 Capability 1):

```text
save_project(
  name:        string,        # required for create — defaults to repo basename
  addTeams:    string[],      # required for create — Team UUID or name; bridge passes [teamId]
  description: string?,       # markdown; bridge seeds with repo URL + "Managed by spec-kit-linear"
  summary:     string?,       # <=255 chars; bridge writes a 1-line repo summary
  state:       string?,       # "Planned" at create; updated at reconcile-time (§4.2)
  icon:        string?,
  color:       string?
) -> Project { id, name, state, teams { id } }
```

The probe confirms `addTeams` (not `teamIds`) is the array-form
field. The bridge always passes a single-element array.

**Idempotency**: The bridge does NOT use `save_project` as a
read-modify-write tool at install. The flow is:

1. Look up by intent (operator-supplied UUID, or by name in the
   bound Team's Projects via `list_projects(team: <teamId>)`).
2. If found and `--attach` mode: write UUID, skip mutation.
3. If not found and `--auto-create` mode: call `save_project` with
   a deterministic `id = uuidv5(teamId + "::" + repoBasename, NS)`.
4. Write resulting UUID to `linear.project.id`.

Re-install resolves to step 1, finds the Project by stored UUID
(`get_project`), warns if name diverged, never calls `save_project`.

**Error handling**: 4xx → re-auth. Validation (e.g.
`ADDTEAMS_REQUIRED`) → bug in the bridge. Conflict → re-query.

### 3.2 `save_project` (MCP) — set initial Status

Issued only if `save_project` in §3.1 didn't already set
`state: "Planned"`. The bridge's reconciler updates this per repo
activity (§4.2); install only ensures a sensible starting value.

---

## 4. Reconcile-time mutations

All reconcile-time mutations issued from AI-invoked paths use the
MCP. From git hooks they use the GraphQL equivalents. The two
modalities are functionally interchangeable per Principle II — the
mutation arguments and effects are identical.

### 4.1 `save_issue` (MCP) / `issueCreate` + `issueUpdate` (GraphQL) — the spec Issue

**Operation**: Create or update the Linear Issue that mirrors one
`specs/NNN-feature/` directory (FR-001, FR-003, FR-004).

**When called**: Every reconcile, for every spec the worktree
authorises writes to (FR-025). Read-only worktrees skip the
mutation but still query.

**MCP signature** (probe §3 Capability 2 — unified create+update):

```text
save_issue(
  id?:         string,        # present → update; absent → create
  title:       string,        # required for create
  team:        string,        # required for create — Team UUID
  description: string,        # markdown — full body incl. "memory" block (FR-004)
  project:     string,        # Project UUID from linear-config.yml
  state:       string,        # workflow-state UUID from linear.workflow_state_uuids
  labels:      string[],      # ["phase:<current>", "speckit-spec:NNN"]
  parentId:    string?        # null for spec Issues (sub-issues use this)
  assigneeId:  string?        # set to `linear.operator.user_id` from config per
                              # FR-034; omitted on `issueUpdate` for
                              # manual-reassign-persistence
) -> Issue { id, identifier, title, state { id }, labels { nodes { name } } }
```

**GraphQL signature** (used by git hooks; no MCP session):

```graphql
mutation IssueUpsert($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue { id identifier title }
  }
}

mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
  issueUpdate(id: $id, input: $input) {
    success
    issue { id identifier title state { id } }
  }
}
```

`IssueCreateInput` includes `assigneeId: String?` per FR-034 — the
bridge reads `linear.operator.user_id` from config and passes it on
every `issueCreate`. `IssueUpdateInput` MUST NOT carry `assigneeId`
(single-write-on-create semantics so manual reassignment in Linear's
UI persists across reconciles); absence of `linear.operator.user_id`
in config degrades gracefully — Issues are created unassigned and a
one-shot warning lands in the reconcile summary.

The bridge picks `issueCreate` vs `issueUpdate` based on the
identity lookup in §4.1.1.

**4.1.1 Identity lookup (mandatory before every `save_issue`)**:

Stable identity is the workspace label `speckit-spec:NNN`
(FR-004b). The bridge queries:

```graphql
query LocateSpecIssue($label: String!, $project: ID!) {
  issues(
    filter: {
      labels:  { name: { eq: $label } }
      project: { id:   { eq: $project } }
    }
    orderBy: updatedAt
  ) {
    nodes { id updatedAt }
  }
}
```

- **0 nodes** → call `save_issue` (no `id`) / `issueCreate`. The
  bridge MUST include `labels: ["speckit-spec:NNN", "phase:…"]` so
  the next query finds it.
- **1 node** → call `save_issue` (with `id: <node.id>`) /
  `issueUpdate(id: <node.id>, …)`.
- **2+ nodes** (race per FR-004b) → pick the node with the most
  recent `updatedAt`; mutate that one. Archive the others via
  `save_issue(id: <loser>, state: <archived-state-uuid>)` — but
  only from the authoritative worktree, and only after surfacing a
  warning.

**Idempotency**: The `save_issue` `description` field is always
overwritten with the bridge's freshly computed body (memory block
+ phase header). This is intentional per FR-004 ("MUST be rewritten
on every reconcile"). Unchanged content produces zero churn in
Linear's activity log because `save_issue` short-circuits when all
fields equal current. Labels are passed as a complete set; Linear
diffs internally (probe §3 Capability 6 — `labels: string[]` is set-semantics, not append).

**Error handling**:

- **4xx auth**: abort this spec, continue with the next spec
  (FR-024). Aggregate error count surfaces in the summary
  (FR-023).
- **5xx**: retry once with 2s backoff, then aggregate as warning.
- **Validation** (e.g. unknown `state` UUID): hard fail this spec,
  point at `speckit.linear.seed`. FR-022 governs.
- **Rate-limit (HTTP 400 + `RATELIMITED`)** per
  `linear-mcp-tool-signatures.md` §2: read
  `X-RateLimit-Endpoint-Remaining`, exponential backoff (1s, 2s,
  4s, 8s, give up). Aggregate as warning.

### 4.2 `save_project` (MCP) / `projectUpdate` (GraphQL) — repo Project Status

**Operation**: Update the consumer-repo Project's `state` to
reflect aggregate activity across all specs (FR-002:
Planned/Started/Paused/Completed/Cancelled).

**When called**: Once per reconcile, **after** all per-spec
`save_issue` calls have settled. Computed from:

- Any spec in `specifying` … `analyzing` → `state: "Started"`
- All specs merged AND none touched in `idle_window_days` → `state: "Paused"`
- All specs merged AND repo retired (manual override) → `state: "Completed"`

**MCP signature**: `save_project(id: <project-uuid>, state: <name-or-uuid>)`.

Per probe §3 Capability 5, the `state` field accepts a state name
string (`"Started"`) and the MCP server resolves it workspace-side.
The GraphQL fallback uses `projectUpdate(id: $id, input: { statusId: $statusId })`
and requires the bridge to have pre-resolved the status UUID — the
MCP path is simpler.

**Idempotency**: Pre-query `get_project(id: <uuid>) { state { name } }`. Skip the
mutation if current name matches desired. Operator override (FR-002)
takes precedence — if operator manually set `Paused`, bridge respects
it and does not re-flip.

**Error handling**: Same as `save_issue`. Failure here does not
block per-spec writes — Project Status is an aggregate sugar; aggregate as warning.

### 4.3 `save_issue` for task-phase sub-issues (MCP / GraphQL)

**Operation**: Create or update one Linear sub-issue per
`## Phase N: <Name>` header in `tasks.md` (FR-005). The sub-issue's
`parentId` points at the spec Issue's UUID. Its `description`
contains the read-only checklist mirror of that phase's tasks
(FR-006).

**When called**: Every reconcile, for every task-phase declared in
`tasks.md`, for every spec the worktree authorises (FR-025).

**MCP signature**: same `save_issue` tool, with `parentId` set. Per
FR-034, `assigneeId` is set to `linear.operator.user_id` from config
on `issueCreate` so task-phase sub-issues inherit the same operator
assignee as their parent spec Issue; `assigneeId` is omitted on
`issueUpdate` for manual-reassign-persistence.

**4.3.1 Identity lookup**:

Two-stage:

1. Find the parent spec Issue (per §4.1.1).
2. Query
   `issues(filter: { parent: { id: { eq: $parentId } }, labels: { name: { eq: "task-phase:N" } } })`.
   - **0 nodes** → create. Stamp `labels: ["task-phase:N"]` for next time.
   - **1 node** → update.
   - **2+ nodes** → most-recent-updatedAt wins, others archived.

**Title format** (FR-005): `Phase N — <Name>` exactly. The em-dash
is the locked separator. Avoids collision with `Phase N: <Name>`
which is the filesystem header form.

**Description format** (FR-006): the bridge generates a markdown
body with this exact header:

```markdown
> **Read-only mirror of `tasks.md` — ticks in Linear are overwritten
> on next reconcile.** Source: `specs/NNN-feature/tasks.md` § Phase N.

- [ ] T###-001 — <title>
- [x] T###-002 — <title>
- [ ] T###-003 — <title>
```

Completion state (`[ ]` vs `[x]`) reflects the box state in
`tasks.md`. The header makes the one-way semantics impossible to
miss per FR-006.

**Idempotency**: Same logic as §4.1. The description is rewritten
verbatim; if unchanged, Linear short-circuits.

**Workflow state** (FR-005, "Todo / In Progress / Done"): the
bridge picks per task-phase based on aggregated checkbox state:

- All `[ ]` → `Todo` (state-type `unstarted`)
- Mix → `In Progress` (state-type `started`)
- All `[x]` → `Done` (state-type `completed`)

These are Linear's per-Team default states. Task-phase sub-issues
use the team's existing default workflow states — Todo, In Progress,
Done — NOT the nine spec-lifecycle states which are scoped to spec
Issues (see § 3.7 of `data-model.md`). The seed step MUST query
`list_issue_statuses(team)` (the live MCP tool name per the runtime
probe §3 catalogue) and capture the UUIDs of any state whose `type`
is in `{unstarted, started, completed}` into a separate
`default_state_uuids` map in `linear-config.yml` alongside
`workflow_state_uuids`. The reconciler reads this map (keys
`task_todo`, `task_in_progress`, `task_done`) when setting sub-issue
workflow states.

**FR-005 invariant**: exactly one task-phase sub-issue is in
`In Progress` while the spec is in an implementing phase. Bridge
enforces by computing per-phase completion FIRST, then verifying
the invariant; if violated, flag in the summary and proceed
(reconcile, never event-push — let next reconcile converge).

### 4.4 `save_issue` for inter-task-phase blocking (MCP)

**Operation**: Add `blocks` / `blockedBy` arrays to task-phase
sub-issues so Phase 2 blocks Phase 3 etc. (FR-007).

**When called**: After all task-phase sub-issues for a spec have
been created/updated, the bridge issues one `save_issue` per
sub-issue with its `blocks` array fully populated.

**MCP signature** (probe §C Capability 4 — NATIVE, no GraphQL
fallback):

```text
save_issue(
  id:               string,        # the task-phase sub-issue
  blocks:           string[],      # sub-issue IDs this phase blocks (append-only)
  removeBlocks:     string[]       # sub-issue IDs to unlink
) -> Issue
```

**Idempotency**: Linear's `blocks` is append-only with no
relation IDs returned. The bridge MUST first call
`get_issue(id: <subissue>) { blocks { id } }`, diff against the
desired set, and issue exactly the deltas (`blocks` for additions,
`removeBlocks` for retractions). Zero deltas → skip the
`save_issue` call entirely.

**Belt-and-braces fallback**: If `save_issue.blocks` double-call
risk is unacceptable (e.g. high-concurrency repo with two
worktrees), the bridge MAY fall back to GraphQL
`issueRelationCreate(input: { id: $deterministicId, issueId, relatedIssueId, type: blocks })`
with a deterministic UUIDv4 — `uuidv5(specUuid + "::" + fromPhase + "->" + toPhase, NS)`.
v1 default is MCP path with a mandatory pre-query (per §4.4
idempotency above): the bridge MUST query the existing `blocks`
array via `get_issue` before invoking `save_issue` with new
`blocks`, diff against the desired set, and issue exactly the
deltas. If the T077 dogfood write probe confirms native
append-with-dedupe semantics on `save_issue.blocks`, the pre-query
MAY be dropped as an optimisation; until then it is mandatory.

**Error handling**: Same as §4.1.

### 4.5 `save_comment` (MCP) / `commentCreate` (GraphQL) — non-task artifacts

**Operation**: Post one comment per non-task lifecycle artifact
discovered on the filesystem (FR-008, FR-015): each
`### Session YYYY-MM-DD` block under `## Clarifications`, each
plan section summary, each red-team finding, each analyze finding,
each ratification entry.

**When called**: Every reconcile, for every newly-discovered
artifact (idempotency below).

**MCP signature** (probe §3 Capability 7):

```text
save_comment(
  issueId:  string,            # the spec Issue UUID
  body:     string,            # markdown
  id?:      string,            # if present → update; absent → create
  parentId?: string            # for threading (unused in v1)
) -> Comment { id, body, createdAt }
```

The probe confirms `save_comment` accepts `issueId` (and `projectId`,
`milestoneId`, etc., but the bridge only uses `issueId`). The
GraphQL fallback is the literal `commentCreate(input: CommentCreateInput!)`
with the same fields.

**Idempotency** (the hardest part of the contract):

The bridge MUST NOT post a duplicate comment for the same
filesystem artifact. Stable identity is the body's first line — a
deterministic marker the bridge emits:

```text
<!-- spec-kit-linear: clarify-session 2026-05-27 -->
**Clarification session 2026-05-27**

- Q: …  
  A: …
```

```text
<!-- spec-kit-linear: red-team-finding red-team-001 -->
**Red-team finding RT-001 — <title>**

…
```

```text
<!-- spec-kit-linear: plan-summary plan.md#L42-L78 -->
**Plan section: Constitution Check**

…
```

Before posting, the bridge queries
`comments(filter: { issue: { id: { eq: $specId } }, body: { startsWith: "<!-- spec-kit-linear: <kind> <id> -->" } })`.
If found, compare bodies; if equal, skip. If diverged, call
`save_comment(id: <existing>, body: <fresh>)` — yes, Linear
comments are mutable via `save_comment(id, body)` per probe §3.

**Per FR-015**: each `### Session YYYY-MM-DD` produces exactly one
comment (idempotent on re-run). The bridge does NOT introduce a
"ratified" phase — ratified clarifications already live inside
`spec.md`; the comment is purely audit-trail surface.

**Error handling**: Same as §4.1. Comment failures aggregate as
warnings and do NOT block the rest of the reconcile.

### 4.6 `save_issue` archive of duplicate spec Issues (MCP)

**Operation**: When §4.1.1 finds 2+ Issues for a single
`speckit-spec:NNN` label (race condition per FR-004b), the bridge
archives all losers by flipping their workflow state to a
type-`canceled` state and removing the `speckit-spec:NNN` label so
future lookups don't re-match.

**MCP signature**: `save_issue(id: <loser>, state: <canceled-uuid>, labels: <loser-labels-minus-speckit-spec:NNN>)`.

**When called**: Only from authoritative worktrees (FR-025).
Read-only worktrees surface the duplicate as a warning and decline
to mutate.

**Idempotency**: Loser identification is deterministic
(most-recent `updatedAt` wins). Archive itself is naturally
idempotent — repeated archive of an already-archived Issue is a
no-op.

---

## 5. Webhook-time mutations

The GitHub Action (`templates/github-action.yml`) issues exactly
**one** GraphQL mutation per fire, per **Principle III** (strict
write-domain separation between Layer D and Layer E).

### 5.1 `issueUpdate` (GraphQL) — flip `stateId` only

**Operation**: Change the spec Issue's workflow state to
`Ready-to-merge` (on PR opened / ready_for_review) or `Merged` (on
PR closed with `merged: true`).

**When called**: `pull_request: [opened, ready_for_review, closed]`
events per FR-027. `closed` events filtered by
`if: github.event.pull_request.merged == true` per
`validation/github-action-mechanics.md` §1.

**Signature** (verbatim from action mechanics):

```graphql
mutation FlipSpecIssueState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
  }
}
```

The Action MUST NOT include any other field in the `input` object.
Labels, description, comments, sub-issues, project status — all
Layer D's responsibility. This is the constitutional firebreak.

**Workflow-state UUID resolution** (FR-032): the Action reads
`linear.workflow_state_uuids.ready_to_merge` / `…merged` from the
checked-out `.specify/extensions/linear/linear-config.yml`. No
name-based lookup. The reference YAML in
`validation/github-action-mechanics.md` §1 uses a runtime name
lookup; the locked decision is **UUID-from-config** per FR-032 —
the reference YAML must be updated in `templates/github-action.yml`
before ship.

**Spec Issue identity lookup**: identical to §4.1.1
(`speckit-spec:NNN` label + project UUID).

**Idempotency**: Same input → same output. If the Issue is already
in the target state, `issueUpdate` returns `success: true` with no
Linear-side change (no activity-log entry). Re-firing the Action
on the same event produces the same Linear state per FR-030.

**Error handling**: See `webhook-action.md` §3 for the full table.
Summary:

- Missing token → fail red; Layer D fills the gap on next
  reconcile.
- 0 matches → `::warning::` + exit 0 (Layer D will create the
  Issue).
- 2+ matches → most-recent-updatedAt wins + `::warning::`. Action
  does NOT archive duplicates (Layer D's responsibility per
  Principle III).
- State UUID missing in config → fail red, point at
  `speckit.linear.seed`.
- 5xx / network → exit 1; Layer D converges on next sync.

---

## 6. Read-only queries used by the bridge

These don't mutate but are first-class members of the contract
because every mutation above relies on one of them for identity
lookup. Documented here for completeness; failure modes match
their mutation counterparts.

| Query | Purpose | FR |
|---|---|---|
| `issues(filter: { labels: { name }, project: { id } })` | Locate spec Issue by stable label | FR-004b |
| `issues(filter: { parent: { id }, labels: { name } })` | Locate task-phase sub-issue under spec | FR-005 |
| `comments(filter: { issue: { id }, body: { startsWith } })` | Locate existing comment by marker | FR-008, FR-015 |
| `workflowStates(filter: { team: { id }, name })` | Seed: discover existing states before create | FR-021 |
| `issueLabels(filter: { name })` | Seed: discover existing labels before create | FR-021 |
| `get_project(id)` / `projects(filter: { id })` | Verify Project still exists; read current `state` | FR-002 |
| `get_issue(id) { blocks { id } }` | Diff blocking relations before mutation | FR-007 |

All queries are issued from both the MCP path (via `list_*` /
`get_*` tools) and the GraphQL path (raw queries against
`https://api.linear.app/graphql`).

---

## 7. Cross-cutting contracts

### 7.1 Authentication

- **MCP path**: OAuth, managed by the operator's MCP-host
  keychain. Bridge never touches the token. Per Principle VI.
- **GraphQL path (local)**: `LINEAR_API_KEY` from `.env`
  (gitignored, FR-020). Wire header: `Authorization: <token>` —
  no `Bearer` prefix per Linear GraphQL docs.
- **GraphQL path (GitHub Action)**: `LINEAR_API_TOKEN` repo
  secret (FR-029). Same wire format.

### 7.2 Rate limits

Per `linear-mcp-tool-signatures.md` §2 and Linear's published
rate-limiting docs (<https://linear.app/developers/rate-limiting>):
5,000 req/hr/user, 2,000,000 complexity points/hr, 10k complexity
per query. No `Retry-After` header; rate-limit errors surface as
HTTP 400 with code `RATELIMITED`. The bridge MUST:

- Implement exponential backoff (1s, 2s, 4s, 8s, give up) on every
  `RATELIMITED` response.
- Respect `X-RateLimit-Endpoint-Remaining` and self-throttle when
  the value drops below 10% of `X-RateLimit-Endpoint-Limit`.
- Surface remaining-budget warnings in the summary block when any
  endpoint stays below 25% for two consecutive mutations.

Personal API tokens (`.env` `LINEAR_API_KEY`) and OAuth-app tokens
share the same per-user ceilings.

### 7.3 Idempotency-via-deterministic-`id`

Every `*Create` GraphQL mutation accepts an optional
`id: String` (UUIDv4) per `linear-mcp-tool-signatures.md` §5. The
bridge passes a deterministic UUIDv5 derived from a stable
filesystem key wherever exactly-once-on-retry semantics matter:

| Entity | UUIDv5 input |
|---|---|
| Spec Issue | `uuidv5(projectUuid + "::spec::" + featureNumber, NS_SPECKIT_LINEAR)` |
| Task-phase sub-issue | `uuidv5(specUuid + "::phase::" + phaseNumber, NS)` |
| Workflow state | `uuidv5(teamId + "::state::" + lifecycleKey, NS)` |
| Blocking relation (fallback path) | `uuidv5(fromSubIssueUuid + "->" + toSubIssueUuid, NS)` |
| Comment | NOT used — comments use body-marker identity (§4.5) |

`NS_SPECKIT_LINEAR` is a fixed namespace UUID baked into
`src/graphql.sh`: `7f3c6e2a-1d4b-5c8f-9e7d-3a2b1c4f5e6d` (locked
v1; never change without a major version bump).

### 7.4 What the bridge NEVER mutates

Per Principle I (Filesystem Is The Single Source of Truth) and
FR-016 / FR-017, the bridge never issues mutations against:

- Pull requests (`pullRequestUpdate`, `pullRequestCreate` — N/A,
  these are GitHub, not Linear, but called out for completeness)
- Linear → filesystem (no `git push`, no file writes triggered by
  Linear state)
- Linear Project Update objects (the weekly status post) — out of
  v1 scope per `linear-mcp-runtime-probe.md` §"Additional gaps"
- Linear cycles, initiatives, documents, attachments —
  out of v1 scope
- Workspace-wide settings, members, integrations — never

If a future spec adds any of these, this contract is the
single-source-of-truth amendment point.

---

## 8. Mutation index (for reviewers)

| # | Mutation | Phase | Path | FR |
|---|---|---|---|---|
| 2.1 | `workflowStateCreate` | Seed | GraphQL | FR-021, FR-032 |
| 2.2 | `create_issue_label` (MCP) | Seed | MCP | FR-021, FR-004b |
| 3.1 | `save_project` (create-or-attach) | Install | MCP | FR-002 |
| 3.2 | `save_project` (set state) | Install | MCP | FR-002 |
| 4.1 | `save_issue` / `issueCreate` / `issueUpdate` (spec) | Reconcile | MCP + GraphQL | FR-001, FR-003, FR-004 |
| 4.2 | `save_project` (Project Status) | Reconcile | MCP | FR-002 |
| 4.3 | `save_issue` (task-phase sub-issue) | Reconcile | MCP + GraphQL | FR-005, FR-006 |
| 4.4 | `save_issue` (blocks/blockedBy) | Reconcile | MCP | FR-007 |
| 4.5 | `save_comment` / `commentCreate` | Reconcile | MCP + GraphQL | FR-008, FR-015 |
| 4.6 | `save_issue` (archive race-duplicate) | Reconcile | MCP | FR-004b |
| 5.1 | `issueUpdate` (stateId only) | Webhook | GraphQL | FR-027, FR-028, FR-032 |

**Total mutations: 11**.
**`projectMilestoneCreate` is explicitly NOT used in v1** — the
filesystem-to-Linear mapping (data-model §1 of `spec.md`) maps task
phases to **sub-issues**, not milestones. The MCP exposes
`save_milestone` (probe §3 Capability 9) and the bridge may adopt
it in a future version if a use case emerges, but v1 ships without.

---

## 9. Items to confirm during T077 dogfood

The 2026-05-28 runtime probe
(`validation/linear-mcp-runtime-probe.md`) resolved every
introspectable unknown. The four items below are write-side
behaviours that the read-only probe couldn't exercise; the T077
dogfood is the canonical write probe and MUST verify each one
against the live ACME workspace.

- **Per-mutation sub-rate-limits.** Per
  `validation/linear-mcp-tool-signatures.md` §2, Linear publishes
  global limits — 5,000 req/hr/user + 2,000,000 complexity points/hr,
  per-query ceiling 10k complexity points — but sub-limits on
  individual mutations are undocumented. The bridge MUST read
  `X-RateLimit-Endpoint-Remaining` from every mutation response and
  back off (1s, 2s, 4s, 8s, give up) when the value drops below 10%
  of `X-RateLimit-Endpoint-Limit`. Errors return HTTP 400 with code
  `RATELIMITED`; there is no `Retry-After` header. T077 dogfood
  records the observed endpoint-limit numbers in
  `validation/performance-baseline.md`.

- **`save_issue.blocks` write-idempotency.** Per the runtime probe
  §"Remaining unknowns", the suspected behaviour is
  append-with-dedupe but not documented. The bridge MUST query the
  existing `blocks` array via `get_issue` before invoking
  `save_issue` with new `blocks` to avoid stacking duplicates. If
  T077 dogfood confirms native append-with-dedupe, the pre-query
  MAY be dropped as an optimisation; otherwise it stays mandatory.

- **Default-state UUIDs for task-phase Todo/In Progress/Done.** The
  team's stock workflow states (state types `unstarted`, `started`,
  `completed`) are queryable via `list_issue_statuses(team)` (live
  MCP tool name per probe §3). The seed step MUST capture these
  UUIDs into a new `default_state_uuids` map in `linear-config.yml`
  (keys: `task_todo`, `task_in_progress`, `task_done`). T077
  dogfood confirms the exact `type` → key mapping against the
  live ACME team.

- **`save_comment` body-mutation on `id` reuse.** Probe §3 documents
  the generic save-mutation contract ("If `id` is provided, updates
  the existing item"); assumed true for comments but not directly
  exercised. Bridge dedupes clarify-session comments by body match
  (first-line HTML marker + 200-char body prefix per §4.5). If an
  operator hand-edits a ratified clarify session in `spec.md`, the
  body match fails and the bridge posts a NEW comment rather than
  mutating the old — Linear's MCP `save_comment` does not currently
  give the bridge an id-stable update path because comment IDs are
  Linear-side-only on first create. T077 dogfood verifies this
  divergence path with one deliberate spec.md edit.
