# Linear MCP runtime probe — 2026-05-28

Resolves the inferred tool names in
`validation/linear-mcp-tool-signatures.md` against the live Linear MCP
server (`https://mcp.linear.app/mcp`) via a `tools/list` JSONRPC call.

## Path attempted

**Path 1 used (preferred).** `mcp-remote` 0.1.37 was available via
`npx`; cached OAuth credentials at
`~/.mcp-auth/mcp-remote-0.1.37/fcc436b0d1e0a1ed9a2b15bbd638eb13_*` were
recognised (MD5 of `https://mcp.linear.app/mcp`). Although the cached
access token had expired (issued 2026-05-06, 24-h TTL), `mcp-remote`
silently refreshed it using the cached refresh token and connected via
StreamableHTTPClientTransport. No browser flow triggered.

Probe driver: send `initialize` + `notifications/initialized` +
`tools/list` over stdio to `npx mcp-remote https://mcp.linear.app/mcp
--transport http-only`, kill after 25 s. Captured server response with
35 tool definitions and full JSONSchemas.

Path 2 (GraphQL introspection) was not needed for MCP surface
confirmation. It remains the only route for the two confirmed gaps
(workflow-state creation, project-update creation).

## Server identity (from `initialize` reply)

```json
{
  "protocolVersion": "2025-03-26",
  "capabilities": {"tools": {"listChanged": true}},
  "serverInfo": {
    "name": "Linear MCP",
    "title": "Linear",
    "version": "1.0.0",
    "websiteUrl": "https://linear.app"
  }
}
```

## Full live tool catalogue (35 tools)

`get_attachment`, `prepare_attachment_upload`,
`create_attachment_from_upload`, `create_attachment` (deprecated),
`delete_attachment`, `list_comments`, `save_comment`, `delete_comment`,
`list_cycles`, `get_document`, `list_documents`, `save_document`,
`extract_images`, `get_issue`, `list_issues`, `save_issue`,
`list_issue_statuses`, `get_issue_status`, `list_issue_labels`,
`create_issue_label`, `list_projects`, `get_project`, `save_project`,
`list_project_labels`, `get_diff`, `list_diffs`, `get_diff_threads`,
`list_milestones`, `get_milestone`, `save_milestone`, `list_teams`,
`get_team`, `list_users`, `get_user`, `search_documentation`.

The validation report estimated 28-31 tools; live count is 35. The
Fiberplane/Speakeasy catalogues are stale.

## Major architectural delta from the validation report

The live server uses **unified `save_*` mutations** (`save_issue`,
`save_project`, `save_comment`, `save_milestone`, `save_document`). The
validation report's claim ("there is **no** unified `save_issue`
mutation — create and update are split") is **wrong**. Behaviour:

> If `id` is provided, updates the existing item; otherwise creates
> a new one.

No standalone `create_issue` / `update_issue` / `create_project` /
`update_project` / `update_project_milestone` tools exist.

Argument naming uses **human-friendly identifiers**, not raw UUID
fields. The MCP resolves names → IDs server-side. Examples:
`team` (not `teamId`), `project` (not `projectId`), `state` (not
`stateId`/`statusId`), `assignee` (not `assigneeId`), `lead` (not
`leadId`), `milestone` (not `projectMilestoneId`). UUIDs are still
accepted; names/slugs/emails work too.

## Previously "needs runtime probe" / "outstanding unknowns" — resolutions

### A. Parameter casing on `update_issue` for `projectMilestoneId`

**Confirmed at runtime: NO (replaced by different shape).** The
field on `save_issue` is `milestone` (string: name or ID), not
`projectMilestoneId`. There is no `update_issue` endpoint.

```json
"milestone": {
  "description": "Milestone name or ID",
  "type": "string"
}
```

### B. `create_comment` accepts `projectId` / `projectUpdateId`?

**Confirmed at runtime: YES, with broader scope.** The tool is
`save_comment` (not `create_comment`). It accepts five mutually
exclusive parents and confirms project comments are first-class:

