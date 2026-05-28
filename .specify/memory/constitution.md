<!--
SYNC IMPACT REPORT
==================
Version change: 1.0.0 → 2.0.0
Amendment date: 2026-05-28

Rationale (why MAJOR, not MINOR): This amendment REDEFINES an existing
principle and REMOVES a constitutional rule, which is backward-incompatible
by the versioning rules below ("MAJOR: backward-incompatible changes —
removing a principle, redefining the data-model mapping, eliminating a
layer"). Principle IV's v1.0.0 rule made the branch-gate enforcement
constitutional ("Reconcile MUST detect the active branch and gate
spec-level mutations on the `<NNN>-...` match"). This amendment DELETES
that gate and replaces it with a drift-aware, surface-don't-enforce model.
Any plan, command, or template previously relying on "non-authoritative
worktrees are read-only" no longer holds — that is a breaking change to a
stated principle rule, so MAJOR (not a mere additive MINOR expansion).

Principle redefined:
  IV. "Write-Authority Follows The Worktree" (v1.0.0, branch-gate)
   →  "Write-Authority Follows The Filesystem (Drift-Aware)" (v2.0.0)
  - REMOVED: the hard branch-gate rule (FR-025 enforcement: only the
    worktree on `<NNN>-...` may write; all other worktrees read-only).
  - ADDED: any worktree MAY write; the filesystem (most-recent commit
    touching `specs/NNN-feature/`) is the authority (consistent with
    Principle I); backward-drift is SURFACED as a warning but MUST NOT
    block the write (Principle VIII).
  - WHY: real dogfood proved the branch-gate too strict for three
    legitimate workflows — merged specs (feature branch deleted; a
    merged spec stayed stuck on "Implementing" because main could not
    grant write), retroactive adoption, and squash-merge/trunk-based
    development on main. The v0.1.1 `--retroactive` stopgap is deprecated
    to a no-op once spec 003 lands.
  - Implemented by spec 003 (003-drift-aware-authority), FR-051..FR-064.

Other principles (I, II, III, V, VI, VII, VIII): unchanged.

Sections touched by this amendment:
  - Core Principles → Principle IV (full rewrite) + principles index
  - Operational Workflow → Sync paragraph (drop "read-only for any spec
    whose feature branch is not the active worktree branch")
  - Version footer (1.0.0 → 2.0.0; Last Amended 2026-05-28)

Templates / dependent docs propagated (forward-facing only):
  ✅ CONTRIBUTING.md — principle name in the principles list.
  ✅ README.md — "write-authority follows the worktree" invariant +
     the "non-authoritative worktree" WARNING troubleshooting entry.
  ✅ commands/linear-push.md — gate description → drift-warn description;
     `--retroactive` reframed as deprecated no-op alias.
  ✅ commands/linear-status.md — "authority status" → "drift status".
  ✅ commands/linear-seed.md — Principle IV scope reference reworded.
  ✅ .specify/templates/plan-template.md — Constitution Check is a generic
     placeholder with no Principle IV / FR-025 reference; no edit needed.
  ✅ .specify/templates/{spec,tasks,checklist,constitution}-template.md —
     no Principle IV / FR-025 references; nothing to sync.
  ✅ .claude/skills/speckit-constitution/SKILL.md — upstream skill file,
     do not modify.

Deliberately NOT modified (point-in-time historical records):
  ⛔ specs/001-spec-kit-linear-bridge/** — spec 001 is the historical
     record that DEFINED FR-025 (the branch-gate). It is a point-in-time
     artifact, not forward-facing guidance; spec 003 supersedes FR-025.
  ⛔ specs/002-install-ergonomics/** — historical artifact.
  ⛔ validation/constitution-recheck-*.md — point-in-time recheck records.
  ⛔ CHANGELOG.md — historical release log (records the v0.1.1 FR-025
     behavior as shipped; not rewritten).

Follow-up TODOs: spec 003's implementation PR is a HARD DEPENDENCY on this
amendment (its /speckit-plan Constitution Check gate must see Principle IV
v2.0.0, or it would flag the FR-025 removal as a violation).
-->

# spec-kit-linear Constitution

The non-negotiable principles that govern how the spec-kit ↔ Linear
bridge is built, installed, and operated. Every functional requirement
in `specs/001-spec-kit-linear-bridge/spec.md` traces to one of these
principles; every future spec MUST be checked against them before
`/speckit-plan` lands. (Principle IV was redefined in v2.0.0 — see the
Sync Impact Report above and spec 003, `003-drift-aware-authority`.)

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

### IV. Write-Authority Follows The Filesystem (Drift-Aware)

For any given spec, the authority for what Linear should reflect is
the **filesystem state of the invoking worktree** (Principle I). ANY
worktree MAY write a spec's Linear state — the branch name is a
HEURISTIC for "who has the latest", not a gate. The worktree holding
the most recent commit touching `specs/NNN-feature/` holds the
freshest state; that commit timestamp (a filesystem-evident key per
Principle II, never raw file mtime) identifies the
canonical-right-now worktree.

The bridge MUST detect **backward-drift** and SURFACE it, but MUST
NOT block the write. Backward-drift is when Linear's recorded
lifecycle phase is strictly further along than the disk-inferred
phase, OR Linear's `updatedAt` is newer than the spec directory's
last commit beyond a clock-skew tolerance. On backward-drift, an
interactive session prompts the operator to proceed (overwrite Linear
from disk) or abort; a non-interactive session proceeds-and-warns
(records a WARNING row) unless an override flag selects abort. The
operator decides — the bridge surfaces, it does not enforce
(Principle VIII).

**Rationale**: The branch-gate model (v1.0.0) tied write authority to
the `<NNN>-...` feature branch and made every other worktree
read-only. Real dogfood proved this too strict: merged specs (feature
branch deleted — a merged spec stayed stuck showing "Implementing"
because `main` could not be granted write to record the post-merge
view), retroactive adoption (no worktree on any feature branch, so
nothing converged — the v0.1.1 `--retroactive` stopgap), and
squash-merge / trunk-based teams developing on `main` all legitimately
need to write from non-feature branches. The filesystem is already
the source of truth (Principle I); the branch name is evidence about
recency, not a substitute for the evidence itself. When heuristic and
evidence disagree, trust the evidence and let the operator decide.

**Rules**:
- Branch name MUST NOT gate spec-level writes. This SUPERSEDES the
  v1.0.0 FR-025 enforcement rule (only the `<NNN>-...` worktree may
  write; all others read-only). Implemented by spec 003 FR-051.
- The backward-drift signal MUST be computed per spec from (a)
  lifecycle-phase ordering (Linear phase vs disk-inferred phase) and
  (b) recency (spec-dir last-commit time vs Linear `updatedAt`, with a
  clock-skew tolerance); either firing raises the warning (FR-052).
- Recency MUST derive from the spec-directory git-commit timestamp,
  never raw mtime, because mtime does not survive clone / checkout /
  worktree creation (FR-053).
- Backward-drift MUST be surfaced as a named WARNING row on every
  reconcile where Linear is ahead, naming the spec, the disk-inferred
  phase, Linear's phase, and which signal(s) fired (FR-054). It MUST
  NOT block: interactive prompts proceed/abort (FR-055);
  non-interactive proceeds-and-warns unless `--on-drift=abort`
  (FR-056). An operator abort leaves Linear unchanged (FR-057).
- Reconcile MUST still SURFACE a spec's current Linear state from any
  worktree without requiring a write. FR-026's surfacing obligation is
  RETAINED; only its coupling to the now-removed write gate is dropped
  (FR-060).
- Layer E is exempt: PR head ref already implies authority.
- The `--retroactive` flag (v0.1.1 stopgap, FR-014) is deprecated to a
  no-op alias once spec 003 lands — writing from any branch is now the
  default, so the flag neither errors nor changes behavior (FR-061).

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
`speckit.linear.push`. Idempotent. Writes from any worktree
(Principle IV, drift-aware); on backward-drift it surfaces a warning
and — interactively — prompts proceed/abort, but never blocks the
write outright.

**Recovery**: on-demand commands (`speckit.linear.push`,
`speckit.linear.pull`, `speckit.linear.status`) are the documented
path for missed hooks, drift inspection, and post-incident audit.

## Governance

This constitution supersedes all other practices and informal
conventions in the `spec-kit-linear` project. Where this constitution
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
reconsideration): none for v2.0.0. Every principle here derives from
either an explicit spec clarification or the validation outputs;
Principle IV's v2.0.0 redefinition derives from spec 003
(`003-drift-aware-authority`) and the downstream dogfood evidence.

**Version**: 2.0.0 | **Ratified**: 2026-05-27 | **Last Amended**: 2026-05-28
