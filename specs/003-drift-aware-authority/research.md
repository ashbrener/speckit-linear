# Phase 0 Research: Drift-Aware Write Authority

**Branch**: `003-drift-aware-authority` | **Date**: 2026-05-28 | **Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Reference doc — one entry per design decision in `plan.md`. Each decision resolves an open implementation question raised by the spec's functional requirements (FR-051..FR-064) and connects back to existing v0.1.x patterns where one applies.

Citations: `FR-NNN` / `SC-NNN` → `spec.md`; `Principle N` → `.specify/memory/constitution.md` (v2.0.0); `src/<file>.sh:NNN` → line in the v0.1.x source; `Edge Case N` → spec.md `## Edge Cases`.

---

### 1. Exact drift-detection mechanism — recency comparison and clock-skew tolerance

**Decision**: Compute the **recency** drift input as a comparison of two epochs:

- **Disk side** — `git_helpers::spec_dir_last_commit <spec_dir>` runs `git log -1 --format=%cI -- <spec_dir>` and converts the ISO-8601 committer date to a Unix epoch. Empty output (no commit touches the spec dir, Edge Case 1) → recency signal **unavailable**, not "old".
- **Linear side** — the spec Issue's `updatedAt` field (already selected on the issue-lookup queries at `src/reconcile.sh:1401` and `:1431`, which return `nodes { id updatedAt }`) converted to a Unix epoch.

Recency drift fires when `linear_updatedAt_epoch - spec_dir_commit_epoch > SKEW_TOLERANCE`, with `SKEW_TOLERANCE = 120` seconds (2 minutes, plan A1). That is: Linear was touched more than two minutes *after* the spec dir's last commit landed → Linear may be ahead. Forward movement (disk commit newer than `updatedAt`) never fires.

The recency input is **secondary**; lifecycle-phase ordering (decision §2) is the primary, most-reliable signal. Either firing raises the warning (FR-052); both firing reinforces it (the warning names which fired, FR-054).

**Rationale**:

- **Why git-commit time, never mtime (FR-053)**: `src/git_helpers.sh:328` `git_helpers::last_touched` uses `stat -c %Y` / `stat -f %m` (mtime) for the FR-004 memory-block "last changed on disk" human display. mtime does NOT survive `git clone`, `git checkout`, or `git worktree add` — a fresh clone stamps every file with the checkout time, which would make every spec look "just touched" and defeat the comparison. The commit timestamp is the filesystem-evident, clone-stable key Principle II Rule 2 mandates. `git_helpers::last_touched` is RETAINED for its memory-block role but is NOT the drift comparator; the new `git_helpers::spec_dir_last_commit` is the sole recency input.
- **Why `%cI` (committer date) over `%aI` (author date)**: committer date reflects when the commit landed in *this* worktree's history (it updates on rebase/cherry-pick/amend), which matches "who has the latest view right now" semantics. Author date can be far in the past for a rebased branch and would understate recency.
- **Why a 120s tolerance**: commit timestamps come from the local clock; Linear's `updatedAt` comes from Linear's servers. A few seconds to a couple of minutes of skew between a developer laptop and Linear's infrastructure is normal. A genuine human edit in Linear advances `updatedAt` by minutes-to-hours past the last disk commit, far beyond 120s — so the tolerance absorbs skew without masking real drift (SC-017: zero false positives on the forward path).
- **Why this avoids the self-write false positive (Edge Case 3)**: a prior reconcile's own write advances `updatedAt`, but the next no-drift reconcile writes nothing (idempotency, FR-063/SC-022), so `updatedAt` stays at the prior write's time and the spec-dir commit (which preceded that write) is within tolerance *only if* nothing else touched Linear. If a human edited Linear after the bridge's write, `updatedAt` advances again and recency correctly fires. The phase-ordering signal (§2) is the dominant guard here: a bridge self-write does not move Linear's lifecycle phase *ahead of* disk, so phase-ordering never fires on a self-write.

**Alternatives considered**:

- **Store a "last reconciled at" cursor on disk** and compare Linear `updatedAt` against it — REJECTED. This is exactly the "what Linear last saw" sidecar Principle II forbids. It also breaks across worktrees/clones (the cursor is per-checkout). The git-commit-time key needs no stored state.
- **Compare against Linear's per-field `updatedAt` (label timestamps, comment timestamps)** instead of the Issue-level `updatedAt` — REJECTED for v0.2.0. The Issue-level `updatedAt` is already fetched and is a sufficient coarse signal; per-field timestamps add GraphQL surface and complexity for marginal precision. The phase-ordering signal already gives the precise "Linear is ahead" answer; recency is the coarse backstop. Deferred unless a need emerges.
- **Use `git log` author date `%aI`** — REJECTED, see Rationale (rebase understates recency).
- **No tolerance (strict `>`)** — REJECTED; trivial clock skew would raise spurious warnings on the normal forward path, violating SC-017.

---

### 2. Lifecycle-phase comparison — how "Linear ahead of disk" is detected (the primary signal)

