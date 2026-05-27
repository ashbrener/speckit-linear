# Phase 0 Research: spec-kit ↔ Linear Bridge

**Branch**: `001-spec-kit-linear-bridge` | **Date**: 2026-05-28 | **Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Reference doc — one entry per decision in `plan.md`. Citations:
`FR-NNN` → `spec.md`; `Principle N` → `.specify/memory/constitution.md`;
`validation/<file>.md` → research artifacts.

---

### 1. Implementation language = Bash 4+

**Decision**: Bash 4+ for all bridge code; external binaries `curl`,
`jq`, `git`, optional `gh`. macOS bash 3.2 refused at install with a
`brew install bash` hint.

**Rationale**: The bridge does one job (read FS, POST HTTP, parse
JSON, write YAML) — bash + `curl` + `jq` is the smallest viable
runtime and is already on a typical operator workstation, satisfying
plan.md's "no Python/Node/Go runtime install" constraint. Bash 4 is
required (not 3.2) because associative arrays are load-bearing for
the `workflow_state_uuids` map (FR-032) and dedupe in `reconcile.sh`
(Principle II zero-churn / SC-002).

**Alternatives considered**:
- *Node + `@linear/sdk`* — rejected; adds a Node toolchain on every
  workstation and CI runner; the SDK gives nothing the live MCP +
  thin GraphQL (per `validation/linear-mcp-runtime-probe.md`) does
  not already cover.
- *Python + `httpx`* — rejected; same toolchain-install objection;
  also a virtualenv lifecycle the install ceremony (FR-018b) would
  have to verify.
- *Go single-binary* — rejected; requires per-arch release pipeline
  or `go install` on the operator's machine for a trivial workload.
- *POSIX-strict `/bin/sh`* — rejected; no associative arrays would
  force every UUID lookup through `grep`/`awk` chains.

---

### 2. Linear MCP path = official `https://mcp.linear.app/mcp` (OAuth)

**Decision**: AI-invoked commands use the official Linear MCP server
at `https://mcp.linear.app/mcp` via OAuth 2.1 in the operator's MCP
client. The dvcrn community MCP is explicitly forbidden as a
dependency.

**Rationale**: `validation/linear-mcp-runtime-probe.md` confirmed the
live server exposes 35 tools — unified `save_*` mutations with
idempotent `id` parameters, native `blocks`/`blockedBy` on
`save_issue` (eliminating one GraphQL gap), one-shot
`save_project.state` writes — covering nearly all bridge needs.
Satisfies FR-020 (no long-lived keys when OAuth is available) and
Principle VI. Per `validation/linear-mcp-capability-check.md` the
dvcrn fork offers strictly less: no project labels, no Feb 2026
features, no project comments.

**Alternatives considered**:
- *`dvcrn/mcp-server-linear`* — rejected; strictly less capable
  (`linear-mcp-capability-check.md` Verdict) and Principle VI Rule 2
  explicitly forbids reintroduction.
- *Static API-key auth against the official MCP* — supported per
  `linear-mcp-tool-signatures.md` §4 but rejected for interactive
  paths; defeats Principle VI. Keys remain allowed at the three
  edges (Decision 4).
- *Third-party MCP wrappers (`definable.ai`, `morphllm`)* —
  rejected; unnecessary indirection over the official server.

---

### 3. Linear GraphQL fallback = direct `curl` + `jq` (no SDK)

**Decision**: Non-MCP write paths (git hooks, GitHub Action, seed's
`workflowStateCreate`) call `https://api.linear.app/graphql` via
`curl` with `jq` for request/response shaping. No Linear SDK.

**Rationale**: After the runtime probe collapsed Capability 4 from
"GAP" into native MCP (`linear-mcp-runtime-probe.md` §Capability 4),
the GraphQL fallback surface is just `workflowStateCreate` (gap
confirmed, FR-021), the one-shot Action `issueUpdate` (per
`validation/github-action-mechanics.md`), and possibly
`projectLabelCreate` (Decision 10). Wrapping that in an SDK would
contradict Decision 1. The Action reference YAML already proves
`curl` + `jq` are sufficient.

