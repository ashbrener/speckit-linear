# speckit-linear — kickoff brief

This document captures the design decisions reached in a planning conversation in the BLOK9 session on 2026-05-27. Drop this in front of a fresh Claude Code session opened at `~/Code/AI/speckit-linear/` to hit the ground running.

## What this is

A standalone Claude Code skill / plugin that bridges GitHub spec-kit's lifecycle (`/speckit-specify` → `-clarify` → `-plan` → `-tasks` → `-red-team` → `-implement` → `-analyze`) into Linear, so that every spec automatically gets a Linear Project, every task an Issue, and every phase transition the right status + labels.

Think of it as the Linear counterpart to `speckit-taskstoissues` (which targets GitHub Issues). Not a fork of spec-kit; an additive bridge that hooks into spec-kit's native `.specify/extensions.yml` mechanism.

## Why now

The operator has 4+ active repos (b9-backend, b9-frontend, project-arc, docs) running spec-kit lifecycles in parallel, and is losing track of phase state across them. Linear becomes the consolidated tracker without abandoning the markdown-artifact-driven spec-kit flow.

## Architectural decisions reached

### Distribution shape

- **Standalone GitHub repo**, not part of project-arc, not part of any consuming repo.
- **Distributed as a Claude Code plugin** (`~/.claude/plugins/`), with a fallback raw-skill install path.
- **Dual adoption channels:**
  1. `speckit-linear init` CLI (shipped in repo) — drops `.specify/extensions.yml` + `.mcp.json` into any repo. Standalone, no other deps.
  2. project-arc ADR 0007 (authored later, in `~/.project-arc/decisions/`) — pointers project-arc siblings at this bridge via `project-arc decisions apply`.
- **No coupling either direction:** speckit-linear works without project-arc; project-arc works without speckit-linear.

### Linear data model

| Speckit artifact | Linear object |
|---|---|
| Spec (e.g. `003-multi-super-admin`) | **Project** — name + description mirror `spec.md` |
| Plan sections (research, data model, contracts) | **Comments** on Project |
| Red-team findings, analyze findings | **Comments** on Project, label-tagged |
| Implementation wave (W0, W1, …) | **Milestone** on Project |
| Task (T003-001..T003-085) | **Issue** in Project, attached to wave milestone |
| Task dependencies | **Blocks / blocked-by relations** between Issues |
| Lifecycle pointer | **Tracker Issue** inside the Project (one per spec) |
| Operator decisions ledger ADRs | **Comments** on Project (ratification trail) |

### Why Project=Spec, not Issue=Spec

- Specs commonly have 30-90 tasks; Linear sub-issues get unwieldy past ~20-30.
- Top-level Issues get full Linear triage tooling (filtering, boards, cycles); sub-issues don't.
- Project Content field is full markdown — natural home for `spec.md`.
- Multiple artifacts (spec/clarify/plan/tasks/red-team/analyze) each want their own comment thread; one Issue would collapse all into one stream.
- Milestones map natively to spec-kit waves.
- Task-Issues can be cycle members independently across specs; sub-issues can't.

### Why a tracker Issue inside the Project

- Project Status is a closed enum (Planned/Started/Paused/Completed/Cancelled) — too coarse for phase substatus.
- Issue workflow states are fully customizable — phase substatus becomes real states on the tracker Issue.
- Tracker Issue gives a single shareable URL per spec.
- Tracker Issue's `LIN-N` identifier auto-links to the PR via branch convention.

### Phase mapping (lives on tracker Issue)

| Speckit phase | Project Status | Tracker Issue Workflow State | Project Label |
|---|---|---|---|
| `/speckit-specify` ran | Planned | Specifying | `phase:specifying` |
| `/speckit-clarify` round in flight | Planned | Clarifying | `phase:clarifying` |
| Round ratified | Planned | Ratified | `phase:ratified` |
| `/speckit-plan` ran | Started | Planning | `phase:planning` |
| `/speckit-tasks` ran | Started | Tasking | `phase:tasking` |
| `/speckit-red-team` ran | Started | Red-team | `phase:red-team` |
| Implementation in flight | Started | Implementing | `phase:implementing` + `wave:W3` etc. |
| `/speckit-analyze` ran | Started | Analyzing | `phase:analyzing` |
| Ready for un-draft | Started | Ready-to-merge | `phase:ready-to-merge` |
| PR merged | Completed | Merged | (phase label cleared) |

### Sync mechanism — reconcile, not push-per-event

Critical design call. The skill is **reconcile-based**, not event-based.

- `.specify/extensions.yml` fires the same skill (`speckit.linear.sync`) on every `after_*` hook
- The skill reads the filesystem state of `specs/NNN-feature/` and pushes whatever Linear needs to match
- Idempotent, resumable, recovers from any missed hook
- Same architectural pattern as `project-arc decisions apply` (design-by-batch)
- Filesystem is source-of-truth; Linear is the mirror

### Multi-workspace strategy

The operator may have 1 Linear workspace per GitHub repo (b9-backend → BLOK9 workspace, future projects → other workspaces).

- **No runtime workspace switching needed.** Per-repo binding.
- Each repo ships its own `.mcp.json` at the repo root. Claude Code reads project-scoped `.mcp.json` automatically.
- Each `.mcp.json` points to the official Linear MCP (`https://mcp.linear.app/sse`, OAuth-based) for that workspace.
- No `LINEAR_TOKEN` env file management. OAuth handles auth.