**Decision**: Detect phase drift by comparing **ordinals** on a fixed lifecycle-phase ladder:

```text
clarifying(0) < specifying(1) < planning(2) < tasking(3) < implementing(4) < ready_to_merge(5) < merged(6)
```

- **Disk-inferred phase** comes from the EXISTING `parser::lifecycle_phase <spec_dir> <pr_state_hint>` (`src/parser.sh:122`), unchanged — spec 003 does not redefine phase inference (spec `## Assumptions` bullet 1).
- **Linear-recorded phase** is derived from the spec Issue's workflow state + `phase:*` label already read during reconcile (the merged case carries no `phase:*` label per FR-013, mapped to ordinal 6).
- **Phase drift fires** when `ordinal(linear_phase) > ordinal(disk_phase)` strictly. Forward movement (`disk > linear`) is the normal write case and never fires (FR-055). Equal phases never fire.

When the disk phase cannot be inferred (malformed artifacts, Edge Case "phase cannot be inferred") the bridge surfaces the existing FR-024/SC-007 malformed-item warning and falls back to the recency signal alone for drift.

**Rationale**:

- Phase ordering is the **most reliable** signal because it is semantic, not temporal: "Linear says Merged, disk infers Planning" is unambiguous backward-drift regardless of any clock. The spec's Clarifications Q1 explicitly designates it the **primary, lifecycle-phase-first** signal.
- The ladder reuses spec 001's canonical phase vocabulary (Principle VIII vocabulary rule — `phase:*` labels, no "wave"). The ordinal table is the only genuinely new artifact and lives in data-model.md as a single lookup; it does not change how a phase is inferred.
- Mapping `merged` → top ordinal (6) with no `phase:*` label aligns with FR-013 (`src/reconcile.sh:1936` already special-cases merged = no phase label). This is what makes US1 correct: once disk infers Merged, Linear's stale "Implementing" (ordinal 4 < 6) is *behind*, so no backward-drift warning fires and the write proceeds cleanly (SC-014's "zero backward-drift warning, Linear was behind").

**Alternatives considered**:

- **Compare workflow-state UUIDs directly** without an ordinal ladder — REJECTED; UUIDs have no ordering, so "ahead/behind" is unanswerable without a ladder. The ladder is unavoidable.
- **Infer Linear's phase only from workflow state, ignoring the `phase:*` label** — REJECTED; the label is the finer-grained signal for the started phases (clarifying→implementing all share a single "Started"-type workflow state in many Linear setups). Reading the label keeps the comparison precise.
- **Treat `ready_to_merge` and `merged` as one terminal bucket** — REJECTED; US1/US3 distinguish them (a PR open-but-ready spec vs a merged spec), and the Action (Layer E) flips them separately. Keep them as distinct ordinals.

---

### 3. The merge-detection gap (ACM-5: merged spec stuck "Implementing") — drift-aware analysis + recommendation

**Decision**: The merge-detection gap is **adjacent to, but NOT inside, spec 003's scope.** Spec 003's FR-051 (write-from-any-branch) is *necessary but not sufficient* to fix ACM-5; the residual fix is a small, separate `git_helpers::pr_state` hardening tracked as its own FR-013 follow-up. This plan RECOMMENDS implementing that hardening as a companion change but NOT folding it into FR-051..FR-064.

**The gap, precisely** (from live dogfood, "ACM-5"): a spec whose PR merged and whose `NNN-feature` branch was deleted shows "Implementing" forever when reconciled from `main`. Root cause, traced in source:

1. `src/reconcile.sh:2479` derives `feature_branch="${feature_number}-${short_name}"` from the spec dir name.
2. `src/reconcile.sh:2512` calls `git_helpers::pr_state "$feature_branch"` to get a merged/open hint that feeds `parser::lifecycle_phase`.
3. `git_helpers::pr_state` (`src/git_helpers.sh:247`):
   - **gh path**: `gh pr view "$branch"` — for a *deleted* branch with a *merged* PR, `gh pr view <branch-name>` from `main` often returns no PR (gh resolves PRs by head branch; a deleted head can fail to resolve), so it falls through.
   - **git fallback**: requires `git rev-parse --verify refs/heads/$branch` to succeed (`src/git_helpers.sh:296`). The feature branch is **deleted**, so this check FAILS and the function returns empty (`:298`).
4. Empty `pr_state` → no `merged` hint → `parser::lifecycle_phase` infers the on-disk phase (Implementing from the presence of `tasks.md`/`plan.md`) → the spec sticks at Implementing, and under v1.0.0 the branch-gate ALSO refused the write from `main`.

**Why FR-051 alone does not fix it**: removing the branch-gate lets `main` *attempt the write*, but the value it would write is still the wrong phase (Implementing), because phase inference still can't see the merge. So FR-051 unsticks the *authority*, not the *inference*. The two are independent bugs that happened to co-occur in the dogfood.

