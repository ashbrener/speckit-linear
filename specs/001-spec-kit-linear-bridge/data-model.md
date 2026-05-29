# Data Model

**Feature**: `001-spec-kit-linear-bridge`
**Phase**: 1 (design)
**Companions**: [spec.md](./spec.md) · [plan.md](./plan.md) · `../../config-template.yml` · `../../extension.yml`

## 1. Overview

This document enumerates every entity the bridge reads or writes — on
the consumer-repo filesystem and inside the Linear workspace — together
with the exact field-level mapping between them. Read it as a schema
reference: the spec (`spec.md`) is the source of truth for *what* the
bridge must do; this file is the source of truth for *what shape* the
data has on each side and *which bridge function* mediates each
mapping.

Cross-reference: the README's architecture diagram (Layer D
reconciler + Layer E webhook, against the filesystem and Linear)
visualises the high-level flow; this document zooms in to field
granularity inside each box.

All Linear entity field definitions are taken from
`validation/linear-mcp-tool-signatures.md` (tool signatures, GraphQL
input shapes), `validation/linear-mcp-runtime-probe.md` (live
`tools/list` output dated 2026-05-28), and
`validation/linear-workspace-probe.md` (concrete shapes observed in
the live `ACME` workspace). The runtime probe resolved every
previously-outstanding field shape; any remaining open question is
flagged inline as `confirm during T077 dogfood`.

---

## 2. Filesystem-side entities

The bridge only touches files under the consumer repository. There is
no `~/.config/spec-kit-linear/`, no SQLite, no JSON state cache (per
`plan.md` Storage section + Principle V).

### 2.1 Consumer repository

The unit a single bridge install covers. One repo ↔ one Linear
Project (FR-002).

| Field | Type | Source | Notes |
|---|---|---|---|
| `root_path` | absolute path | derived (`git rev-parse --show-toplevel`) | Working tree root |
| `.git/` | dir presence | filesystem | Required — bridge refuses non-git dirs |
| `.specify/` | dir presence | filesystem | Required — bridge refuses non-spec-kit dirs |
| `.specify/extensions/linear/linear-config.yml` | file presence | filesystem | Required for any sync; bridge halts with seed-prompt if absent |
| `.specify/extensions.yml` | file presence | filesystem | Required to be writable for install (hook auto-registration, FR-031) |
| `.git/hooks/` | dir presence + writability | filesystem | Required for FR-033 local-hook install |
| `.github/workflows/` | dir presence | filesystem | Optional — required only if operator opts into Layer E |
| `.env` | file presence | filesystem | Optional — required only for direct-GraphQL paths (seed, git hooks) |

**Invariants**

- MUST be a git repository (`.git/` present).
- MUST be a spec-kit consumer (`.specify/` present, `.specify/extensions.yml` parseable).
- MUST have committed `linear-config.yml` after install (Principle V — repo self-describing).

### 2.2 Spec directory (`specs/NNN-feature/`)

One directory per spec. Identified by feature number.

| Field | Type | Source | Notes |
|---|---|---|---|
| `feature_number` | string `NNN` (3-digit, zero-padded) | dirname prefix | e.g. `001` |
| `short_name` | string (kebab-case) | dirname suffix | e.g. `spec-kit-linear-bridge` |
| `dir_name` | string | dirname | `NNN-<short_name>` |
| `path` | absolute path | derived | `<root>/specs/<dir_name>/` |
| `files` | string[] | filesystem | Subset of: `spec.md`, `plan.md`, `tasks.md`, `research.md`, `data-model.md`, `quickstart.md`, `contracts/*`, `checklists/*`, `red-team*.md`, `analyze*.md` |
| `lifecycle_phase` | enum | derived | See § 6 — function of which files exist + their content |

**Derivation rule for `lifecycle_phase`** (also restated in § 6):

```
no spec.md                                              → (skip; warn)
spec.md only, no plan.md                                → Specifying
spec.md + ## Clarifications session,  no plan.md        → Clarifying
spec.md + plan.md, no tasks.md                          → Planning
spec.md + plan.md + tasks.md, no red-team*.md           → Tasking
red-team*.md present, no implementation evidence        → Red-team
implementation evidence, no analyze*.md                 → Implementing
analyze*.md present, PR not opened                      → Analyzing
PR opened / ready_for_review                            → Ready-to-merge
PR merged (or branch reachable from default)            → Merged
```

Authoritative phase table: see spec.md FR-012 + FR-013 + key entity
"Lifecycle phase".

**Invariants**

