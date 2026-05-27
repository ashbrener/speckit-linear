<!--
SYNC IMPACT REPORT
==================
Version change: (uninitialised template) → 1.0.0
Rationale: Initial ratification — first concrete constitution for the
speckit-linear project, derived from BRIEF.md, spec 001, and the
linear-mcp-capability-check validation.

Principles defined (initial ratification, no prior names to rename):
  I.    Filesystem Is The Single Source of Truth
  II.   Reconcile, Never Event-Push
  III.  Layered Idempotency (D + E)
  IV.   Write-Authority Follows The Worktree
  V.    UUID-Based Binding, Per-Repo Config
  VI.   OAuth-First, Keys-At-The-Edges
  VII.  Memory-Just-Works, Escape Hatches Beside It
  VIII. Surface, Don't Enforce — Observable Failure

Added sections:
  - Core Principles (8 principles)
  - Architectural Constraints (data-model + layer boundaries)
  - Operational Workflow (install / seed / sync / recovery)
  - Governance (amendment + versioning + compliance)

Removed sections: none (template was empty)

Templates requiring updates:
  ✅ .specify/templates/plan-template.md — Constitution Check is a
     placeholder; will be wired to these principles when /speckit-plan
     first runs against a feature. No edit needed now.
  ✅ .specify/templates/spec-template.md — mandatory sections align; no
     change required.
  ✅ .specify/templates/tasks-template.md — already uses canonical
     `## Phase N: <Name>` terminology (Principle VIII); no change.
  ✅ .specify/templates/checklist-template.md — generic; nothing to sync.
  ✅ .claude/skills/speckit-constitution/SKILL.md — upstream skill file,
     do not modify.

Follow-up TODOs: none deferred.
-->

# speckit-linear Constitution

The non-negotiable principles that govern how the spec-kit ↔ Linear
bridge is built, installed, and operated. Every functional requirement
in `specs/001-spec-kit-linear-bridge/spec.md` traces to one of these
principles; every future spec MUST be checked against them before
`/speckit-plan` lands.

## Core Principles

### I. Filesystem Is The Single Source of Truth

The filesystem under each consumer repo's `specs/NNN-feature/` is
canonical. Linear is a unidirectional, read-only mirror. The bridge
MUST NOT write back to the filesystem in response to any Linear change.
Operator-side mutations in Linear (checklist ticks, edited labels,
spec-influencing comments) are not a control surface; the next
reconcile overwrites them.

**Rationale**: Two-way sync between a git-versioned markdown corpus
and a hosted issue tracker is a conflict-resolution tar-pit. Pinning
one direction lets the bridge stay small, predictable, recoverable,
and survivable across Linear outages or workspace migrations.

**Rules**:
- Reconcile MUST be the only write path into Linear.
- Linear → filesystem flow is OUT OF SCOPE indefinitely.
- Task-phase checklists in Linear MUST carry a header noting they are
  read-only mirrors of `tasks.md`.

### II. Reconcile, Never Event-Push

Every invocation — hook-fired or manual — reads full filesystem state
and pushes whatever Linear needs to match. The bridge MUST NOT track
per-event diffs, MUST NOT maintain a filesystem-side cache of "what
Linear last saw", and MUST be safe to re-run any number of times
against unchanged state with zero observable churn.

**Rationale**: Event-diff systems break on missed events, replays,
out-of-order delivery, and partial failures. A reconciler converges
from any starting state — the only architecture that survives
operator interrupts and forgotten manual edits without a corruption
story.

**Rules**:
- Hook-triggered, manual, and CI-triggered sync MUST share one code
  path and produce identical outcomes (spec FR-011).
- Stable identity for every mirrored entity MUST derive from
  filesystem-evident keys (feature number, task code, branch name,
  seeded workflow-state UUID) — never from a local sidecar file.
- Unchanged-state reconcile MUST be observable as zero label-modified
  timestamps, zero comment posts, zero relation rewrites (spec SC-002,
  SC-006).

### III. Layered Idempotency (D + E)

The bridge ships two cooperating layers, each independently idempotent
and each individually sufficient for correctness:

- **Layer D — Reconciliation.** Synchronous, filesystem-driven, runs
  in the operator's session. Owns labels, comments, sub-issues,
  description blocks, Project Status, and merged-state detection (via
  `gh` with git-only fallback).
- **Layer E — Webhook.** A GitHub Action installed per consumer repo.
  Owns real-time workflow-state flips on PR open / ready / merge.
  Mutates the spec Issue's workflow state ONLY.

Layer boundaries are absolute. Layer E MUST NOT touch labels,
comments, sub-issues, or description blocks. Cross-layer writes to the
same Linear attribute are a defect, not an optimisation.

**Rationale**: Webhooks deliver low-latency UX but break when Actions
are disabled or secrets rotate. Reconcilers guarantee correctness but
are only as fresh as their last run. Both, with strict write-domain
separation, give us responsive UX without sacrificing recoverability.

