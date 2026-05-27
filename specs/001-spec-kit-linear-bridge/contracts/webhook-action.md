# GitHub Action Contract (`speckit-linear-sync.yml`)

**Status**: Phase 1 contract. Documents the input/output surface
of the Layer E webhook (per Principle III, layered idempotency).
The Action's reference implementation lives in
`validation/github-action-mechanics.md`; this file is the locked
contract every implementer + reviewer relies on.

**Constitutional anchor**: Principle III requires strict
write-domain separation between Layer D (reconcile, see
`command-shapes.md`) and Layer E (this Action). The Action's
**single permitted Linear mutation** is `issueUpdate` flipping
ONLY `stateId` on a spec Issue. Everything else — labels,
descriptions, comments, sub-issues, project status, archives — is
forbidden territory. Reviewer verification at PR time catches any
drift.

**FRs implemented**: FR-027, FR-028, FR-029, FR-030, FR-032.

---

## 1. Trigger

```yaml
on:
  pull_request:
    types: [opened, ready_for_review, closed]
```

The three event types are locked by FR-027:

| GitHub event | Linear target state | Rationale |
|---|---|---|
| `opened` | `ready_to_merge` | PR exists; spec is "review-ready" |
| `ready_for_review` | `ready_to_merge` | PR un-drafted; same semantic |
| `closed` (with `merged: true`) | `merged` | PR landed on default branch |

**Filter for merged-only closes** (action mechanics §1):

```yaml
jobs:
  sync-linear:
    if: >
      github.event.action != 'closed' ||
      github.event.pull_request.merged == true
```

This drops close events where the PR was abandoned (merged
false). Drop-closed PRs intentionally leave Linear at its
last-known state; the operator can manually flip via `/speckit-linear-push`
from any worktree if they want to mark the spec cancelled — that
gesture is Layer D's responsibility, not the Action's.

**Intentionally excluded event types** (action mechanics §1):

- `synchronize` — Layer D handles mid-PR commits.
- `reopened` — does not change phase semantics; Layer D handles.
- `edited`, `assigned`, `review_requested`, etc. — unrelated to
  lifecycle phase.

**Non-feature branches**: if the PR's `head.ref` does not match
the canonical `<NNN>-…` pattern, the Action exits cleanly with
`skip=true` per the reference YAML. This avoids spurious failure
on Dependabot / chore PRs.

---

## 2. Permissions

```yaml
permissions:
  contents: read
```

**Exactly one scope. Every other permission OMITTED.**

Per `validation/github-action-mechanics.md` §2 and GitHub's
hardening guidance, the Action requires only `contents: read` for
`actions/checkout@v4` to clone the repo (so the runner can read
`.specify/extensions/linear/linear-config.yml`).

**The Action does NOT call any GitHub API.** It writes nothing to
the PR, the repo, the Issues, or the Actions log other than its
own step output. All writes go to Linear via
`LINEAR_API_TOKEN`. Tight scoping per Principle III.

**Forbidden by Principle III** (would expand the write domain):

- `pull-requests: write` — would let the Action comment on PRs.
- `issues: write` — would let the Action create GitHub Issues.
- `contents: write` — would let the Action push commits.
- `id-token: write` — would let the Action mint OIDC tokens.

Adding any of these requires a constitutional amendment and a
spec revision.

---

## 3. Secrets

### 3.1 The single secret

```yaml
env:
  LINEAR_API_TOKEN: ${{ secrets.LINEAR_API_TOKEN }}
```

- **Name**: `LINEAR_API_TOKEN` (locked by FR-029 — config schema
  treats this as a `const`).
- **Scope**: GitHub repository secret. Per-repo, not org-wide
  (operator may have multiple repos with different Linear
  workspaces; FR-019).
- **Value**: A Linear personal API key (`lin_api_…`) OR a Linear
  machine-user account's token. FR-029 permits both; the bridge
  documents the trade-off but does not enforce a choice.

### 3.2 Provisioning steps (exact, verbatim in install output)

Per `validation/github-action-mechanics.md` §2 and FR-029, the
bridge's `speckit.linear.install` command surfaces these three
steps:

```bash
# 1. Visit Linear API settings:
#    https://linear.app/settings/api
#    Create new personal API key, suggested name: speckit-linear-sync
#    Copy the token (starts with `lin_api_`).

# 2. Decide token scope:
#    - Personal key:    full workspace access (simplest, ties to operator account)
#    - Machine-user:    dedicated bot Linear account (recommended for shared / OSS repos)

# 3. Set the secret on the consumer repo:
gh secret set LINEAR_API_TOKEN -R <owner>/<repo>
# (paste token when prompted)
```

