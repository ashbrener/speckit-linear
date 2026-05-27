# Contributing to speckit-linear

This project is itself a spec-kit feature: every change to the bridge flows through the same `/speckit-*` lifecycle the bridge is built to mirror. So "contributing" here is not "open a PR" — it's drive a spec through specify → clarify → plan → tasks → implement → analyze, and ship the PR at the end of that loop.

## Before you start

- Read [the constitution](./.specify/memory/constitution.md). All 8 principles are non-negotiable and the `/speckit-plan` Constitution Check gate enforces them.
- Read [the spec for the current feature](./specs/001-spec-kit-linear-bridge/spec.md) for the locked data-model mapping, the FR numbering scheme, and the design vocabulary (`spec Issue`, `task phase`, `Layer D / Layer E`, `read-only mirror`, etc.). Use these terms verbatim — Principle VIII forbids inventing new ones.
- Skim [`BRIEF.md`](./BRIEF.md) for the original kickoff context and the decisions that were already made before spec 001 was written.
- Install the toolchain:
  - **spec-kit** (`uv tool install specify-cli`, or per the spec-kit docs) — pinned to ≥ v0.8.13.
  - **bash 4+**, **curl**, **jq**, **gh** (authenticated), **git** — these are the only runtimes the bridge is allowed to depend on (Principle VI / "no daemon, no DB" architectural constraint).

## How to propose a change

Two paths, depending on the size of the change.

### Small fixes (typo, doc tweak, single-FR amendment)

- Open a PR against `main` with the change.
- In the PR body, reference the FR number(s) you're touching (e.g. "amends FR-004b"). If you're touching the constitution, name the principle.
- A maintainer reviews. If the change has any behavioural ripple, the maintainer may ask you to re-run the affected lifecycle step (typically `/speckit-clarify` or `/speckit-analyze`) before merging.

### New feature (or any change that adds/removes an FR or alters a data-model mapping)

Drive the full spec-kit lifecycle. Each command creates or extends artifacts under `specs/NNN-feature/`:

1. **`/speckit-specify "<one-paragraph feature description>"`** — creates `specs/NNN-feature/spec.md` on a new feature branch `NNN-name` (branch numbering is sequential per [`.specify/init-options.json`](./.specify/init-options.json)).
2. **`/speckit-clarify`** — interactively resolves ambiguities. Answers land as `## Clarifications → ### Session YYYY-MM-DD` bullets in the spec. Re-run as needed; each accepted clarification is immediately part of the spec (canonical spec-kit semantics, see FR-015).
3. **`/speckit-plan`** — produces `plan.md`, `research.md`, `data-model.md`, `contracts/`, `quickstart.md`. The **Constitution Check gate runs here** — a plan that violates a principle either gets revised or triggers a constitution amendment (separate PR; see Governance below) before you proceed.
4. **`/speckit-tasks`** — produces `tasks.md` with a dependency-ordered, phased task list (`## Phase N: <Name>` headers, canonical task codes `T<feature-number>-<seq>`).
5. **`/speckit-implement`** — drives implementation Phase by Phase. Implementation must obey the locked technical decisions: bash 4+, `set -euo pipefail`, standard layout (`src/*.sh`, `templates/`, `tests/`).
6. **`/speckit-analyze`** — cross-artifact consistency check. The PR is not ready until this is clean.
7. **Open a draft PR early** (right after `/speckit-specify` is a fine moment), keep it updated as the lifecycle advances, and mark it ready when `/speckit-analyze` is clean.

## Hooks that fire (and you'll see)

Per [`.specify/extensions.yml`](./.specify/extensions.yml), the following hooks are wired into this repo today. Once the bridge it produces is installed locally, `speckit.linear.push` will join the `after_*` set (per FR-031). Both `before_*` and `after_*` git hooks are visible — expect to see commit prompts.

