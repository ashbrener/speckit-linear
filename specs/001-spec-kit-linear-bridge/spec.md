# Feature Specification: spec-kit ↔ Linear Bridge

**Feature Branch**: `001-spec-kit-linear-bridge`

**Created**: 2026-05-27

**Status**: Draft

**Input**: User description: "spec-kit ↔ Linear bridge — see BRIEF.md and validation/linear-mcp-capability-check.md for the design context. Author the spec from those. think hard"

## Overview

A spec-kit extension that mirrors the local filesystem state of each
spec-kit feature (`specs/NNN-feature/` plus the surrounding lifecycle
artifacts) into a Linear workspace, so operators running spec-kit across
multiple repositories can see and steer their work in a single Linear
view without leaving the markdown-driven spec-kit flow.

The mirror is **unidirectional** (filesystem → Linear) and
**reconcile-based** (each invocation reads filesystem state and pushes
whatever Linear needs to match, rather than diffing per event). The
extension installs into a consumer repo via `specify extension add` and
attaches to spec-kit's native `after_*` hooks so that every lifecycle
transition automatically refreshes Linear.

### Data-model mapping (locked in 2026-05-27)

| Filesystem concept | Linear primitive |
|---|---|
| Linear workspace (e.g. an "INFRA" workspace shared across personal / OSS repos) | Linear Workspace |
| Single owning team for all repos | Linear Team |
| Consumer repository | Linear **Project** |
| Spec (`specs/NNN-feature/`) | Linear **Issue** (one per spec) |
| Lifecycle phase | Workflow state on the spec Issue, plus a `phase:*` label |
| Implementation wave (W0, W1, …) | Linear **sub-issue** under the spec Issue |
| Tasks within a wave | Markdown **checklist** in the wave sub-issue's description (read-only mirror of `tasks.md`) |
| Inter-wave ordering | Linear blocking relation between wave sub-issues |
| Non-task artifacts (clarify answers, plan sections, red-team findings, analyze findings, ratification entries) | Comments on the spec Issue |
| Branch / worktree / last-touched-by metadata | Structured block in the spec Issue's description |

This mapping is the load-bearing decision behind every functional
requirement below.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Filesystem-to-Linear reconciliation (Priority: P1)

An operator with a spec-kit feature directory on disk wants Linear to
contain a faithful mirror of that feature: a Project named after the
spec, with milestones for each implementation wave, Issues for each
task, blocking relations for task dependencies, and a tracker Issue
that captures current phase state.

**Why this priority**: This is the bridge's core value. Without
reconciliation, none of the rest matters. It is also the slice that
defines the data-model contract every other story depends on.

**Independent Test**: Place a synthetic `specs/NNN-feature/` directory
with `spec.md`, `plan.md`, `tasks.md` (containing tasks with at least
one dependency and at least two waves) into a consumer repo that has
the extension installed and the Linear workspace seeded. Invoke the
reconcile operation. Verify the target Linear workspace now contains a
Project whose name and description match `spec.md`, milestones match
the waves, Issues match the tasks, blocking relations match the task
dependencies, and a tracker Issue exists with the correct phase
state. Re-invoke; verify no second copy is created and no fields
drift.

**Acceptance Scenarios**:

1. **Given** a `specs/NNN-feature/` dir with `spec.md` in a consumer
   repo whose Linear Project already exists, **When** sync runs,
   **Then** a Linear Issue exists inside that repo's Project with
   title matching the feature number + short name, a phase label
   matching the current lifecycle phase, and a "memory" block in its
   description showing branch, worktree, current wave/task and
   last-touched timestamp.
2. **Given** a `tasks.md` containing tasks grouped by wave with
   inter-wave dependencies, **When** sync runs, **Then** the spec
   Issue has one sub-issue per wave (stable identity across reruns),
   each wave sub-issue's description contains a checklist of that
   wave's tasks, and Linear blocking relations between wave
   sub-issues match the inter-wave dependencies.