### Linear MCP choice

- **Official Linear MCP** (`mcp-remote https://mcp.linear.app/sse`) — preferred. OAuth, centrally hosted, auto-updates.
- **Fallback: `dvcrn/mcp-server-linear`** — only if official MCP lacks needed capabilities. Supports multi-workspace via `TOOL_PREFIX` (not needed for per-repo binding model).

### Scope deferred

- **Bidirectional sync from Linear → filesystem.** Out of scope. Filesystem is source-of-truth; Linear changes don't write back.
- **Auto-PR creation from tracker Issue.** Out of scope. PR creation stays a human action.

## Open questions for clarify round

1. **Full task mirror vs wave-only mirror?** A spec like 003 produced 85 task Issues if we mirror everything, or ~9 wave Issues if we roll up. Operator usage pattern unclear — recommend resolving via dogfooding both on one spec.
2. **Linear MCP capability coverage.** Must verify official Linear MCP supports: create/update Project, create/update Issue, attach Issue to milestone, set blocking relations, set Project Status, add/remove labels, post comments. 30-min validation task before committing to the official MCP. If gaps, fall back to `dvcrn/mcp-server-linear` or direct GraphQL via a `scripts/linear-api.ts` (pattern from `twanahc/claude-linear-skill`).
3. **Workspace seed CLI scope.** A `speckit-linear seed-workspace` command that creates the `phase:*` labels, `wave:*` labels, custom workflow states for tracker Issues. Run once per Linear workspace, before any sync. Should it accept a Team UUID arg, or create a "speckit" Team?
4. **How does sync detect "current phase" when artifacts already exist?** E.g. spec 003 is already merged. When the sync skill is run for the first time against an already-complete spec, it should reconcile to "merged" state. Detection logic: which artifacts exist? Is there a `*.draft` marker? Is the PR open or merged? Git history?
5. **Ratification marker.** How does the sync skill know clarify round N has been ratified vs is still in flight? Operator-idle window auto-ratification (from BLOK9 session) muddies this. Candidate: a `RATIFIED` marker line in spec.md's Clarifications section, or a `.specify/ratifications.yml` file.
6. **Task dependency parsing.** Tasks files often encode deps via `[T003-013, T003-014]` style markers in the task header. Parser needs to handle the canonical format and emit Linear blocking relations.

## Reference repos / prior art

- [tim-mcdonnell/spec-kit-linear](https://github.com/tim-mcdonnell/spec-kit-linear) — fork of spec-kit for Linear. Single-workspace assumption baked in. Useful for label/milestone conventions.
- [dvcrn/mcp-server-linear](https://github.com/dvcrn/mcp-server-linear) — community MCP, multi-workspace via TOOL_PREFIX. Fallback if official MCP has gaps.
- [twanahc/claude-linear-skill](https://github.com/twanahc/claude-linear-skill) — skill-based Linear orchestrator with subagents. Reference for skill architecture, not for our use directly.
- [wrsmith108/linear-claude-skill](https://github.com/wrsmith108/linear-claude-skill) — generic Linear issue management skill.
- [Linear MCP docs](https://linear.app/docs/mcp) — official server reference.

## Suggested kickoff for the new session

```
Read BRIEF.md for full context. Then drive the spec-kit lifecycle on this
repo's first spec (001-spec-kit-linear-bridge):

1. Run `spec-kit init` to scaffold .specify/
2. /speckit-specify "spec-kit ↔ Linear bridge — see BRIEF.md for the design"
3. /speckit-clarify — work through the 6 open questions in BRIEF.md § "Open questions for clarify round"
4. Standard lifecycle from there

Pre-clarify task: 30-min validation that the official Linear MCP covers
the capabilities listed in open question #2. If gaps, the bridge needs to
fall back to dvcrn's MCP or direct GraphQL — that changes the plan.

Note: this repo dogfoods spec-kit but CANNOT dogfood itself on spec 001
(chicken-and-egg — the bridge it produces is what would sync 001 to Linear).
Spec 002 onwards can dogfood the bridge.
```

## Expected first-pass deliverables

- `speckit-linear-sync` skill at `skills/speckit-linear-sync/SKILL.md`
- `scripts/linear-sync.ts` (or `.py`) — the actual reconcile logic
- `templates/extensions.yml` — drop-in for each consuming repo's `.specify/`
- `templates/mcp.json` — drop-in for each consuming repo root
- `bin/speckit-linear` CLI with `init` + `seed-workspace` subcommands
- `plugin.json` — Claude Code plugin manifest
- Working dogfood on at least 1 spec in 1 consuming repo (b9-backend most likely)

Once first-pass works and the operator validates on a real spec, install it locally (`~/.claude/plugins/`) and start using from BLOK9 sessions for production specs.

## Out-of-scope for first pass (deferred)

- Plugin marketplace listing / public release
- Project-arc ADR 0007 — author only once the bridge is installed and battle-tested
- Multi-Linear-workspace-per-repo (e.g. mirroring one spec into two workspaces)
- Linear → filesystem reverse sync
- Auto-PR-creation
- Auto-un-drafting of PRs based on Linear state
