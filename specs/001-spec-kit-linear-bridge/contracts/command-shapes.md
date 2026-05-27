# Command Shapes Contract (`speckit.linear.*`)

**Status**: Phase 1 contract. Documents the five `speckit.linear.*`
commands declared in `extension.yml` `provides.commands`. Each
section is the operator-facing API for one command and the
contract every implementer + reviewer relies on.

**Three invocation paths exist** for every command (per plan.md §1):

1. **AI-agent invocation** — operator runs the slash-command
   form (`/speckit-linear-push`) in their coding agent. The agent
   reads `commands/linear-<sub>.md` and executes the algorithm,
   shelling out to `src/*.sh` for deterministic work.
2. **Spec-kit `after_*` hook chain** — only `speckit.linear.push`
   is wired in. The host agent dispatches it from
   speckit-taskstoissues's Post-Execution block per
   `validation/extension-shape-recon.md` §2.
3. **On-demand shell invocation** — operator (or a CI job)
   directly invokes `bash src/<role>.sh` with the same flags. The
   command markdowns are skippable; `src/*.sh` is the contract.

Exit codes (per FR-022) are consistent across all five commands:

| Code | Meaning |
|---|---|
| `0` | Success. Possibly with warnings (FR-024). |
| `1` | Recoverable failure. Network blip, Linear 5xx, transient lock. Operator re-runs to resolve. |
| `2` | Workspace-level config error (FR-022). Missing `linear-config.yml`, unseed workspace, malformed UUIDs. Operator MUST fix config before re-running. |

---

## 1. `speckit.linear.push`

**Three-dot name**: `speckit.linear.push`
**Slash form**: `/speckit-linear-push`
**Implementation**: `src/reconcile.sh`
**FRs implemented**: FR-001, FR-002, FR-003, FR-004, FR-004b,
FR-005, FR-006, FR-007, FR-008, FR-010, FR-013, FR-014, FR-015,
FR-016, FR-023, FR-024, FR-025, FR-026.

### 1.1 Role

The single convergent reconcile operation. Reads every
`specs/NNN-feature/` directory in the consumer repo, computes the
desired Linear state, and issues whatever mutations bring Linear
into convergence. The ONLY path that mutates Linear from Layer D.

### 1.2 Invocation contexts

- **AI agent** via `/speckit-linear-push`.
- **All six `after_*` hooks** (FR-031) fire this command
  automatically.
- **All three local git hooks** (`post-checkout`, `post-commit`,
  `post-merge` per FR-033) fire `src/reconcile.sh` directly,
  bypassing the markdown.
- **On-demand**: `bash src/reconcile.sh [flags]` from any
  worktree.

### 1.3 Arguments

```bash
bash src/reconcile.sh [--spec <NNN>] [--dry-run] [--quiet] [--all]
```

| Flag | Type | Default | Meaning |
|---|---|---|---|
| `--spec <NNN>` | feature number (e.g. `001`) | inferred from current branch | Reconcile only this spec. Auto-detected when invoked from a feature branch matching `<NNN>-…`. |
| `--all` | flag | false | Force reconcile of every spec in the repo regardless of branch. Used by retroactive sync (FR-014, User Story 5). |
| `--dry-run` | flag | false | Compute the diff and emit the summary; issue zero Linear mutations. Used for safe inspection. |
| `--quiet` | flag | false | Suppress per-mutation log lines. Summary still emitted unless `sync.emit_summary: false` in config. |

Positional args: none.

### 1.4 Inputs read

- **Filesystem**:
  - `specs/NNN-feature/spec.md` (every NNN matching the
    `--spec` / `--all` filter)
  - `specs/NNN-feature/plan.md` (optional)
  - `specs/NNN-feature/tasks.md` (optional; required for
    task-phase sub-issues per FR-005)
  - `specs/NNN-feature/red-team*.md` (optional, FR-012)
  - `specs/NNN-feature/analyze*.md` (optional)
  - `.specify/extensions/linear/linear-config.yml` (required,
    FR-022)
- **Environment**:
  - `LINEAR_API_KEY` (`.env` or shell, required for direct-GraphQL
    paths from git hooks; ignored when MCP session present)
  - `MCP_SESSION_AVAILABLE` (set by the AI-agent harness; selects
    MCP path)