**The bridge MUST NOT perform step 3** (FR-029). Token handling
stays in the operator's hands. The install command merely prints
the three steps and verifies the secret's *presence* via
`gh secret list -R <repo> | grep LINEAR_API_TOKEN` after the
operator confirms they've set it.

### 3.3 Wire format

Per Linear's GraphQL docs (and `validation/github-action-mechanics.md`
§2), the HTTP header is:

```http
Authorization: <token>
Content-Type: application/json
```

**NO `Bearer` prefix.** Raw token only. This is the one detail
implementers most often get wrong — Linear's docs are specific.

---

## 4. Inputs

The Action reads exactly two inputs per fire:

### 4.1 PR metadata (from GitHub event payload)

```yaml
env:
  HEAD_REF: ${{ github.event.pull_request.head.ref }}
  ACTION:   ${{ github.event.action }}
```

- `HEAD_REF` — the PR's source branch name. Used to extract the
  feature number via the regex `^([0-9]{3,})-`, per FR-028. Branches
  not matching this pattern cause clean skip (§1).
- `ACTION` — `opened`, `ready_for_review`, or `closed`. Maps to
  target Linear state per §1.

`github.event.pull_request.merged` is also read in the top-level
`if:` filter (§1) to gate `closed` events to merged-only.

### 4.2 Per-repo config (from `actions/checkout@v4`)

```yaml
steps:
  - uses: actions/checkout@v4
  - name: Read linear-config.yml
    run: |
      CFG=.specify/extensions/linear/linear-config.yml
      [[ -f "$CFG" ]] || { echo "::error::$CFG missing"; exit 1; }
      PID=$(yq -r '.linear.project.id' "$CFG")
      TID=$(yq -r '.linear.team.id'    "$CFG")
      RTM=$(yq -r '.linear.workflow_state_uuids.ready_to_merge' "$CFG")
      MRG=$(yq -r '.linear.workflow_state_uuids.merged'         "$CFG")
```

- **File path**: `.specify/extensions/linear/linear-config.yml`,
  per the locked layout in `extension.yml` `provides.config`.
- **Fields read**:
  - `linear.project.id` — Project UUID (FR-002).
  - `linear.team.id` — Team UUID (FR-002).
  - `linear.workflow_state_uuids.ready_to_merge` (FR-032).
  - `linear.workflow_state_uuids.merged` (FR-032).
- **Tool**: `yq` (preinstalled on `ubuntu-latest`). For
  self-hosted runners, pin `mikefarah/yq-action` per the action
  mechanics §4 Open Question 2.

### 4.3 Departure from reference YAML

`validation/github-action-mechanics.md` §1 shows a reference YAML
that reads `.project_id` and `.team_id` as TOP-LEVEL scalars and
looks up workflow states by NAME at runtime. **The locked
contract is different on both counts**:

- Config fields are nested under `linear.*` per
  `contracts/config-schema.json`.
- Workflow-state lookup is by UUID from
  `linear.workflow_state_uuids.*` per FR-032 — NOT by name.

The reference YAML predates FR-032's lock-in; the shipped
`templates/github-action.yml` MUST follow this contract, not the
reference verbatim.

---

## 5. Outputs

### 5.1 The single Linear mutation

```graphql
mutation FlipSpecIssueState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
  }
}
```

- **One mutation per fire.** No exceptions.
- **`input` contains ONLY `stateId`.** Per Principle III, the
  Action MUST NOT pass `labels`, `description`, `assigneeId`,
  `comments`, or any other field. Reviewer verifies.
- **`stateId`** is read from `linear.workflow_state_uuids.ready_to_merge`
  or `linear.workflow_state_uuids.merged` per §1's mapping table.

### 5.2 Spec Issue identity lookup (read query, not a mutation)

Before issuing the mutation, the Action queries:

```graphql
query LocateSpecIssue($label: String!, $project: ID!) {
  issues(
    filter: {
      labels:  { name: { eq: $label } }
      project: { id:   { eq: $project } }
    }
    orderBy: updatedAt
  ) {
    nodes { id updatedAt }
  }
}
```