- `feature_number` MUST be unique within the repo.
- `short_name` MUST match the feature branch name suffix (FR-025
  authority check).

### 2.3 `spec.md`

Markdown, spec-kit's native shape. Parsed by `src/parser.sh`.

| Parsed field | Source | Shape |
|---|---|---|
| `feature_branch` | line `**Feature Branch**: \`NNN-name\`` | string |
| `created_at` | line `**Created**: YYYY-MM-DD` | ISO date |
| `status` | line `**Status**: <Draft\|Locked\|…>` | enum |
| `overview` | `## Overview` body up to next `##` | markdown block |
| `data_model_mapping_table` | table inside `## Overview` | rows |
| `clarification_sessions[]` | each `### Session YYYY-MM-DD` under `## Clarifications` | `{ date, qa_bullets[] }` |
| `user_stories[]` | each `### User Story N - <title>` block | `{ priority, story, acceptance_scenarios[] }` |
| `edge_cases[]` | bullets under `### Edge Cases` | string[] |
| `functional_requirements[]` | each `- **FR-NNN**: …` bullet under `### Functional Requirements` | `{ id, body, group }` |
| `key_entities[]` | bullets under `### Key Entities` | `{ name, description }` |
| `success_criteria[]` | each `- **SC-NNN**: …` bullet | `{ id, body }` |
| `assumptions[]` | bullets under `## Assumptions` | string[] |

**Parser invariants**

- Each `### Session YYYY-MM-DD` heading opens one clarify round
  (FR-015). Bullets under it are that session's Q/A pairs.
- A `- **FR-NNN**:` bullet outside any `### …` group heading is
  still captured but warned.
- An empty or absent `spec.md` causes the parent spec dir to be
  skipped with a warning (spec.md edge case § 1).

### 2.4 `tasks.md`

Markdown, spec-kit's native shape. Parsed by `src/parser.sh`.

| Parsed field | Source | Shape |
|---|---|---|
| `task_phases[]` | each `## Phase N: <Name>` header | `{ index: int, name: string, tasks: Task[] }` |
| `task_phases[].tasks[]` | checklist items under each phase header | `{ code, title, complete, estimate, dependency_markers[] }` |
| `task_phases[].tasks[].code` | `T###-NNN` from line prefix | string |
| `task_phases[].tasks[].complete` | `[x]` vs `[ ]` | bool |
| `task_phases[].tasks[].estimate` | optional `[N]` (digit-only bracketed token) within first 5 leading bracketed prefixes — FR-035 | int? |
| `task_phases[].tasks[].dependency_markers[]` | inline `(depends on T###-NNN)` tokens | string[] |
| `inter_phase_dependencies[]` | derived from per-task deps that cross phase boundaries | `{ from_phase: int, to_phase: int }` |
| `phase_estimate(N)` | sum of `[N]` markers across phase N's tasks; empty when no marker present | int? |
| `spec_estimate` | sum of every `[N]` across all phases; empty when no marker present | int? |

**Parser invariants**

- A task line outside any `## Phase N:` heading is a parse error →
  warned, skipped (FR-024).
- Phase indices MUST be monotonic positive integers starting at 1;
  gaps are warned but tolerated.
- Task codes follow the canonical `T<feature-number>-<seq>` form
  (Assumptions list in spec.md); non-canonical codes are warned but
  preserved verbatim in the mirrored checklist.
- Dependency markers that reference an unknown task code are warned
  and surfaced in the task-phase sub-issue's checklist header (FR-024
  + edge case § 2).

### 2.5 `linear-config.yml`

Lives at `.specify/extensions/linear/linear-config.yml`. **Committed**
to the consumer repo (Principle V). Full schema mirrors
`config-template.yml`.

```yaml
schema_version: 1            # int, required
config_version: 1            # int, required (bump on hand-edit)

linear:
  workspace:
    name: string             # informational, display only
    url_key: string          # informational, workspace URL slug
  team:
    id: UUID                 # REQUIRED, FR-002 — authoritative
    key: string              # informational, not used for lookup
    name: string             # informational
  project:
    id: UUID                 # REQUIRED, FR-002 — authoritative
    name: string             # informational, display only
  workflow_state_uuids:      # REQUIRED block, FR-032
    specifying:     UUID     # REQUIRED
    clarifying:     UUID     # REQUIRED
    planning:       UUID     # REQUIRED
    tasking:        UUID     # REQUIRED
    red_team:       UUID     # REQUIRED
    implementing:   UUID     # REQUIRED
    analyzing:      UUID     # REQUIRED
    ready_to_merge: UUID     # REQUIRED
    merged:         UUID     # REQUIRED

sync:
  enabled: bool              # default true (FR-031 disable mechanism)
  idle_window_days: int      # default 30; 0 disables Paused flip (FR-002)
  emit_summary: bool         # default true (FR-023)

webhook:
  installed: bool            # flipped true by install when YAML committed
  workflow_path: string      # `.github/workflows/spec-kit-linear-sync.yml`
  secret_name: string        # `LINEAR_API_TOKEN` (FR-029)

git_hooks:
  installed: bool            # flipped true by install (FR-033)
  hooks: string[]            # ["post-checkout", "post-commit", "post-merge"]
```

