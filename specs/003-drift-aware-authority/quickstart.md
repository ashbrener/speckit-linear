# Quickstart: Drift-Aware Write Authority

**Feature**: `003-drift-aware-authority` | **Phase**: 1 | **Companions**: [plan.md](./plan.md) · [spec.md](./spec.md)

Operator walkthrough of the new behavior shipped by spec 003: **write a spec's Linear state from any branch**, and understand the **backward-drift warning** when your worktree looks older than Linear. Mirrors the v0.1.0 quickstart's tone. Assumes the bridge is already installed (`speckit.linear.install`) and seeded.

## What changed (one paragraph)

Before spec 003 (v0.1.x), the bridge only let the worktree sitting on a spec's `NNN-feature` branch write that spec to Linear; every other worktree (notably `main`) was read-only and a `--retroactive` flag existed to bypass the gate. As of v0.2.0 that gate is gone. **Any worktree may write.** The filesystem is the authority (Constitution Principle I), and the branch name is just a hint about who has the latest. If your worktree's spec content looks *older* than what Linear already records, the bridge warns you — but it never refuses to write. You decide.

## 1. Write a merged spec from `main` — no flag needed

The single most common case the redesign fixes. A spec's PR merged, its `NNN-feature` branch was deleted, and you're on `main`:

```bash
# on main, feature branch long gone
speckit.linear.push --spec 005
```

Expected:

- The spec Issue moves to **Merged** and its `phase:*` label is cleared.
- **No backward-drift warning** — Linear was *behind* (still "Implementing"), not ahead. Forward movement never warns.
- The summary records the write.

Re-run it and nothing happens (idempotent — zero churn). Previously this needed `--retroactive`; now it just works.

> If the spec still shows "Implementing" after this, see the note in §6 — that is the separate merge-*detection* concern, not write authority.

## 2. First reconcile after a retroactive install — no flag needed

You installed the bridge into an existing repo whose specs are mostly already merged, and no worktree is on any feature branch:

```bash
# from anywhere — main, a chore branch, detached HEAD, whatever
speckit.linear.push --all
```

Expected:

- Every enumerated spec converges to its current filesystem-derived state.
- No spec is skipped for "write-authority" reasons.
- You never need to learn `--retroactive`.

If you paste an old v0.1.1 command that still has the flag:

```bash
speckit.linear.push --all --retroactive
```

it runs identically and prints exactly one line:

```text
INFO  --retroactive is deprecated and now the default — writing from any branch needs no flag (use --all to enumerate)
```

## 3. Backward-drift warning — Linear is ahead of your worktree

You have two worktrees: one on `main` (older view of spec 005), one on `005-foo` (which progressed 005 to Implementing). You run the push from the **`main`** worktree:

```bash
# in the main worktree, spec 005 on disk is only at Planning
speckit.linear.push --spec 005
```

The bridge detects Linear is *ahead* and prints a structured warning:

```text
WARNING  spec 005 backward-drift: disk=planning  linear=implementing  signals=phase_ordering,recency
         spec dir last commit 2026-05-20T14:02:11Z  <  linear updatedAt 2026-05-26T09:31:40Z (> 120s)
         canonical worktree: /Users/op/code/repo-feature-005 (branch 005-foo) — most recent spec-dir commit
         touching worktrees: /Users/op/code/repo (main), /Users/op/code/repo-feature-005 (005-foo)
```

Then, because this is an interactive terminal, it prompts:

```text
spec 005 — Linear appears ahead of this worktree. Overwrite Linear from disk? [p]roceed / [a]bort (default: abort):
```

- Press **Enter** or `a` → **abort**: Linear is left exactly as it was (zero diff), the summary records `skipped by operator`. You avoided regressing the spec.
- Type `p` → **proceed**: the bridge overwrites Linear with `main`'s (older) disk view, and records the override.

The warning told you which worktree is canonical right now (`005-foo`), so you know where the latest work lives.

## 4. Non-interactive runs (hooks / CI) — never hang

When a `after_*` hook or a CI job runs the push, there is no terminal to prompt. The bridge does not hang:

- **Default** is **proceed-and-warn**: it writes the disk state and records the drift as a `WARNING` row in the summary so it is auditable in the log. Hooks keep converging Linear without you present (Principle VII).
- To make CI **skip** drifted specs instead:

```bash
speckit.linear.push --all --on-drift=abort
```

Drifted specs are left unchanged with a `WARNING` row; everything else converges. `--on-drift=proceed` is the explicit form of the default.

## 5. Inspect drift without writing

The read-only status command still surfaces a spec's current Linear state from any worktree, and now also shows the drift signal and the canonical worktree pointer:

```bash
speckit.linear.status --spec 005
```

No write happens; you see disk phase, Linear phase, whether drift is detected, and which worktree holds the most recent spec-dir commit.

## 6. Note: "stuck on Implementing" after a merge

If a merged spec keeps showing **Implementing** even when you push from `main`, the cause is *merge detection*, not write authority. Spec 003 lets `main` write — but the bridge still has to *infer* the spec is Merged, which depends on detecting the merged PR for a now-deleted feature branch. That hardening is tracked as a separate `pr_state` fix (see [research.md §3](./research.md)); the v0.2.0 release ships it alongside this feature. Once detection is fixed, §1's flow records Merged correctly.

## Recap

| You want to… | Command | Drift behavior |
|---|---|---|
| Write a merged spec from `main` | `speckit.linear.push --spec NNN` | none (Linear behind) |
| Retroactive first reconcile | `speckit.linear.push --all` | none (Linear empty) |
| Push when Linear might be ahead, interactively | `speckit.linear.push --spec NNN` | warn + prompt proceed/abort |
| Push in CI, skip drifted | `speckit.linear.push --all --on-drift=abort` | warn + skip drifted |
| Just look | `speckit.linear.status --spec NNN` | warn, no write |
