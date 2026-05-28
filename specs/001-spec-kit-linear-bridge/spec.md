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
| Implementation task phase (Phase 1, Phase 2, …) | Linear **sub-issue** under the spec Issue |
| Tasks within a task phase | Markdown **checklist** in the task-phase sub-issue's description (read-only mirror of `tasks.md`) |
| Inter-task-phase ordering | Linear blocking relation between task-phase sub-issues |
| Non-task artifacts (clarify answers, plan sections, red-team findings, analyze findings, ratification entries) | Comments on the spec Issue |
| Branch / worktree / last-touched-by metadata | Structured block in the spec Issue's description |

This mapping is the load-bearing decision behind every functional
requirement below.

## Clarifications

### Session 2026-05-27

- Q: How does the bridge find the right Linear Project for a given consumer repo on every sync? → A: At `specify extension add linear` time the bridge prompts the operator with a default (create a new Project named after the repo directory) and an option to attach to an existing Project; the resolved Project UUID is written to a committed config file at `.specify/extensions/linear/config.yml`. Non-interactive installs require explicit `--project <UUID>` or `--auto-create` flags rather than silent guessing.
- Q: How does the bridge find a spec's existing Linear Issue on subsequent syncs (so it updates rather than duplicates)? → A: When the bridge creates a spec Issue it stamps a workspace label `speckit-spec:NNN` (NNN = feature number) on the Issue, and on subsequent syncs queries "Issues in this repo's Linear Project with label `speckit-spec:NNN`". No state file is maintained on the filesystem side. If a race produces multiple Issues with the same label in the same Project, the bridge auto-resolves on next sync by keeping the Issue with the most recent Linear activity and archiving the rest.
- Q: How does the bridge identify task groupings inside `tasks.md`, and what terminology should Linear use? → A: Adopt canonical spec-kit terminology. The bridge parses `## Phase N: <Name>` markdown headers in `tasks.md`; each header opens a task-phase group whose tasks are the checklist items underneath until the next `## Phase` header. Linear sub-issues are titled `Phase N — <Name>`. The optional filter label uses the canonical form `task-phase:N`. The BRIEF's "wave / W0 / W1" terminology is dropped in favour of spec-kit's native vocabulary.
- Q: How does the bridge identify the Linear Team that owns repo-Projects? → A: The per-repo `.specify/extensions/linear/config.yml` holds both `team_id` and `project_id`. At `specify extension add linear` time the bridge auto-detects: if the workspace has exactly one team it pre-fills with no prompt; if multiple teams exist it prompts the operator to pick (default = team named "INFRA" or matching the workspace name). Both UUIDs are written to the same per-repo config so the repo is fully self-describing — clone it, run sync, no other state needed.
- Q: How does the bridge detect that a spec is "Merged" vs "Ready-to-merge" vs still "Implementing"? → A: Two-layer architecture (D + E). Layer E (webhook): a GitHub Action installed in each consumer repo at extension-add time fires on `pull_request` events (opened, ready_for_review, closed-with-merged=true) and calls Linear directly to flip the spec Issue's workflow state — authoritative, real-time. Layer D (reconciliation): ad-hoc and hook-driven syncs use `gh` CLI when available for full merge / draft / non-draft signal, falling back to git-only branch-reachability for the merged-or-not check when `gh` is missing. The two layers are independently idempotent; either layer alone keeps Linear converging to the right state, both together cover live commits and retroactive sync.
- Q: At `specify extension add linear` time, MUST the install step verify and report on every dependency it touches (Linear MCP wiring in `.mcp.json`, OAuth ceremony status, `gh` CLI presence, bridge runtime), or is best-effort silent install acceptable? → A: Install MUST verify and report on every dependency it touches; silent failures are not acceptable. The concrete dependency list (which runtimes, which MCP entries, which OAuth scopes) is fixed by `/speckit-plan` once the bridge's implementation language is chosen; FR-018b codifies the single load-bearing rule.
- Q: Should the extension auto-register its `after_*` hooks in the consumer repo's `.specify/extensions.yml` at install time, or ship only on-demand commands the operator triggers manually? → A: Auto-register all relevant `after_*` hooks at install time with `optional: false`, so every lifecycle command pings Linear automatically (the "memory just works" default). Ship on-demand commands (`speckit.linear.push`, `speckit.linear.pull`, `speckit.linear.status`) as escape hatches for manual control / recovery. Operators can disable any individual hook by editing the YAML.
- Q: When the GitHub Action fires and needs to flip the spec Issue's workflow state, does it look up the state by NAME (e.g. `"Ready-to-merge"`, `"Merged"`) or by UUID? → A: UUID-based binding, mirroring the Project and Team UUID pattern. The seed step (FR-021) creates the workflow states, captures their UUIDs at creation time, and writes them to `.specify/extensions/linear/config.yml` under a `workflow_state_uuids` map (keyed by lifecycle-phase name). The Action reads UUIDs from config and queries Linear by UUID. Name changes in Linear's UI don't break the lookup; only state deletion does, which surfaces as an explicit error.
- Q: Should the bridge also fire on local git operations (branch checkout, commit, local merge) so Linear's branch/worktree/current-task memory block stays current even when the operator hasn't run a spec-kit command? → A: Yes. The bridge auto-installs local git hooks (`post-checkout`, `post-commit`, `post-merge`) at `specify extension add linear` time per FR-033. These hooks invoke the same reconciler as spec-kit's `after_*` hooks. Crons, daemons, filesystem watchers, and other long-running or scheduled triggers remain explicitly out of scope.