**Type notes**

- `UUID` = RFC 4122 string, e.g. `00000000-0000-0000-0000-000000000000`.
  Validated by `src/config.sh` before any reconcile (FR-022 / Principle
  VIII Rule 1).
- All `informational` fields are display-only — the bridge never
  resolves Linear entities by name (FR-032).

**Invariants**

- The file MUST be a copy/rename of `config-template.yml` (the CLI
  does not auto-rename; see `extension.yml` `config:` block).
- Every `linear.*.id` and every `linear.workflow_state_uuids.*` value
  MUST be a non-zero UUID before reconcile runs.

### 2.6 `.env`

Gitignored. Holds the API key used by the direct-GraphQL paths
(workspace seed, local git hooks, ad-hoc Action local-run). Not needed
when only the MCP path is in use (operator-driven AI commands).

| Field | Type | Required | Notes |
|---|---|---|---|
| `LINEAR_API_KEY` | string | Required for: `speckit.linear.seed`, git-hook reconciles, GitHub Action local-test | Loaded as env var by `src/graphql.sh`; never committed (FR-020) |

---

## 3. Linear-side entities

Field shapes come from `validation/linear-mcp-tool-signatures.md`
(tool & input schemas) and `validation/linear-workspace-probe.md`
(live workspace).

### 3.1 Workspace

The Linear container. One workspace per OAuth token; the bridge never
passes a `workspaceId` (it is implicit in the token).

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | org-level UUID; e.g. `c4e7538f-…` in ACME |
| `name` | string | e.g. `ACME` |
| `urlKey` | string | slug used in `https://linear.app/<urlKey>/…` URLs |

Relationship: **owns N Teams**, **owns N Projects** (Projects are
workspace-scoped, not team-scoped).

### 3.2 Team

The container for Issues and (critically) for workflow states. One team
per consumer-repo install in v1 — though Linear allows multi-team
Projects.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | stored in `linear.team.id` |
| `key` | string | issue-identifier prefix, e.g. `ACM` (Issues become `ACM-123`) |
| `name` | string | e.g. `ACME` |
| `members[]` | User[] | not consulted by bridge |

Relationship: workspace owns team; team owns WorkflowStates (team-scoped
per § 5 of the MCP tool-signatures doc).

### 3.3 Project (= consumer repo)

One Linear Project per consumer repository (FR-002). 1:1 mapping.

| Field | Type | Source | Notes |
|---|---|---|---|
| `id` | UUID | resolved at install | stored in `linear.project.id`, the authoritative lookup key |
| `name` | string | install-time prompt | default = consumer repo's directory name |
| `description` | string (markdown) | bridge | populated by reconcile with a repo-level memory block; see render note below |
| `state` / `statusId` | UUID | bridge | references one of the workspace's `ProjectStatus` records; six valid `ProjectStatusType` values: `backlog`, `planned`, `started`, `paused`, `completed`, `canceled` |
| `slugId` | string | Linear | URL slug (display only) |
| `teamIds[]` | UUID[] | bridge | set at create_project to `[linear.team.id]` |
| `leadId` | UUID? | optional | not set by bridge |

**Invariants**

- 1:1 with consumer repo. Lookup ALWAYS by `linear.project.id`, never
  by name (FR-002 / Principle V).
- Project Status reflects repo-wide activity, not any single spec's
  phase (FR-013) — see § 6.

**`description` rendering**

Renders as Linear's standard GitHub-flavoured markdown: headings
(H1–H6), bold/italic, lists, code blocks, inline code, links, tables,
blockquotes. Linear does NOT render mermaid diagrams in Project or
Issue descriptions as of the 2026-05-28 runtime probe; the bridge MUST
NOT embed mermaid in description fields. Image embedding via standard
markdown image syntax works.
<!-- Confirmed during T077 dogfood. -->

