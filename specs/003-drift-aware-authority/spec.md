# Feature Specification: Drift-Aware Write Authority

**Feature Branch**: `003-drift-aware-authority`

**Created**: 2026-05-28

**Status**: Draft

**Input**: User description: "Redefine FR-025's write-authority model from
enforce-on-branch to warn-on-drift. Real-world dogfood (a downstream consumer repo,
11 specs) proved the hard branch-gate is too strict for merged specs,
retroactive adoption, and teams iterating on main. The filesystem is the
authority (Principle I); branch name is a heuristic for 'who has the latest',
not a substitute for it."

## Overview

Spec 001 locked write authority to the worktree on a spec's canonical
`NNN-feature` branch (FR-025, Constitution Principle IV). Every other
worktree's reconcile is read-only for that spec. The intent was sound:
prevent a stale worktree on `main` from regressing a spec that another
worktree is actively progressing on its feature branch.

Real-world dogfood against a downstream consumer repo (11 specs, mostly merged)
proved the hard branch-gate is **too strict** in the common case:

- **Merged specs.** Once a feature PR merges, the canonical
  `NNN-feature` branch is typically deleted. `main` now holds the latest
  state of that spec, but FR-025 has no authoritative worktree to grant
  write to — the operator is locked out of writing the post-merge view
  (Merged workflow state, cleared phase label) for every merged spec.