- **Git state**:
  - `git branch --show-current` (FR-025 — write-authority gate)
  - `git worktree list` (FR-004 — memory block)
  - `gh pr view --json mergedAt,isDraft` (optional; FR-013 falls
    back to git-only branch reachability when `gh` absent)
- **Linear state** (queried before mutation):
  - `issues(filter: { labels: { name: "speckit-spec:NNN" }, project: { id } })` — identity lookup per FR-004b
  - `comments(filter: { issue: { id }, body: { startsWith: "<!-- speckit-linear:" } })` — comment dedup per FR-008
  - `get_issue(id) { blocks { id } }` — blocking-relation diff per FR-007

### 1.5 Outputs produced

- **Linear mutations** per `contracts/linear-graphql-mutations.md`
  §4 (reconcile-time block): `save_issue` for spec Issues,
  `save_issue` for task-phase sub-issues, `save_issue` for
  blocking relations, `save_comment` for non-task artifacts,
  `save_project` for Project Status.
- **Structured summary to stderr** (FR-023) on every run unless
  `sync.emit_summary: false`. Format:

```text
speckit-linear push summary
  Specs processed:    3
  Issues created:     1
  Issues updated:     2
  Sub-issues created: 4
  Sub-issues updated: 1
  Comments posted:    2
  Comments skipped:   8 (already present)
  Project state:      Started (unchanged)
  Warnings:           1
    - spec 002: task T002-014 references unknown phase 'Phase 99'
  Read-only specs:    1
    - spec 003 (worktree on main; authoritative branch '003-foo' not checked out)
  Wall-clock:         3.2s
```

- **No stdout output** except the summary. Per-mutation logs go
  to stderr.
- **No filesystem writes** (FR-016).

### 1.6 Exit codes

- `0`: every spec processed; warnings non-fatal.
- `1`: Linear API transient failure (5xx, rate-limit exhaustion,
  network). Re-run to converge.
- `2`: `linear-config.yml` missing / malformed / unseeded workspace.
  Per FR-022, halt without partial mutation.

### 1.7 Failure modes

| Failure | Behaviour | Operator response |
|---|---|---|
| `linear-config.yml` missing | Exit 2 with "Run `/speckit-linear-install` first" | Run install ceremony |
| `linear.workflow_state_uuids.*` unfilled (all zeroes) | Exit 2 with "Run `/speckit-linear-seed` first" per FR-022 | Run seed |
| Bash 3.2 detected (macOS shipped) | Exit 2 with `brew install bash` remediation | Install bash 4+ |
| OAuth session expired (4xx from MCP) | Per-spec warning + skip; continue with next spec | Re-auth via MCP host |
| `LINEAR_API_KEY` missing in git-hook context | Exit 1 with "set in `.env` or via shell" | Populate `.env` |
| Spec `spec.md` missing or empty | Per-spec warning + skip; continue (edge case in spec) | Fix or remove the spec directory |
| Malformed `## Phase N:` header in `tasks.md` | Per-task-phase warning; sync the rest of the spec (FR-024) | Fix the header |
| Linear 5xx during a mutation | Retry once + 2s backoff; if still fails, per-spec warning | Re-run reconcile later |
| Linear `RATELIMITED` (HTTP 400) | Exponential backoff (1s, 2s, 4s, 8s); aggregate as warning if exhausted | Re-run after a few minutes |
| Two Issues found for one `speckit-spec:NNN` (race) | Keep most-recent `updatedAt`, archive others if authoritative worktree, warn either way (FR-004b) | None — auto-resolved |
| Invoked from non-authoritative worktree | Per-spec read-only mode (FR-025); summary lists "Read-only specs" | None — expected; switch worktrees to write |

---

## 2. `speckit.linear.pull`

**Three-dot name**: `speckit.linear.pull`
**Slash form**: `/speckit-linear-pull`
**Implementation**: `src/reconcile.sh --read-only` (thin wrapper)
**FRs implemented**: FR-026, FR-024.

### 2.1 Role

Read-only display of Linear's current state for the current spec
(or every spec in the repo). NEVER mutates Linear; NEVER writes
to the filesystem. Used from non-authoritative worktrees per
FR-025/FR-026 where push is forbidden but the operator still
needs visibility.

### 2.2 Invocation contexts