**Why it is not a backward-drift case**: once inference is correct (disk = Merged, ordinal 6), Linear's "Implementing" (ordinal 4) is *behind*, so drift correctly does NOT fire and the write proceeds (SC-014). Drift detection is downstream of phase inference; it cannot compensate for a wrong disk phase.

**Recommended companion fix (separate FR/PR)**: harden `git_helpers::pr_state` for the deleted-branch / squash-merge case so it can answer "merged" without a live branch ref:

- Try `gh pr list --head <branch> --state merged --json mergedAt,url` (lists merged PRs by head even after branch deletion) before the single-PR `gh pr view`.
- In the git-only fallback, when `refs/heads/<branch>` is absent, probe `refs/remotes/origin/<branch>` and, failing that, search the default-branch history for the squash-merge commit subject `(#<pr-number>)` or a merge commit referencing the branch — best-effort, surfaced as indeterminate (Principle VIII) when unresolvable rather than guessed.

**Rationale for keeping it separate**: FR-013 (merge detection) is a spec-001 requirement; ACM-5 is a *defect in FR-013's implementation under deleted-branch conditions*, not a redesign of write authority. Folding `pr_state` hardening into FR-051..FR-064 would scope-creep the drift feature, conflate two test surfaces, and muddy the clean "spec 003 = the amended Principle IV" mapping the Constitution Check relies on. Tracking it as a dedicated `fix(reconcile): pr_state detects merged PRs for deleted feature branches` follow-up keeps both changes reviewable and independently testable. The dogfood evidence motivates BOTH, and the v0.2.0 release should ship both, but as two commits/PRs.

**Alternatives considered**:

- **Fold the `pr_state` fix into FR-051's user story US1** — REJECTED; US1's Independent Test asserts the *write reaches Merged*, which presumes inference already yields Merged. Making US1 also own the inference fix overloads it. Recommend instead that US1's integration test (`drift_e2e.bats`) DEPENDS ON the companion `pr_state` fix being present, and the plan flags that dependency (plan A7).
- **Add a new `--mark-merged` operator flag** — REJECTED; that is operator-driven enforcement of state, contrary to Principle I (filesystem is truth — the merge IS in the filesystem's git history, the bridge should infer it, not be told).

---

### 4. `--retroactive` deprecation path

**Decision**: Convert `--retroactive` (FR-014, PR #3) to a **no-op alias that emits exactly one INFO row** and is otherwise ignored (FR-061). Concretely in `src/reconcile.sh`:

- KEEP the `--retroactive)` arg-parse case (`src/reconcile.sh:318`) so documented v0.1.1 commands still parse without a usage error (SC-021).
- The flag no longer sets a behavior-changing `ARG_RETROACTIVE=1` gate-bypass; instead it sets a `ARG_RETROACTIVE_DEPRECATED=1` marker whose only effect is to emit one INFO row: `--retroactive is deprecated and now the default — writing from any branch needs no flag`.
- RETIRE the `_RECONCILE_RETROACTIVE_BYPASS_COUNT` accumulator (`src/reconcile.sh:206`) and the per-spec bypass-skip-warning suppression logic (`src/reconcile.sh:1639`): there is no gate left to bypass, so there is no bypass to count.
- KEEP the `--retroactive`-implies-`--all` convenience (`src/reconcile.sh:348`) ONLY if it does not surprise; recommend dropping it too, since `--all` is the documented enumeration flag and the deprecated alias should be inert. (Plan-level: drop the implies-`--all` coupling; the INFO row tells the operator to use `--all`.)

The flag is retained for **at least one minor release** (through v0.2.x) then removed (spec Out of Scope: full removal is a later release).

**Rationale**:

- FR-061 mandates a no-op alias (neither errors nor changes behavior) emitting one deprecation INFO row. Keeping the parse case but stripping the behavior satisfies this exactly.
- SC-021 requires a documented v0.1.1 `--retroactive` command to run with identical results to omitting the flag. Because write-from-any-branch is now the default (FR-051), omitting the flag already produces the retroactive behavior, so the alias is genuinely inert — identical results by construction.
- FR-062 preserves FR-014's *convergence contract* (first reconcile into an existing repo converges 100% of specs with no intermediate phase artifacts) independently of the flag — that contract is now the default behavior, validated by US2's Independent Test (SC-015).
- Retiring the bypass accumulator removes dead code and prevents a stale "N specs bypassed authority gate" INFO row from appearing when there is no gate — a Principle VIII honesty concern (don't report a thing that no longer happens).

**Alternatives considered**:

- **Hard-remove `--retroactive` now** — REJECTED; breaks documented v0.1.1 commands immediately (SC-021 violation). The one-release deprecation window is the spec's chosen migration path (spec `## Assumptions` bullet 6).
- **Keep `--retroactive` as a true bypass of the (now-removed) gate** — N/A; there is no gate to bypass after FR-051, so the flag has nothing to do but announce its own deprecation.
- **Emit the deprecation as a WARNING rather than INFO** — REJECTED; FR-061 specifies an INFO row. The flag's continued use is not an error condition, just legacy; INFO is the honest severity.