### 3.4 Issue (= spec)

One Linear Issue per spec. The central entity the bridge manipulates.

| Field | Type | Source | Notes |
|---|---|---|---|
| `id` | UUID | Linear | resolved on first sync via label lookup (FR-004b) |
| `identifier` | string | Linear | `ACM-NNN` form, display only |
| `title` | string | bridge | encodes feature number + short name: `NNN-<short-name>` (FR-003) |
| `description` | string (markdown) | bridge | fully bridge-owned body — overview ++ memory ++ diagrams in canonical order (FR-004, FR-016); see schema below |
| `teamId` | UUID | bridge | = `linear.team.id` |
| `projectId` | UUID | bridge | = `linear.project.id` |
| `stateId` | UUID | bridge | one of `workflow_state_uuids.*`, computed from `lifecycle_phase` (§ 6) |
| `labelIds[]` | UUID[] | bridge | always contains `phase:<current>` and `speckit-spec:NNN`; also carries one sticky `agent:<family>` label per AI agent that has reconciled this Issue (FR-036); possibly other operator-added labels (preserved) |
| `parentId` | UUID? | n/a | spec Issues have no parent |
| `priority` | int? | n/a | not set by bridge |
| `assigneeId` | UUID? | bridge (create only) | set to `linear.operator.user_id` from config on every `issueCreate` (FR-034); NOT passed on `issueUpdate` so manual reassignment in Linear's UI persists. Absent config block → unassigned with one warning per reconcile run (graceful degradation). |
| `createdAt` / `updatedAt` | DateTime | Linear | read for race-resolution (FR-004b) |

**Description body schema** (FR-004) — the bridge writes the entire
`description` on every reconcile in canonical order: `overview ++
memory ++ diagrams` (each separated by a blank line; overview and
diagrams are skipped when empty). No fence markers wrap any block —
Linear renders HTML comments and `<details>` tags as visible text
nodes, so fences would leak as literal markup. Operator annotations
belong in Linear comments on the spec Issue (FR-008), which the
bridge never reads or writes.

The memory block itself is the markdown table emitted by
`render_memory_block`:

```markdown
| Field | Value |
|---|---|
| **Phase** | <lifecycle_phase> |
| **Branch** | `<feature-branch>` |
| **Worktree(s)** | `<absolute-path-1>` [, `<absolute-path-2>`, …] |
| **Last touched** | YYYY-MM-DDTHH:MM:SSZ |
| **Last reconciled by** | `<agent-model-id>` · YYYY-MM-DDTHH:MM:SSZ |
| **Source** | [GitHub →](<github-url-to-specs/NNN-feature/>) |
| **Spec** | NNN-<short-name> |
```

The `**Last reconciled by**` row (FR-036) is conditional: emitted only
when the running shell exposes `CLAUDE_CODE_MODEL`, `CODEX_MODEL`, or
`AGENT_NAME`. Its timestamp is co-bound to the description idempotency
probe — a no-op reconcile by a different agent MUST NOT mutate just
to refresh the timestamp (preserves SC-002).

**Invariants**

- Stamped with `speckit-spec:NNN` label at creation; subsequent syncs
  locate the Issue by that label scoped to `projectId` (FR-004b).
- Race resolution: if >1 Issue with the same `speckit-spec:NNN` label
  exists in the same Project, keep the one with the most recent
  `updatedAt`; archive the others (FR-004b).
- The description body is rewritten on EVERY reconcile (FR-004,
  FR-016 — unidirectional sync).

### 3.5 Sub-issue (= task phase)

One Linear sub-issue per task phase (`## Phase N:` block in
`tasks.md`).

| Field | Type | Source | Notes |
|---|---|---|---|
| `id` | UUID | Linear | resolved by `(parentId, task-phase:N label)` |
| `title` | string | bridge | `Phase <N> — <Name>` (canonical spec-kit form per Clarification round 3) |
| `description` | string (markdown) | bridge | one-way-mirror header + checklist (FR-006); see below |
| `parentId` | UUID | bridge | = spec Issue's `id` |
| `teamId` | UUID | bridge | = `linear.team.id` |
| `projectId` | UUID | bridge | = `linear.project.id` |
| `stateId` | UUID | bridge | task-phase progress state — Todo / In Progress / Done (using team's stock states; not the bridge's nine spec-phase states) |
| `labelIds[]` | UUID[] | bridge | contains `task-phase:N`; also carries one sticky `agent:<family>` label per AI agent that has reconciled this sub-issue (FR-036) |