- **AI agent** via `/speckit-linear-pull` — the most common path.
- **On-demand**: `bash src/reconcile.sh --read-only [flags]`.
- **NOT wired to any hook** (would be redundant with push).

### 2.3 Arguments

```bash
bash src/reconcile.sh --read-only [--spec <NNN>] [--all] [--format json|text]
```

| Flag | Default | Meaning |
|---|---|---|
| `--spec <NNN>` | current branch's spec | Show one spec |
| `--all` | false | Show every spec the consumer repo owns in Linear |
| `--format` | `text` | `text` for human reading; `json` for piping (drift detection scripts, etc.) |

### 2.4 Inputs read

- `.specify/extensions/linear/linear-config.yml` (required)
- Linear state via `get_issue` / `list_issues` / `get_project` /
  `list_comments`. NO filesystem parsing beyond config.

### 2.5 Outputs produced

- **No Linear mutations.** Guarded at the entry of
  `src/reconcile.sh` when `--read-only` is set.
- **No filesystem writes.**
- **Display to stdout** in the chosen format:

```text
spec 001-spec-kit-linear-bridge
  Linear Issue:    OSH-42 (https://linear.app/osh-infra/issue/OSH-42)
  Workflow state:  Implementing
  Phase label:     phase:implementing
  Memory block:    branch=001-spec-kit-linear-bridge worktree=/Users/ash/Code/AI/speckit-linear last_touched=2026-05-28T12:30Z
  Task phases:
    Phase 1 — Foundation       Done   ████████████ 12/12
    Phase 2 — Reconciler core  In Progress  ██████░░░░░░  6/12
    Phase 3 — Webhook layer    Todo   ░░░░░░░░░░░░  0/8
  Comments:        17 (3 clarify sessions, 8 plan summaries, 4 red-team, 2 analyze)
```

### 2.6 Exit codes

- `0`: queries succeeded.
- `1`: Linear API failure (queries only; no mutation could have
  partially applied).
- `2`: `linear-config.yml` missing / unparseable.

### 2.7 Failure modes

| Failure | Behaviour | Operator response |
|---|---|---|
| `linear-config.yml` missing | Exit 2 with install hint | Install |
| Spec has no Linear Issue yet | Per-spec "no Issue found; reconcile from authoritative worktree to create" line | Run push from authoritative branch |
| OAuth expired | Exit 1 with re-auth hint; no partial display | Re-auth |
| Linear 5xx | Exit 1; nothing displayed for affected spec | Retry |

---

## 3. `speckit.linear.status`

**Three-dot name**: `speckit.linear.status`
**Slash form**: `/speckit-linear-status`
**Implementation**: `src/reconcile.sh --status` (dry-run + drift
detection wrapper)
**FRs implemented**: FR-023, FR-024, FR-025 (read-only).

### 3.1 Role

Per-spec report covering: detected lifecycle phase, worktree
write-authority (FR-025), drift between filesystem state and
Linear's current state, the last reconcile's summary if one was
captured. Diagnostic command — answers "is my Linear actually
in sync?" without running a full reconcile.

### 3.2 Invocation contexts

- **AI agent** via `/speckit-linear-status`.
- **On-demand**: `bash src/reconcile.sh --status [flags]`.
- **NOT hook-wired.**

### 3.3 Arguments

```bash
bash src/reconcile.sh --status [--spec <NNN>] [--all] [--format json|text]
```

Same flag semantics as `pull` (§2.3).

### 3.4 Inputs read

- Everything `push` reads (§1.4), PLUS:
- Linear state via the same identity queries `push` uses, so
  drift can be computed.

### 3.5 Outputs produced

- **No Linear mutations** (status is `--dry-run` always).
- **Drift report to stdout**:

```text
spec 001-spec-kit-linear-bridge
  Filesystem phase: implementing
  Linear phase:     implementing                 ✓ in sync
  Worktree authority: WRITE (branch '001-spec-kit-linear-bridge' checked out at /Users/ash/Code/AI/speckit-linear)
  Drift detected:
    - task-phase 'Phase 3 — Webhook layer': filesystem has 8 tasks (1 done), Linear has 7 (1 done)
      → reconcile will ADD checklist line for T001-024
    - comment 'plan-summary plan.md#L42-L78' missing in Linear
      → reconcile will POST 1 comment
    - blocking relation Phase 2 → Phase 3 missing in Linear
      → reconcile will ADD 1 blocks relation
  Mutations next reconcile would issue: 3 (1 issue update, 1 comment, 1 blocks)
```

