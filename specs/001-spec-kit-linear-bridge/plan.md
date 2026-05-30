# Implementation Plan: spec-kit ↔ Linear Bridge

**Branch**: `001-spec-kit-linear-bridge` | **Date**: 2026-05-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-spec-kit-linear-bridge/spec.md`

## Summary

Build the spec-kit ↔ Linear bridge as a spec-kit extension (per
`extension.yml`, installed via `specify extension add linear`) whose
implementation is a small set of POSIX-leaning **bash 4+** scripts
under `src/`, invoked three ways:

1. **AI-agent invocation** via markdown command files under
   `commands/` (one per `speckit.linear.*` command). The operator's
   coding agent (Claude Code, etc.) reads the algorithm in the
   markdown and shells out to `src/*.sh` for the deterministic work.
2. **Spec-kit `after_*` hooks** auto-registered into the consumer
   repo's `.specify/extensions.yml` at install time
   (`optional: false`).
3. **Local git hooks** (`post-checkout`, `post-commit`, `post-merge`)
   auto-installed into the consumer repo's `.git/hooks/` at install
   time, calling the same `src/reconcile.sh`.

Linear access goes through two paths matching Principle VI of the
constitution: the **official Linear MCP** (OAuth, used by AI-invoked
commands when an agent session is present) and **direct Linear
GraphQL via `curl`** (used by git hooks and the GitHub Action which
have no MCP session). The official MCP exposes **unified `save_*` tools** (`save_issue`, `save_project`, `save_comment`, `save_milestone`) per the runtime probe, with name-based arguments that the MCP server resolves to UUIDs server-side. Per Principle V the bridge still STORES UUIDs in `linear-config.yml`; the MCP-call boundary translates UUID → name (using the config's informational `*.name` fields, or a lookup query) before invoking `save_*`. Direct GraphQL paths (git hooks, GitHub Action, seed step) continue to operate on UUIDs natively. Both paths converge on the same reconciler
logic. A GitHub Action template
(`.github/workflows/spec-kit-linear-sync.yml`) ships as Layer E for
real-time PR-event sync; it talks to Linear via direct GraphQL with a
repo-secret token.

State lives in three places only (per constitution Architectural
Constraints): the consumer repo's filesystem (`specs/NNN-feature/`
plus `.specify/extensions/linear/linear-config.yml`), Linear itself,
and the GitHub Action's per-invocation environment. **No daemon, no
cron, no FS watcher, no database, no hosted backend.**

A runtime probe of the live Linear MCP (`validation/linear-mcp-runtime-probe.md`, 2026-05-28) confirmed the unified `save_*` tool surface and reduced the bridge's direct-GraphQL surface to seed-time-only operations; the amendment above reflects that finding without altering the architecture.

## Technical Context

**Language/Version**: Bash 4+ (POSIX-leaning where convenient,
Bash-4 features — associative arrays, `mapfile`, `[[ ]]`, parameter
expansion — where useful). Install step verifies bash version per
FR-018b and surfaces a remediation hint (macOS users typically
`brew install bash`).

**Primary Dependencies**:

- `bash` 4+ (required)
- `curl` (required — Linear GraphQL HTTP)
- `jq` 1.6+ (required — JSON in/out for Linear and config)
- `git` 2.30+ (required — branch / worktree / hooks)
- `gh` CLI (optional — full Layer D fidelity; falls back to git-only
  branch-reachability per FR-030 when absent)
- Official **Linear MCP** at `https://mcp.linear.app/mcp` (used by
  AI-invoked commands; OAuth-authenticated per the operator's MCP
  client)
  - Live tool surface confirmed 2026-05-28: 35 tools, unified `save_*` mutations. Detailed tool inventory in `validation/linear-mcp-runtime-probe.md`.
- `.env` `LINEAR_API_KEY` (used by direct-GraphQL paths only: git
  hooks, GitHub Action local-run, seed step; gitignored per spec
  FR-020)

**Storage**: Filesystem only. Per consumer repo:

- `.specify/extensions/linear/linear-config.yml` — the per-repo
  config (Project + Team UUIDs, `workflow_state_uuids` map, sync
  toggles). Committed.
- `.env` (gitignored) — optional, holds `LINEAR_API_KEY` for the
  direct-GraphQL paths.
- `.github/workflows/spec-kit-linear-sync.yml` — the Layer E webhook.
  Committed. Opt-in.
- `.git/hooks/post-{checkout,commit,merge}` — local git hooks.
  Per-clone (`.git/` is not versioned).
- `.specify/extensions.yml` — the consumer's spec-kit hook registry,
  updated by `speckit.linear.install`.

No SQLite, no JSON sidecar databases, no `~/.config/spec-kit-linear/`.

**Testing**:

- **shellcheck** for static analysis of every `*.sh`. Zero warnings
  required to pass CI (already wired in `.github/workflows/ci.yml`).
- **bats-core** for unit tests (`tests/unit/`) and integration tests
  (`tests/integration/`, gated on `RUN_INTEGRATION_TESTS=1`).
- **yamllint** for `extension.yml`, `config-template.yml`, and the
  Action workflow template.
- **markdownlint-cli2** for `commands/*.md` and prose docs.
- **Integration test sandbox**: a dedicated Linear test workspace
  (separate from the operator's INFRA workspace) for end-to-end
  reconcile tests against real Linear API. Set up once; reused.
- **Fixture-based parser tests**: synthetic `specs/NNN-feature/`
  trees under `tests/fixtures/specs/` exercise every spec-kit
  artifact shape (single-phase, multi-phase, malformed, missing
  spec.md, etc.).

**Target Platform**:

- Operator dev machines: macOS (Intel + Apple Silicon) and Linux.
- CI: `ubuntu-latest` runner.
- GitHub Action runtime: `ubuntu-latest` (shell + curl + jq, no
  Docker, no Node, no Python — matches recommendation from
  `validation/github-action-mechanics.md`).

**Project Type**: spec-kit extension (markdown-command-driven, bash
implementation). Single-project layout.

**Performance Goals**:

- **Reconcile a single spec** (~5 task phases, ~30 tasks total):
  < 5s hot, < 15s cold (cold = first reconcile of an existing repo
  with every Issue/sub-issue created).
- **Reconcile a full repo** (10 specs × 30 tasks): < 30s hot, < 90s
  cold.
- **Idle re-reconcile** (no filesystem changes): < 5s — bridge
  should detect "no change" via a fast in-memory diff of computed
  state vs Linear-side state and skip mutation calls (idempotent per
  Principle II).
- **GitHub Action invocation** (single PR event → single Linear
  workflow-state flip): < 10s wall-clock.
- **Local git hook** (post-checkout, post-commit, post-merge): < 2s
  added latency to the git operation. Achieved by deferring the full
  reconcile to a backgrounded `nohup`-style invocation if Linear API
  latency exceeds threshold.

**Constraints**:

- No daemons, crons, FS watchers, or background services (per
  operator decision recorded in spec.md `## Clarifications` round 1
  + Principle II/III).
- Idempotent (Principle II): zero-churn reconcile on unchanged
  state.
- GraphQL fallback scope **REDUCED** by runtime probe: `issueRelationCreate` is NOT needed (the MCP's `save_issue` accepts native `blocks`/`blockedBy`/`relatedTo`/`duplicateOf` arrays); `save_project.state` accepts a status name in one step (no separate workspace status enum lookup). Direct GraphQL is now needed only at seed time for `workflowStateCreate`, project-label creation, and project-update creation — all one-shot setup operations, never in the hot reconcile path.
- OAuth-first for interactive (Principle VI). API keys only at edges.
- UUID-based Linear binding (Principle V).
- Bash 4+, curl, jq, git only — no Python/Node/Go runtime install on
  operator dev machines.
- Single language for all bridge code (bash) to avoid context
  switching between implementations.
- macOS bash 3.2 (Apple-shipped) is NOT supported — install step
  detects and refuses with a one-liner brew remediation.

**Scale/Scope**:

- Operator dimension: 4-10 personal/OSS repos in v1 (per BRIEF).
- Spec dimension: ~50 active specs total across all repos.
- Task dimension: 5-90 tasks per spec, ~5 task phases per spec on
  average.
- Linear dimension: 1 workspace (`ACME` per the live probe), 1
  team (`ACM`), N projects (one per consumer repo), many spec Issues
  + task-phase sub-issues.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1
design.*

Walked through all 8 principles in `.specify/memory/constitution.md`
(v1.0.0). All gates pass:

### I. Filesystem Is The Single Source of Truth — **PASS**

The plan commits to a one-direction reconciler (`src/reconcile.sh`).
No Linear → filesystem write path exists in any FR or in the planned
project structure. Task-phase checklists in Linear carry a read-only
header (FR-006 commitment carried into the data model).

### II. Reconcile, Never Event-Push — **PASS**

Every invocation path (AI command, spec-kit hook, git hook, GitHub
Action) routes through one function (`src/reconcile.sh` for local /
hook paths; `templates/github-action.yml` issues a single
`issueUpdate` for Layer E — itself idempotent). No per-event diff
cache on the filesystem; no `last_sync.json`. Stable identity from
filesystem-evident keys (feature number, `speckit-spec:NNN` label,
workflow-state UUIDs).

### III. Layered Idempotency (D + E) — **PASS**

Layer D = `src/reconcile.sh` plus the AI-invoked command markdowns +
git hooks. Layer E = `templates/github-action.yml`. Strict
write-domain separation: the Action's GraphQL mutation flips ONLY
`stateId` on the spec Issue. Labels, comments, sub-issues,
description, Project Status are all Layer D's responsibility. The
Action workflow YAML hard-codes a single mutation; reviewer
verification at PR time will catch any drift.

### IV. Write-Authority Follows The Worktree — **PASS**

`src/reconcile.sh` opens with a `git_helpers::current_branch` call
and gates each per-spec mutation block on a `current_branch ==
"<NNN>-…"` check. Non-authoritative invocations enter a read-only
display mode (FR-026), surfacing Linear's current state without
calling any mutation. Unit-tested via bats fixtures simulating
worktrees on `main`, on an unrelated feature branch, and on the
authoritative branch.

### V. UUID-Based Binding, Per-Repo Config — **PASS**

`config-template.yml` locks the schema: `linear.team.id`,
`linear.project.id`,
`linear.workflow_state_uuids.{specifying,…,merged}` — all UUIDs.
`src/config.sh` validates that every UUID is present and well-formed
before any reconcile step. MCP-path operations translate UUID → name at the call boundary using the informational `*.name` fields in config (e.g. `linear.team.name`, `linear.project.name`, plus a small in-memory map from workflow-state UUID to its captured name). The translation does NOT undermine Principle V — the lookup key remains the UUID; the MCP merely accepts a name-shaped argument that the server resolves back to the same UUID. No per-operator config (`~/.config/`,
env-var-only bindings) — forbidden by Principle V Rules.

### VI. OAuth-First, Keys-At-The-Edges — **PASS**

AI-invoked command markdowns route through the official Linear MCP
(OAuth). `src/graphql.sh` (used by git hooks for direct mutation when no MCP session is available, plus the seed step's `workflowStateCreate` / project-label-create / project-update-create operations, and the Action) reads `LINEAR_API_KEY` from `.env`. Per the runtime probe, the MCP-path covers the full reconcile hot path including blocking relations and project status — direct GraphQL is reserved for the operations the MCP does not yet expose. The Action reads
`LINEAR_API_TOKEN` from a GitHub repo secret. Three edges, all
documented; no key globalisation. `dvcrn/mcp-server-linear` is
explicitly NOT a dependency.

### VII. Memory-Just-Works, Escape Hatches Beside It — **PASS**

`speckit.linear.install` writes `after_*` hook entries into the
consumer's `.specify/extensions.yml` with `optional: false`. The
five on-demand commands ship as escape hatches: documented in
CONTRIBUTING.md's "Recovery" section, not in the quickstart. The
install step honours `enabled: false` on re-install (verified in the
install ceremony script).

### VIII. Surface, Don't Enforce — Observable Failure — **PASS**

`src/reconcile.sh` ends with a `summary::emit` call that prints
counts (created / updated / archived / warned) and a list of named
warnings, in the structured format Principle VIII Rule 1 requires.
The install step (`src/install.sh`) verifies every touched
dependency (FR-018b) and refuses to complete silently. Vocabulary
audit: `task-phase:N`, `Phase N — <Name>`, no "wave" anywhere in
shipped code or labels.

**Verdict**: All 8 gates GREEN. No constitutional violations to
track in Complexity Tracking. Phase 0 research may proceed.

## Project Structure

### Documentation (this feature)

```text
specs/001-spec-kit-linear-bridge/
├── spec.md              # locked clarification-clean specification (33 FRs)
├── plan.md              # this file
├── research.md          # Phase 0 output — resolves remaining unknowns
├── data-model.md        # Phase 1 — concrete entity schemas (config.yml, Linear mappings)
├── quickstart.md        # Phase 1 — end-to-end "install + first sync" walkthrough
├── contracts/           # Phase 1 — JSON / YAML / GraphQL contracts
│   ├── linear-graphql-mutations.md   # the exact mutations the bridge issues
│   ├── config-schema.json            # JSON schema for linear-config.yml
│   ├── extension-manifest.md         # extension.yml contract per spec-kit
│   ├── command-shapes.md             # speckit.linear.* invocation + output contracts
│   └── webhook-action.md             # GitHub Action input/output contract
├── checklists/
│   └── requirements.md   # validation checklist (clean, 8 iterations logged)
└── tasks.md              # Phase 2 — generated by /speckit-tasks, NOT by /speckit-plan
```

### Source Code (repository root)

```text
extension.yml                 # spec-kit extension manifest
config-template.yml           # per-consumer-repo config schema
README.md                     # operator-facing explainer with mermaid diagrams
LICENSE                       # MIT
CHANGELOG.md                  # Keep-a-Changelog
CONTRIBUTING.md               # spec-kit lifecycle walkthrough for contributors
.gitignore                    # secret + ephemera exclusions
.env.example                  # documents LINEAR_API_KEY for fallback paths

commands/                     # AI-agent-invoked algorithmic markdown (3-dot names)
├── linear-push.md            # speckit.linear.push   — full reconcile FS → Linear
├── linear-pull.md            # speckit.linear.pull   — show Linear state
├── linear-status.md          # speckit.linear.status — sync + worktree authority info
├── linear-seed.md            # speckit.linear.seed   — one-shot workspace seed
└── linear-install.md         # speckit.linear.install — install ceremony

src/                          # bash implementation called by commands + hooks + Action
├── reconcile.sh              # the reconciler; entry point for every sync path
├── parser.sh                 # parses spec.md, tasks.md (## Phase N:), clarify sessions
├── graphql.sh                # thin Linear GraphQL client (curl wrapper, jq-piped)
├── config.sh                 # loads + validates .specify/extensions/linear/linear-config.yml
├── git_helpers.sh            # branch, worktree, PR-state detection (gh + git fallback)
├── seed.sh                   # workspace seed (workflowStateCreate × 9, label creation)
├── install.sh                # install ceremony (write config, register hooks, install Action + git hooks)
└── summary.sh                # structured summary emitter (Principle VIII)

templates/                    # files installed into consumer repos
├── github-action.yml         # → .github/workflows/spec-kit-linear-sync.yml (Layer E)
└── git-hooks/                # → .git/hooks/ (per-clone)
    ├── post-checkout
    ├── post-commit
    └── post-merge

tests/
├── unit/                     # bats unit tests, one *.bats per src/*.sh
├── integration/              # end-to-end tests gated on RUN_INTEGRATION_TESTS=1
└── fixtures/
    └── specs/                # synthetic specs/NNN-feature/ trees for parser tests

specs/
└── 001-spec-kit-linear-bridge/   # this spec (recursive — we dogfood)

validation/                   # research artefacts informing this plan
├── linear-mcp-capability-check.md
├── linear-mcp-tool-signatures.md
├── linear-mcp-runtime-probe.md          # background agent in flight at plan time
├── linear-github-integrations-survey.md
├── linear-workspace-probe.md
├── extension-shape-recon.md
└── github-action-mechanics.md

.specify/                     # spec-kit scaffold (templates, hooks, scripts, memory)
├── extensions.yml            # already has `git` extension registered
├── memory/constitution.md    # v1.0.0
├── templates/                # spec-kit's own templates
└── scripts/                  # spec-kit's helper scripts

.claude/skills/               # spec-kit skills auto-installed by specify init

.github/
└── workflows/
    └── ci.yml                # spec-kit-linear's OWN CI (shellcheck, bats, yamllint, markdownlint)
```

**Structure Decision**: Single-project layout (Option 1 from the
template). The bridge is one logical artifact — an extension with
commands + scripts + templates — not a multi-package monorepo. The
parallel `commands/` (AI-invoked markdown) and `src/` (bash impls)
dirs are not two projects; they're the algorithm-and-implementation
sides of the same artifact. The AI commands shell out to `src/` so
the deterministic work is unit-testable independently of any AI
agent.

## Complexity Tracking

*Filled ONLY if Constitution Check has violations that must be
justified.*

No violations to track. All 8 constitutional principles pass without
exception or deferred concern. The plan ships strictly what the spec
and constitution require:

- One language (bash) — no polyglot complexity.
- One reconciler — no per-event diff tracking, no state cache.
- Two layers with hard write-domain separation — no cross-layer
  reconciliation logic.
- One config file per repo — no per-operator state.
- No daemon, no DB, no hosted backend — three state-living-places
  only.

If implementation surfaces a constraint that forces a constitutional
exception, this section MUST be revisited and the violation
justified with a "simpler alternative rejected because" line per the
template.