**Alternatives considered**:
- *`@linear/sdk` via `npx`* — rejected; reintroduces Node runtime.
- *Linear Python SDK* — rejected; same reason.
- *Raw `curl` without `jq`* — rejected; hand-rolled JSON escaping in
  shell is a footgun. `jq -nc --arg` (the pattern in
  `github-action-mechanics.md`) is the safe form.

---

### 4. Auth model = OAuth-first interactive, API key at three edges

**Decision**: Interactive AI sync = OAuth via official MCP. Long-lived
API keys at exactly three edges: (1) one-shot seed step
(`workflowStateCreate` via GraphQL), (2) local git hooks (no MCP
session), (3) GitHub Action (no operator session). For (1)+(2): key in
gitignored `.env` (FR-020); for (3): `LINEAR_API_TOKEN` repo secret
(FR-029).

**Rationale**: Direct mechanical implementation of Principle VI
("OAuth-First, Keys-At-The-Edges"), which names exactly these three
edges as legitimate. `linear-mcp-tool-signatures.md` §4 confirms the
official MCP accepts both auth modes, so a uniform backend with
different credentials per surface is mechanically straightforward. The
three edges all have an unavoidable "no human in the loop" property
that makes OAuth impossible.

**Alternatives considered**:
- *API-key everywhere* — rejected; direct Principle VI violation.
- *OAuth everywhere* — rejected; impossible for the GitHub Action.
- *Per-operator `~/.config/linear/credentials`* — rejected;
  Principle V Rule 5 forbids per-operator global config.

---

### 5. Merge-detection = layered D + E

**Decision**: Layer D (reconciliation) = `src/reconcile.sh` from AI
commands, spec-kit `after_*` hooks, and git hooks; uses `gh` with
git-only branch-reachability fallback (FR-030). Layer E (webhook) =
`templates/github-action.yml` firing on `pull_request` events.
Write-domain separation absolute: Layer E flips `stateId` only; Layer
D owns labels, comments, sub-issues, descriptions, Project Status.

**Rationale**: Locked by spec.md Clarifications round 5, codified as
Principle III. Two layers give webhook-speed UX (SC-010: <1 min) while
preserving correctness when Actions are disabled or secrets rotate
(SC-011: Layer D alone sufficient). Strict separation avoids the
two-writers-same-attribute defect Principle III Rule 2 forbids. The
reference YAML in `github-action-mechanics.md` issues exactly one
`issueUpdate` mutation, mirroring "fail loud, no retry" pattern #5
from `validation/linear-github-integrations-survey.md`.

**Alternatives considered**:
- *Layer D only* — fails SC-010 (merge → Linear lag).
- *Layer E only* — fails SC-011 (no reconciliation when Actions are
  disabled or token rotated).
- *Linear's GitHub App* — rejected per
  `linear-github-integrations-survey.md` §1; it bidirectionally syncs
  labels, colliding with the bridge's `phase:*` / `speckit-spec:NNN`
  / `task-phase:N` vocabulary owned by Layer D.
- *Polling daemon* — rejected by spec.md round 9 + Principle II.

---

### 6. Webhook runtime = `ubuntu-latest` shell + curl + jq

**Decision**: Layer E runs on `ubuntu-latest` with plain `run:` shell
steps using `curl` and `jq` (preinstalled). No Docker, no
`actions/setup-node`, no Python setup, no third-party Linear action.

**Rationale**: `github-action-mechanics.md` §1 documented the full
reference YAML in this shape and confirmed runtime preinstalls. The
Action's total work — read one YAML, do three GraphQL POSTs, exit —
makes a composite/Docker action wasted complexity. Minimal runtime
also makes Principle III Rule 1's "stateId only" scope-creep
mechanically harder.

**Alternatives considered**:
- *`linear/linear-release-action`* — rejected per
  `linear-github-integrations-survey.md` §2; targets commit→Release,
  not PR-event→Issue-state.
- *Docker container action* — rejected; image-build pipeline +
  registry hosting for a 3-call GraphQL operation.
- *`actions/setup-node` + SDK script* — rejected; Node-runtime
  objection from Decision 1, plus setup cold-start on every PR event.
- *Composite action published from this repo* — deferred; inline YAML
  is easier to audit at PR-review per Principle III Rule 3.

---

### 7. Linear identifier binding = UUID-based, committed config