### 3.6 Exit codes

- `0`: status computed; drift count surfaced regardless.
- `1`: Linear query failure.
- `2`: `linear-config.yml` missing.

### 3.7 Failure modes

Inherits from `pull` (§2.7). Additionally: if drift count is
unusually high (e.g. >50 mutations queued), the report flags it
as a possible "first reconcile after retroactive adoption"
situation per FR-014/User Story 5 and recommends running
`push --all`.

---

## 4. `speckit.linear.seed`

**Three-dot name**: `speckit.linear.seed`
**Slash form**: `/speckit-linear-seed`
**Implementation**: `src/seed.sh`
**FRs implemented**: FR-021, FR-022, FR-032.

### 4.1 Role

One-shot workspace seed: creates the nine canonical workflow
states in the consumer's Linear Team (FR-032), creates the
`phase:*` label family, captures every UUID into
`linear-config.yml.linear.workflow_state_uuids`. Safe to re-run;
re-runs are no-ops for already-existing states/labels.

### 4.2 Invocation contexts

- **AI agent** via `/speckit-linear-seed` — required step before
  first `push` per FR-022.
- **On-demand**: `bash src/seed.sh [flags]`.
- **NOT hook-wired** (one-shot per workspace).

### 4.3 Arguments

```bash
bash src/seed.sh [--team <UUID>] [--dry-run] [--force]
```

| Flag | Default | Meaning |
|---|---|---|
| `--team <UUID>` | from `linear-config.yml.linear.team.id` | Override team for seeding |
| `--dry-run` | false | Compute what would be created; issue zero mutations |
| `--force` | false | Re-create states even if existing (DANGEROUS; almost never needed) |

### 4.4 Inputs read

- `.specify/extensions/linear/linear-config.yml` (required —
  needs `linear.team.id` populated by `install` first).
- Linear state via `workflowStates(filter: { team: { id } })`
  and `list_issue_labels(name: <name>)` to discover existing
  resources before create.

### 4.5 Outputs produced

- **Linear mutations** per `contracts/linear-graphql-mutations.md`
  §2: up to 9 × `workflowStateCreate` (GraphQL — no MCP tool
  exists per probe Capability 8) plus up to 8 × `create_issue_label`
  for `phase:*` (MCP).
- **`linear-config.yml` MUTATION** — the seed step writes the
  captured workflow-state UUIDs back into the config file under
  `linear.workflow_state_uuids`. This is the ONLY command that
  writes to the config file other than `install`.
- **Structured summary to stderr**:

```text
speckit-linear seed summary
  Workflow states created:  9
  Workflow states existing: 0 (would skip; none found in team)
  Issue labels created:     8 (phase:specifying ... phase:ready_to_merge)
  Issue labels existing:    0
  Config updated:           .specify/extensions/linear/linear-config.yml
                            linear.workflow_state_uuids: 9 UUIDs written
  Wall-clock:               4.7s
```

### 4.6 Exit codes

- `0`: seed completed; config updated.
- `1`: Linear API transient failure (re-run to converge — seed is
  designed for safe retry).
- `2`: `linear-config.yml` missing / `linear.team.id` unfilled.

### 4.7 Failure modes

| Failure | Behaviour | Operator response |
|---|---|---|
| `linear.team.id` not yet populated | Exit 2 with "Run `/speckit-linear-install` first" | Install |
| Insufficient OAuth scope (no `write`) | Per-state error + abort before `linear-config.yml` mutation | Re-auth with full scopes (see install) |
| Multiple existing states match a target name | Warn and require operator to pick — never auto-resolve | Manually pass UUID via config |
| Linear 5xx mid-seed (some states created, some not) | Captures whatever UUIDs were created into config; surfaces remaining unseeded list; safe re-run completes | Re-run seed |
| `--force` against a populated config | Refuses unless `--force --confirm-destroy` (extra flag); never silently overwrites UUIDs | Don't use `--force` |

---

## 5. `speckit.linear.install`

**Three-dot name**: `speckit.linear.install`
**Slash form**: `/speckit-linear-install`
**Implementation**: `src/install.sh`
**FRs implemented**: FR-002, FR-018, FR-018b, FR-019, FR-020,
FR-027, FR-029, FR-031, FR-033.