**Checklist description schema** (FR-006):

```markdown
> **One-way mirror.** This checklist reflects `tasks.md` on the
> spec's feature branch. Ticking items here has no effect; the next
> reconcile will overwrite this list to match the filesystem.
>
> Warnings (if any): <bulleted list of malformed task references>

- [ ] **T001-001** — Task title
- [x] **T001-002** — Task title
- …
```

**Invariants**

- Exactly one sub-issue per task phase; ordered by `N` (FR-005).
- At most one sub-issue in the "In Progress" team-stock state at any
  time while the spec is in an implementing phase (FR-005).
- Adding / removing one task in `tasks.md` MUST result in exactly one
  changed line in exactly one sub-issue's checklist (SC-006).

### 3.6 Label

Linear `IssueLabel` records. Four label families used by the bridge,
all parent-grouped per the workspace probe.

| Family | Naming | Scope | Lifecycle |
|---|---|---|---|
| `phase:*` | `phase:specifying`, `phase:clarifying`, …, `phase:merged` | team (children of `phase` parent group) | 9 created by seed (FR-021) |
| `task-phase:*` | `task-phase:1`, `task-phase:2`, … | team (children of `task-phase` parent group) | minted lazily at sync time |
| `speckit-spec:*` | `speckit-spec:001`, `speckit-spec:002`, … | team (children of `speckit-spec` parent group) | minted lazily on first Issue creation (FR-004b) |
| `agent:*` | `agent:claude`, `agent:codex`, …, `agent:<lowercased-first-word>` | workspace (set by bridge; sticky) | 2 canonical (`agent:claude`, `agent:codex`) created by seed (FR-021 / FR-036) with UUIDs captured into `linear.agent_label_uuids`; non-canonical families minted lazily by reconcile at sync time. Once applied to an Issue / sub-issue the bridge MUST NOT remove the label — cross-agent provenance is preserved. |

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | per-label |
| `name` | string | as listed above |
| `color` | string (hex) | required by Linear |
| `parentId` | UUID? | one of the three parent group label UUIDs; Linear allows one level of nesting (workspace probe § Labels) |
| `teamId` | UUID? | team-scoped per probe; null possible workspace-scoped — confirmed team-scoped in dogfood workspace |

**Scope clarification**: per `linear-workspace-probe.md` §Labels and
`linear-mcp-tool-signatures.md` §Capability 6, `IssueLabel.parent` is
singular (one nesting level only). Workspace-scoped vs team-scoped:
the probe observed team-scoped labels in `ACME`. Bridge uses
team scoping uniformly.

### 3.7 WorkflowState

The nine spec-kit lifecycle states, created by the seed step
(FR-021).

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | captured at creation, written to `workflow_state_uuids` map |
| `name` | string | display only — bridge looks up by UUID (FR-032) |
| `type` | enum string | one of `backlog`, `unstarted`, `started`, `completed`, `canceled` |
| `color` | string (hex) | required |
| `position` | float | optional ordering |
| `teamId` | UUID | REQUIRED — workflow states are team-scoped (MCP tool-signatures § 2) |
| `description` | string? | optional |

**The nine states created by `speckit.linear.seed`** (FR-021,
key=`workflow_state_uuids.*`):

| Key (config) | Linear `name` | Linear `type` |
|---|---|---|
| `specifying`     | Specifying      | `backlog` |
| `clarifying`     | Clarifying      | `unstarted` |
| `planning`       | Planning        | `unstarted` |
| `tasking`        | Tasking         | `unstarted` |
| `red_team`       | Red-team        | `started` |
| `implementing`   | Implementing    | `started` |
| `analyzing`      | Analyzing       | `started` |
| `ready_to_merge` | Ready-to-merge  | `started` |
| `merged`         | Merged          | `completed` |

Type mapping derived from `validation/linear-workspace-probe.md`
§ "Gap vs spec lifecycle" and the spec's lifecycle ordering. Stock
states (`Backlog`, `Todo`, `In Progress`, `Done`, `Canceled`,
`Duplicate`) remain untouched and continue to serve non-speckit
Issues + task-phase sub-issues (§ 3.5).

### 3.8 Comment (on spec Issue)

Linear `Comment` records on the spec Issue. Used as the surface for
non-task lifecycle artifacts (FR-008, FR-015).