| Hook event | Extension fired | Optional? |
|---|---|---|
| `before_constitution` | `speckit.git.initialize` | required |
| `before_specify` | `speckit.git.feature` (creates branch) | required |
| `before_clarify` / `before_plan` / `before_tasks` / `before_implement` / `before_checklist` / `before_analyze` / `before_taskstoissues` | `speckit.git.commit` | optional |
| `after_constitution` / `after_specify` / `after_clarify` / `after_plan` / `after_tasks` / `after_implement` / `after_checklist` / `after_analyze` / `after_taskstoissues` | `speckit.git.commit` | optional |
| `after_specify` / `after_clarify` / `after_plan` / `after_tasks` / `after_implement` / `after_analyze` *(once the bridge is dogfooded — spec 002 onwards per the bootstrapping note in `README.md`)* | `speckit.linear.push` | required (`optional: false` per FR-031) |

`auto_execute_hooks: true` is set, so hooks run without per-invocation prompts.

## Code style

- **Bash**: target Bash 4+. Every script starts with `set -euo pipefail`. Quote everything. Prefer POSIX patterns when they're short and obvious; use Bash 4 features (associative arrays, `mapfile`, `[[ ]]`) when they meaningfully simplify the code.
- **shellcheck**: must pass with zero warnings. CI runs it on every PR; run locally before pushing.
- **bats-core**: unit tests for every `src/*.sh` function. Integration tests gated on `RUN_INTEGRATION_TESTS=1` so a default `bats` run never hits the real Linear API.
- **YAML / Markdown**: match the formatting of existing files. CI runs YAML lint and markdown lint.
- **No new runtimes**: bash + curl + jq + gh + git only. Adding a runtime (Python, Node, Go, a daemon, a database) requires a constitution amendment — see Principle VI and the Architectural Constraints section.
- **Vocabulary**: use canonical spec-kit terms (`task phase`, `Phase N — <Name>`, `task-phase:N`, never `wave / W0 / W1`). Disambiguate by context when "phase" is overloaded (lifecycle vs task).

## Constitution gates

Constitution v1.0.0 ratifies 8 principles:

1. Filesystem Is The Single Source of Truth
2. Reconcile, Never Event-Push
3. Layered Idempotency (D + E)
4. Write-Authority Follows The Worktree
5. UUID-Based Binding, Per-Repo Config
6. OAuth-First, Keys-At-The-Edges
7. Memory-Just-Works, Escape Hatches Beside It
8. Surface, Don't Enforce — Observable Failure

`/speckit-plan`'s Constitution Check gate runs every plan against these. Do not attempt to merge a plan that violates a principle — either revise the plan, or amend the constitution first. **Constitution amendments are their own PR** (per the Governance section of the constitution): update the file, propagate to dependent templates per the Sync Impact Report header, bump the semver, and name the principle(s) you're touching in the PR description.

## Commit messages

Match existing style:

- `chore(spec-NNN): <summary>` — spec, clarify, plan, tasks, analyze work
- `feat(<scope>): <summary>` — implementation changes
- `fix(<scope>): <summary>` — bug fixes
- `docs: <summary>` — docs-only changes
- `chore(constitution): <summary>` — constitution amendments (call out the version bump)

No AI co-author trailers. No "Generated with …" footers in commit messages.

## Reporting issues

- If the issue concerns a specific feature, prefix the title with `[spec-NNN]`.
- If it concerns the constitution, name the principle (`[Principle IV] …`).
- Include: clear repro steps, expected vs actual, the FR or principle in tension, and the spec-kit / bash / gh versions you're on.
- For bridge runtime issues against a real Linear workspace, include the `speckit.linear.status` output (once that command exists — TBD as spec-kit conventions stabilise).

## Maintainer review checklist

Before merging, a maintainer checks:

- [ ] Branch follows `NNN-feature` naming (spec-kit's `speckit-git-validate`).
- [ ] All artifacts referenced in the PR exist under `specs/NNN-feature/` (`spec.md`, `plan.md`, `tasks.md` as applicable).
- [ ] `/speckit-analyze` was run and is clean (or the PR explains the deferred findings).
- [ ] No constitution violation, or an accompanying constitution-amendment PR is linked.
- [ ] Code changes touch only files under `src/`, `templates/`, `tests/`, `commands/`, or `.specify/` as appropriate; no rogue new top-level directories.
- [ ] shellcheck, bats unit tests, YAML lint, and markdown lint all green.
- [ ] No new runtime dependency introduced (or a constitution amendment is attached).
- [ ] Commit messages follow the conventions above; no AI-attribution trailers.
- [ ] FR numbers referenced in the PR body actually exist in the current spec.