### Session 2026-05-28

- Q: Should Linear Issues + sub-issues the bridge creates be assigned to a specific Linear user? → A: Yes — assigned to the operator (the Linear user whose API key / OAuth token authenticates the install) on creation, captured via `viewer { id name email }` GraphQL query at install time and persisted to `linear.operator.user_id` in `linear-config.yml`. Sub-issues for task phases inherit the same assignee. `issueUpdate` calls do NOT pass `assigneeId`, so manual reassignment in Linear's UI persists across reconciles. FR-034 codifies this.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Filesystem-to-Linear reconciliation (Priority: P1)

An operator with a spec-kit feature directory on disk wants Linear to
contain a faithful mirror of that feature: a Project named after the
spec, with sub-issues for each implementation task phase, checklist
items for each task, blocking relations for task-phase dependencies,
and a tracker Issue that captures current phase state.

**Why this priority**: This is the bridge's core value. Without
reconciliation, none of the rest matters. It is also the slice that
defines the data-model contract every other story depends on.

**Independent Test**: Place a synthetic `specs/NNN-feature/` directory
with `spec.md`, `plan.md`, `tasks.md` (containing tasks with at least
one dependency and at least two task phases) into a consumer repo
that has the extension installed and the Linear workspace seeded.
Invoke the reconcile operation. Verify the target Linear workspace now
contains a Project whose name and description match `spec.md`,
sub-issues match the task phases, checklist items match the tasks,
blocking relations match the task-phase dependencies, and a tracker
Issue exists with the correct phase state. Re-invoke; verify no
second copy is created and no fields drift.

**Acceptance Scenarios**:

1. **Given** a `specs/NNN-feature/` dir with `spec.md` in a consumer
   repo whose Linear Project already exists, **When** sync runs,
   **Then** a Linear Issue exists inside that repo's Project with
   title matching the feature number + short name, a phase label
   matching the current lifecycle phase, and a "memory" block in its
   description showing branch, worktree, current task phase / task
   and last-touched timestamp.
2. **Given** a `tasks.md` containing tasks grouped by task phase with
   inter-task-phase dependencies, **When** sync runs, **Then** the
   spec Issue has one sub-issue per task phase (stable identity
   across reruns), each task-phase sub-issue's description contains
   a checklist of that task phase's tasks, and Linear blocking
   relations between task-phase sub-issues match the
   inter-task-phase dependencies.
