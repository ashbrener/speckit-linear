# Quickstart: install and first sync

> Time required: ~10 minutes for the first repo; ~3 minutes for each
> subsequent repo (workspace already seeded).
>
> Audience: an operator who has a Linear workspace and a git repo
> with `specify init`'d spec-kit. The repo may be brand-new (zero
> specs) OR already in flight (specs at various lifecycle phases).

The bridge runs no daemon — every sync is a hook firing on a
`/speckit-*` command, a local git hook firing on `git checkout` /
`commit` / `merge`, or a GitHub Action firing on a PR event. See the
[README](../../README.md) for architecture and the [spec](./spec.md)
for the locked data model.

## Prerequisites

Front-run the checks the install ceremony will repeat (FR-018b):

```bash
bash --version | head -1   # >= 4.x — macOS ships 3.2, brew install bash
curl --version  | head -1
jq --version               # >= 1.6
git --version              # >= 2.30
gh --version               # optional but recommended (Layer D fidelity)
specify --version          # spec-kit itself, satisfies extension.yml requires
```

If you're on the Apple-shipped bash 3.2:

```bash
brew install bash   # then re-open your shell or prepend /opt/homebrew/bin to PATH
```

You also need:

- A **Linear workspace** plus a team where you can create Projects,
  Issues, labels, and workflow states. The dogfood workspace
  `OSH-INFRA` (team `OSH`, UUID
  `6ab43461-6d22-4f02-bb1e-0be9859c7997`) is the worked example
  below.
