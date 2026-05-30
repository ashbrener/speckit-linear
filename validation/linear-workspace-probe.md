# Linear Workspace Probe — ACME

- **Probed**: 2026-05-27 (read-only)
- **Workspace**: ACME (urlKey `acme`, org UUID `c4e7538f-0c5d-4b12-b49b-24fa49875fba`)
- **Operator (viewer)**: `operator@example.com` (UUID `33333333-3333-4333-8333-333333333333`)
- **API key valid**: yes (token from `.env` authenticated successfully against `viewer`, `organization`, `teams`, `team(states/labels)`, `projects`)
- **Logo**: none set
- **Mutations performed**: zero — every call was a `query`

## Teams (1 of 1 returned, no pagination needed)

| Team UUID | Key | Name | Members | Description |
|---|---|---|---|---|
| `11111111-1111-4111-8111-111111111111` | `ACM` | ACME | 1 (operator only) | null |

The workspace contains exactly one team — `ACME` (issue-identifier prefix `ACM-`). It is the de-facto INFRA team for this operator.

## Workflow states on team `ACME`

| Position | Name | Type | Color | Description |
|---|---|---|---|---|
| 0 | Backlog | `backlog` | #bec2c8 | — |
| 1 | Todo | `unstarted` | #e2e2e2 | — |
| 2 | In Progress | `started` | #f2c94c | — |
| 3 | Done | `completed` | #5e6ad2 | — |
| 4 | Canceled | `canceled` | #95a2b3 | — |
| 5 | Duplicate | `duplicate` | #95a2b3 | — |

This is the stock Linear default state set. **None** of the nine spec-kit lifecycle phases (Specifying / Clarifying / Planning / Tasking / Red-team / Implementing / Analyzing / Ready-to-merge / Merged) exist yet.

### Gap vs spec lifecycle (per spec.md line 555)

All nine required states (`Specifying` backlog, `Clarifying`/`Planning`/`Tasking` unstarted, `Red-team`/`Implementing`/`Analyzing`/`Ready-to-merge` started, `Merged` completed) are missing. The existing `In Progress` (`started`) and `Done` (`completed`) types overlap semantically but name-mismatch the bridge's phase labels, so the seed should **create all nine** rather than rename. Leave `Backlog`/`Todo`/`In Progress`/`Done`/`Canceled`/`Duplicate` intact for non-speckit Issues — Linear permits >6 states per team.

## Labels on team `ACME`

| UUID | Name | Color | Parent |
|---|---|---|---|
| `f21e4c4c-…` | Feature | #BB87FC | — |
| `b4110aa7-…` | Improvement | #4EA7FC | — |
| `a073328f-…` | Bug | #EB5757 | — |

Three stock labels, no parents, no label groups. **Zero** match the bridge's conventions — no `phase:*`, no `task-phase:*`, no `speckit-spec:*`. Seed must create the nine `phase:*` labels plus the three parent groups (`phase`, `task-phase`, `speckit-spec`); the `task-phase:N` and `speckit-spec:NNN` children are minted lazily at sync time. Linear's `IssueLabel.parent` is singular (one level of nesting), which matches the design.

## Projects

`projects(first: 50)` returned an empty array. **No Linear Projects exist in this workspace at all.**

Implication: there is no pre-existing `spec-kit-linear`, `wingman`, or `a backend repo` Project to attach to. Every consumer repo (starting with this one) needs the bridge to either create a fresh Project on first sync or use a clearly named pre-existing one. Since none exist, **create-on-first-sync** is the only viable path right now.

## Concrete recommendations

1. **`team_id` for the dogfood `.specify/extensions/linear/config.yml`**: `11111111-1111-4111-8111-111111111111` (key `ACM`, name `ACME`). There is no choice — this is the only team. The bridge can resolve by either UUID or `teamKey: ACM`; UUID is more stable.

2. **Workflow states to create in seed (FR-021)** — all nine:
   `Specifying` (backlog), `Clarifying` (unstarted), `Planning` (unstarted), `Tasking` (unstarted), `Red-team` (started), `Implementing` (started), `Analyzing` (started), `Ready-to-merge` (started), `Merged` (completed). Leave existing Backlog/Todo/In Progress/Done/Canceled/Duplicate untouched.

3. **Labels to create in seed**:
   - Parent group `phase` + 9 children (`phase:specifying` … `phase:merged`).
   - Parent group `speckit-spec` (children minted per-feature at sync time).
   - Parent group `task-phase` (children minted per-spec-phase at sync time).
   - Leave Feature/Improvement/Bug alone.

4. **Project attachment**: no existing Project to reuse. The bridge's first sync for the `spec-kit-linear` repo should **create** a new Linear Project named e.g. `spec-kit-linear` and store its UUID in `.specify/extensions/linear/config.yml` (or a sibling `.specify/extensions/linear/.state.yml`) so subsequent syncs target it. Same pattern for every future consumer repo.

5. **Idempotency note for the seed implementer**: before creating each state/label, query existing ones by `name` on the team and skip on hit. The seed will be re-run by other operators against workspaces that may already have a partial setup.

## Open questions

- None blocking. (The `membersCount` field on `Team` does not exist in current Linear schema; I substituted `members { nodes { id } }` and counted nodes — non-mutating, single-member result trivially `1`.)