Per FR-004b, identity is `speckit-spec:NNN` (where NNN comes
from `HEAD_REF`) within the repo's Linear Project. Multi-match
race resolution: most-recent `updatedAt` wins; the Action does
NOT archive losers (Layer D's responsibility per Principle III).

### 5.3 Structured log output

The Action emits one of these stderr lines per fire (preserves
the GitHub Actions log conventions: `::error::`, `::warning::`):

| Outcome | Log line |
|---|---|
| Success | `Flipped <issue-id> -> <target-state>` |
| No spec Issue found | `::warning::No Issue for speckit-spec:NNN in project <UUID>. Layer D will create it.` |
| Multiple matches | `::warning::Multiple matches for speckit-spec:NNN; using <issue-id>.` |
| Branch not a spec branch | `Branch '<head-ref>' is not a spec-kit feature branch. Skipping.` |
| Config missing | `::error::.specify/extensions/linear/linear-config.yml missing` |
| Token missing | `::error::LINEAR_API_TOKEN missing. Run: gh secret set LINEAR_API_TOKEN -R <owner>/<repo>` |
| State UUID missing | `::error::State <key> UUID missing in config — run /speckit-linear-seed` |
| GraphQL failure | `::error::issueUpdate failed: <response-body>` |

No annotations on PRs, no PR comments, no labels touched on the
PR or the GitHub Issue surface. Per Principle III.

### 5.4 What the Action NEVER does

- Create PR comments (`pull-requests: write` is denied).
- Add labels to the GitHub PR or Issue.
- Update the spec Issue's description, assignee, project, or any
  field other than `stateId`.
- Create / update / archive sub-issues.
- Post comments to the Linear spec Issue.
- Mutate the Linear Project Status.
- Archive race-duplicate Issues (Layer D handles).
- Touch `.specify/extensions/linear/linear-config.yml`.

---

## 6. Failure modes

| Failure | Action behaviour | What the operator sees | Recovery |
|---|---|---|---|
| `LINEAR_API_TOKEN` missing | Step exits 1 with `gh secret set` hint | Red check on PR; error in Actions log | Set the secret + re-run job; Layer D fills gap until then (FR-030) |
| Token expired / revoked (401) | `curl` non-zero, step exits 1 | Red check; "401 Unauthorized" in log | Rotate token in Linear, update secret via `gh secret set`, re-run job |
| `linear-config.yml` missing on the checked-out commit | Step exits 1 with config path in error | Red check; "$CFG missing" in log | Re-run `speckit.linear.install` locally, commit `linear-config.yml`, re-trigger PR event |
| `linear.workflow_state_uuids.<key>` missing or zero | Step exits 1, points at `/speckit-linear-seed` | Red check; "State <key> UUID missing" in log | Run seed locally, commit updated config, re-trigger |
| No Issue matches `speckit-spec:NNN` | `::warning::`, exits 0 cleanly | Green check with warning annotation | Layer D will create the Issue on next `push`; subsequent PR events will flip it correctly |
| Multiple Issues match (race) | Most-recent `updatedAt` wins, `::warning::`, exits 0 | Green check with warning | Layer D archives extras per FR-004b on next `push` |
| Target state UUID points at deleted state | Step exits 1 with "STATE_NOT_FOUND" Linear error | Red check; GraphQL error body in log | Run `/speckit-linear-seed --force` to recreate (rare); operator must update config |
| Linear 5xx / network failure | Step exits 1 | Red check; raw GraphQL response in log | Re-run job manually OR wait for next Layer D `push` — both converge per FR-030 |
| Branch doesn't match `<NNN>-…` | Skip cleanly, exit 0 | Green check with "Skipping" note | None — expected for non-spec PRs (chore branches etc.) |
| GitHub Actions disabled on repo (org policy) | Workflow never fires | No checks appear on PRs | Layer D handles merged detection via `gh`/git fallback per FR-013; bridge degrades gracefully (no broken state) |
| `merged: false` close event | Top-level `if:` filters out; no job runs | No check on the PR for that event | None — correct; drop-closes intentionally leave Linear unchanged |
| Token rotated but secret stale | Same as "Token expired" | Red check on subsequent PR events | Update secret; Layer D fills the gap in the meantime |

Per the spec.md edge case "GitHub Action's Linear API token has
been rotated or removed but the secret hasn't been updated", the
bridge does NOT signal webhook breakage in-band. Operators
discover broken webhooks by seeing red Action runs in GitHub.
Layer D's reconciliation continues to converge Linear correctly
in the meantime per FR-030.

---

## 7. Idempotency

Per FR-030 and Principle III, the Action and Layer D MUST be
independently idempotent and convergent.

### 7.1 Re-firing on the same event

GitHub may re-deliver `pull_request` events on retry. The Action
handles this naturally:

- The identity lookup (§5.2) is deterministic — same label, same
  project → same Issue.
- `issueUpdate(id: $i, input: { stateId: $s })` with the same
  `$s` is a no-op when the Issue is already in that state. Linear
  returns `success: true` without producing an activity-log entry
  (per `linear-mcp-tool-signatures.md` §5 — `save_*` mutations
  short-circuit on unchanged input).

Therefore: firing twice on the same event produces the same
Linear state. Firing the Action AND running `push` from a Layer D
worktree produces the same Linear state. Firing the Action,
running `push`, then firing the Action again still produces the
same Linear state.

### 7.2 Reconcile-after-webhook

A common sequence:

1. PR opens at `T=0`. Action fires, flips spec Issue to
   `ready_to_merge`. Layer E done.
2. Operator runs `/speckit-implement` at `T=10s`. The
   `after_implement` hook fires `push`. Layer D re-derives state
   from filesystem (still implementing-ish on disk — PR open but
   not merged) and may attempt to flip back to `implementing`.

**Resolution per FR-014/FR-030**: Layer D's `push` consults
`gh pr view --json mergedAt,isDraft` to detect "PR open, not
merged, not draft" and computes target state `ready_to_merge` —
matching what the Action already wrote. No churn. If `gh` is
absent, Layer D falls back to branch reachability and may compute
`implementing` instead; that's the documented degradation per
FR-030 last sentence.

### 7.3 Webhook-only repos

If the operator declines the Action install (FR-027 — opt-in), or
the repo has Actions disabled, Layer D alone is sufficient (SC-011).
Reconcile picks up merged state via `gh pr view` (or branch
reachability) and flips Linear correctly on the next sync. The
Action is a real-time accelerator (SC-010 — under one minute) but
never a correctness dependency.

---

## 8. Reference YAML

The reference implementation lives at
`/Users/ashbrener/Code/AI/speckit-linear/validation/github-action-mechanics.md`
§1. The shipped `templates/github-action.yml` MUST:

1. Match the reference YAML's overall structure (`on:`,
   `permissions:`, three-step job).
