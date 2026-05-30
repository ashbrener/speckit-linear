# Contract: Drift-Warning Surface

**Feature**: `003-drift-aware-authority` | **Phase**: 1 | **Companions**: [plan.md](../plan.md) · [data-model.md](../data-model.md) · [spec.md](../spec.md)

Defines exactly what the operator SEES when drift is detected — the named WARNING row, the interactive prompt, the non-interactive proceed-and-warn row, the skipped-by-operator row, and the `--retroactive` deprecation INFO row. This is the Principle VIII (Surface, Don't Enforce) surface for spec 003.

All rows render through the existing `src/summary.sh` emitter (FR-022) so they appear in the same structured reconcile summary block as v0.1.0's counts and warnings. No new output channel.

## 1. Severity vocabulary

| Severity | Used for | Source FR |
|---|---|---|
| `WARNING` | backward-drift detected (Linear ahead of disk) | FR-054 |
| `INFO` | `--retroactive` deprecation notice | FR-061 |
| *(skip note)* | spec skipped by operator abort / `--on-drift=abort` | FR-057 |

## 2. The backward-drift WARNING row (FR-054)

Emitted on EVERY reconcile where `BackwardDriftSignal.fired == true`, before any prompt. MUST name: the spec, the disk-inferred lifecycle phase, Linear's recorded lifecycle phase, and which signal(s) fired.

**Format** (single logical row, may wrap):

```text
WARNING  spec 005 backward-drift: disk=planning  linear=implementing  signals=phase_ordering,recency
         spec dir last commit 2026-05-20T14:02:11Z  <  linear updatedAt 2026-05-26T09:31:40Z (> 120s)
         canonical worktree: /Users/op/code/repo-feature-005 (branch 005-foo) — most recent spec-dir commit
         touching worktrees: /Users/op/code/repo (main), /Users/op/code/repo-feature-005 (005-foo)
```

**Required fields**:

- `spec <NNN>` — the feature number.
- `disk=<phase>` — disk-inferred lifecycle phase token.
- `linear=<phase>` — Linear-recorded lifecycle phase token.
- `signals=<csv>` — one or both of `phase_ordering`, `recency`.
- Recency detail line — present ONLY when `recency` fired: the spec-dir last-commit ISO time, Linear `updatedAt` ISO time, and the tolerance that was exceeded.
- Worktree lines — present when >1 worktree touches the spec (FR-058): the canonical (most-recent-commit) worktree and the full touching set, each with path + branch.

**Rules**:

- The WARNING row is emitted regardless of disposition — even on `proceed`, the operator gets the audit trail (FR-054).
- Single-worktree case: the "touching worktrees" / "canonical worktree" lines collapse to nothing (only the invoking worktree touches the spec).

## 3. Interactive prompt (FR-055)

Shown ONLY when `[[ -t 0 ]]` (TTY) AND drift fired. Printed AFTER the WARNING row.

```text
spec 005 — Linear appears ahead of this worktree. Overwrite Linear from disk? [p]roceed / [a]bort (default: abort):
```

**Rules**:

- Accepts `p` / `proceed` → `DriftDisposition = proceed`; `a` / `abort` / empty-enter → `abort` (plan A5: empty defaults to the safe abort).
- Invalid input re-prompts (does not crash, does not silently pick).
- Forward-movement and no-drift writes MUST NOT prompt (FR-055).
- The prompt reads the controlling terminal; it MUST NOT consume the spec-enumeration stdin stream.

## 4. Non-interactive disposition (FR-056)

No TTY → no prompt (SC-019: never hangs). Disposition resolves from `--on-drift`:

| `--on-drift` value | Default? | Disposition | Row emitted |
|---|---|---|---|
| *(absent)* | yes | `proceed` | WARNING (drift) — write proceeds, drift recorded |
| `proceed` | no | `proceed` | WARNING (drift) — write proceeds, drift recorded |
| `abort` | no | `abort` | WARNING (drift) + skip note |

**Rules**:

- Default (proceed-and-warn) writes the disk state AND records the WARNING row so it is auditable in CI logs (FR-056 / Principle VII keeps hooks converging).
- `--on-drift=abort` skips the drifted spec with both the WARNING row and a skip note.
- An unrecognised `--on-drift` value is a usage error at arg-parse time (plan A6).

## 5. Skipped-by-operator note (FR-057)

Emitted when disposition is `abort` (interactive or `--on-drift=abort`).

```text
SKIP     spec 005 skipped by operator (backward-drift abort) — Linear unchanged
```

**Rules**:

- The skip note guarantees the summary does not appear to succeed silently (Principle VIII).
- A skipped spec MUST show zero Linear mutation: zero label-modified timestamps, zero comment posts, zero relation rewrites (FR-057 / SC-018).

## 6. `--retroactive` deprecation INFO row (FR-061)

Emitted EXACTLY ONCE per reconcile when `--retroactive` is passed, regardless of how many specs are processed.

```text
INFO     --retroactive is deprecated and now the default — writing from any branch needs no flag (use --all to enumerate)
```

**Rules**:

- Exactly one INFO row per invocation (not per spec).
- The flag otherwise changes nothing (no-op alias) — identical results to omitting it (SC-021).
- INFO severity, not WARNING — legacy use is not an error (research §4).

## 7. Summary-block placement

| Row type | Section in summary block |
|---|---|
| drift `WARNING` | the existing "warnings" section (alongside FR-024 malformed-item warnings) |
| `SKIP` note | the existing per-spec disposition counts; increments a `skipped-by-operator` counter |
| `--retroactive` `INFO` | a top-of-summary INFO line, once |

The drift counters (`drifted`, `skipped-by-operator`, `overridden-proceed`) are additive to the existing FR-022 created/updated/warned counts; they MUST NOT replace or hide them.