3. **Given** a previously-synced spec, **When** sync runs again with
   no filesystem changes, **Then** Linear state is unchanged: no
   duplicate Issues or sub-issues, no churn on labels, comments, or
   blocking relations.
4. **Given** a previously-synced spec where a task is added to
   `tasks.md` in an existing wave, **When** sync runs, **Then** the
   only change in Linear is one new line in that wave sub-issue's
   checklist; no other Issues, sub-issues, or comments are touched.

---

### User Story 2 - Automatic sync on lifecycle transitions (Priority: P1)

An operator running `/speckit-specify`, `/speckit-clarify`,
`/speckit-plan`, `/speckit-tasks`, `/speckit-implement`, or
`/speckit-analyze` wants Linear to update automatically without
having to remember a separate sync step.

**Why this priority**: P1 because it is what makes the bridge feel
seamless rather than a chore. Without it, operators drift back to
manually managing Linear and the bridge atrophies.

**Independent Test**: Install the extension in a fresh consumer repo
with a seeded workspace. Run `/speckit-specify` for a new feature.
Verify the corresponding Linear Issue is created inside the repo's
Linear Project in the "Specifying" workflow state with phase label
`phase:specifying`. Run `/speckit-plan`. Verify the spec Issue's
workflow state moves to "Planning" with label `phase:planning`, the
"memory" block in its description updates to reflect the new phase,
and the repo's Linear Project status is "Started".

**Acceptance Scenarios**:

1. **Given** the extension is installed and the workspace is seeded,
   **When** any `/speckit-*` command completes, **Then** the
   corresponding `after_*` hook invokes the reconcile operation
   automatically and Linear reflects the new lifecycle state within
   the same operator-visible step.
2. **Given** a lifecycle phase transition (e.g. `/speckit-plan`),
   **When** reconcile runs, **Then** the spec Issue's workflow state
   and `phase:*` label match the canonical phase mapping for that
   phase, and the owning repo's Project Status reflects that the
   repo is active.
3. **Given** the hook is configured but disabled in
   `.specify/extensions.yml`, **When** a `/speckit-*` command
   completes, **Then** reconcile does not run and the operator is
   not prompted.

---

### User Story 3 - Cross-repo unified view (Priority: P2)

An operator running spec-kit in multiple repositories (each
potentially bound to a different Linear workspace) wants Linear to
surface state from all of them so they can see active phase, wave,
and blocker state in one place without switching repositories.

**Why this priority**: P2 because it is the value multiplier — the
reason to use Linear as the consolidated tracker rather than just
relying on filesystem state. But it follows from P1; if mirroring
works per-repo, cross-repo is essentially "install in more places".

**Independent Test**: Install the extension in two consumer repos
bound to the same Linear workspace. Drive a different spec to a
different phase in each. Verify both Projects exist in the workspace
with correct phase labels and tracker Issue states, and a single
filter (`phase:implementing` or similar) returns the right subset.

**Acceptance Scenarios**:

1. **Given** two repos each bound to the same workspace with active
   specs in different phases, **When** the operator filters the
   workspace by phase label, **Then** the relevant Projects from both
   repos appear with no naming or identity collisions.
2. **Given** two repos bound to different workspaces, **When** sync
   runs in each, **Then** each Project lands in its own workspace and
   neither repo's data leaks into the other workspace.

---

### User Story 4 - One-shot install and workspace seed (Priority: P2)

An operator adopting the bridge in a new repo or workspace wants the
configuration steps (hook wiring, MCP endpoint, label and workflow
state creation) to be accomplished by one or two named commands
rather than hand-editing config files.

**Why this priority**: P2 because adoption friction kills tools like
this. If installing takes 20 minutes per repo, the operator will not
install it in repo #4.

**Independent Test**: From a fresh consumer repo with spec-kit
already initialized and a fresh Linear workspace, run the documented
install sequence (extension add + workspace seed). Verify the
consumer repo now has the bridge's hooks registered and the workspace
has all required labels and tracker-Issue workflow states. Then run
`/speckit-specify` for a new feature and verify the full sync works
end-to-end with no further manual configuration.