### 5.1 Role

Install ceremony invoked once per consumer repo. Verifies every
external dependency the bridge touches, surfaces a structured
status report (per FR-018b — NOT silent), copies the config
template, resolves Linear Team + Project UUIDs, drops the GitHub
Action template, installs local git hooks. The "make this repo
ready for `seed` + `push`" command.

### 5.2 Invocation contexts

- **AI agent** via `/speckit-linear-install` (typical path).
- **On-demand**: `bash src/install.sh [flags]`.
- **NOT hook-wired** (one-shot per repo).

### 5.3 Arguments

```bash
bash src/install.sh [--project <UUID>|--auto-create] [--team <UUID>]
                    [--no-action] [--no-git-hooks] [--no-prompt]
```

| Flag | Default | Meaning |
|---|---|---|
| `--project <UUID>` | interactive prompt | Attach to existing Linear Project (FR-002 non-interactive path) |
| `--auto-create` | mutually exclusive with `--project` | Create a new Project named after the repo basename (FR-002 non-interactive path) |
| `--team <UUID>` | auto-detect (sole team) or interactive prompt | Override team selection (FR-002) |
| `--no-action` | false | Skip the `.github/workflows/speckit-linear-sync.yml` install step (operator may not have repo admin) |
| `--no-git-hooks` | false | Skip the local git-hook install step (FR-033) |
| `--no-prompt` | false | Fully non-interactive; requires `--project`/`--auto-create` and `--team` to be passed |

### 5.4 Inputs read

- **Filesystem**:
  - Current working directory (must be a git repo root)
  - `.specify/extensions/linear/config-template.yml` (must be
    present — shipped by `specify extension add linear`)
  - `.specify/extensions.yml` (read + write; hook registration)
  - `.git/hooks/` (read + write; FR-033)
  - `.github/workflows/` (write — creates if absent)
  - `.mcp.json` (read + write — adds Linear MCP entry per
    FR-018b)
- **Environment**:
  - `bash --version` (must be ≥ 4 per plan.md Technical Context;
    abort on 3.2)
  - `curl --version` (must be present)
  - `jq --version` (must be ≥ 1.6)
  - `git --version` (must be ≥ 2.30)
  - `gh --version` (optional; absence noted in report per FR-018b)
- **Linear state** (via MCP):
  - `list_teams()` — auto-detect single-team case
  - `list_projects(team: <teamUuid>)` — surface existing Projects
    for the interactive picker
  - OAuth introspection (verify granted scopes per
    `defaults.oauth_scopes`)

### 5.5 Outputs produced

- **Filesystem writes**:
  - `.specify/extensions/linear/linear-config.yml` — created
    from `config-template.yml`, with `linear.team.id`,
    `linear.project.id`, `webhook.installed`, `git_hooks.installed`
    populated. (NOT the workflow-state UUIDs — those come from
    `seed`.)
  - `.specify/extensions.yml` — six `after_*` hook entries added
    per FR-031 (deduplicated on re-install).
  - `.github/workflows/speckit-linear-sync.yml` — dropped from
    `templates/github-action.yml` unless `--no-action`.
  - `.git/hooks/post-checkout`, `post-commit`, `post-merge` —
    dropped from `templates/git-hooks/` unless `--no-git-hooks`.
    Chained behind any pre-existing hook per FR-033.
  - `.mcp.json` — Linear MCP entry added (created if absent).
- **Linear mutations**:
  - `save_project` (create-or-attach) per
    `contracts/linear-graphql-mutations.md` §3.1, if
    `--auto-create` or operator picked "create new" in prompt.
- **Structured dependency report to stderr** (FR-018b — load-bearing):