| Field | Type | Source | Notes |
|---|---|---|---|
| `id` | UUID | Linear | passed in CreateInput as deterministic UUIDv4 for idempotency (MCP tool-signatures § 2) |
| `body` | string (markdown) | bridge | Q/A bullets, plan section summary, red-team finding, analyze finding, etc. |
| `issueId` | UUID | bridge | = spec Issue id |
| `projectId` | UUID? | n/a | unused — bridge comments live on Issue, not Project (FR-008) |
| `projectUpdateId` | UUID? | n/a | unused (see § 3.9) |
| `parentId` | UUID? | n/a | bridge does not thread comments |
| `createdAt` | DateTime | Linear | used for chronological display only |

**Categories** (each posted exactly once per source artifact,
idempotent via deterministic comment UUIDs):

| Category | Source | Trigger | Body shape |
|---|---|---|---|
| Clarify session | each `### Session YYYY-MM-DD` in spec.md | `after_clarify` (FR-015) | Q/A bullets |
| Plan section summary | `plan.md` sections | `after_plan` | section title + 1-paragraph synthesis |
| Red-team finding | `red-team*.md` | `after_*` post red-team | finding header + body |
| Analyze finding | `analyze*.md` | `after_analyze` | finding header + body |
| Decision / ratification | spec.md decision entries | `after_clarify` / `after_plan` | bullet list |

**Invariants**

- One comment per ratified clarify session (FR-015).
- Idempotent: deterministic UUIDv4 derived from `(spec_id, source_kind,
  source_id)` ensures re-sync never duplicates.
- Order in Linear: chronological by `createdAt` (Linear's native
  sort), which matches source order on the filesystem.

### 3.9 ProjectUpdate (NOT used in v1)

Linear has a `ProjectUpdate` entity (and `projectUpdateId` is a valid
foreign key on `Comment` per `linear-mcp-tool-signatures.md` § 2 /
Capability 7). The bridge considered surfacing non-task artifacts as
Project Updates but Clarification round 2 settled on **Issue comments**
instead (per FR-008 — "comments on the spec Issue").

`ProjectUpdate` is therefore **reserved for future use**. No bridge
code reads or writes it in v1. The field is mentioned here only so
maintainers know it is intentionally unused, not overlooked.

---

## 4. Filesystem ↔ Linear mapping

Field-by-field expansion of the spec's data-model mapping table.
"Mapping function" names follow the `src/` layout in `plan.md` § Project
Structure.

| FS entity → field | Linear entity → field | Mapping function (in `src/`) |
|---|---|---|
| Repo / `root_path` (dirname) | Project / `name` (at create only) | `install.sh::project_default_name` |
| Repo / lifecycle activity | Project / `state` (statusId) | `reconcile.sh::resolve_project_status` (Started/Paused/Completed; see § 6) |
| Spec / `feature_number` | Issue / `labels[]` contains `speckit-spec:NNN` | `parser.sh::feature_number_label` |
| Spec / `feature_number` + `short_name` | Issue / `title` | `reconcile.sh::compose_issue_title` |
| Spec / `spec.md` (overview + memory block fields) | Issue / `description` | `parser.sh::extract_overview` + `summary.sh::render_memory_block` |
| Spec / `lifecycle_phase` | Issue / `stateId` | `reconcile.sh::resolve_workflow_state` (reads `workflow_state_uuids.*` from config) |
| Spec / `lifecycle_phase` | Issue / `labels[]` contains `phase:<phase>` | `reconcile.sh::resolve_phase_label` |
| Spec / `tasks.md` `## Phase N:` block | Sub-issue (parent = spec Issue) | `reconcile.sh::sync_task_phase_subissue` |
| Task phase / `index` | Sub-issue / `labels[]` contains `task-phase:N` | `reconcile.sh::resolve_task_phase_label` |
| Task phase / `index` + `name` | Sub-issue / `title` | `reconcile.sh::compose_subissue_title` (`Phase N — <Name>`) |
| Task phase / `tasks[]` | Sub-issue / `description` (markdown checklist) | `parser.sh::render_task_checklist` |
| `inter_phase_dependencies[]` | IssueRelation type=`blocks` between sub-issues | `graphql.sh::issue_relation_create` (UUIDv4-keyed for idempotency) |
| `clarification_sessions[]` | Comment[] on spec Issue | `reconcile.sh::sync_clarify_comments` (FR-015) |
| `plan.md` sections | Comment[] on spec Issue | `reconcile.sh::sync_plan_comments` |
| `red-team*.md` findings | Comment[] on spec Issue | `reconcile.sh::sync_red_team_comments` |
| `analyze*.md` findings | Comment[] on spec Issue | `reconcile.sh::sync_analyze_comments` |
| `feature_branch` + `git worktree list` | Issue / `description` memory block fields | `git_helpers.sh::collect_branch_worktrees` + `summary.sh::render_memory_block` |
| GitHub source URL | Issue / `description` memory block `Source` field | `git_helpers.sh::compose_github_source_url` |
| PR state (open / ready / merged) | Issue / `stateId` (Ready-to-merge / Merged) | `git_helpers.sh::detect_pr_state` (`gh` → git-only fallback per FR-030) + Layer E action |