**Acceptance Scenarios**:

1. **Given** a fresh consumer repo with spec-kit installed, **When**
   the operator runs the extension add command, **Then**
   `.specify/extensions.yml` gains the bridge's hooks and a consumer
   `.mcp.json` is created (or updated) so the operator's coding agent
   can reach Linear.
2. **Given** a fresh Linear workspace, **When** the operator runs the
   workspace seed operation, **Then** the workspace contains the
   required phase labels, wave labels, and the tracker-Issue
   workflow states needed by the bridge.
3. **Given** the workspace is **not** seeded, **When** sync runs,
   **Then** sync halts with a clear error pointing the operator to
   the seed step (no partial state is created in Linear).

---

### User Story 5 - Retroactive sync of already-complete specs (Priority: P3)

An operator adopting the bridge mid-flight wants to point the
reconcile operation at a repo that already contains in-progress and
already-merged specs, and have Linear end up reflecting the correct
current state for each — including marking already-merged specs as
"Merged" without resurrecting them through every phase.

**Why this priority**: P3 because it is convenience, not core
function. An operator could manually mark older specs as merged. But
omitting this story would force exactly that manual cleanup on
adoption, which is enough friction to delay adoption.

**Independent Test**: In a repo that contains one in-flight spec
(say, midway through implementation) and one already-merged spec,
run reconcile from a clean Linear workspace. Verify the repo's
Linear Project is created, both spec Issues appear inside it, the
in-flight one in the correct mid-implementation workflow state with
its waves' sub-issues in correct per-wave states, and the merged
one directly in "Merged" workflow state — without intermediate
phase transitions appearing in Linear's activity log.

**Acceptance Scenarios**:

1. **Given** an already-merged spec, **When** sync runs against a
   workspace that has never seen this spec, **Then** the resulting
   spec Issue is created in "Merged" workflow state directly, not
   by transitioning through every prior phase.
2. **Given** an in-flight spec whose phase the bridge must infer
   from filesystem (no prior Linear record), **When** sync runs,
   **Then** the phase chosen matches the phase that would have
   resulted from running every hook in sequence, and any waves
   whose tasks are partly complete appear with the correct
   per-checklist-item progress.

---

### Edge Cases

- A `specs/NNN-feature/` directory exists but `spec.md` is missing
  or empty. (Reconcile should skip the directory and surface a
  warning, not crash or create a partially-populated spec Issue.)
- A task entry in `tasks.md` is malformed or its inter-wave
  dependency references a wave that does not exist. (Reconcile
  should still sync the rest of the spec; bad items surface as
  warnings inside the wave sub-issue's checklist header.)
- Linear API rate limits or transient network failures partway
  through a sync. (Reconcile should be safely re-runnable; partial
  state on Linear should converge to correct state on the next run.)
- A spec directory is renamed on disk (e.g. `003-old-name` →
  `003-new-name`) between syncs. (Reconcile should find the existing
  spec Issue by stable identifier — feature number scoped to its
  consumer repo's Linear Project — and update its title rather than
  creating a duplicate.)
- Tasks are added, removed, or reordered between syncs. (Reconcile
  should converge: the affected wave sub-issue's checklist is
  rewritten to match `tasks.md`; no other sub-issues or Issues
  change.)
- The operator triggers two hooks in rapid succession or the same
  hook twice. (Reconcile should be safe under concurrent invocation —
  the worst-case outcome is duplicated work, not corrupted Linear
  state.)
- The Linear OAuth session has expired. (Reconcile should fail with
  a clear "reauthenticate" message; no partial mutation should
  occur.)
- The consumer's Linear workspace lacks the labels or workflow
  states that the bridge expects. (Reconcile should halt with a
  clear pointer to the seed step.)
- The same feature number is reused across consumer repos (e.g.
  `speckit-linear/specs/001-…` and `wingman/specs/001-…`).
  (Reconcile should disambiguate by the owning Linear Project — i.e.
  by consumer repo identity — and never cross-pollinate.)
- The operator ticks a checklist item in Linear's UI. (The next
  reconcile rewrites that checklist to match `tasks.md` and the tick
  is lost; the wave sub-issue description's header must make this
  one-way behavior obvious to avoid surprise.)