```json
"properties": {
  "id":           {"type": "string", "description": "Comment ID. If provided, updates the existing comment"},
  "issueId":      {"type": "string"},
  "projectId":    {"type": "string"},
  "initiativeId": {"type": "string"},
  "documentId":   {"type": "string"},
  "milestoneId":  {"type": "string"},
  "parentId":     {"type": "string"},
  "body":         {"type": "string", "description": "Content as Markdown"}
},
"required": ["body"]
```

Note: no `projectUpdateId` field exposed at the MCP layer — the
GraphQL schema has it but the MCP surface omits it. Project Update
comments are not reachable via MCP.

### C. Per-mutation sub-rate-limits

**NOT TESTABLE via introspection.** Only discoverable from response
headers on real mutations. Out of scope for read-only probe.

## Capability matrix — previously "unverified" items

### Capability 1 — Create/update Project

**Confirmed at runtime: YES (different shape than report).**

```json
"save_project": {
  "required_for_create": ["name", "addTeams OR setTeams"],
  "fields": {
    "id":                   "string (update path)",
    "name":                 "string",
    "icon":                 "string (emoji)",
    "color":                "string (hex)",
    "summary":              "string (<=255 chars)",
    "description":          "string (markdown)",
    "state":                "string (name/type/ID — was statusId)",
    "startDate":            "string (ISO)",
    "startDateResolution":  "halfYear|month|quarter|year",
    "targetDate":           "string (ISO)",
    "targetDateResolution": "halfYear|month|quarter|year",
    "priority":             "integer 0..4",
    "addTeams":             "string[] (names/IDs)",
    "removeTeams":          "string[]",
    "setTeams":             "string[] (replace)",
    "labels":               "string[] (names/IDs)",
    "lead":                 "string|null (user id/name/email/me)",
    "addInitiatives":       "string[]",
    "removeInitiatives":    "string[]",
    "setInitiatives":       "string[]"
  }
}
```

Deltas vs. report: `state` replaces `statusId`; `lead` replaces
`leadId`; `addTeams`/`removeTeams`/`setTeams` triad replaces
`teamIds`; `addInitiatives`/`removeInitiatives`/`setInitiatives`
triad added; new fields `summary`, `icon`, `color`, `startDate`,
`*DateResolution`, `priority`; no `milestones` nested-create field
(use separate `save_milestone` calls).

### Capability 2 — Create/update Issue in a Project

**Confirmed at runtime: YES (different shape than report).**

```json
"save_issue": {
  "required_for_create": ["title", "team"],
  "fields": {
    "id":          "string (update path; accepts UUID or LIN-123)",
    "title":       "string",
    "description": "string (markdown)",
    "team":        "string (name or ID)",
    "cycle":       "string (name/number/ID)",
    "milestone":   "string (name or ID)",
    "priority":    "number 0..4",
    "project":     "string (name/ID/slug)",
    "state":       "string (state type, name, or ID)",
    "assignee":    "string|null (id/name/email/me)",
    "delegate":    "string|null (agent name/ID; Linear agent name = 'Linear')",
    "labels":      "string[]",
    "dueDate":     "string (ISO)",
    "parentId":    "string|null (LIN-123 ok)",
    "estimate":    "number",
    "links":       "array<{url,title}> (append-only attachments)",
    "blocks":      "string[] (append-only)",
    "blockedBy":   "string[] (append-only)",
    "relatedTo":   "string[] (append-only)",
    "duplicateOf": "string|null",
    "removeBlocks":     "string[]",
    "removeBlockedBy":  "string[]",
    "removeRelatedTo":  "string[]"
  }
}
```

Deltas vs. report: `team` (not `teamId`); `project` (not `projectId`);
`milestone` (not `projectMilestoneId`); `state` (not `stateId`);
`assignee` (not `assigneeId`); `labels` (not `labelIds`); `cycle` (not
`cycleId`); new top-level relation fields (see Capability 4 below).
A `delegate` field exists for Agent assignment — passing the literal
string `"Linear"` invokes Linear's built-in agent.

### Capability 3 — Attach Issue to Project Milestone

**Confirmed at runtime: YES.** `save_issue.milestone` (name or ID).
Validation report's claim that the field is `projectMilestoneId` is
incorrect at the MCP layer; that name only exists in the GraphQL
schema, where the MCP server translates it.

### Capability 4 — Blocks / blocked-by relations