3. **Given** a previously-synced spec, **When** sync runs again with
   no filesystem changes, **Then** Linear state is unchanged: no
   duplicate Issues or sub-issues, no churn on labels, comments, or
   blocking relations.
4. **Given** a previously-synced spec where a task is added to
   `tasks.md` in an existing task phase, **When** sync runs, **Then**
   the only change in Linear is one new line in that task-phase
   sub-issue's checklist; no other Issues, sub-issues, or comments
   are touched.

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
surface state from all of them so they can see active phase, task
phase, and blocker state in one place without switching repositories.

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
3. **Given** the same spec exists in two worktrees (one on the
   spec's feature branch, one on `main`) and the feature-branch
   worktree has progressed the spec further, **When** sync runs
   from the `main` worktree, **Then** Linear's state for that spec
   is unchanged and the operator is shown the Linear-current view
   without local mutation.

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
   required phase labels, task-phase labels, and the tracker-Issue
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
its task phases' sub-issues in correct per-task-phase states, and
the merged one directly in "Merged" workflow state — without
intermediate phase transitions appearing in Linear's activity log.

**Acceptance Scenarios**:

1. **Given** an already-merged spec, **When** sync runs against a
   workspace that has never seen this spec, **Then** the resulting
   spec Issue is created in "Merged" workflow state directly, not
   by transitioning through every prior phase.
2. **Given** an in-flight spec whose phase the bridge must infer
   from filesystem (no prior Linear record), **When** sync runs,
   **Then** the phase chosen matches the phase that would have
   resulted from running every hook in sequence, and any task
   phases whose tasks are partly complete appear with the correct
   per-checklist-item progress.

---

### Edge Cases

- A `specs/NNN-feature/` directory exists but `spec.md` is missing
  or empty. (Reconcile should skip the directory and surface a
  warning, not crash or create a partially-populated spec Issue.)
- A task entry in `tasks.md` is malformed or its inter-task-phase
  dependency references a task phase that does not exist. (Reconcile
  should still sync the rest of the spec; bad items surface as
  warnings inside the task-phase sub-issue's checklist header.)
- Linear API rate limits or transient network failures partway
  through a sync. (Reconcile should be safely re-runnable; partial
  state on Linear should converge to correct state on the next run.)
- A spec directory is renamed on disk (e.g. `003-old-name` →
  `003-new-name`) between syncs. (Reconcile should find the existing
  spec Issue by stable identifier — feature number scoped to its
  consumer repo's Linear Project — and update its title rather than
  creating a duplicate.)
- Tasks are added, removed, or reordered between syncs. (Reconcile
  should converge: the affected task-phase sub-issue's checklist is
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
  `spec-kit-linear/specs/001-…` and `wingman/specs/001-…`).
  (Reconcile should disambiguate by the owning Linear Project — i.e.
  by consumer repo identity — and never cross-pollinate.)
- The operator ticks a checklist item in Linear's UI. (The next
  reconcile rewrites that checklist to match `tasks.md` and the tick
  is lost; the task-phase sub-issue description's header must make
  this one-way behavior obvious to avoid surprise.)
- No worktree currently has the spec's feature branch checked out
  (e.g. operator switched all worktrees to `main`). The spec's
  Linear state stays frozen at whatever the last authoritative sync
  recorded; any sync invoked from a non-authoritative worktree is
  read-only for that spec, per FR-025.
- The operator runs sync from a worktree whose filesystem view of a
  spec is older than Linear's current state for the same spec (e.g.
  worktree is on `main`, another worktree on the feature branch has
  progressed the spec to `Implementing`). The non-authoritative
  worktree's sync MUST NOT regress Linear's state; FR-025 prevents
  the regression by making the sync read-only for that spec.
- The GitHub Action's Linear API token has been rotated or removed
  but the secret hasn't been updated. The webhook fails silently on
  the Action side; the next reconciliation sync (Layer D) detects
  the merged state and reconciles Linear correctly. The operator is
  not told via the bridge that the webhook is broken — they discover
  it by seeing repeated red Action runs in GitHub.