**Where each function lives** is normative per `plan.md` § Project
Structure (`src/reconcile.sh`, `src/parser.sh`, `src/graphql.sh`,
`src/config.sh`, `src/git_helpers.sh`, `src/seed.sh`, `src/install.sh`,
`src/summary.sh`).

---

## 5. Identity & uniqueness rules

How the bridge avoids duplicates per Linear entity. All rules derive
from FR-002, FR-004b, FR-005, FR-032 and Principle V (UUID-based
binding).

| Linear entity | Stable identity | Lookup function | Race / duplicate handling |
|---|---|---|---|
| Project | `linear.project.id` (UUID) from `linear-config.yml` | `config.sh::project_uuid` | Bridge never creates a Project except via `install.sh`; subsequent syncs read by UUID. |
| Team | `linear.team.id` (UUID) from `linear-config.yml` | `config.sh::team_uuid` | Resolved once at install; never re-created. |
| WorkflowState | `linear.workflow_state_uuids.<phase>` (UUID) | `config.sh::workflow_state_uuid("<phase>")` | Seed step skips creation if a state with the same name exists on the team (probe § 5 recommendation). |
| Spec Issue | `speckit-spec:NNN` label scoped to `projectId` | `graphql.sh::issue_by_speckit_label` | FR-004b: keep most-recent-`updatedAt`, archive the rest. |
| Sub-issue (task phase) | `parentId` (spec Issue) + `task-phase:N` label | `graphql.sh::subissue_by_phase_label` | Bridge never creates duplicate; if found, archive newer copies (analogous to FR-004b). |
| IssueRelation (blocks) | Deterministic UUIDv4 derived from `(blocker_subissue_id, blocked_subissue_id)` | `graphql.sh::issue_relation_id` | Idempotent — Linear input accepts custom `id` (MCP tool-signatures § 2 `IssueRelationCreateInput.id`). |
| Comment | Deterministic UUIDv4 derived from `(spec_issue_id, source_kind, source_id)` | `graphql.sh::comment_id` | Idempotent — Linear input accepts custom `id` (`CommentCreateInput.id`). |
| Label (`phase:*`, `task-phase:N`, `speckit-spec:NNN`) | `name` scoped to team | `graphql.sh::label_by_name` | Lazy mint: query by name first; skip on hit. |

---

## 6. State transitions

### 6.1 Lifecycle phase state machine (spec Issue `stateId`)

Trigger artifacts (filesystem) → resolved phase → Linear state UUID.
Resolution function: `reconcile.sh::resolve_workflow_state`.

| From | Trigger artifact | To | `stateId` source |
|---|---|---|---|
| (no Issue) | `spec.md` created | `Specifying` | `workflow_state_uuids.specifying` |
| `Specifying` | `### Session YYYY-MM-DD` added to spec.md | `Clarifying` | `workflow_state_uuids.clarifying` |
| `Clarifying` | `plan.md` created (clarify answers ratified by appearing in spec.md per FR-015) | `Planning` | `workflow_state_uuids.planning` |
| `Planning` | `tasks.md` created | `Tasking` | `workflow_state_uuids.tasking` |
| `Tasking` | `red-team*.md` created | `Red-team` | `workflow_state_uuids.red_team` |
| `Red-team` | implementation evidence (commits on feature branch, ticked checklist items) | `Implementing` | `workflow_state_uuids.implementing` |
| `Implementing` | `analyze*.md` created | `Analyzing` | `workflow_state_uuids.analyzing` |
| `Analyzing` | PR opened or marked ready (Layer E webhook or `gh pr view` poll) | `Ready-to-merge` | `workflow_state_uuids.ready_to_merge` |
| `Ready-to-merge` | PR merged (`merged: true` event or `git merge-base --is-ancestor` against default branch) | `Merged` | `workflow_state_uuids.merged` |

**Retroactive sync rule (FR-014)**: when the bridge first sees a spec
already in a late phase (e.g. already merged), it MUST resolve directly
to the terminal state without emitting intermediate-phase comments or
transitional state flips. Implementation: `resolve_workflow_state`
selects the highest-precedence phase whose trigger artifacts are
present and writes the spec Issue directly to that `stateId`.