- A **personal Linear API key**
  ([linear.app/settings/api](https://linear.app/settings/api)) for
  the direct-GraphQL paths (seed, git hooks, the GitHub Action).
  The interactive MCP path uses OAuth and needs no key — see
  `.env.example` for which paths use which.
- (Optional) The **`LINEAR_API_TOKEN` GitHub repository secret** for
  Layer E. Step 6 covers the post-hoc setup if you skip it now.

## Step 1 — Install the extension in your consumer repo

```bash
cd path/to/your/consumer-repo
specify extension add linear   # copies the extension tree into .specify/extensions/linear/
/speckit-linear-install        # the load-bearing install ceremony — FR-018b
```

The install ceremony walks five sub-steps. Exact wording is pinned
by `commands/linear-install.md` — `[TBD by /speckit-tasks]` for any
prompt not yet locked.

1. **Dependency report.** A table of every dependency the bridge
   touches (`bash`, `curl`, `jq`, `git`, `gh`, the consumer
   `.mcp.json` entry, Linear MCP OAuth status, `.git/hooks/`
   writability) with green/yellow/red status and a copy-pasteable
   remediation per non-green row. The install refuses to proceed
   silently — missing `gh` either gets installed or you explicitly
   accept the degraded `Ready-to-merge` path before continuing.
2. **Team picker.** Auto-fills if exactly one team exists; otherwise
   prompts (default = team named "INFRA" or matching the workspace
   name). Non-interactive: `--team <UUID>`.
3. **Project picker.** Default is "create a new Project named after
   the repo directory". You can attach to an existing Project by
   UUID or rename. Non-interactive: `--project <UUID>` or
   `--auto-create`.
4. **Webhook offer.** Asks whether to drop
   `.github/workflows/speckit-linear-sync.yml` (Layer E). If you
   accept, it prints the exact
   `gh secret set LINEAR_API_TOKEN -R <owner>/<repo>` command and
   waits for you to confirm the secret before flipping
   `webhook.installed: true`.
5. **Local git hooks.** Drops `post-checkout`, `post-commit`, and
   `post-merge` into `.git/hooks/`, chaining onto any pre-existing
   hooks per FR-033. Unresolvable collisions are surfaced as an
   explicit choice, never silently overwritten.

End-state after Step 1:

- `.specify/extensions/linear/linear-config.yml` exists with
  `linear.team.id` and `linear.project.id` populated (UUIDs per
  FR-002 / Principle V). `workflow_state_uuids` is still all zeroes
  — Step 2 fills it.
- `.specify/extensions.yml` has the six `after_*` hooks registered
  with `optional: false` (FR-031).
- `.git/hooks/post-{checkout,commit,merge}` installed (FR-033).
- You were guided through provisioning `LINEAR_API_TOKEN` as a
  GitHub repo secret, or skipped Layer E.
- `.github/workflows/speckit-linear-sync.yml` written, if Layer E
  was accepted.

## Step 2 — Seed the Linear workspace (one-shot, per workspace)

```bash
/speckit-linear-seed
```

**Per workspace, not per repo.** If another repo's install already
seeded the workspace, re-running `seed` is a no-op (it queries by
name and skips on hit per `validation/linear-workspace-probe.md` §5).

The seed creates the nine spec-kit lifecycle workflow states on the
team, with these type mappings:

| State            | Type        |
|------------------|-------------|
| `Specifying`     | `backlog`   |
| `Clarifying`     | `unstarted` |
| `Planning`       | `unstarted` |
| `Tasking`        | `unstarted` |
| `Red-team`       | `started`   |
| `Implementing`   | `started`   |
| `Analyzing`      | `started`   |
| `Ready-to-merge` | `started`   |
| `Merged`         | `completed` |

It also creates the `phase`, `task-phase`, and `speckit-spec` label
groups plus the nine `phase:*` children. `task-phase:N` and
`speckit-spec:NNN` children are minted lazily by sync. Stock states
(`Backlog`, `Todo`, `In Progress`, `Done`, `Canceled`, `Duplicate`)
are left alone — Linear permits more than six states per team.

Every state UUID is written back into `linear.workflow_state_uuids`
in the config per FR-021 / FR-032. From here on, lookups are
UUID-only — renames in Linear's UI can't break sync.

Expected output against a fresh `OSH-INFRA`-style workspace:

```
seed: workflow states  → created 9, skipped 0
seed: phase labels     → created 9 (parent group "phase" created)
seed: speckit-spec     → parent group created (children minted on first sync)
seed: task-phase       → parent group created (children minted on first sync)
seed: wrote workflow_state_uuids to .specify/extensions/linear/linear-config.yml
seed: done in ~6s
```

Against a partially-seeded workspace:

```
seed: workflow states  → created 0, skipped 9 (already present)
seed: captured 9 workflow state UUIDs into config
```

`[TBD by /speckit-tasks]`: exact summary line wording is pinned by
`src/summary.sh`.

## Step 3 — First reconcile (sync existing specs OR scaffold for new)

```bash
/speckit-linear-push
```

`push` is the single convergent operation (FR-001 / FR-011) — every
`after_*` hook is just `push` running again.

### Scenario A — Brand-new repo (no specs yet)

```
push: 0 specs to mirror
push: Project status → Planned (no spec touched yet)
push: done in ~2s
```

The repo is wired. The first meaningful sync happens automatically
the moment you run `/speckit-specify`.

### Scenario B — Existing repo with specs in various phases

`push` enumerates `specs/*/`, infers each spec's lifecycle phase
from filesystem state per FR-012 (presence of `spec.md`, `plan.md`,
`tasks.md`, `red-team*.md`, `analyze*.md`, ratification markers, and
PR open/merged state via `gh` / git branch reachability), creates
one Issue per spec inside the Project, sub-issues per task phase,
checklists per task, and comments mirroring each ratified clarify
session per FR-015.

Already-merged specs jump straight to `Merged` without intermediate
transitions appearing in Linear's activity log (FR-014):

```
push: discovered 4 specs
  - 001-old-feature       merged (gh: PR #12 merged 2026-02-04)
  - 002-billing-cleanup   implementing (3/5 task phases done)
  - 003-search-rework     planning (plan.md present, no tasks.md)
  - 004-auth-rewrite      specifying (spec.md only)
push: 001 → Issue created in workflow state "Merged"          (phase:merged cleared per FR-013)
push: 002 → Issue created with 5 sub-issues, 3 "Done", 1 "In Progress", 1 "Todo"
push: 003 → Issue created in workflow state "Planning"
push: 004 → Issue created in workflow state "Specifying"
push: mirrored 7 ratified clarify sessions as comments
push: Project status → Started (specs 002, 003, 004 active)
push: done in ~28s (cold)
```

Re-running `push` on unchanged state is a no-op — zero churn, no
modified-timestamps, no activity-log entries (Principle II).

## Step 4 — Verify in Linear

Open the Projects view for your workspace, e.g.:

```
https://linear.app/osh-infra/team/OSH/projects
```

Confirm:

- A Project exists with the name you accepted in Step 1.
- Each spec is an Issue under that Project, in the workflow state
  matching its filesystem-inferred phase, with `phase:<name>` and
  `speckit-spec:NNN` labels (FR-003, FR-004b).
- Each spec Issue's description has a **memory block** showing
  current branch, worktree path(s), current task phase / task,
  last-touched timestamp, and a GitHub source link (FR-004).
- Each implementing spec has Phase 1 / Phase 2 / … sub-issues,
  each with a `tasks.md`-mirroring checklist headed by the
  one-way-mirror banner per FR-006.
- The Project's Status reflects activity (`Started` if any spec is
  active; `Planned` if none; `Paused` after `sync.idle_window_days`).

## Step 5 — Verify the auto-sync chain

Pick any spec and run a lifecycle command:

```bash
/speckit-clarify
```

The `after_clarify` hook fires `speckit.linear.push` (you'll see
the same summary block from Step 3, scoped to this spec). Refresh
Linear:

- Spec Issue workflow state is `Clarifying`, label
  `phase:clarifying` is set, the previous `phase:*` label removed.
- Each `### Session YYYY-MM-DD` block under `## Clarifications` in
  `spec.md` is a comment on the spec Issue, posted exactly once per
  FR-015.

Demonstrate worktree write-authority (FR-025):

```bash
git worktree add ../consumer-repo-main main
cd ../consumer-repo-main
/speckit-linear-push
```

Push runs but enters read-only mode for any spec whose feature
branch isn't checked out in this worktree. The summary names the
read-only specs and prints their current Linear-side state per
FR-026 — answer "what's done?" from `main` without risking a
regression.

## Step 6 — (Optional) Set up the GitHub Action webhook

If you skipped Layer E in Step 1:

1. **Mint a Linear API token** at
   [linear.app/settings/api](https://linear.app/settings/api).
   Personal key or dedicated machine-user — security-sensitive
   repos should use the machine user. Rotate on your org's cadence;
   the bridge does not enforce.
2. **Set the GitHub secret**:

   ```bash
   gh secret set LINEAR_API_TOKEN -R <owner>/<repo>
   gh secret list -R <owner>/<repo> | grep LINEAR_API_TOKEN
   ```

3. **Install the workflow.** Re-run `/speckit-linear-install` and
   accept the webhook prompt — it drops
   `.github/workflows/speckit-linear-sync.yml` and flips
   `webhook.installed: true`. Commit both.
4. **Verify.** Open a draft PR for a spec's feature branch, mark
   ready for review, then merge. Watch the Actions tab — the
   workflow fires per event and flips the spec Issue's state
   (`Ready-to-merge` → `Merged`) within ~10s. SC-010 requires
   sub-minute end-to-end.

If Layer E breaks later (rotated token, deleted secret, Actions
disabled), the bridge doesn't surface it — you discover it via red
Action runs. Layer D's next reconcile still converges to `Merged`
per SC-011.

## Troubleshooting

| Symptom                                                                 | Remediation                                                                                                              |
|-------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `Bash 3.2 detected. Install bash >= 4.`                                 | `brew install bash`, re-open shell, re-run.                                                                              |
| `gh: not authenticated.`                                                | `gh auth login`; accept the `repo` scope so the bridge can read PR state for Layer D fallback.                           |
| `Linear MCP OAuth not present.`                                         | Authenticate the MCP endpoint from your coding agent. `[TBD by /speckit-tasks]` — exact slash command pinned at task time. |
| `workspace not seeded — workflow_state_uuids missing for <phase>`       | Run `/speckit-linear-seed`. The push halts cleanly per FR-022 — no partial Linear state.                                 |
| `Spec NNN has no spec.md. Skipping with warning.`                       | Expected per FR-024. Fix `spec.md` or remove the directory.                                                              |
| `Two Issues with label speckit-spec:NNN. Kept most recent; archived 1.` | Expected per FR-004b — rare race auto-resolved. Open the archived Issue to copy history out if needed.                   |
| `Action fired but no LINEAR_API_TOKEN secret.`                          | `gh secret set LINEAR_API_TOKEN -R <owner>/<repo>`. Failed Action runs don't corrupt Linear; Layer D still works.        |
| `sync: read-only — branch 'main' is not authoritative writer for NNN`   | Expected per FR-025 — switch to a worktree on `NNN-…` to write, or use the read-only view to inspect.                    |
| `workflow state UUID <id> not found in Linear`                          | Someone deleted the state in Linear's UI. Re-run `/speckit-linear-seed` to recreate it and capture a fresh UUID.         |

## Next steps

- Run `/speckit-specify "<my next feature>"` — the `after_specify`
  hook fires `push` and the spec Issue lands in `Specifying` with
  no further action.
- Repeat Step 1 in your next consumer repo. The workspace is
  already seeded so Step 2 is a no-op — ~3 minutes per repo.
- For what the bridge writes where, see
  [`data-model.md`](./data-model.md) and the contracts under
  [`contracts/`](./contracts/).
- For the principles the bridge is built on, see
  [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md).
- If you'll contribute back to speckit-linear, read
  [`CONTRIBUTING.md`](../../CONTRIBUTING.md).