**Confirmed at runtime: YES, NATIVELY SUPPORTED. No GraphQL fallback
needed.** The validation report flagged this as "GAP. No MCP tool."
The live `save_issue` tool exposes four relation arrays plus
remove-counterparts:

```json
"blocks":      "string[] — issue IDs/identifiers this blocks. Append-only",
"blockedBy":   "string[] — issue IDs/identifiers blocking this. Append-only",
"relatedTo":   "string[] — related issue IDs/identifiers. Append-only",
"duplicateOf": "string|null — duplicate of issue ID/identifier",
"removeBlocks":     "string[]",
"removeBlockedBy":  "string[]",
"removeRelatedTo":  "string[]"
```

`issueRelationCreate` GraphQL fallback is **no longer required**.
Implication for bridge: drop the `@linear/sdk` dependency for
relations; everything goes through `save_issue` calls. Idempotency
trade-off: arrays are append-only with no `id` field per relation, so
the bridge must dedupe by reading current relations via `get_issue`
before each save. There is no documented unique-relation guarantee
from the MCP; if double-call risk matters, retain `issueRelationCreate`
with a deterministic `id` as a belt-and-braces option.

### Capability 5 — Set Project Status

**Confirmed at runtime: YES, simpler than report claims.**
`save_project.state` accepts a string (state type, name, or ID). The
validation report's two-step dance (call `list_project_statuses`, map
to UUID, then call `update_project` with `statusId`) is unnecessary —
pass the human-readable status name (e.g. `"Started"`) directly to
`save_project.state` and the MCP resolves it. There is no
`list_project_statuses` tool in the live catalogue, which matches:
status resolution is server-side.

```json
"state": {
  "description": "Project state",
  "type": "string"
}
```

Same field is available as a filter on `list_projects.state`.

### Capability 6 — Labels on Projects & Issues

**Partially confirmed at runtime.**

| Sub-capability | Result | Tool |
|---|---|---|
| List project labels | YES | `list_project_labels` (filter by name, paginated) |
| List issue labels | YES | `list_issue_labels` |
| Create issue label | YES | `create_issue_label(name, description?, color?, teamId?, parent?, isGroup?)` |
| Create project label | **NO** | No `create_project_label` or `save_project_label` tool exists |
| Assign labels on issue | YES | `save_issue.labels: string[]` (names/IDs) |
| Assign labels on project | YES | `save_project.labels: string[]` |

Bridge gap: creating new project labels requires GraphQL
(`projectLabelCreate`). Existing project labels are fully assignable
via MCP by name.

### Capability 7 — Comments on Projects & Issues

**Confirmed at runtime: YES.** See section B above. Tool is
`save_comment`, not `create_comment`/`projectCommentCreate`. Accepts
`issueId`, `projectId`, `initiativeId`, `documentId`, `milestoneId` as
parent (exactly one). `projectUpdateId` is NOT exposed at MCP layer
(GraphQL-only).

### Capability 8 — Create custom Workflow States

**Confirmed at runtime: NO (still a gap).** No `save_workflow_state`,
`create_workflow_state`, or similar tool in the live catalogue.
`list_issue_statuses(team)` and `get_issue_status(id|name|team)` exist
for reads only. Workflow-state creation remains a GraphQL fallback
(`workflowStateCreate`). The validation report's GraphQL schema for
that mutation is unchanged and still authoritative.

### Capability 9 — Create Project Milestones

**Confirmed at runtime: YES (different shape than report).**

```json
"save_milestone": {
  "required": ["project"],
  "required_for_create": ["project", "name"],
  "fields": {
    "project":    "string (name/ID/slug) — required",
    "id":         "string (update path)",
    "name":       "string",
    "description":"string",
    "targetDate": "string|null (ISO; null removes)"
  }
}
```

Deltas vs. report: `sortOrder` is NOT exposed (validation report
included it). No `update_project_milestone` — `save_milestone` with
`id` handles updates.

## Additional MCP-layer gaps discovered (not in original capability matrix)

1. **Project Updates** (the weekly project-status post type): no
   `save_project_update` / `create_project_update` tool. If the bridge
   needs to post project updates, GraphQL `projectUpdateCreate` is the
   only path.