- **Retroactive adoption.** An operator installing the bridge into an
  existing repo whose specs are mostly already merged hits the gate on
  the very first reconcile: no worktree sits on any feature branch, so
  nothing converges. This is precisely why v0.1.1 shipped the
  `--retroactive` bypass flag (PR #3) as a stopgap.
- **Teams iterating on main.** Squash-merge and trunk-based workflows
  keep developing on `main`. FR-025 forbids the bridge from writing at
  all under that workflow — the bridge becomes useless to those teams.

The deeper truth, already constitutional, is **Principle I: the
filesystem is the single source of truth**. Whichever worktree holds the
most recent commit touching `specs/NNN-feature/` IS the latest view of
that spec. The branch name is a useful *heuristic* for "who has the
latest", but it is not a substitute for the filesystem evidence itself.
When the heuristic and the evidence disagree (merged spec on `main`,
retroactive adoption, trunk-based development), the bridge should trust
the evidence and let the operator decide — not refuse to write.

This feature replaces FR-025's hard branch-gate with a **drift-aware
model**:

1. **Write from anywhere is the default.** Any worktree may WRITE to a
   spec's Linear Issue. The branch name no longer gates the write.
2. **Warn on backward-drift.** When the writing worktree's spec content
   appears OLDER than Linear's current state, the bridge surfaces a
   structured warning naming the drift — but it MUST NOT block. This is
   Principle VIII (Surface, Don't Enforce) applied correctly: the
   earlier FR-025 enforcement was a Principle VIII violation hiding
   inside Principle IV.
3. **The operator decides.** A warning surfaces the drift; the operator
   proceeds (overwriting Linear with disk state) or aborts.
   Non-interactive runs get a flag to pre-select the behavior.
4. **Multi-worktree conflict signal.** When the same spec is checked out
   in multiple worktrees, the bridge surfaces which worktrees touch it
   and which holds the most recent commit, so the operator can tell at a
   glance which worktree is canonical right now.

The `--retroactive` flag (FR-014, PR #3) becomes redundant: writing from
any branch is now the default, so the first reconcile after a retroactive
install "just works" with zero extra flags. The flag is retained as a
deprecated no-op alias for one minor release to avoid breaking documented
v0.1.1 commands.

> **Constitution note**: This is a redefinition of **Principle IV
> (Write-Authority Follows The Worktree)** and therefore requires a
> CONSTITUTION AMENDMENT, tracked as a separate PR per the constitution's
> Governance section. See [Constitution Impact](#constitution-impact)
> below. This spec flags the amendment and sketches the new principle
> wording; it does NOT author the amendment.

## Clarifications

### Session 2026-05-28

- Q: What exactly defines "backward-drift" — local spec-dir mtime vs
  Linear `updatedAt`, the git log of the spec dir, Linear's lifecycle
  phase being further along than disk's inferred phase, or a combination?
  → A: A **combination, lifecycle-phase-first**. The primary, most
  reliable signal is **lifecycle-phase ordering**: if Linear's recorded
  lifecycle phase for the spec is strictly *further along* than the phase
  the bridge infers from disk (e.g. Linear says `Merged` or
  `Implementing`, disk infers `Planning`), that is backward-drift. The
  secondary signal is **recency**: the most recent commit touching
  `specs/NNN-feature/` (via `git log -1 -- specs/NNN-feature/`, the
  filesystem-evident key, NOT raw file mtime which is unreliable across
  clones/checkouts) is compared against Linear's `updatedAt` on the spec
  Issue. If the spec-dir's last commit predates Linear's `updatedAt` by
  more than a small clock-skew tolerance, that is a recency drift signal.
  Either signal alone raises a warning; both raising reinforces it. Raw
  file mtime is explicitly rejected as a primary signal because it does
  not survive `git clone`, `git checkout`, or worktree creation. Forward
  movement (disk ahead of Linear) is the normal write case and never
  warns.

- Q: Is the interactive default warn-and-proceed, or interactive-confirm
  (prompt before overwriting)? → A: **Interactive-confirm on detected
  backward-drift; warn-and-proceed otherwise.** When no backward-drift is
  detected, the bridge writes silently (normal forward case, no prompt).
  When backward-drift IS detected in an interactive session, the bridge
  prints the structured drift warning and prompts the operator to proceed
  (overwrite Linear from disk) or abort that spec. This keeps the common
  forward case friction-free while making the genuinely risky case
  (writing a stale view over a more-advanced Linear state) a deliberate
  operator choice. Non-interactive runs never prompt; they obey a flag
  (next clarification).

- Q: In non-interactive mode (hooks, CI, `--yes`), what is the default
  on detected backward-drift, and is `--retroactive` deprecated or kept?
  → A: **Non-interactive default is proceed-and-warn** (write the disk
  state, emit the warning to the summary block as a named WARNING row so
  it is auditable). A `--on-drift=abort|proceed` flag lets the operator
  flip the non-interactive default to skip drifted specs instead. This
  preserves "memory just works" (Principle VII) — hooks keep converging
  Linear without an operator present — while still surfacing the drift
  loudly (Principle VIII). `--retroactive` is **deprecated, retained as a
  no-op alias** for one minor release: because write-from-any-branch is
  now the default, the flag's behavior is the default, so it neither
  errors nor changes anything; it emits a one-line deprecation INFO row
  pointing at the new default. It is removed in a later release.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Write the post-merge view of a merged spec from main (Priority: P1)

An operator has a spec whose feature PR has merged; the `NNN-feature`
branch is deleted and every worktree is on `main`. The operator runs
reconcile from `main`. The bridge writes the spec's post-merge view
(Merged workflow state, cleared `phase:*` label, updated memory block)
to Linear — no special flag required — because `main` now holds the
latest filesystem state for that spec and nothing in Linear is further
along.

**Why this priority**: This is the single most common dogfood failure
(merged specs dominate a downstream consumer repo). Without it the bridge cannot
record the terminal state of any merged spec, which is the bulk of a
mature repo. It is the minimum viable slice of the redesign.

**Independent Test**: In a repo with one merged spec (feature branch
deleted, on `main`), run reconcile with zero extra flags and observe the
spec Issue move to Merged with its phase label cleared, and zero
backward-drift warning (Linear was behind, not ahead).

**Acceptance Scenarios**:

1. **Given** a spec whose PR merged and whose `NNN-feature` branch is
   deleted, with the operator on `main`, **When** reconcile runs with no
   flags, **Then** the bridge WRITES the spec's Merged workflow state and
   cleared phase label to Linear and reports the write in the summary.
2. **Given** the same merged spec where Linear already shows Merged,
   **When** reconcile runs again from `main`, **Then** the reconcile is
   idempotent — zero label-modified timestamps, zero comment posts, zero
   relation rewrites (Principle II / SC-002).
3. **Given** a spec on `main` whose disk state is strictly ahead of
   Linear (disk Implementing, Linear Planning), **When** reconcile runs,
   **Then** the bridge writes the advance with no drift warning, because
   forward movement is the normal write case.

---

### User Story 2 - Retroactive first-reconcile just works without a flag (Priority: P2)

An operator installs the bridge into an existing repo whose specs are a
mix of merged and in-flight, with no worktree on any feature branch. The
operator runs the first reconcile with no flags. Every enumerated spec
converges to its current filesystem-derived state. The operator never
learns the `--retroactive` flag exists; if they paste a documented
v0.1.1 command that still contains `--retroactive`, it runs unchanged and
prints a one-line deprecation notice.

**Why this priority**: Retroactive adoption is the install experience for
every repo that predates the bridge. Requiring a special flag on the
first run is a documented stopgap (PR #3), not a design. Folding it into
the default removes the stopgap and makes onboarding frictionless. It is
P2 because P1's write-from-anywhere mechanism is the prerequisite that
makes this "just work".

**Independent Test**: In a fresh repo with several existing specs (none
on a feature-branch worktree), run the first reconcile with zero flags
and confirm every spec converges to its current state, with backward-drift
warnings only where Linear was genuinely ahead (it is not, on a fresh
install — Linear starts empty).

**Acceptance Scenarios**:

1. **Given** a freshly installed bridge in a repo with existing specs and
   no feature-branch worktree, **When** the first reconcile runs with no
   flags, **Then** every spec is created/updated in Linear to match disk,
   with no spec skipped for write-authority reasons.
2. **Given** a documented v0.1.1 command that passes `--retroactive`,
   **When** it runs under this release, **Then** the run behaves
   identically to running without the flag and emits a single INFO row
   noting `--retroactive` is deprecated and now the default.
3. **Given** a retroactive install where one spec's Linear Issue already
   exists and is further along than disk (rare: pre-existing manual
   Issue), **When** the first reconcile runs non-interactively, **Then**
   the default proceeds and writes disk state, recording a WARNING row
   for that spec.

---

### User Story 3 - Multi-worktree backward-drift warning (Priority: P3)

An operator has two worktrees for the same repo: one on `main` (older
view of spec `NNN`), one on `NNN-feature` (which has progressed the spec
to Implementing). The operator runs reconcile from the `main` worktree.
The bridge detects that Linear's lifecycle phase for `NNN` is further
along than `main`'s disk view (backward-drift), prints a structured
warning naming both worktrees and which holds the most recent commit
touching `specs/NNN/`, and — interactively — prompts to proceed or abort.
The operator aborts to avoid regressing the spec.

**Why this priority**: This is the exact regression FR-025 was written to
prevent. The redesign must preserve the *protection* (the operator is
warned and can avoid the regression) while removing the *enforcement*
(the bridge no longer unilaterally refuses). It is P3 because it is the
less-common case (concurrent worktrees on one spec) and depends on the
drift-detection machinery from P1.

**Independent Test**: With two worktrees (one `main`, one feature branch
ahead), run reconcile from `main` and confirm a structured backward-drift
warning naming the worktrees and the most-recent-commit holder appears,
and that an interactive abort leaves Linear unchanged while an interactive
proceed overwrites Linear from `main`'s disk view.

**Acceptance Scenarios**:

1. **Given** two worktrees on one repo (one `main` behind, one feature
   branch ahead) and Linear reflecting the feature branch's advanced
   phase, **When** reconcile runs interactively from `main`, **Then** the
   bridge prints a backward-drift warning listing both worktree paths and
   which holds the most recent commit touching the spec dir, and prompts
   to proceed or abort.
2. **Given** that prompt, **When** the operator aborts, **Then** Linear's
   state for that spec is unchanged (zero diff) and the summary records
   the spec as skipped-by-operator.
3. **Given** that prompt, **When** the operator proceeds, **Then** the
   bridge overwrites Linear with `main`'s disk view and records the
   override in the summary.
4. **Given** the same situation non-interactively with
   `--on-drift=abort`, **When** reconcile runs, **Then** the drifted spec
   is skipped with a WARNING row and no prompt.

---

### Edge Cases

- **No git history for the spec dir** (`git log` empty — uncommitted
  brand-new spec). The recency signal is unavailable; the bridge falls
  back to the lifecycle-phase signal alone and treats absence of
  recency data as "no drift" rather than fabricating a warning.
- **Clock skew between local commit time and Linear `updatedAt`.** The
  recency comparison applies a small tolerance window so trivial skew
  does not raise spurious backward-drift warnings.
- **Linear `updatedAt` reflects a bridge write, not a human edit.** The
  comparison is against the spec's lifecycle phase and last *spec-dir*
  commit, not raw `updatedAt` alone, so a prior reconcile's own write
  does not register as someone-else-is-ahead drift on the next run.
- **Detached HEAD or unnamed branch.** Writing is allowed (branch name no
  longer gates); drift detection runs normally on the spec-dir commit and
  Linear phase.
- **Spec exists on disk but its lifecycle phase cannot be inferred**
  (malformed artifacts). The bridge surfaces the existing malformed-item
  warning (FR-024 / SC-007) and uses only the recency signal for drift.
- **Same feature number across consumer repos.** Drift comparison is
  scoped per owning Linear Project (consumer repo identity), never
  cross-repo, consistent with spec 001's disambiguation rule.
- **Non-interactive run where stdin is not a TTY but no `--on-drift` is
  given.** The bridge uses the proceed-and-warn default (does not hang
  waiting for a prompt).

## Requirements *(mandatory)*

### Functional Requirements

#### Drift-aware write authority (supersedes FR-025 enforcement)

- **FR-051**: Reconcile MUST allow any worktree to WRITE to a spec's
  Linear Issue and sub-issues, regardless of the worktree's current git
  branch. The branch name is no longer a write gate. This SUPERSEDES
  FR-025's enforcement clause (the read-only-for-non-authoritative-
  worktree rule). The filesystem state of the invoking worktree is the
  authority for the write (Constitution Principle I).
- **FR-052**: Reconcile MUST compute a **backward-drift signal** per spec
  before writing, from two inputs: (a) **lifecycle-phase ordering** —
  whether Linear's recorded lifecycle phase for the spec is strictly
  further along than the phase the bridge infers from the invoking
  worktree's disk state (the PRIMARY signal); and (b) **recency** —
  whether the most recent commit touching `specs/NNN-feature/` (via
  `git log -1 -- specs/NNN-feature/`) predates Linear's `updatedAt` on the
  spec Issue by more than a clock-skew tolerance. Recency is a
  CORROBORATING signal only: backward-drift is signalled when (a) holds,
  and (b) may reinforce it but MUST NOT raise drift on its own.
  Rationale: the bridge owns the Issue body, so its own writes (and any
  third-party text edit) advance `updatedAt` without advancing the phase;
  treating recency as a standalone trigger would make every no-op re-run
  report spurious drift and violate idempotency (SC-017).
- **FR-053**: Reconcile MUST NOT use raw filesystem mtime as the recency
  signal. Recency MUST derive from the git commit timestamp of the spec
  directory (a filesystem-evident key per Principle II), because mtime
  does not survive clone, checkout, or worktree creation.
- **FR-054**: When backward-drift is detected, reconcile MUST emit a
  structured warning that names: the spec, the inferred disk lifecycle
  phase, Linear's recorded lifecycle phase, and which drift signal(s)
  fired (phase-ordering, recency, or both). The warning MUST appear in
  the reconcile summary block as a named WARNING row (Principle VIII).
- **FR-055**: When backward-drift is detected in an **interactive**
  session, reconcile MUST prompt the operator to proceed (overwrite
  Linear from disk) or abort (skip that spec, leaving Linear unchanged),
  per spec. It MUST NOT block or refuse the write unilaterally. Forward
  movement (disk ahead of Linear) and no-drift writes MUST NOT prompt.
- **FR-056**: In a **non-interactive** session (hook-fired, CI, or
  stdin-not-a-TTY), reconcile MUST NOT prompt. The default on detected
  backward-drift is **proceed-and-warn**: write the disk state and record
  the drift as a WARNING row. A `--on-drift=abort|proceed` flag MUST let
  the operator override this default; `abort` skips drifted specs with a
  WARNING row instead of writing them.
- **FR-057**: When a spec is skipped due to operator abort (interactive)
  or `--on-drift=abort` (non-interactive), reconcile MUST leave that
  spec's Linear state unchanged (zero label-modified timestamps, zero
  comment posts, zero relation rewrites) and record it as
  skipped-by-operator in the summary.

#### Multi-worktree conflict signal (extends FR-026, FR-004)

- **FR-058**: When the same spec is checked out in more than one
  worktree, reconcile MUST surface, in the backward-drift warning and in
  the spec Issue's memory block, the set of worktree paths that touch the
  spec and WHICH worktree holds the most recent commit touching
  `specs/NNN-feature/`. This makes "which worktree is canonical right
  now" answerable at a glance. This EXTENDS FR-004 (memory block already
  lists worktree paths) and FR-026 (surfacing current state) — it adds
  the most-recent-commit pointer.
- **FR-059**: The most-recent-commit determination across worktrees MUST
  use the spec-directory git log (FR-053's signal), not branch name or
  mtime, so the canonical-right-now pointer is consistent with the
  drift signal.

#### Read-only inspection preserved (amends FR-026)

- **FR-060**: Reconcile and the on-demand `speckit.linear.status` command
  MUST continue to surface a spec's current Linear state (lifecycle
  phase, current task phase / task, branch and worktree pointers from the
  memory block) from any worktree without requiring a write. FR-026's
  *surfacing* obligation is RETAINED; only its coupling to a now-removed
  write gate is dropped.

#### `--retroactive` deprecation (amends FR-014)

- **FR-061**: The `--retroactive` flag (introduced by FR-014 / PR #3) is
  DEPRECATED. Because write-from-any-branch is now the default, the flag
  MUST become a no-op alias: it neither errors nor changes behavior, and
  it emits exactly one INFO row noting the flag is deprecated and that
  writing from any branch is now the default. The flag MUST be retained
  for at least one minor release before removal so documented v0.1.1
  commands continue to run.
- **FR-062**: FR-014's *convergence contract* MUST be preserved
  independently of the flag: a first reconcile after installing the
  bridge into a repo with existing specs MUST converge every enumerated
  spec to its current state without intermediate phase artifacts (no
  spurious comments, no transitional status flips), exactly as FR-014
  specified — now as the default behavior rather than a flag-gated one.

#### Behavioral invariants retained from spec 001

- **FR-063**: All writes triggered by this feature MUST remain
  idempotent: re-running reconcile against unchanged state produces zero
  observable churn (Principle II / FR-011 / SC-002), including the
  drift-detection path (a no-drift second run writes nothing new).
- **FR-064**: This feature MUST NOT introduce any Linear → filesystem
  write, any PR mutation, or any new hosted/daemon/database state. It
  operates entirely within the existing Layer D reconcile path and the
  three permitted state locations (consumer filesystem, Linear, Action
  environment), per the constitution's Architectural Constraints.

### Key Entities *(include if feature involves data)*

- **Backward-drift signal**: A per-spec boolean derived from two inputs —
  lifecycle-phase ordering (Linear phase vs disk-inferred phase) and
  recency (spec-dir last-commit timestamp vs Linear `updatedAt`, with
  clock-skew tolerance). Carries which input(s) fired, for the warning.
- **Disk-inferred lifecycle phase**: The lifecycle phase the bridge
  derives from the invoking worktree's filesystem artifacts for a spec
  (the existing phase-inference logic from spec 001).
- **Linear-recorded lifecycle phase**: The lifecycle phase currently
  stored on the spec Issue (workflow state + `phase:*` label).
- **Spec-dir recency**: The commit timestamp of `git log -1 --
  specs/NNN-feature/` for a given worktree — the filesystem-evident
  recency key, replacing mtime.
- **Worktree-recency comparison**: Across all worktrees that have the
  spec checked out, the ranking by spec-dir last-commit timestamp,
  yielding the "canonical right now" worktree pointer for the memory
  block and warning.
- **Drift disposition**: The outcome for a drifted spec — `proceed`
  (overwrite Linear from disk) or `abort` (skip, leave Linear
  unchanged) — chosen interactively by prompt or non-interactively by
  `--on-drift`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-014**: An operator can reconcile a merged spec from `main` (feature
  branch deleted) with **zero extra flags**, and the spec Issue reaches
  Merged with its `phase:*` label cleared. (Directly fixes the dominant
  downstream dogfood failure.)
- **SC-015**: A retroactive first-reconcile into a repo with existing
  specs converges **100% of enumerated specs** to their current state
  with zero `--retroactive` (or any other) flag, with no spec skipped for
  write-authority reasons.
- **SC-016**: In **100% of cases where Linear is genuinely ahead** of the
  invoking worktree (lifecycle-phase further along OR Linear `updatedAt`
  newer than the spec-dir last commit beyond tolerance), reconcile emits
  a backward-drift warning naming the spec and the firing signal(s).
- **SC-017**: In **0% of forward-movement or no-drift cases** does
  reconcile emit a backward-drift warning or prompt (no false positives
  on the normal write path).
- **SC-018**: An interactive operator who aborts at a backward-drift
  prompt observes **zero diff** on Linear for that spec (no label
  timestamps changed, no comments posted, no relations rewritten).
- **SC-019**: A non-interactive (hook/CI) reconcile against a drifted
  spec **never hangs** awaiting input and obeys the `--on-drift`
  default/override deterministically.
- **SC-020**: When a spec is checked out in multiple worktrees, the
  backward-drift warning and the spec Issue memory block both name every
  touching worktree path and identify the single worktree holding the
  most recent spec-dir commit.
- **SC-021**: A documented v0.1.1 command passing `--retroactive` runs
  successfully under this release with identical results to omitting the
  flag, emitting exactly one deprecation INFO row.
- **SC-022**: Re-running reconcile against unchanged state after this
  feature lands still produces zero observable churn (idempotency holds
  through the drift-detection path).

## Constitution Impact

This feature **redefines Constitution Principle IV (Write-Authority
Follows The Worktree)** and therefore **requires a Constitution
Amendment**, authored and reviewed as a **separate PR** per the
constitution's Governance section ("any amendment MUST (a) update this
file, (b) propagate to dependent templates, (c) bump the version per
semver, (d) be committed in a PR whose description names the principle(s)
redefined"). This spec does NOT author the amendment; it flags the need
and sketches the new wording.

**Principle affected**: IV — *Write-Authority Follows The Worktree*.

**Version impact**: Likely **MAJOR** (1.0.0 → 2.0.0). The current
Principle IV makes the branch-gate enforcement constitutional ("Reconcile
MUST detect the active branch and gate spec-level mutations on the
`<NNN>-...` match"). Removing that gate is a backward-incompatible change
to a stated principle rule. The amendment PR author should confirm MAJOR
vs MINOR; the redefinition (not mere expansion) of an existing principle
points to MAJOR.

**Proposed new wording sketch** (for the amendment PR to refine — NOT
authored here):

> ### IV. Write-Authority Follows The Filesystem (drift-aware)
>
> For any given spec, the authority for what Linear should reflect is the
> **filesystem state of the invoking worktree** (Principle I). Any
> worktree MAY write a spec's Linear state. The bridge MUST detect
> **backward-drift** — Linear's recorded lifecycle phase being further
> along than the invoking worktree's disk-inferred phase, OR Linear's
> `updatedAt` being newer than the spec directory's last commit beyond a
> clock-skew tolerance — and MUST surface it as a structured warning
> (Principle VIII). The bridge MUST NOT block the write: interactively it
> prompts proceed/abort; non-interactively it proceeds-and-warns unless
> overridden. The "most recent commit touching the spec directory"
> identifies the canonical-right-now worktree; branch name is a heuristic,
> not a gate.
>
> **Rules**:
>
> - Branch name MUST NOT gate spec-level writes (supersedes the prior
>   `<NNN>-...` enforcement rule).
> - Backward-drift MUST be surfaced as a named warning on every reconcile
>   where Linear is ahead.
> - Recency MUST derive from spec-directory git-commit time, never mtime.
> - Layer E remains exempt: PR head ref already implies authority.

**Dependent updates the amendment PR must consider**: the Sync Impact
Report header in `constitution.md`; the `## Operational Workflow` →
*Sync* paragraph (which currently states "Read-only for any spec whose
feature branch is not the active worktree branch"); and any plan-template
Constitution Check references to FR-025.

## Assumptions

- The existing phase-inference logic (spec 001) is reusable as the
  disk-inferred lifecycle phase input for the drift signal; this feature
  does not redefine how a phase is inferred from disk.
- `git` is available in every worktree where reconcile runs (already a
  spec 001 dependency for branch/worktree detection and `gh` fallback).
- Linear's spec Issue exposes a reliable `updatedAt` timestamp via the
  official Linear MCP / GraphQL for the recency comparison.
- A small, fixed clock-skew tolerance (on the order of a few minutes) is
  acceptable for the recency comparison; the exact value is a planning
  detail, not a spec decision.
- "Interactive" means stdin is a TTY and the bridge is operator-driven;
  hook-fired and CI runs are non-interactive by definition.
- Deprecating `--retroactive` to a no-op alias for one minor release is
  an acceptable migration window for documented v0.1.1 commands.

## Dependencies

- **Spec 001** (`001-spec-kit-linear-bridge`): provides the reconcile
  path (Layer D), phase inference, memory block (FR-004), worktree
  enumeration, summary block, and the FR-025/FR-026/FR-014 behaviors this
  feature supersedes/amends.
- **Constitution amendment** to Principle IV: a hard dependency for
  shipping — the implementation of this spec MUST NOT land before (or
  must land together with) the amendment PR, since `/speckit-plan`'s
  Constitution Check gate will otherwise flag the FR-025 removal as a
  violation.
- **PR #3** (`--retroactive`, v0.1.1): the flag this feature deprecates;
  FR-061 assumes the flag exists to alias.
- **Official Linear MCP**: for reading spec Issue `updatedAt` and
  lifecycle phase during drift detection (Principle VI).

## Out of Scope

- Authoring the Constitution amendment itself (separate PR).
- Linear → filesystem writes of any kind (Principle I; remains out of
  scope indefinitely).
- Two-way conflict *resolution* (auto-merging Linear and disk state). The
  bridge surfaces drift and lets the operator decide; it never merges.
- Automatic deletion or recreation of feature branches.
- Changing how lifecycle phase is inferred from disk (reused as-is).
- Any change to Layer E (webhook) write authority — PR head ref already
  implies authority and is untouched.
- Removing the `--retroactive` flag entirely (a later release; this spec
  only deprecates it to a no-op alias).
- A configurable per-repo drift policy beyond the `--on-drift` flag
  (e.g. persisted policy in config) — deferred unless a later need
  emerges.