**Label sync rule (FR-003 / FR-013)**: every reconcile sets the
`labelIds[]` to include exactly one `phase:<current>` and the
`speckit-spec:NNN` label; any other operator-added labels are preserved.
Exception: when phase becomes `Merged`, the `phase:*` label is removed
entirely (FR-013).

### 6.2 Project Status state machine (`Project.statusId`)

Resolution function: `reconcile.sh::resolve_project_status`. Operates
on the *repo* as a whole, not on any single spec.

| From | Condition | To |
|---|---|---|
| (any) | at least one spec is in `Specifying`…`Analyzing` | `Started` |
| (any) | at least one spec is in `Ready-to-merge` and none in earlier active phases | `Started` |
| `Started` | no spec touched on disk within `sync.idle_window_days` (config; default 30, 0 disables) | `Paused` |
| `Paused` | any spec touched on disk again | `Started` |
| `Started` / `Paused` | every spec is `Merged` (or operator override) | `Completed` |
| (any) | operator manually sets Project Status in Linear | (preserved — bridge yields to operator override per FR-002) |

`Cancelled` and `Planned` are valid `ProjectStatusType` values but the
bridge never writes them; they are operator-only.

---

## 7. Validation rules

What `src/config.sh` / `src/parser.sh` / `src/reconcile.sh` validate
before writing.

### 7.1 `linear-config.yml`

Performed by `src/config.sh` on every invocation; halts before any
Linear mutation if any check fails (FR-022 / Principle VIII Rule 1).

- File exists at `.specify/extensions/linear/linear-config.yml`.
- `schema_version == 1`.
- `linear.team.id` is a non-zero UUID.
- `linear.project.id` is a non-zero UUID.
- All 9 keys in `linear.workflow_state_uuids` are present and each is
  a non-zero UUID (FR-032). Missing key → error names the missing
  phase and points at `speckit.linear.seed`.
- `sync.idle_window_days >= 0`.

### 7.2 `tasks.md`

Performed by `src/parser.sh`. Warnings surface in summary (FR-024)
but do not halt sync.

- File parseable as markdown.
- At least one `## Phase N:` heading present (if any tasks exist).
- Each task line has a `T###-NNN` code (warn if not).
- Dependency markers reference real task codes (warn if dangling;
  surfaced in task-phase sub-issue checklist header per FR-024).

### 7.3 `spec.md`

- File exists and is non-empty (else parent spec dir skipped with
  warning — edge case § 1).
- `**Feature Branch**` line present (warn if missing).
- Each `### Session YYYY-MM-DD` heading has a parseable ISO date
  (warn if not).

### 7.4 Consumer repository

- `.git/` present (else hard error: not a git repo).
- `.specify/` present (else hard error: not a spec-kit consumer).
- Bridge has write access to `.specify/extensions.yml` (else install
  step fails with remediation — FR-018b).
- Bridge has write access to `.git/hooks/` (else install step fails
  with remediation — FR-018b / FR-033).

### 7.5 Linear-side preconditions (verified at runtime, halt if missing)

- The team identified by `linear.team.id` has all nine workflow
  states whose UUIDs are in `workflow_state_uuids` (FR-022). Missing
  state → halt with "run `speckit.linear.seed`".
- The Project identified by `linear.project.id` exists and is
  readable.
- All three parent label groups (`phase`, `task-phase`,
  `speckit-spec`) exist on the team (created by seed). Children are
  minted lazily.
- The OAuth session (for MCP paths) or `LINEAR_API_KEY` (for direct
  GraphQL paths) is valid. Expired session → halt with
  "reauthenticate" message (edge case § OAuth expired).

---

## Cross-references

- `spec.md` §Overview data-model mapping table — the locked
  filesystem ↔ Linear primitive mapping.
- `spec.md` FR-001…FR-033 — the requirements that motivate every
  field above.
- `plan.md` §Technical Context + §Project Structure — where each
  mapping function physically lives.
- `config-template.yml` — the committed shape of `linear-config.yml`.
- `extension.yml` — the install-time manifest that hooks the bridge
  into the consumer's `.specify/extensions.yml`.
- `validation/linear-mcp-tool-signatures.md` — Linear GraphQL input
  schemas referenced throughout § 3.
- `validation/linear-workspace-probe.md` — concrete entity shapes
  from the live `ACME` workspace.