## Requirements *(mandatory)*

### Functional Requirements

#### Mirroring (data-model contract)

- **FR-001**: The bridge MUST reconcile the filesystem state of every
  `specs/NNN-feature/` directory in a consumer repo into a single
  Linear **Issue** per spec, all owned by the **Linear Project** that
  represents that consumer repo. Reconciliation MUST be idempotent:
  running it repeatedly against unchanged filesystem state MUST
  produce no observable changes in Linear.
- **FR-002**: For each consumer repo, the bridge MUST maintain
  exactly one Linear Project named after the repo. The Project's
  Status enum (Planned / Started / Paused / Completed / Cancelled)
  MUST reflect the repo's lifecycle (e.g. Started while any spec is
  active; Paused if no spec has been touched in a configurable idle
  window; the operator may override).
- **FR-003**: Each spec Issue's title MUST encode the feature number
  and short name (e.g. `001-spec-kit-linear-bridge`). Its workflow
  state MUST reflect the spec's lifecycle phase; a `phase:*` label on
  the Issue MUST mirror the same phase for filter-by-label use.
- **FR-004**: The spec Issue's description MUST contain a structured
  "memory" block that surfaces, at minimum: current lifecycle phase,
  current implementation wave and current task identifier (when
  applicable), the git branch the spec lives on, the worktree path(s)
  where that branch is currently checked out, the timestamp the spec
  was last touched on disk, and a link to the spec's GitHub source.
  This block MUST be rewritten on every reconcile so it is the
  authoritative quick-look view for "what is this spec doing right
  now".
- **FR-005**: Each implementation wave (W0, W1, W2, …) declared in
  `tasks.md` or `plan.md` MUST become a Linear **sub-issue** under
  the spec Issue, with stable identity across syncs (so that a wave
  is never duplicated). The wave sub-issue's workflow state MUST
  reflect the wave's progress (e.g. Todo / In Progress / Done) and
  exactly one wave MUST be in the "In Progress" state at any time
  while the spec is in an implementing phase.
- **FR-006**: The wave sub-issue's description MUST contain a
  markdown checklist that mirrors the tasks belonging to that wave
  from `tasks.md`, with each checklist item showing the task code
  (`T###-NNN`) and its title, and reflecting completion state from
  `tasks.md`. The checklist MUST include a clear header noting that
  Linear's checkboxes are a read-only mirror — operator-side ticks
  in Linear are overwritten on the next reconcile.