- The consumer repo has GitHub Actions disabled (org policy, or
  manually disabled). The webhook layer is unavailable; the
  reconciliation layer alone is responsible for merged detection.
  The bridge MUST detect this at install time and warn the operator
  rather than silently leaving an unused workflow file.
- `gh` CLI is not installed on the operator's machine and the
  webhook also failed (or was never installed). Merged detection
  falls back to git-only branch reachability — the bridge can tell
  "merged or not" but cannot detect the "Ready-to-merge"
  intermediate state. The spec Issue stays at "Implementing" or
  "Analyzing" until merge, then jumps directly to "Merged".

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
  exactly one Linear Project. The Project's UUID MUST be resolved at
  `specify extension add linear` time — interactively by prompting
  the operator with a default ("create a new Project named after the
  repo directory") plus options to attach to an existing Project or
  rename, or non-interactively via `--project <UUID>` or
  `--auto-create` flags. The resolved Project UUID and the owning
  Team UUID MUST both be written to
  `.specify/extensions/linear/config.yml` (committed to the consumer
  repo) and subsequent syncs MUST look up the Project by that UUID,
  not by name. The Project's Status enum (Planned / Started / Paused
  / Completed / Cancelled) MUST reflect the repo's lifecycle (e.g.
  Started while any spec is active; Paused if no spec has been
  touched in a configurable idle window; the operator may override).
  The Team UUID is resolved at the same `specify extension add linear`
  step: if the bound Linear workspace contains exactly one team the
  bridge auto-fills with no prompt; if multiple teams exist the
  bridge prompts the operator to pick (default = team named "INFRA"
  or matching the workspace name); a `--team <UUID>` flag overrides
  for non-interactive installs.
  The same config file also stores a `workflow_state_uuids` map (per
  FR-032) populated by the seed step; the bridge reads these UUIDs at
  runtime instead of relying on workflow state names.
- **FR-003**: Each spec Issue's title MUST encode the feature number
  and short name (e.g. `001-spec-kit-linear-bridge`). Its workflow
  state MUST reflect the spec's lifecycle phase; a `phase:*` label on
  the Issue MUST mirror the same phase for filter-by-label use.
- **FR-004**: The spec Issue's description MUST contain a structured
  "memory" block that surfaces, at minimum: current lifecycle phase,
  current implementation task phase and current task identifier (when
  applicable), the git branch the spec lives on, the worktree path(s)
  where that branch is currently checked out, the timestamp the spec
  was last touched on disk, and a link to the spec's GitHub source.
  The bridge fully owns the spec Issue's description body: the entire
  description is rewritten on every reconcile (overview → memory →
  diagrams, in canonical order) and any prior content is discarded.
  No fence markers are used — Linear's renderer surfaces HTML comments
  and `<details>` tags as visible text nodes, so there is no fence
  shape that can hide bridge framing from the UI. Operator
  annotations belong in Linear comments on the spec Issue (per FR-008,
  the canonical escape hatch), which the bridge never touches. This
  is the description-layer expression of the unidirectional sync rule
  in FR-016.
- **FR-004b**: The bridge MUST stamp a workspace label
  `speckit-spec:NNN` (NNN = feature number) on each spec Issue at
  creation time and use that label as the stable lookup key on every
  subsequent sync; if multiple Issues with the same label exist in
  the same Project (rare race condition), the bridge MUST keep the
  one with the most recent Linear activity and archive the others.
- **FR-005**: Each implementation task phase (Phase 1, Phase 2,
  Phase 3, …) declared in `tasks.md` or `plan.md` MUST become a
  Linear **sub-issue** under the spec Issue, with stable identity
  across syncs (so that a task phase is never duplicated). The
  task-phase sub-issue's workflow state MUST reflect the task
  phase's progress (e.g. Todo / In Progress / Done) and exactly one
  task phase MUST be in the "In Progress" state at any time while
  the spec is in an implementing phase.
