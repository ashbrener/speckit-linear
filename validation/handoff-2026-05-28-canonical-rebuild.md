# Handoff: 2026-05-28 — pre-compaction state + Plan B (canonical rebuild)

Snapshot of where the spec-kit-linear project sits at the moment a long
session is being compacted. Read this top-to-bottom before resuming.

## Project identity

- **GitHub repo**: `https://github.com/ashbrener/spec-kit-linear` (renamed earlier today from `speckit-linear`)
- **Local checkout**: `/Users/ashbrener/Code/AI/speckit-linear/` (operator hasn't renamed the local dir yet — low priority; OS-level rename is `cd ~/Code/AI && mv speckit-linear spec-kit-linear`)
- **Branch in flight**: `001-spec-kit-linear-bridge`
- **PR #1**: open, currently `MERGEABLE / CLEAN` (head `1e32f29` at handoff time)
- **CI**: green on every dispatched run; workflow only fires via `workflow_dispatch` because `pull_request: synchronize` was broken until `.github/workflows/ci.yml` landed on `main` (commit `8864515`). After every push, run `gh workflow run ci.yml --ref 001-spec-kit-linear-bridge --repo ashbrener/spec-kit-linear` to fire CI manually.
- **HTTPS push pattern**: SSH key not registered on GitHub for this account; every push uses `git -c credential.helper='!gh auth git-credential' push https://github.com/ashbrener/spec-kit-linear.git 001-spec-kit-linear-bridge`. `gh` token has `gist, read:org, repo, workflow` scopes (`workflow` was added mid-session).

## Linear state (ACME workspace)

- **Workspace**: `ACME` (`urlKey=acme`)
- **Team UUID**: `11111111-1111-4111-8111-111111111111` (team key `ACM`)
- **Project**: `spec-kit-linear` UUID `22222222-2222-4222-8222-222222222222`. Manually created via `projectCreate` curl call during dogfood because install.sh's `--auto-create` was deferred at the time (now fixed in `f39bc0d`).
- **Project URL**: `https://linear.app/acme/project/spec-kit-linear-97bca3d5ede3`
- **Project Status**: `In Progress` (type `started`) — flipped by reconcile.sh's FR-002 logic
- **Spec Issue (parent)**: ACM-5 = `001-spec-kit-linear-bridge`. URL: `https://linear.app/acme/issue/ACM-5/001-spec-kit-linear-bridge`
- **Task-phase sub-issues**: ACM-6..ACM-13 (Phase 1..Phase 8). Workflow states correctly inferred from each Phase's checklist completion ratio. Labels `task-phase:N` applied.
- **Operator identity** (FR-034 captured at install): `operator@example.com`, user_id `33333333-3333-4333-8333-333333333333`. Assignee on every issueCreate.
- **Workflow states seeded** (9): Specifying / Clarifying / Planning / Tasking / Red-team / Implementing / Analyzing / Ready-to-merge / Merged.
- **Labels seeded** (workspace scope): `phase:*` × 9, `task-phase:N` × 9, plus `speckit-spec:001` auto-stamped on ACM-5.

## Recent commit history (chronological)

| SHA | Message |
|---|---|
| `38e94c8` | feat(spec-001): Phase 4 (US2) + Phase 6 (US4) + label-UUID fix |
| `80af617` | docs(readme): simplify "How sync works" diagram |
| `b5fbebe` | chore: rename `speckit-linear → spec-kit-linear` (268 occurrences across 41 files) |
| `c7d1091` | merge: bring main's infra commit into feature branch (resolved PR #1 conflict) |
| `8864515` | (on `main`) chore(main): land OSS-hygiene infrastructure from feature branch — ci.yml, .markdownlint-cli2.jsonc, LICENSE, CONTRIBUTING, CHANGELOG. Unblocked CI triggering. |
| `429ec7d` | feat(spec-001): FR-034 operator-assignee binding + dogfood pre-stage + README data-model split |
| `66994e7` | chore(t077): dogfood success — spec 001 mirrored to ACME |
| `f39bc0d` | fix(spec-001): 6 dogfood follow-ups — table memory block, diagrams section, Project Status flip, install.sh awk + projectCreate, dogfood verify |
| `1e6ef19` | feat(spec-001): Fix 7 — human-readable Overview section in spec Issue description |
| `1e32f29` | fix(reconcile): replace 4 awk -v block=multi-line with bash state machines |

## Where we stand on the spec

- **Task progress**: ~62/84 tasks marked done in `specs/001-spec-kit-linear-bridge/tasks.md`. Phases 1-4 + 6 + FR-034 implemented. Phase 5 (US3 cross-repo), Phase 7 (US5 retroactive), Phase 8 polish remain.
- **Constitution**: v1.0.0 at `.specify/memory/constitution.md`. 8 principles. No drift.
- **Spec.md**: 35+ FRs including FR-034 (operator assignee) — clarification-clean (zero NEEDS CLARIFICATION markers).
- **Plan.md + tasks.md + research.md + data-model.md + contracts/ + quickstart.md**: all written, committed, on origin.

## The Plan B work to execute next

User picked **Plan B (canonical rebuild)** for refactoring `src/reconcile.sh::compose_issue_description`. Goal:

The current implementation has THREE per-fence splices (memory, overview, diagrams) each with REPLACE-or-PREPEND/INSERT logic. The order they execute determines where new blocks land when the body is in an "unexpected" state. We hit this during dogfood: ACM-5 ended up with order `memory → overview → diagrams` instead of the canonical `overview → memory → diagrams`.

**Refactor target**: `reconcile::compose_issue_description` (in `src/reconcile.sh`, around lines 785-921 at handoff time).

**Algorithm to implement**:

1. Strip all three fenced blocks from input `$body` (each fence pair: `<!-- spec-kit-linear:<name>:begin -->` ... `<!-- spec-kit-linear:<name>:end -->`).
2. Whatever is left (call it `body_remainder`) is operator-around-fences content.
3. Reconstruct in canonical order:
   ```
   overview_fenced + "\n\n" + memory_fenced + "\n\n" + diagrams_fenced + "\n\n" + body_remainder
   ```
   Skip a fenced block if its content is empty (graceful degradation for specs with no `## Overview`, no GitHub remote, etc.).
4. Trim trailing whitespace; return.

**Replaces** ~80 lines of per-fence-bespoke splicing with ~25 lines of canonical-order rebuild. Future-proofs against adding new blocks (FR-035 estimates, etc.).

**Why B is best-practice** (the reasoning we agreed on):

- Aligns with Constitution Principle II (reconcile, never event-push). Description is fully reconstructed from filesystem state every reconcile.
- Aligns with Principle I (filesystem is single source of truth). Bridge owns the description; operator annotations belong in comments (which the bridge never overwrites).
- ONE behavior, not 2-3 paths per splice × 3 splices.
- Adding a new block = add one line to the canonical-order list; no positional plumbing.

**The one behavior trade-off**: Plan B wipes any operator-added prose around the fences on every reconcile. This is consistent with the constitution but a real behavior change from the current splice-and-preserve approach. Operator annotations should go in Linear comments, not in the description body.

**Files to touch (just one)**: `src/reconcile.sh` — only the `compose_issue_description` function. Other functions (`render_memory_block`, `render_overview_block`, `render_diagrams_block`, `_github_base_url`) stay as-is.

**Verification flow after refactor**:

1. `shellcheck --shell=bash --severity=style src/reconcile.sh` → zero output
2. `bash -n src/reconcile.sh` → syntax ok
3. Commit + push (HTTPS-via-gh pattern above)
4. `gh workflow run ci.yml --ref 001-spec-kit-linear-bridge --repo ashbrener/spec-kit-linear` to dispatch CI
5. Wait for CI green
6. Re-run `bash scripts/dogfood.sh --skip-install --skip-seed` to reconcile ACM-5 with the new canonical order
7. Verify ACM-5 description order with the GraphQL query in §"Verification command" below

## Verification command (paste verbatim after refactor)

```bash
set -a; source .env; set +a
curl -sS -H "Authorization: $LINEAR_API_KEY" \
     -H "Content-Type: application/json" \
     -X POST https://api.linear.app/graphql \
     -d '{"query":"query { issues(filter: { labels: { name: { eq: \"speckit-spec:001\" } } }) { nodes { description } } }"}' \
  | jq -r '.data.issues.nodes[0].description' \
  | grep -nE "^<!--" | head -10
```

**Expected output** (order matters):

```
1:<!-- spec-kit-linear:overview:begin -->
N:<!-- spec-kit-linear:overview:end -->
M:<!-- spec-kit-linear:memory:begin -->
K:<!-- spec-kit-linear:memory:end -->
L:<!-- spec-kit-linear:diagrams:begin -->
P:<!-- spec-kit-linear:diagrams:end -->
```

If the order is wrong, the refactor regressed something.

## Pending follow-ups after Plan B (not blocking)

| Priority | Item | Notes |
|---|---|---|
| Medium | T063-T065 install.sh seed-check + FR-033b ratification | Codify `SPECKIT_LINEAR_DOGFOOD_SAFE` env var in spec; wire seed-state detection into install.sh's report |
| Medium | FR-035 estimates (`[N]` markers in `tasks.md`) | Operator-authored Fibonacci points, parser extracts, reconcile passes `estimate` field |
| Medium | linear-status command with staleness checks (Phase 5 T051) | "Is current worktree latest or stale" — `bash src/status.sh` style |
| Low | Phase 5 (US3): linear-pull command | Cross-repo unified view command |
| Low | Phase 7 (US5): retroactive sync | Already covered by reconcile.sh's phase-inference; needs tests |
| Low | Phase 8 polish: T076 perf harness, T082 constitution re-check, T084 release tag | Final polish before v0.1.0 |
| Op | Rotate `LINEAR_API_KEY` | Was pasted into chat earlier today; .env still uses it |
| Op | Register SSH key on GitHub | Every push needs HTTPS-via-gh fallback |
| Op | Rename local dir | `cd ~/Code/AI && mv speckit-linear spec-kit-linear` from a different shell |

## Resume prompt (for after compaction)

Paste this verbatim after compacting the session — it will pick up exactly where we left off:

> Resuming spec-kit-linear work. Read `validation/handoff-2026-05-28-canonical-rebuild.md` for full context first. Then execute Plan B: refactor `src/reconcile.sh::compose_issue_description` to use canonical-rebuild semantics per §"The Plan B work to execute next" of the handoff. After the refactor: shellcheck + bash -n locally → commit + push (HTTPS-via-gh pattern) → dispatch CI → re-run `bash scripts/dogfood.sh --skip-install --skip-seed` → verify ACM-5 description order with the GraphQL command in the handoff. If ACM-5 shows `overview → memory → diagrams` in that order, Plan B is done. Surface the result and ask what to fire next from §"Pending follow-ups".