```text
speckit-linear install dependency report

Runtime dependencies (FR-018b):
  ✓ bash 5.2.21
  ✓ curl 8.5.0
  ✓ jq 1.7
  ✓ git 2.43.0
  ✓ gh 2.40.1 (authenticated as @ashbrener)

Linear MCP wiring:
  ✓ .mcp.json entry present at mcp.linear.app/mcp
  ✓ OAuth session active (scopes: read, write, issues:create, comments:create)

Filesystem dependencies:
  ✓ .git/hooks/ writable (3 hooks installed: post-checkout, post-commit, post-merge)
  ✓ .github/workflows/ writable (speckit-linear-sync.yml installed)
  ✓ .specify/extensions.yml writable (6 after_* hooks registered)

Linear binding:
  ✓ Team:    OSH-INFRA (00000000-0000-0000-0000-000000000abc) [single-team workspace, auto-selected]
  ✓ Project: speckit-linear (00000000-0000-0000-0000-000000000def) [created new]
  ✗ Workflow state UUIDs: NOT YET SEEDED
    → Next step: run /speckit-linear-seed

Webhook secret (FR-029):
  ⚠ GitHub repo secret LINEAR_API_TOKEN: NOT SET
    → Run:    gh secret set LINEAR_API_TOKEN -R ashbrener/speckit-linear
    → Source: https://linear.app/settings/api (create personal API key 'speckit-linear-sync')

Install complete. Run /speckit-linear-seed next.
```

`✓` = verified. `⚠` = warning (operator action required but
install completed). `✗` = error (one of these fails the install
with exit code 2).

### 5.6 Exit codes

- `0`: install complete; report emitted; all `✗` items absent.
- `1`: Linear API transient failure during Project create / list.
- `2`: workspace-level config error — e.g. bash 3.2 detected,
  `config-template.yml` missing from the extension dir (CLI
  install was incomplete), `linear-config.yml` exists but is
  malformed and `--force` not passed.

### 5.7 Failure modes

| Failure | Behaviour | Operator response |
|---|---|---|
| Bash 3.2 (Apple-shipped) | Exit 2 immediately with `brew install bash` | Install bash 4+; re-run install |
| `gh` CLI absent | `⚠` in report; install completes; degradation note in report (FR-013 fallback path) | Optional — install `gh` for full Layer D fidelity |
| `.mcp.json` write fails (permission) | Exit 2 with chmod hint | Fix perms |
| OAuth scopes incomplete | `⚠` in report listing missing scopes; install completes but `seed` may fail | Re-auth with full scope set |
| `.git/hooks/post-commit` pre-exists (non-bridge content) | Warn; install chains the bridge hook AFTER existing content per FR-033 | Review chained hook; operator may consolidate |
| `.github/workflows/speckit-linear-sync.yml` pre-exists | Warn; install refuses to overwrite (operator may have customised it); install completes with the file untouched | Manually merge changes |
| `--no-prompt` without `--project`/`--auto-create` | Exit 2 with usage error | Pass required flags |
| Multiple teams found, no `--team`, `--no-prompt` set | Exit 2 listing all teams + their UUIDs | Pass `--team <UUID>` |
| `linear-config.yml` already exists with mismatched Project UUID | Warn loudly; never overwrite without `--force`; report drift in dependency report | Operator decides — keep existing or `--force` overwrite |

---

## 6. Cross-command invariants

### 6.1 All five commands MUST

- Read `linear-config.yml` through `src/config.sh` (single
  validation point; exit 2 on malformation).
- Verify bash 4+ as the first runtime check (early-exit before
  any other operation).
- Honour `--dry-run` / `--read-only` where declared by never
  issuing mutations.
- Emit the structured summary per FR-023 unless explicitly
  silenced.
- Surface warnings without aborting non-fatal flows per FR-024.
- Exit 0 on success-with-warnings, 1 on transient failure, 2 on
  workspace-level config error.

### 6.2 None of the five MUST

- Write to the filesystem (other than `install` to config /
  hooks, and `seed` to `linear.workflow_state_uuids`).
- Mutate pull requests (FR-017).
- Globalise any operator-level config (Principle V).
- Re-enable a hook the operator has set `enabled: false`
  (Principle VII).
- Use long-lived API keys when an OAuth path is available
  (Principle VI).
- Fail silently (Principle VIII).

### 6.3 Command interdependencies

```text
install ──┬──► seed ──► push ◄─── after_* hooks (auto-fire)
          │                  ◄─── git hooks (auto-fire)
          │                  ◄─── operator (on-demand)
          │
          ├──► pull (independent; works after install + seed even before first push)
          │
          └──► status (independent; works after install + seed even before first push)
```

`install` → `seed` → `push` is the canonical first-run sequence
(SC-003: ≤10 minutes hands-on). `pull` and `status` are
diagnostic, runnable any time after `seed`.
