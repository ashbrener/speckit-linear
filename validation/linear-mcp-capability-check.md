# Linear MCP capability validation — 2026-05-27

Pre-clarify validation for spec 001-spec-kit-linear-bridge. Resolves BRIEF.md
open question #2.

## Verdict: YELLOW

The official Linear MCP server (`https://mcp.linear.app/mcp`, OAuth 2.1)
covers **7 of 9** required capabilities cleanly. Two confirmed gaps and three
unverified-but-likely items need either a thin GraphQL helper or a runtime
probe.

**Recommendation:** official MCP + a small Linear GraphQL adapter (~50 LOC)
for the named exceptions. Do **not** fall back to `dvcrn/mcp-server-linear` —
it offers strictly less than the official server (no project labels, no
Feb 2026 features, no project comments).

## Per-capability matrix

| # | Capability | Coverage | Path |
|---|---|---|---|
| 1 | Create/update Project with markdown description | YES (high confidence) | `create_project` / `update_project` |
| 2 | Create/update Issue in a Project | YES | `create_issue` / `update_issue` (or unified `save_issue`) |
| 3 | Attach Issue to Project Milestone | LIKELY YES — runtime probe | `update_issue` with `projectMilestoneId` |
| 4 | Blocks / blocked-by relations between Issues | **GAP** | GraphQL `issueRelationCreate` |
| 5 | Set Project Status enum (Planned/Started/…) | LIKELY YES — runtime probe | `update_project` with `state` |
| 6 | Add/remove labels on Projects & Issues | YES | Confirmed by Feb 2026 changelog |
| 7 | Comments on Projects & Issues | PARTIAL — Issues YES, Projects **GAP** | Substitute Project Updates (`projectUpdateCreate`) or GraphQL |
| 8 | Create custom Workflow States | **GAP** | GraphQL `workflowStateCreate` |
| 9 | Create Project Milestones | YES | Added in Feb 2026 changelog |

## Confirmed gaps requiring GraphQL fallback

1. `issueRelationCreate` — for blocks/blocked-by relations between task Issues
2. `workflowStateCreate` — for one-time creation of the per-spec tracker-Issue
   phases (Specifying / Clarifying / Ratified / Planning / Tasking / Red-team
   / Implementing / Analyzing / Ready-to-merge / Merged)
3. Project comments — if literal Project-comment objects are required (vs
   Project Updates as substitute)

## Items needing runtime probe before plan lock

- Does `update_project` accept the `state` enum mutation? (Required for phase
  → Project Status mapping.)
- Does `update_issue` accept `projectMilestoneId` for milestone attachment?
- Does the MCP description input actually render markdown? (Almost certain
  yes — Linear's Project description field is markdown-native.)

If any probe fails, the GraphQL adapter absorbs the gap; no architectural
rework needed.

## Architectural implication

The bridge's sync code has two backends:

- **Primary:** Linear MCP (OAuth, hosted, no key management)
- **Exception path:** `lib/linear-graphql.ts` (or `.py`) — a thin adapter
  using the Linear SDK with a personal OAuth token, scoped to the 2-3
  operations the MCP can't do

The exception adapter is invoked only for the named operations. The MCP
remains the default path for everything else.

## Sources verified

- https://linear.app/docs/mcp
- https://linear.app/changelog/2026-02-05-linear-mcp-for-product-management
- https://linear.app/changelog/2025-05-01-mcp
- https://github.com/dvcrn/mcp-server-linear (fallback comparison)
- https://www.morphllm.com/linear-mcp-server (tool catalogue)
- https://www.mcpbundles.com/blog/linear-mcp-server (tool catalogue)
- https://definable.ai/apps/linear/ (third-party wrapper — useful as
  contrast: 33 tools incl. `issueRelationCreate` and raw-query passthrough,
  signalling what the official MCP lacks)
- https://linear.app/docs/issue-relations
- https://linear.app/developers/graphql (confirms `issueRelationCreate` and
  `workflowStateCreate` exist in GraphQL)