- **FR-006**: The task-phase sub-issue's description MUST contain a
  markdown checklist that mirrors the tasks belonging to that task
  phase from `tasks.md`, with each checklist item showing the task
  code (`T###-NNN`) and its title, and reflecting completion state
  from `tasks.md`. The checklist MUST include a clear header noting
  that Linear's checkboxes are a read-only mirror — operator-side
  ticks in Linear are overwritten on the next reconcile.
- **FR-007**: Inter-task-phase ordering MUST be mirrored as Linear
  blocking relations between task-phase sub-issues (e.g. Phase 2
  blocks Phase 3 if Phase 3's tasks depend on Phase 2's outputs).
  Inter-task ordering within or across task phases remains as text
  inside the checklist; the bridge MUST NOT create per-task blocking
  relations.
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

#### Concurrency & write authority

- **FR-025**: For any given spec, the only worktree authorised to
  WRITE to Linear is the one currently checked out on that spec's
  feature branch (i.e. the branch named `<feature-num>-...`).
  Worktrees on any other branch (e.g. `main`, an unrelated feature
  branch) MUST NOT mutate the spec's Linear Issue or its sub-issues
  even if the bridge is invoked from that worktree; their syncs are
  read-only with respect to that spec.
- **FR-026**: When the bridge is invoked from a non-authoritative
  worktree for a given spec, it MUST still surface that spec's
  current Linear state (phase, current task phase / task,
  branch/worktree pointers from the memory block) to the operator
  so the operator can answer "what's done?" from any worktree
  without mutating state.

#### Operator identity

- **FR-034**: The bridge MUST capture the operator's Linear user
  identity (`user_id`, `name`, `email`) at `specify extension add
  linear` time via the GraphQL `viewer` query, and persist it to
  `.specify/extensions/linear/linear-config.yml` under
  `linear.operator.user_id` (UUID, the lookup key) plus
  `linear.operator.name` and `linear.operator.email` (informational,
  for the install-time summary and for the memory block). The
  reconciler MUST pass this `user_id` as `assigneeId` on every
  `issueCreate` mutation it issues (both the spec Issue and the
  task-phase sub-issues), but MUST NOT pass `assigneeId` on
  `issueUpdate` mutations — single-write-on-create semantics so an
  operator who manually reassigns an Issue in Linear keeps that
  reassignment across reconciles. If `linear.operator.user_id` is
  absent from the config (older configs, manually-edited config),
  the reconciler MUST surface a warning and create Issues
  unassigned rather than fail (graceful degradation).

#### Estimates (story points)

- **FR-035**: Each task line in `tasks.md` MAY carry an optional
  Fibonacci-scale story-point marker (`[N]` where N ∈ {1, 2, 3, 5, 8,
  13, 21}) within the leading run of bracketed prefixes that follow
  the task code, e.g. `- [ ] T001 [3] Author the contracts JSON` or
  `- [x] T020 [P] [US1] [5] Integration test for fresh reconcile`.
  The bridge MUST extract the FIRST digit-only bracketed token
  (anywhere in the first 5 leading bracketed tokens, scanning left to
  right) as the task's estimate. Non-digit bracketed tokens (`[P]`,
  `[US1]`, etc.) MUST be preserved in the task description — only
  the digit token is consumed.
  The bridge MUST emit Linear `estimate` values as follows:
  - Each task-phase sub-issue's `estimate` field = sum of every `[N]`
    marker across the tasks belonging to that phase. If NO task in
    the phase carries a marker, the bridge MUST omit `estimate`
    from the mutation entirely (Linear's UI shows "—" rather than
    "0"), so the absence of markers reads as "operator declined to
    estimate" rather than "estimated as zero".
  - The spec Issue's `estimate` field = sum of every `[N]` across
    all of `tasks.md` (the spec-level rollup). Same omission rule:
    no markers at all ⇒ no `estimate` field on the mutation.
  Single-write-on-create-plus-driven-update semantics, mirroring
  FR-034 but in reverse: on `issueCreate` the bridge stamps the
  computed estimate (if any). On `issueUpdate` the bridge MUST
  rewrite the estimate when the computed value is non-empty AND
  differs from Linear's current value; if the computed value is
  empty (no markers anywhere) the bridge MUST NOT clear an
  operator-set Linear estimate, so manual Linear-side estimation
  remains the operator's escape hatch.
  Bridge behaviour MUST be tolerant of malformed markers: any
  bracketed token whose contents are NOT pure digits is ignored as
  an estimate candidate and left in the description verbatim. The
  bridge MUST NOT validate Fibonacci-scale membership — if an
  operator writes `[7]` (off-scale), the bridge passes 7 through to
  Linear and lets Linear's team-level estimation scale handle
  rounding or rejection.

