# Contract: Recency Comparison

**Feature**: `003-drift-aware-authority` | **Phase**: 1 | **Companions**: [plan.md](../plan.md) · [research.md](../research.md) · [data-model.md](../data-model.md)

Defines the recency drift input (FR-052b, FR-053) and the multi-worktree ranking (FR-058/FR-059): how the spec-directory git-commit timestamp is obtained, how it is compared against Linear's `updatedAt`, the clock-skew tolerance, and the empty-history fallback. This is the secondary drift signal; lifecycle-phase ordering (see [drift-detection-graphql.md](./drift-detection-graphql.md) §3 and data-model §2) is primary.

## 1. The recency key — `git_helpers::spec_dir_last_commit`

**Signature**: `git_helpers::spec_dir_last_commit <spec_dir>` → echoes ISO-8601 committer date, or empty.

**Implementation contract**:

```bash
git log -1 --format=%cI -- "<spec_dir>"
```

| Property | Value | Why |
|---|---|---|
| date selected | committer date (`%cI`) | reflects when the commit landed in THIS worktree's history; clone/checkout-stable (FR-053, research §1) |
| format | ISO-8601 strict (`%cI`, e.g. `2026-05-20T14:02:11+00:00`) | unambiguous; parseable to epoch cross-platform |
| scope | `-- <spec_dir>` pathspec | only commits touching the spec dir count |
| empty output | no commit touches the spec dir | Edge Case 1 — recency signal `unavailable` |

**MUST NOT**: use `stat`/mtime (FR-053). The existing `git_helpers::last_touched` (mtime-based, `src/git_helpers.sh:328`) is RETAINED for the FR-004 memory-block human display only and MUST NOT be the recency comparator.

## 2. Epoch conversion (cross-platform)

The ISO string is converted to a Unix epoch for arithmetic comparison, reusing the dual GNU/BSD pattern already in `git_helpers::last_touched`:

```bash
# GNU coreutils
date -d "<iso>" +%s
# BSD/macOS fallback
date -j -f "%Y-%m-%dT%H:%M:%S%z" "<iso>" +%s
```

Both paths MUST be attempted (GNU first, BSD fallback), matching the repo's existing cross-platform date handling. Conversion failure → treat recency as `unavailable` (do not fabricate a comparison).

## 3. The comparison

Given `disk_epoch` (spec-dir last commit) and `linear_epoch` (Linear `updatedAt`):

```text
recency_drift = (linear_epoch - disk_epoch) > SKEW_TOLERANCE_SECONDS
```

| Constant | Value | Source |
|---|---|---|
| `SKEW_TOLERANCE_SECONDS` | `120` | plan A1 ("a few minutes"; absorbs laptop↔Linear clock skew without masking real edits) |

**Rules**:

- `recency_drift = false` when `disk_epoch` is `unavailable` (Edge Case 1) — fall back to phase-ordering alone.
- Forward case: `disk_epoch >= linear_epoch` (or within tolerance) → `recency_drift = false` (SC-017 — no false positive on the normal write path).
- The comparison uses the **Issue-level** `updatedAt`, not per-field timestamps (research §1 alternatives).
- A prior reconcile's own write does not re-fire recency on the next no-op run because idempotency means `updatedAt` does not advance (Edge Case 3 / FR-063).

## 4. Multi-worktree ranking — `git_helpers::worktrees_touching_spec`

**Signature**: `git_helpers::worktrees_touching_spec <feature_number>` → echoes, one per line, `<commit_epoch>\t<worktree_path>\t<branch>` for every worktree whose checkout contains `specs/<NNN>-*/`.

**Implementation contract**:

- Enumerate worktrees via `git worktree list --porcelain` (already used by `git_helpers::list_worktrees`, `src/git_helpers.sh:83`).
- For each worktree that has the spec dir present, compute `spec_dir_last_commit` (§1) within that worktree's checkout.
- The `canonical_worktree` is the line with the maximum `commit_epoch` (FR-059 — ranking by spec-dir commit time, NEVER branch name or mtime).

**Rules**:

- Single-worktree repos: one line, the invoking worktree is canonical (no extra output in the warning, drift-warning-surface §2).
- The canonical pointer is surfaced in BOTH the drift WARNING row (FR-058) and the spec Issue memory block (FR-058 extends FR-004).
- Ties (identical commit epochs across worktrees) resolve to the invoking worktree as canonical, with both listed in the touching set.

## 5. Worked examples

| disk commit | linear updatedAt | phase disk | phase linear | recency_drift | phase_drift | fired |
|---|---|---|---|---|---|---|
| 2026-05-26T09:31:00Z | 2026-05-26T09:31:30Z (+30s) | implementing | implementing | false (within 120s) | false | **false** (forward/equal) |
| 2026-05-20T14:02:11Z | 2026-05-26T09:31:40Z (+6d) | planning | implementing | true | true | **true** (both) |
| 2026-05-26T10:00:00Z | 2026-05-26T09:31:40Z (disk newer) | implementing | planning | false | false (disk ahead) | **false** (forward) |
| *(unavailable — no commit)* | 2026-05-26T09:31:40Z | planning | implementing | false (unavailable) | true | **true** (phase only) |
| 2026-05-26T09:00:00Z | 2026-05-26T09:30:00Z (+30m) | merged | implementing | false (disk phase ahead → not a recency concern; but linear behind) | false (disk ahead) | **false** (US1 merged-from-main: Linear behind) |