**Rules**:
- Either layer alone MUST keep Linear converging (spec SC-011).
- A repo lacking Layer E (Actions disabled, install declined) MUST
  still satisfy every SC except SC-010 via Layer D alone.
- Layer E silent-failure modes (rotated token, deleted secret) are
  acceptable PROVIDED Layer D reconciles on its next run. The bridge
  MUST NOT report webhook health out-of-band.

### IV. Write-Authority Follows The Worktree

For any given spec, the ONLY worktree authorised to mutate that
spec's Linear state is the one currently checked out on its feature
branch (`<NNN>-...`). Any reconcile invoked from another worktree
(on `main`, an unrelated branch, detached HEAD) is **read-only with
respect to that spec**: it MAY display Linear's current state but
MUST NOT write.

**Rationale**: Operators routinely run multiple worktrees against
the same repo. A naive sync from a stale worktree would regress
Linear's state for a spec being progressed elsewhere. Tying write
authority to the feature branch makes worktree topology safe by
construction.

**Rules**:
- Reconcile MUST detect the active branch and gate spec-level
  mutations on the `<NNN>-...` match (spec FR-025).
- Non-authoritative invocations MUST still surface the spec's
  current Linear state (spec FR-026).
- Layer E is exempt: PR head ref already implies authority.

### V. UUID-Based Binding, Per-Repo Config

Every Linear identifier the bridge depends on — Project, Team,
workflow states — is stored as a UUID in the consumer repo at
`.specify/extensions/linear/config.yml` (committed). Runtime lookups
MUST use UUIDs, never names. Cloning the repo is sufficient to drive
sync; no per-operator global state is required.

**Rationale**: Linear UI names are operator-editable. Name-based
lookups make the bridge fragile to harmless cosmetic edits. UUIDs are
immutable for the resource's lifetime; the only failure mode is hard
deletion, which the bridge surfaces as an explicit error rather than
silent drift.

**Rules**:
- Project UUID, Team UUID, and the `workflow_state_uuids` map all
  live in the committed per-repo config (spec FR-002, FR-032).
- The seed step MUST capture every workflow-state UUID at creation
  time and write it to config; no post-seed name-fallback is allowed
  (spec FR-021, FR-032).
- The GitHub Action workflow file MUST read UUIDs from config at
  runtime (spec FR-028).
- Per-operator global config (`~/.config/`, env-var-only bindings)
  is forbidden; rebinding a repo means committing a config change.

### VI. OAuth-First, Keys-At-The-Edges

Normal interactive sync (operator-driven `/speckit-*` and on-demand
`speckit.linear.*` commands) MUST authenticate to Linear via OAuth
through the official Linear MCP. Long-lived API keys are permitted
ONLY where OAuth is unavailable: the seed-step GraphQL fallback
(`workflowStateCreate`, `issueRelationCreate`) and the GitHub Action
running without an operator present.

**Rationale**: API keys on operator workstations are a perpetual
rotation and exfiltration headache. OAuth via the official MCP shifts
auth lifecycle to Linear's infrastructure. Keys remain unavoidable at
two edges (unattended CI, capability gaps); we contain them there.

**Rules**:
- Interactive paths MUST use the official Linear MCP
  (`https://mcp.linear.app`) and MUST NOT prompt for an API key.
- The community fallback (`dvcrn/mcp-server-linear`) is NOT the
  default and MUST NOT be reintroduced — validation determined it
  offers strictly less than the official MCP.
- Seed-step GraphQL operations MAY use an API key from a gitignored
  `.env` (spec FR-020); the key MUST NOT be committed or globalised.
- The GitHub Action MUST read its token from `LINEAR_API_TOKEN`
  (repo secret); the bridge MUST NOT provision that secret
  programmatically (spec FR-029).

### VII. Memory-Just-Works, Escape Hatches Beside It

At `specify extension add linear` time the bridge MUST auto-register
every relevant `after_*` hook (`after_specify`, `after_clarify`,
`after_plan`, `after_tasks`, `after_implement`, `after_analyze`) with
`optional: false`. Default UX: run a spec-kit command, Linear
updates. On-demand commands (`speckit.linear.push`, `.pull`,
`.status`) ship as **escape hatches** for recovery, ad-hoc inspection,
and incident response — NOT as the primary path.

**Rationale**: A bridge whose primary UI is "remember to run sync" is
a bridge that drifts and gets abandoned. Auto-firing on every
lifecycle transition is what earns the bridge its toolchain slot.

**Rules**:
- Hook auto-registration MUST be `optional: false` at install (spec
  FR-031). Operators MAY disable individual hooks by editing
  `.specify/extensions.yml`; the bridge MUST honour `enabled: false`
  and MUST NOT silently re-enable on reinstall.
- On-demand commands MUST be functionally equivalent to the
  hook-fired path (Principle II / spec FR-011).