#### Setup, auth, and multi-workspace

- **FR-018**: The bridge MUST be installable into a consumer repo via
  spec-kit's `specify extension add` mechanism, with no additional
  global package install required on the operator's machine beyond
  spec-kit itself. Installation MUST also offer to drop a GitHub
  Action workflow at `.github/workflows/spec-kit-linear-sync.yml` in
  the consumer repo (per FR-027) and guide the operator through
  provisioning a Linear API token as a GitHub repository secret named
  `LINEAR_API_TOKEN` if the operator accepts.
- **FR-018b**: The `specify extension add linear` install step MUST
  verify the presence of every external dependency it touches and
  surface a clear status report to the operator before completing.
  At minimum this covers: the consumer repo's `.mcp.json` (entry
  for the Linear MCP added, or already present); the Linear MCP
  OAuth status (operator has authenticated at least once); the
  `gh` CLI (present and authenticated, or explicitly noted as
  absent with degradation guidance); the bridge's own runtime
  dependencies as defined by `/speckit-plan`. The install MUST
  NOT silently leave any dependency unverified. If any dependency
  cannot be auto-installed, the install MUST print exact remediation
  steps the operator can copy-paste.
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
  At creation time, the seed step MUST capture the UUID of every
  workflow state it creates and write the resulting
  `workflow_state_uuids` map into the consumer repo's
  `.specify/extensions/linear/config.yml` (per FR-032).
- **FR-022**: If a consumer repo's bound workspace has not been
  seeded, sync MUST halt with a clear error that names the missing
  resources and points to the seed operation, rather than partially
  succeeding.

#### Observability

- **FR-023**: Each reconcile invocation MUST produce a structured
  summary (counts of Projects / Issues / sub-issues created or
  updated, plus any warnings) visible to the operator at the
  invocation point.
- **FR-024**: Warnings (malformed dependency markers, missing
  spec.md, etc.) MUST be surfaced without aborting the whole sync —
  the bridge MUST process every spec it can and only halt for
  workspace-level configuration errors (per FR-022).

#### External GitHub integration (webhook layer)

- **FR-027**: The bridge MUST ship a GitHub Action workflow that
  consumer repos install to `.github/workflows/spec-kit-linear-sync.yml`
  at `specify extension add linear` time. Installation is opt-in
  (the operator may decline and rely solely on the reconciliation
  layer). The workflow MUST be authored to handle three GitHub
  events at minimum: pull request opened, pull request marked
  ready-for-review (transitioning from draft), and pull request
  closed with `merged: true`.
- **FR-028**: When the GitHub Action fires, it MUST identify the
  spec it belongs to by parsing the feature number from the PR's
  source branch name (e.g. branch `001-spec-kit-linear-bridge` →
  feature number `001`), then call the Linear API directly to flip
  the matching spec Issue's workflow state: "Ready-to-merge" when
  the PR is opened or marked ready, "Merged" when the PR is closed
  with `merged: true`. The Action MUST use the workspace label
  `speckit-spec:NNN` (per FR-004b) and the Project UUID stored in
  the consumer repo's `.specify/extensions/linear/config.yml` to
  locate the spec Issue unambiguously.
  Workflow state lookups MUST use UUIDs from
  `.specify/extensions/linear/config.yml.workflow_state_uuids` (per
  FR-032), not workflow state names.