2. **Diverge** on config-read paths to use the locked nested
   schema (`linear.project.id`, `linear.team.id`,
   `linear.workflow_state_uuids.*`) per `contracts/config-schema.json`.
3. **Diverge** on state lookup to use UUIDs from config per
   FR-032, NOT runtime name lookup against Linear.
4. Preserve the reference's clean-skip behaviour on non-feature
   branches.
5. Preserve the reference's `if: merged == true` filter on
   `closed` events.

A future revision MAY add:

- `concurrency: { group: speckit-linear-${{ github.event.pull_request.number }}, cancel-in-progress: false }`
  per action mechanics §4 Open Question 4. TBD pending decision
  on whether `opened → ready_for_review` races are observed in
  practice.

A future revision MUST NOT add:

- Any field to `issueUpdate.input` other than `stateId`.
- Any GitHub API call.
- Any `permissions:` entry beyond `contents: read`.

These are constitutional invariants per Principle III.

---

## 9. Verification checklist (for PR reviewers)

When reviewing changes to `templates/github-action.yml`,
reviewers MUST confirm:

- [ ] `permissions:` block contains exactly `contents: read`.
- [ ] No GitHub API calls (no `gh` CLI calls, no `curl https://api.github.com`).
- [ ] No `pull-requests:` or `issues:` permission scopes.
- [ ] The only Linear mutation is `issueUpdate` with `input: { stateId: ... }`.
- [ ] No fields other than `stateId` appear in any `input:` object.
- [ ] `LINEAR_API_TOKEN` is read from `secrets.*`, never
      hardcoded or echoed.
- [ ] Wire format is `Authorization: <token>` — no `Bearer` prefix.
- [ ] Config reads use the nested `linear.*` paths per
      `contracts/config-schema.json`.
- [ ] Workflow-state lookups use UUIDs from
      `linear.workflow_state_uuids.*`, never name lookups.
- [ ] Branch regex matches `^([0-9]{3,})-`.
- [ ] `if: merged == true` filter is present on the job.
- [ ] No PR comment, label, or annotation calls.

Any one of these failing is grounds for blocking the PR.

---

## 10. TBDs

- **Concurrency group** (§8) — decide based on observed race
  behaviour. Reference YAML omits.
- **Self-hosted runner yq fallback** (action mechanics §4 Open
  Question 2) — pin `mikefarah/yq-action` if self-hosted support
  is required; v1 targets `ubuntu-latest` only.
- **Label filter shape** (`labels: { name: { eq } }` vs
  `labels: { some: { name: { eq } } }`) — reference YAML uses the
  flat form; live-tested against the workspace probe in
  `validation/linear-workspace-probe.md` before ship. TBD pending
  one-shot live verification.