- Documentation MUST present the auto-sync flow first; on-demand
  commands appear in a recovery section, never in the quickstart.

### VIII. Surface, Don't Enforce — Observable Failure

The bridge warns the operator about gaps (missing `spec.md`,
malformed tasks, deleted Linear resources, unauthenticated MCP,
absent `gh`) but never "fixes" the operator's workflow or filesystem
unilaterally. Every reconcile MUST emit a structured summary (counts
created/updated, named warnings). Every Action run MUST log its
decisions. The bridge MUST NOT appear to succeed when it has silently
skipped work.

This principle also fixes terminology: the bridge uses canonical
spec-kit vocabulary. Task groupings are `## Phase N: <Name>` (per the
tasks template), never "wave / W0 / W1". When spec-kit terms collide
(lifecycle "phase" vs task-grouping "phase"), the bridge disambiguates
by context ("lifecycle phase" / "task phase") and never invents new
words.

**Rationale**: Operators install this bridge into their working
toolchain; silent mutation, auto-PR creation, or hidden failures
would make the bridge an adversary rather than a mirror. Loud,
structured failure is the contract that lets the operator trust the
bridge enough to leave its hooks `optional: false`.

**Rules**:
- Reconcile MUST process every spec it can and only halt for
  workspace-level configuration errors (spec FR-022, FR-024).
- Install MUST verify every dependency it touches (MCP wiring, OAuth
  status, `gh`, runtime) and surface exact copy-paste remediation for
  missing pieces (spec FR-018b). Silent best-effort install is
  forbidden.
- Vocabulary in code, comments, command names, Linear labels, and
  docs MUST match canonical spec-kit terms (`task-phase:N` labels,
  `Phase N — <Name>` sub-issue titles).
- Auto-creation/un-drafting of PRs and any other write to the
  operator's git/GitHub state are OUT OF SCOPE (spec FR-017) and MUST
  NOT be added without amending this principle.

## Architectural Constraints

The data-model mapping locked in spec 001 — consumer repo → Linear
Project; spec → Linear Issue; task phase → sub-issue; tasks →
checklist items; non-task artifacts → spec-Issue comments; lifecycle
state → spec-Issue workflow state + `phase:*` label — is
constitutional. Amending it is a MAJOR version bump.

Layer responsibility boundaries (Principle III) are constitutional.
Layer E mutates ONLY the spec Issue's workflow state; Layer D owns
everything else.

The bridge MUST NOT introduce a hosted backend, an operator-side
daemon, or a database. State lives in three places only: the consumer
repo's filesystem, Linear itself, and the GitHub Action's
per-invocation environment.

## Operational Workflow

**Install** (per consumer repo): `specify extension add linear` →
resolve Project + Team UUIDs (prompt or `--project` / `--team` /
`--auto-create`) → write `.specify/extensions/linear/config.yml` →
register `after_*` hooks with `optional: false` → offer the GitHub
Action and guide `LINEAR_API_TOKEN` provisioning → verify every
touched dependency (Principle VIII) and report status.

**Seed** (one-shot per Linear workspace): create required `phase:*`
labels, `task-phase:*` labels, and tracker-Issue workflow states →
capture each state's UUID → write `workflow_state_uuids` into the
per-repo config. Safe to re-run.

**Sync**: auto on every `after_*` hook; available on-demand via
`speckit.linear.push`. Idempotent. Read-only for any spec whose
feature branch is not the active worktree branch (Principle IV).

**Recovery**: on-demand commands (`speckit.linear.push`,
`speckit.linear.pull`, `speckit.linear.status`) are the documented
path for missed hooks, non-authoritative-worktree inspection, and
post-incident audit.

## Governance

This constitution supersedes all other practices and informal
conventions in the `speckit-linear` project. Where this constitution
and any other document (BRIEF.md, validation notes, README) conflict,
this constitution wins.

**Compliance**: every PR touching the bridge MUST be reviewed for
compliance. `/speckit-plan`'s Constitution Check gate is the formal
enforcement point — plans that violate a principle MUST be revised or
trigger an amendment before implementation begins.

**Amendments**: any amendment MUST (a) update this file, (b)
propagate to dependent templates per the Sync Impact Report header,
(c) bump the version per semver below, (d) be committed in a PR whose
description names the principle(s) added, removed, or redefined.

**Versioning**:
- **MAJOR**: backward-incompatible changes — removing a principle,
  redefining the data-model mapping, eliminating a layer.
- **MINOR**: adding a principle, materially expanding guidance,
  adding a new constitutional constraint.
- **PATCH**: clarifications, wording, typo fixes.

**Operator may revise** (judgement calls flagged for future
reconsideration): none for v1.0.0. Every principle here derives from
either an explicit spec-001 clarification or the validation outputs.

**Version**: 1.0.0 | **Ratified**: 2026-05-27 | **Last Amended**: 2026-05-27