**Decision**: Project UUID, Team UUID, and nine workflow-state UUIDs
stored in `.specify/extensions/linear/linear-config.yml` (committed).
All runtime lookups use UUIDs, never names.
`workflow_state_uuids` keyed by canonical identifier (`specifying` …
`merged`) per FR-032.

**Rationale**: Mechanical implementation of Principle V. The runtime
probe (`linear-mcp-runtime-probe.md` §"Argument naming") confirmed the
MCP accepts both names and UUIDs, but names are operator-editable in
the UI — a cosmetic rename would silently break a name-based lookup.
UUIDs are immutable for the resource's lifetime; the only failure
mode is hard deletion, which the bridge surfaces as an explicit error
(Principle V Rationale). The reference Action YAML in
`github-action-mechanics.md` already reads `project_id` and `team_id`
as top-level scalars, fixing the committed schema.

**Alternatives considered**:
- *Name-based lookups* — Principle V Rule 4 forbids; fragile to UI
  edits.
- *Per-operator global config* — Principle V Rule 5 forbids; clone =
  sync must hold.
- *Env-var-only bindings* — same Rule 5 violation; the Action reads
  the file, not the operator's shell.

---

### 8. Spec Issue identity = workspace label `speckit-spec:NNN`

**Decision**: Each spec Issue carries a `speckit-spec:NNN` label
(NNN = feature number) stamped at creation. Subsequent lookups query
"Issues with that label in this repo's Project UUID". On a multi-match
race the bridge keeps the most-recent-activity Issue and archives the
rest. No filesystem sidecar tracks Issue UUIDs.

**Rationale**: Locked in spec.md round 2, codified as FR-004b.
Principle II Rule 2 mandates filesystem-evident keys, never a sidecar.
The feature number is filesystem-evident (`specs/NNN-feature/`);
scoping by Project UUID prevents cross-repo collisions (spec edge case
lines 290–293). `linear-mcp-runtime-probe.md` confirmed
`save_issue.labels` accepts label-name strings, and the filter
expression `labels: { name: { eq: $l } }` from
`github-action-mechanics.md` step 1 works against both MCP and direct
GraphQL.

**Alternatives considered**:
- *Filesystem sidecar (`.state.yml` mapping feature→UUID)* —
  Principle II Rule 2 violation; drifts across branches/worktrees.
- *PR-title parsing or magic-words (Linear GitHub App style)* —
  FR-017 forbids the bridge from creating/updating PRs; identity
  would scatter across surfaces.
- *Linear's auto-assigned issue ID (`OSH-123`)* — only assigned
  post-create; the bridge needs a key computable before creation to
  make `save_issue` idempotent via deterministic `id`.

---

### 9. Local sync triggers = `after_*` hooks + git hooks

**Decision**: Two trigger mechanisms, auto-installed at
`specify extension add linear`. (a) Spec-kit `after_*` hooks
(`after_specify`, `after_clarify`, `after_plan`, `after_tasks`,
`after_implement`, `after_analyze`) in `.specify/extensions.yml` with
`optional: false`. (b) Local git hooks (`post-checkout`,
`post-commit`, `post-merge`) in `.git/hooks/`. Both route to
`src/reconcile.sh`. Crons, daemons, FS watchers, scheduled jobs are
out of scope.

**Rationale**: Locked by spec.md rounds 7+9, codified as FR-031 +
FR-033 and Principle VII. `validation/extension-shape-recon.md` §2
documented the hook-firing mechanism — spec-kit core commands run
Pre/Post-Execution blocks that read `.specify/extensions.yml`, locate
`hooks.after_<name>`, and emit `EXECUTE_COMMAND` directives — so
auto-registration is the supported path, no core-skill patching
required. Git hooks cover the operator paths spec-kit hooks miss:
branch/worktree switches, ordinary commits, local merges. FR-033 makes
git-hook install part of FR-018b's verification contract for per-clone
idempotency.

**Alternatives considered**:
- *Cron / `launchd` / `systemd` timer* — rejected by spec.md round 9
  + Principle II.
- *FS watcher (`fswatch`, `inotify`)* — same rejection; introduces a
  long-running per-operator process the bridge is constitutionally
  forbidden to require.
- *Manual-only (on-demand commands as primary path)* — rejected by
  Principle VII; on-demand commands ship only as Recovery-section
  escape hatches.