- **FR-029**: The Action MUST authenticate to Linear using a Linear
  API token stored as a GitHub repository secret named
  `LINEAR_API_TOKEN`. The bridge's install flow MUST surface the
  exact token-provisioning steps to the operator (link to Linear's
  API key page, `gh secret set LINEAR_API_TOKEN` example). The
  bridge MUST NOT attempt to provision the secret on the operator's
  behalf — token handling stays in the operator's hands.
- **FR-030**: The webhook (Layer E) and the reconciliation sync
  (Layer D) MUST be independently idempotent. Linear state MUST
  converge to the same value whether reached by webhook only,
  reconciliation only, or both layers in sequence. If the webhook
  is not installed in a repo (operator declined or the repo
  pre-dates the bridge), the reconciliation sync MUST still detect
  Merged state on demand via `gh` (with git-only branch-reachability
  fallback when `gh` is unavailable).
- **FR-031**: The bridge MUST auto-register all relevant `after_*`
  hooks (`after_specify`, `after_clarify`, `after_plan`,
  `after_tasks`, `after_implement`, `after_analyze`) into the
  consumer repo's `.specify/extensions.yml` at
  `specify extension add linear` time, with `optional: false` so
  every lifecycle command triggers reconciliation automatically.
  The bridge MUST also ship on-demand commands
  (`speckit.linear.push`, `speckit.linear.pull`,
  `speckit.linear.status`) for manual control, recovery from
  missed hooks, and ad-hoc state inspection without invoking a
  lifecycle command. The operator MAY disable any registered hook
  by editing `.specify/extensions.yml` directly; the bridge MUST
  honour `enabled: false` and not re-enable on subsequent
  reinstalls without explicit operator action.