- **FR-007**: Inter-wave ordering MUST be mirrored as Linear blocking
  relations between wave sub-issues (e.g. W1 blocks W2 if W2's tasks
  depend on W1's outputs). Inter-task ordering within or across waves
  remains as text inside the checklist; the bridge MUST NOT create
  per-task blocking relations.
- **FR-008**: Non-task lifecycle artifacts (each ratified clarify
  round, plan section summaries, red-team findings, analyze findings,
  decision entries) MUST be surfaced as **comments on the spec
  Issue**, in chronological order, so they are discoverable from
  within Linear without leaving the spec Issue's thread.

#### Triggering

- **FR-009**: The bridge MUST be invokable via spec-kit's native
  `.specify/extensions.yml` hooks at every spec-kit lifecycle
  transition, at minimum `after_specify`, `after_clarify`,
  `after_plan`, `after_tasks`, `after_implement`, and
  `after_analyze`.
- **FR-010**: The bridge MUST also be invokable on demand
  (independent of any hook), so an operator can manually trigger
  reconciliation to recover from a missed or failed hook.
- **FR-011**: Reconciliation triggered by any path (hook or manual)
  MUST be identical in behaviour and outcome.

#### Detection

- **FR-012**: The bridge MUST infer the current lifecycle phase of
  each spec from filesystem state alone (presence of `spec.md`,
  `plan.md`, `tasks.md`, `red-team*.md`, `analyze*.md`; any
  ratification marker; PR open/merged state where determinable),
  without requiring a separate "current phase" file maintained by
  the operator.
- **FR-013**: The bridge MUST detect when a spec is "merged" (the PR
  has landed on the default branch) and reflect this as spec Issue
  workflow state "Merged", phase label cleared, and the `phase:*`
  label removed. The owning repo's Project Status reflects whether
  the repo overall is still active (independent of any single
  spec's merge).
- **FR-014**: When inferring phase for a spec the bridge has not seen
  before, the bridge MUST converge to the same end state that would
  result from running every hook in sequence — without producing any
  intermediate phase artifacts (no spurious comments, no transitional
  status flips visible in Linear's activity log).
- **FR-015**: For every `### Session YYYY-MM-DD` subheading the
  bridge finds under the `## Clarifications` section of `spec.md`,
  it MUST post (exactly once, idempotently) a comment on the spec
  Issue containing that session's Q/A bullets. The bridge MUST NOT
  introduce a separate "ratified" lifecycle phase — canonical
  spec-kit treats each accepted clarification as immediately part
  of the spec, and the bridge mirrors that semantics.

#### Direction & boundaries

- **FR-016**: Sync MUST be unidirectional. The bridge MUST NOT write
  back to the filesystem based on Linear changes. The filesystem is
  the single source of truth.
- **FR-017**: The bridge MUST NOT create or update pull requests,
  nor un-draft existing pull requests, in response to any Linear or
  filesystem state.

#### Setup, auth, and multi-workspace

- **FR-018**: The bridge MUST be installable into a consumer repo via
  spec-kit's `specify extension add` mechanism, with no additional
  global package install required on the operator's machine beyond
  spec-kit itself.
- **FR-019**: After installation, the bridge MUST be configurable per
  consumer repo (not globally per operator), so different repos can
  bind to different Linear workspaces without runtime switching.
- **FR-020**: Authentication to Linear MUST NOT require the operator
  to manage long-lived API keys when an OAuth-based path is
  available; any unavoidable secret (e.g. for the fallback path)
  MUST be loaded from a gitignored file or environment variable,
  never committed.
- **FR-021**: The bridge MUST provide a workspace seed operation
  that creates all required labels and tracker-Issue workflow states
  in a Linear workspace. This operation MUST be safe to re-run.
- **FR-022**: If a consumer repo's bound workspace has not been
  seeded, sync MUST halt with a clear error that names the missing
  resources and points to the seed operation, rather than partially
  succeeding.

#### Observability

- **FR-023**: Each reconcile invocation MUST produce a structured
  summary (counts of Projects / Issues / Milestones created or
  updated, plus any warnings) visible to the operator at the
  invocation point.
- **FR-024**: Warnings (malformed dependency markers, missing
  spec.md, etc.) MUST be surfaced without aborting the whole sync —
  the bridge MUST process every spec it can and only halt for
  workspace-level configuration errors (per FR-022).

### Key Entities

- **Consumer repo**: A git repository that has the bridge installed
  via `specify extension add` and is bound to one Linear workspace.
  Mirrors to one Linear **Project** per repo.
- **Spec**: The unit of work on the filesystem
  (`specs/NNN-feature/`). Identified by its feature number (`NNN`).
  Mirrors to one Linear **Issue** inside the repo's Project.
- **Wave**: A grouping of tasks (W0, W1, …) declared in `tasks.md`
  or `plan.md`. Mirrors to one Linear **sub-issue** under the spec
  Issue. Carries its own workflow state.
- **Task**: An entry in `tasks.md`. Identified by its task code
  (e.g. `T003-013`). Mirrors to one **checklist item** in its wave
  sub-issue's description — not a Linear Issue.
- **Lifecycle phase**: The spec's current position in the spec-kit
  flow (Specifying, Clarifying, Planning, Tasking, Red-team,
  Implementing, Analyzing, Ready-to-merge, Merged). Encoded on the
  spec Issue's workflow state and a `phase:*` label. The bridge
  does not introduce a distinct "Ratified" phase — canonical
  spec-kit writes accepted clarifications directly into `spec.md`,
  so the Clarifying phase ends when `plan.md` appears.
- **Decision / ratification record**: A non-task artifact captured
  during the spec's life (ratified clarify answers, plan section
  summaries, red-team findings, analyze findings). Mirrors to a
  comment on the spec Issue.
- **Repo Linear Project**: The Linear Project that owns all spec
  Issues from a single consumer repo. Its Project Status enum
  reflects whether the repo is actively worked on.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator running a `/speckit-*` command on a seeded
  workspace sees the corresponding Linear update reflected on the
  next refresh of their Linear view (no more than one
  operator-visible step between completing the spec-kit command and
  seeing the Linear change).
- **SC-002**: Reconciliation against an unchanged filesystem
  produces zero observable changes in Linear (no churn in activity
  log, no modified-timestamps on labels or relations).
- **SC-003**: Installing the bridge in a new repo and seeding a
  fresh Linear workspace takes the operator no more than ten minutes
  of hands-on time end-to-end.
- **SC-004**: At least one operator (the bridge's author)
  successfully uses the bridge to track lifecycle state on at least
  three concurrent specs across at least two consumer repositories
  without losing track of any spec's phase.
- **SC-005**: After running reconcile against a repo that contains
  one already-merged spec and one in-flight spec, the operator can
  identify the current phase of every spec from the Linear workspace
  alone (no need to open the consumer repo to disambiguate).
- **SC-006**: Adding or removing a single task from `tasks.md` and
  re-running reconcile changes exactly one line in exactly one wave
  sub-issue's checklist in Linear, with no churn on any other Issue,
  sub-issue, comment, or label.
- **SC-007**: A reconcile run that encounters a malformed task entry
  or inter-wave dependency still successfully syncs every other
  spec, wave, and checklist in the repo and surfaces a warning
  naming the malformed item.
- **SC-008**: At any moment during normal operation, a Linear filter
  for `phase:implementing` returns a list of every spec across every
  bound consumer repo that is currently being implemented, with each
  result showing the spec's current branch and worktree directly in
  the result row's preview.

## Assumptions

- The operator is running spec-kit ≥ v0.8.13 (the current pinned
  version) and the GitHub `specify` CLI extension mechanism is the
  install path.
- Each consumer repo is bound to exactly one Linear workspace. The
  bridge does not mirror a single spec into multiple workspaces in
  v1.
- The official Linear MCP server (`https://mcp.linear.app`) is the
  default authentication and integration surface, accessed via
  OAuth. Issue comments — the surface used by FR-008 for non-task
  artifacts — are natively supported. The only capability gap that
  the bridge cares about for runtime use is `workflowStateCreate`,
  which is needed only at workspace-seed time (a one-shot setup
  step) and is handled by a small Linear GraphQL helper invoked
  during seed; no long-lived API key is required for normal sync
  operation.
- Task identifiers follow the canonical `T<feature-number>-<seq>`
  form (e.g. `T003-013`) and dependency markers follow the
  canonical form used in spec-kit's `tasks.md` template;
  non-canonical formats will surface as warnings rather than block
  sync.
- Linear → filesystem reverse sync is out of scope. Automatic PR
  creation, drafting, and un-drafting are out of scope.
- The bridge's own development repository will dogfood itself
  starting from spec 002 onwards; spec 001 (this spec) may be
  retroactively synced after the v1 implementation lands.
- A shared "INFRA" Linear workspace is available for dogfooding the
  bridge on its own development and on other personal / OSS
  projects during early iterations.