- *`optional: true` hook registration* — rejected by FR-031 explicit
  text ("with `optional: false`").

---

### 10. Workspace seed = direct GraphQL workflowStateCreate × 9

**Decision**: `src/seed.sh` (via `speckit.linear.seed` command)
creates the nine workflow states (`Specifying`, `Clarifying`,
`Planning`, `Tasking`, `Red-team`, `Implementing`, `Analyzing`,
`Ready-to-merge`, `Merged`) via direct GraphQL `workflowStateCreate`
on the team in config. Captured UUIDs written to
`linear-config.yml.workflow_state_uuids`. Seed also creates parent
label groups (`phase`, `task-phase`, `speckit-spec`) and the nine
`phase:*` children; `task-phase:N` and `speckit-spec:NNN` minted
lazily at sync time. Re-running queries by name on the team and
skips on hit.

**Rationale**: `linear-mcp-runtime-probe.md` §Capability 8 confirmed
workflow-state creation is **not** in the live MCP; GraphQL is the
only path. `linear-mcp-tool-signatures.md` §2 documented the
mutation shape, including the team-scoped requirement.
`validation/linear-workspace-probe.md` confirmed the dogfood team
`OSH-INFRA` ships none of the nine required states, so create-all-
nine (rather than rename-existing) is the only viable path. Capturing
UUIDs at creation is mandatory per FR-032 + Principle V Rule 2 ("no
post-seed name-fallback is allowed").

**Alternatives considered**:
- *Manually create states in Linear UI, then "seed-discover" by
  name* — introduces a name-binding window (Principle V violation)
  and fails the SC-003 10-minute install target.
- *Reuse Linear's stock 6 states* — rejected per
  `linear-workspace-probe.md` §"Gap vs spec lifecycle"; stock states
  semantically overlap but name-mismatch the lifecycle.
- *Lazy workflow-state creation* — FR-022 requires sync to halt with
  a clear error if the workspace isn't seeded; lazy creation makes
  the seeded-or-not check undecidable.

---

### 11. Project / Team config resolution = interactive prompt + flags

**Decision**: `src/install.sh` prompts interactively at
`specify extension add linear`. Team: auto-fill silently if exactly
one team in workspace; otherwise prompt with default = team named
"INFRA" or matching workspace name. Project: default = "create new
named after repo dir", with option to attach to existing. Flags
`--project <UUID>`, `--team <UUID>`, `--auto-create` substitute in
non-interactive installs. Both UUIDs written to committed
`linear-config.yml`.

**Rationale**: Locked by spec.md rounds 1+4, codified as FR-002. The
Team auto-fill heuristic derives from `linear-workspace-probe.md`:
the dogfood workspace has exactly one team, making the no-prompt
path the common case. The probe also found zero existing Projects,
so create-on-first-sync must be the default. Non-interactive flags
satisfy Principle VIII (scripted installs without TTY). Committed
UUIDs satisfy Principle V (clone-and-sync).

**Alternatives considered**:
- *Silently guess (auto-create + use first team)* — FR-002
  explicitly forbids: "Non-interactive installs require explicit
  flags rather than silent guessing".
- *Resolve at runtime on every sync* — Principle V + FR-002
  violation.
- *Auto-attach to a Project with the same name as the repo* — kept
  as the **prompted default** (per round 1) but rejected as **silent
  default**: identical repo names across operators would
  cross-pollinate without confirmation.

---

### 12. Task-grouping terminology = canonical `## Phase N:`

**Decision**: Bridge parses `## Phase N: <Name>` headers in
`tasks.md`; tasks under each header until the next `## Phase` form
the task-phase group. Linear sub-issues titled `Phase N — <Name>`.
Filter label `task-phase:N`. BRIEF.md's "wave / W0 / W1"
terminology is explicitly dropped.

**Rationale**: Locked by spec.md round 3 and Principle VIII Rule 3
("Vocabulary in code, comments, command names, Linear labels, and
docs MUST match canonical spec-kit terms"). The spec-kit tasks
template already uses `## Phase N` (per the constitution's Sync
Impact Report). Matching upstream means the bridge's parser is
grep-compatible with what every consumer repo already produces. The
constitution flags the lifecycle-phase vs task-phase collision and
disambiguates via prefixed forms ("lifecycle phase" / "task phase");
no new words.

**Alternatives considered**:
- *Keep BRIEF.md's "wave / W0 / W1"* — Principle VIII Rule 3
  violation; forces operators to mentally translate.
- *Bridge-specific term ("stage", "tier")* — same violation;
  introducing a third vocabulary makes drift worse.
- *Mirror tasks individually as Linear sub-issues* — FR-005/006/007
  explicitly map task phases → sub-issues, tasks → checklist items,
  and the bridge MUST NOT create per-task blocking relations.

---

### 13. Testing toolchain = shellcheck + bats-core + yamllint + markdownlint-cli2

**Decision**: CI runs `shellcheck` on every `*.sh` (zero warnings),
`bats-core` for unit (`tests/unit/`) and integration tests
(`tests/integration/`, gated on `RUN_INTEGRATION_TESTS=1` against a
dedicated Linear test workspace), `yamllint` for `extension.yml` /
`config-template.yml` / Action template, `markdownlint-cli2` for
`commands/*.md` and prose docs. Fixture-based parser tests under
`tests/fixtures/specs/` cover single-phase, multi-phase, malformed,
and missing-spec.md cases.

**Rationale**: Each tool is the de-facto standard for its surface
and runs without a heavy runtime — matching Decision 1's bash-only
posture. `shellcheck` enforces correctness `reconcile.sh`'s
idempotency depends on. Integration tests must hit a real Linear API
because SC-002's zero-churn guarantee (and `save_issue.blocks`
append-only behaviour from `linear-mcp-runtime-probe.md` Capability
4) cannot be mocked faithfully. The dedicated test workspace (not
INFRA) protects production-tracking data.

**Alternatives considered**:
- *Mock the Linear API* — rejected for integration tests; the
  reconciler's idempotency depends on real Linear behaviour. Unit
  tests still mock at the `curl` layer.
- *Skip CI shellcheck* — bash without shellcheck accumulates subtle
  bugs (unquoted expansions, missing `set -e`) the reconciler can't
  tolerate.
- *Python pytest driving bash via subprocess* — reintroduces Python
  runtime for the test rig only; violates single-language posture.

---

### 14. Project layout = single-project (Option 1)

**Decision**: Single project (Option 1 from the template), not
polyrepo or multi-package monorepo. Parallel `commands/` (AI-invoked
markdown algorithms) and `src/` (bash impls) are not two projects;
they are the algorithm and implementation sides of one artifact. AI
commands shell out to `src/` so deterministic work is unit-testable
independently of any AI agent.

**Rationale**: The bridge is one logical artifact: an extension with
commands + scripts + templates. `validation/extension-shape-recon.md`
§1 documented that spec-kit-red-team ships in this exact shape, and
§3 confirmed `specify extension add` operates on the directory as a
single `shutil.copytree` unit. Splitting commands/ and src/ into
separate packages would add release-coordination overhead and
complicate the install ceremony (FR-018b verifies everything in one
go). The parallel-but-not-separate structure keeps the algorithm
side (AI-readable) versioned in lockstep with the bash side.

**Alternatives considered**:
- *Web app layout (Option 2: backend/ + frontend/)* — bridge has no
  web surface.
- *Mobile/native layout (Option 3)* — same.
- *Per-command sub-extensions (separate extension per
  `speckit.linear.*` command)* — multiplies FR-018b dependency
  verification by command count for no isolation benefit.

---

### 15. State location = filesystem + Linear + Action env only

**Decision**: State in exactly three places: (1) consumer repo
filesystem (`specs/NNN-feature/`, `linear-config.yml`, gitignored
`.env`), (2) Linear itself, (3) GitHub Action per-invocation env
(secrets + checkout-time `config.yml` read). No hosted backend, no
daemon, no database (SQLite or otherwise), no JSON sidecar, no
`~/.config/speckit-linear/`.

**Rationale**: Constitutionally locked by Architectural Constraints
("State lives in three places only"). Direct mechanical consequence
of Principle II (no event log = no state cache needed) and Principle
I (filesystem canonical = no other authoritative store). The three
places are operator-inspectable: `cat` the filesystem, open Linear,
read the Action's workflow file. A fourth state location would
create an inspection-opaque idempotency boundary.

**Alternatives considered**:
- *SQLite cache of "last Linear state seen"* — makes the reconciler
  an event-diff system (Principle II violation); drifts across
  worktrees/clones.
- *Hosted backend* — Architectural Constraints forbids; install
  ceremony (FR-018b) cannot verify it.
- *JSON sidecar (`.state.json`)* — Principle II Rule 2 forbids; the
  identity scheme (Decision 8) makes it unnecessary.
- *Per-operator `~/.config/speckit-linear/`* — Principle V Rule 5
  forbids; OAuth state belongs to the MCP client, not the bridge.

---

## Remaining unknowns

1. **MCP `save_issue.blocks`/`blockedBy` idempotency under re-runs.**
   `linear-mcp-runtime-probe.md` §Capability 4: arrays append-only,
   no per-relation `id`; server-side dedupe suspected, undocumented.
   **Recovery**: Phase 3 bats integration test calls `save_issue`
   twice with identical `blocks` array, asserts no duplicate. On
   failure, fall back to GraphQL `issueRelationCreate` with
   deterministic `id` per (sourceTask, targetTask) — Decision 3
   already accommodates.

2. **Per-mutation sub-rate-limits.** Only discoverable from response
   headers (`linear-mcp-tool-signatures.md` §2). **Recovery**:
   `src/graphql.sh` implements header-driven adaptive backoff; if
   hot-reconcile hits a sub-limit during integration testing, lower
   parallelism in `reconcile.sh`.

3. **Exact GraphQL shape for `projectLabelCreate`.** Needed only if
   the bridge provisions project labels at seed
   (`linear-mcp-runtime-probe.md` §Capability 6 noted no MCP tool).
   **Recovery**: seed currently provisions Issue labels only (per
   `linear-workspace-probe.md` rec 3); project labels out of scope
   unless a future FR demands them.

4. **MCP `save_issue.delegate: "Linear"` behaviour.**
   `linear-mcp-runtime-probe.md` Remaining unknowns: unclear if
   extra workspace install step required. **Recovery**: bridge does
   not currently use `delegate`; revisit only if a future spec adds
   Agent-assignment semantics.

5. **`yq` on self-hosted GitHub runners.** Preinstalled on hosted
   `ubuntu-latest` per `github-action-mechanics.md` §2; self-hosted
   may lack it. **Recovery**: FR-018b warns at install if consumer
   declares self-hosted runners; `templates/github-action.yml` can
   pin `mikefarah/yq-action` as fallback later.

The previously-tracked in-flight artifact
`validation/linear-mcp-runtime-probe.md` is now present and was
fully incorporated into Decisions 2, 3, 8, 10 above plus unknowns
1 and 4.

---

## Research artifact index

| Artifact | Informed decisions |
|---|---|
| `validation/linear-mcp-capability-check.md` | 2 (dvcrn rejection), 3 (GraphQL gaps inventory), 4 (OAuth-vs-key surface) |
| `validation/linear-mcp-tool-signatures.md` | 2 (tool naming, idempotency-via-`id`), 3 (fallback shapes), 4 (OAuth scopes), 7 (UUID acceptance), 10 (`workflowStateCreate` input), unknown 2 |
| `validation/linear-mcp-runtime-probe.md` | 2 (35-tool live catalogue, `save_*` unification), 3 (blocks native, gap-list shrunk), 7 (name-or-UUID), 8 (label-name filter shape), 10 (workflow-state gap confirmed), unknowns 1, 3, 4 |
| `validation/linear-github-integrations-survey.md` | 5 (Layer E mimics GitHub App minus label sync), 6 (per-repo secret pattern), 8 (branch-name as join key) |
| `validation/linear-workspace-probe.md` | 7 (config-shape sanity), 10 (which states + labels seed creates), 11 (single-team auto-fill; create-Project-on-first-sync default) |
| `validation/extension-shape-recon.md` | 9 (`after_*` firing mechanism, `optional: false` semantics), 11 (install-from-directory dev path), 14 (single-project matches `specify extension add` shape) |
| `validation/github-action-mechanics.md` | 5 (Layer E architecture), 6 (`ubuntu-latest` shell + curl + jq runtime), 7 (config.yml read shape), unknown 5 |