- **FR-032**: All Linear workflow state references in the bridge
  (the GitHub Action's GraphQL lookup, the reconciliation sync's
  state transitions, the seed step's verification queries) MUST
  use Linear workflow state UUIDs as the lookup key, NOT state
  names. The seed step MUST create the required workflow states,
  capture their UUIDs at creation, and write them to
  `.specify/extensions/linear/config.yml` under a
  `workflow_state_uuids` map (keys: the lifecycle-phase
  identifiers `specifying`, `clarifying`, `planning`, `tasking`,
  `red_team`, `implementing`, `analyzing`, `ready_to_merge`,
  `merged`). Consumers of these states (Action workflow file,
  bridge sync code) MUST read the UUIDs from this map at runtime.
  Renames of the workflow states in the Linear UI MUST NOT break
  the bridge; only deletion of a referenced state MUST surface as
  an explicit error.

#### Local git triggers

- **FR-033**: The bridge MUST install local git hooks
  (`post-checkout`, `post-commit`, `post-merge`) into the consumer
  repo's `.git/hooks/` at `specify extension add linear` time.
  These hooks MUST invoke the same reconcile operation that
  spec-kit's `after_*` hooks invoke, so that operator actions
  outside spec-kit commands — switching branches or worktrees,
  committing work that ticks off a task, merging locally — also
  keep Linear in sync without polling, daemons, or scheduled jobs.
  Installation MUST be idempotent (re-installation does not
  duplicate hook entries) and MUST coexist with any pre-existing
  hooks the consumer repo already has (chain rather than overwrite,
  or surface a clear collision report and let the operator decide).
  Because `.git/hooks/` is not versioned, the install step is
  per-clone and re-runs as part of the dependency-verification
  contract in FR-018b.

- **FR-033b**: The bridge MUST honour the `SPECKIT_LINEAR_DOGFOOD_SAFE`
  environment variable as an explicit "dogfood-safe" install override.
  When the variable is set to `1` (or `true` / `yes` / `on`), the
  install ceremony MUST proceed even when the target Linear workspace
  already carries spec issues for this project — the canonical
  collision shape produced by the bridge dogfooding into its own
  repo, by reinstalling against a workspace that was seeded against
  the same Project UUID by an earlier checkout, or by an operator
  rerunning install after a prior aborted attempt. The install MUST
  detect the variable at startup, surface a "dogfood-safe mode
  active" warning row in the FR-018b dependency report, and add a
  corresponding entry to the final FR-023 summary block so the
  operator can confirm at a glance that the safety override is
  engaged. Absent the variable, behaviour is unchanged — the
  install treats colliding spec issues with the same caution as any
  other unexpected workspace state. Mirrors the existing
  `${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}` condition marker that
  guards the bridge's own auto-fire hooks (T048) so a single env
  var governs both install-time and hook-fire-time safety.

### Key Entities

- **Consumer repo**: A git repository that has the bridge installed
  via `specify extension add` and is bound to one Linear workspace.
  Mirrors to one Linear **Project** per repo.
- **Spec**: The unit of work on the filesystem
  (`specs/NNN-feature/`). Identified by its feature number (`NNN`).
  Mirrors to one Linear **Issue** inside the repo's Project.
- **Task Phase**: A grouping of tasks (Phase 1, Phase 2, …) declared
  in `tasks.md` or `plan.md` via canonical spec-kit
  `## Phase N: <Name>` headers. Mirrors to one Linear **sub-issue**
  under the spec Issue. Carries its own workflow state.
- **Task**: An entry in `tasks.md`. Identified by its task code
  (e.g. `T003-013`) and optionally a Fibonacci `[N]` story-point
  estimate marker (per FR-035) carried in the leading bracketed
  prefix run (e.g. `T003 [3]` or `T003 [P] [US1] [3]`). Mirrors to
  one **checklist item** in its task-phase sub-issue's description —
  not a Linear Issue. Estimates roll up: per-phase sum → sub-issue
  `estimate`; spec-level sum → spec Issue `estimate`.
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
  re-running reconcile changes exactly one line in exactly one
  task-phase sub-issue's checklist in Linear, with no churn on any
  other Issue, sub-issue, comment, or label.
- **SC-007**: A reconcile run that encounters a malformed task entry
  or inter-task-phase dependency still successfully syncs every other
  spec, task phase, and checklist in the repo and surfaces a warning
  naming the malformed item.
- **SC-008**: At any moment during normal operation, a Linear filter
  for `phase:implementing` returns a list of every spec across every
  bound consumer repo that is currently being implemented, with each
  result showing the spec's current branch and worktree directly in
  the result row's preview.
- **SC-009**: No invocation of the bridge from a worktree that is
  not on a given spec's feature branch ever changes that spec's
  Linear state. (Verifiable by deliberately invoking sync from
  `main` while another worktree holds the feature branch and
  observing zero diff on the Linear side.)
- **SC-010**: A spec's PR being merged on GitHub results in the
  spec Issue moving to "Merged" workflow state in Linear within
  one minute of the merge event, without the operator running
  any sync command, when the webhook layer is installed and
  configured.
- **SC-011**: A repo that has never had the webhook installed (or
  has Actions disabled) still converges to the correct Merged
  state on the next reconciliation sync, demonstrating that Layer
  D alone is sufficient for correctness even when Layer E is
  absent.

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
- Consumer repos are hosted on GitHub and the operator has
  permission to add workflow files and repository secrets to each
  consumer repo. The webhook layer (per FR-027..FR-030) requires
  this; without it, the bridge degrades gracefully to the
  reconciliation layer only.
- The Linear API token provisioned as a GitHub repository secret
  may be the operator's personal API key or a dedicated machine-user
  account's token. The bridge documents both paths in the install
  guidance but does not enforce one over the other. Operators
  responsible for security-sensitive repos are expected to use a
  dedicated machine-user account.