2. **Comments on Project Updates**: `save_comment` lacks
   `projectUpdateId`. GraphQL fallback required if needed.
3. **Project labels**: `create_project_label` missing (see Capability 6).
4. **Issue relations with explicit IDs**: `save_issue.blocks` etc. do
   not return relation IDs; deletes use `removeBlocks` by issue ID, not
   relation ID. Most cases this is fine.

## Plan-time impact

### Assumptions in `linear-mcp-tool-signatures.md` now CONFIRMED

- Project description accepts markdown (`save_project.description`
  documented as Markdown).
- Issue can be attached to project milestone via a single field on the
  save mutation.
- Project status can be set via the project save mutation in one call.
- Project comments are MCP-native via the same comment tool as issue
  comments.
- Workflow-state creation is not in MCP; GraphQL fallback required.
- Idempotency-via-`id` strategy works (every `save_*` accepts `id`).

### Assumptions in `linear-mcp-tool-signatures.md` now INVALIDATED — bridge code must change before plan lock

1. **Tool names** — drop `create_issue` / `update_issue` /
   `create_project` / `update_project` / `create_comment` /
   `create_project_milestone` / `update_project_milestone`. The live
   tools are `save_issue`, `save_project`, `save_comment`,
   `save_milestone`.
2. **Parameter naming** — drop the camelCase-ID convention
   (`teamId`, `projectId`, `stateId`/`statusId`, `assigneeId`,
   `leadId`, `cycleId`, `projectMilestoneId`, `labelIds`,
   `parentIssueId`). Live MCP uses friendlier names that accept
   name/ID/slug strings: `team`, `project`, `state`, `assignee`,
   `lead`, `cycle`, `milestone`, `labels`, `parentId` (parentId is the
   one exception, still suffixed).
3. **Capability 4 (blocks/blocked-by) is NOT a gap.** Remove the
   `@linear/sdk` requirement and `issueRelationCreate` GraphQL fallback
   from the design. Use `save_issue.blocks` /
   `save_issue.blockedBy`. Caveat on idempotency (append-only, dedupe
   client-side or fall back to GraphQL with deterministic `id` for
   guaranteed exactly-once).
4. **Capability 5 (project status) workflow is one-step**, not two.
   Drop the "cache workspace status map" requirement. Just pass the
   status name string.
5. **Tool count** is 35, not the 28-31 estimated.
6. **`save_project` requires `setTeams` OR `addTeams`** (array form);
   no scalar `teamIds` field exists.
7. **`save_milestone` does not expose `sortOrder`**; remove from any
   planned task payload.
8. **`save_project.summary`** is a separate 255-char field, distinct
   from `description`. The bridge may want to populate both.

### Assumptions still needing attention (not invalidated, but worth noting)

- **OAuth scope behaviour**: not introspectable via MCP. The validation
  report's scope recommendations remain advisory.
- **Rate-limit per-endpoint sub-limits**: still only discoverable at
  call time from response headers. Implement adaptive backoff.
- **Comment threading on project updates**: bridge cannot do it via
  MCP. Either route those calls through GraphQL `commentCreate` with
  `projectUpdateId`, or drop the requirement.
- **Creating project labels** at runtime requires GraphQL
  (`projectLabelCreate`). If the bridge only ever assigns existing
  project labels, ignore; if it provisions labels, add this to the
  GraphQL fallback list.

## Remaining unknowns

- Per-mutation sub-rate-limits (headers-only, runtime discovery).
- Whether `save_issue.blocks`/`blockedBy` writes are idempotent against
  re-runs with the same array (suspected append-with-dedupe but not
  documented; needs a write probe, out of scope here).
- Exact GraphQL mutation name and shape for project-label creation
  (likely `projectLabelCreate(input: ProjectLabelCreateInput!)`, not
  introspected here).
- Whether `delegate: "Linear"` requires any extra workspace install
  step before the agent will pick up the assignment.

## Reproducer

```bash
# Requires cached OAuth at ~/.mcp-auth/mcp-remote-*/...
(
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0.1"}}}'
  sleep 3
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
  sleep 1
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  sleep 8
) | npx -y mcp-remote https://mcp.linear.app/mcp --transport http-only
```
