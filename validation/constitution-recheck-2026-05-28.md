# Constitution v1.0.0 Re-Check — 2026-05-28

## Summary

Pre-merge audit of `001-spec-kit-linear-bridge` against the 8 principles
ratified in `.specify/memory/constitution.md` v1.0.0 (2026-05-27). The
as-built bridge conforms to every principle; the Plan B canonical-rebuild
refactor for `compose_issue_description` (commit `2979d96`) materially
strengthened conformance to Principle II at the description layer. No
drift detected. One sub-issue-description nuance is noted as a caveat under
Principle III (Layer D writes sub-issue description body once per
reconcile via update-only path — no boundary violation, documented).

| Principle | Verdict |
| ---------------------------------------------- | ---------------- |
| I. Filesystem Is The Single Source of Truth   | Conforms          |
| II. Reconcile, Never Event-Push                | Conforms          |
| III. Layered Idempotency (D + E)               | Conforms w/ caveat|
| IV. Write-Authority Follows The Worktree       | Conforms          |
| V. UUID-Based Binding, Per-Repo Config         | Conforms          |
| VI. OAuth-First, Keys-At-The-Edges             | Conforms          |
| VII. Memory-Just-Works, Escape Hatches Beside It | Conforms        |
| VIII. Surface, Don't Enforce — Observable Failure | Conforms       |
| Architectural constraints (no daemon/DB/runtime) | Conforms       |

**Verdict: 7 Conform / 1 Conform-with-caveat / 0 Drift. No blockers for merge.**

---

## Principle I: Filesystem Is The Single Source of Truth

**Status: Conforms**

Evidence:
- Reconciler has zero filesystem-mutating paths against `specs/` or
  `.specify/`. Audit of `src/reconcile.sh:1-2300` shows only tempfile
  use under `$(mktemp)`; no `>`, `>>`, `tee`, `cp`, or `mv` against
  on-disk spec artifacts.
- Sub-issue mirror header is the literal contract operator-facing copy:
  `src/reconcile.sh:128` —
  `'> **Read-only mirror of `tasks.md` — ticks in Linear are overwritten on next reconcile.**'`.
- `templates/github-action.yml:44` explicitly bans the Action from touching
  `.specify/extensions/linear/linear-config.yml` "or any other filesystem
  path under the checked-out repo".
- No Linear → filesystem pull path exists in any `src/*.sh`, `commands/*.md`,
  or the Action template. Linear is strictly the downstream mirror.

Notes: The `commands/linear-pull.md` escape-hatch surface flagged in
extension.yml is implemented as read-only display (no write back). 

---

## Principle II: Reconcile, Never Event-Push

**Status: Conforms** — materially tightened by Plan B refactor.

Evidence:
- `src/reconcile.sh:30-32` — header declares "no diff cache, no sidecar
  `last_sync.json`".
- Plan B refactor at `src/reconcile.sh:846-901` (`compose_issue_description`)
  fully reconstructs the description on every reconcile in canonical
  order (overview → memory → diagrams → operator remainder). This
  eliminates the splice-per-fence path whose ordering depended on the
  current description shape — the surviving function is pure
  filesystem-to-Linear, with no Linear-state-dependent branches. (See
  commit `2979d96` diff: `+105 / -136`.)
- Hook path (`templates/git-hooks/post-checkout:100-104`) fires
  `reconcile.sh --spec NNN` — same code path the on-demand
  `speckit.linear.push` command invokes. No diff payload is constructed
  by the hook; the reconciler converges from disk state.
- Layer E (`templates/github-action.yml:461`) flips exactly one field
  (`stateId`) per fire; re-firing against an already-correct state is
  a Linear no-op per the comment at line 83.
- Filesystem-derived stable keys only: spec label, feature number,
  task-phase label, workflow-state UUID. Confirmed at
  `src/reconcile.sh:1664, 1697` (Issue lookup by label, not by ID cache).

---

## Principle III: Layered Idempotency (D + E)

**Status: Conforms with caveats**

Evidence:
- Layer E firebreak in `templates/github-action.yml:30-50` enumerates
  the exact forbidden operations (no labels, no comments, no sub-issues,
  no description, no project status, no GitHub API). Mutation site at
  `templates/github-action.yml:461` is the only `issueUpdate` call and
  its `input` is `{ stateId }` only — verified at line 432 comment
  ("input contains ONLY stateId").
- Layer D owns labels/sub-issues/comments/Project Status; Action does
  not touch them. Boundary is enforced by code shape (different files,
  different surfaces).
- Either-layer-alone correctness: Layer D's per-spec gate
  (`src/reconcile.sh:2174`) calls `pr_state` and infers
  `merged`/`ready_to_merge` from `gh` or git-only fallback
  (`src/git_helpers.sh:247-260`), so Layer E absence still converges
  state on the next reconcile (FR-030).

Caveat: Layer D writes the spec Issue description (Layer D-owned field
per design) and Layer E writes `stateId` (Layer E-owned). These are
disjoint Linear-attribute domains, so the constitution's
"cross-layer writes to the same Linear attribute are a defect" rule
is honoured. The caveat is documentary only — operators should not
expect Layer E to ever surface bridge-side description issues.

---

## Principle IV: Write-Authority Follows The Worktree

**Status: Conforms**

Evidence:
- `src/git_helpers.sh:153-172` — `is_authoritative_for_spec` returns 0
  iff `current_branch =~ ^<NNN>-.+$`. Rejects detached HEAD, `main`,
  and non-matching feature branches.
- `src/reconcile.sh:2174-2176` — per-spec gate calls
  `is_authoritative_for_spec` and falls through to
  `reconcile::read_only_display` (defined at line 1458) on mismatch.
- `reconcile::read_only_display:1458-1490` writes nothing to Linear;
  emits `summary::add skipped` with the spec/branch context (FR-026).
- post-checkout hook (`templates/git-hooks/post-checkout:25-31`)
  comments that fire-on-any-checkout is safe because non-authoritative
  invocations degrade to read-only display.
- Layer E exemption respected: Action keys off PR head ref, not
  worktree state.

---

## Principle V: UUID-Based Binding, Per-Repo Config

**Status: Conforms**

Evidence:
- `config-template.yml:32-78` carries UUID-shaped placeholder values for
  team, project, operator, all 9 workflow states, and the 3 default
  team states.
- `src/config.sh:52` — `CONFIG_UUID_REGEX` enforces RFC 4122; validator
  at `src/config.sh:415-491` flags every missing/malformed/zero-UUID
  field with operator-actionable diagnostics.
- All 9 lifecycle phases enumerated at `src/config.sh:56-66`; getter
  at `src/config.sh:337-364` halts on unknown phase or missing UUID
  with a `/spec-kit-linear-seed` remediation hint.
- Action reads UUIDs from `.specify/extensions/linear/linear-config.yml`
  at runtime — `templates/github-action.yml:222-237` uses `yq -r` to
  pull `linear.project.id`, `linear.team.id`, and the
  `ready_to_merge`/`merged` workflow-state UUIDs. Names are never the
  lookup key.
- Per-operator global config explicitly excluded — `config::load`
  (`src/config.sh:250-271`) only accepts a path argument; no
  `~/.config` fallback exists.

---

## Principle VI: OAuth-First, Keys-At-The-Edges

**Status: Conforms**

Evidence:
- Interactive path: `src/install.sh:107` —
  `INSTALL_LINEAR_MCP_URL="https://mcp.linear.app/mcp"`. Install verifies
  OAuth via cached `~/.mcp-auth/mcp-remote-*` credentials
  (`src/install.sh:619-630`); never prompts for an API key in the
  interactive flow.
- Keys-at-edges only: `LINEAR_API_KEY` is loaded at GraphQL boundary
  in `src/graphql.sh:105-125` (read from env or `.env`, never from
  global config). Used as `-H "Authorization: ${LINEAR_API_KEY}"` at
  `src/graphql.sh:210` — no `Bearer` prefix per Linear's docs.
- `.env` is gitignored (`.gitignore` includes `.env`); FR-020 honoured.
- Action token comes from repo secret `LINEAR_API_TOKEN`; bridge does
  not provision it (no `gh secret set` call in `src/install.sh`).
- Key value is never logged: `graphql::_log_error`/`_log_warn`
  (`src/graphql.sh:78-90`) print messages without ever interpolating
  `${LINEAR_API_KEY}`. The only string referencing the var by name is
  the "missing" diagnostic at `src/install.sh:648` (variable name only,
  not value).
- Community fallback `dvcrn/mcp-server-linear` is not referenced
  anywhere in `src/`, `commands/`, or `templates/`. Verified via
  ripgrep.

---

## Principle VII: Memory-Just-Works, Escape Hatches Beside It

**Status: Conforms**

Evidence:
- Hook auto-registration at install: `src/install.sh:1389` writes
  `optional: false` for every rendered hook block; loop covers all 6
  `after_*` hooks (`src/install.sh:93-99`).
- `extension.yml:169-227` declares all 6 hooks with `optional: false`
  (spec FR-031).
- post-checkout / post-commit / post-merge templates exist under
  `templates/git-hooks/` and all funnel to `reconcile.sh --spec NNN`,
  matching the auto-fire-on-lifecycle posture.
- post-checkout dogfood guard (`templates/git-hooks/post-checkout:54`)
  honours `SPECKIT_LINEAR_DOGFOOD_SAFE != "true"` opt-out without
  touching the upstream `optional: false` contract.
- On-demand escape hatches: `commands/linear-push.md`,
  `linear-install.md`, `linear-seed.md` exist as separate command
  surfaces; they share the same `reconcile.sh` code path (Principle II
  rule honoured).
- Memory block in spec Issue description: `src/reconcile.sh:114-115`
  defines `RECONCILE_MEMORY_BEGIN/END` fences; built into description
  by `compose_issue_description` (`src/reconcile.sh:855-858`).

---

## Principle VIII: Surface, Don't Enforce — Observable Failure

**Status: Conforms**

Evidence:
- Structured summary emitter: `src/summary.sh:219-244` prints
  `===== speckit.linear summary =====` block with all 6 counter types
  and a warnings list. Format locked per spec FR-023.
- Reconciler accumulates errors via `summary::add error` (~30 sites
  in `src/reconcile.sh`), then promotes exit to 1 if any errors landed
  (`reconcile::main` end — `summary::has_errors` check) per the exit
  code contract.
- Config validator halts loudly with exit 2 and per-field problem list
  (`src/config.sh:481-488`); does NOT auto-repair or write to disk.
- Install verifier surfaces dependency gaps with copy-paste remediation
  strings rather than auto-installing (e.g.
  `src/install.sh:629` MCP-cred fix string; `src/install.sh:648`
  LINEAR_API_KEY remediation).
- Vocabulary discipline confirmed: `RECONCILE_SUBISSUE_HEADER`
  references `tasks.md` Phase N; `task-phase:N` labels used throughout;
  no occurrences of "wave / W0 / W1" in `src/` or `commands/`.
- No silent best-effort install — `src/install.sh` exits non-zero on
  unmet preconditions; verified by inspecting the dep-check loop.
- Auto-PR creation explicitly excluded: no `gh pr create` or
  `gh pr ready` in `src/reconcile.sh` or `templates/github-action.yml`.

---

## Architectural Constraints

**Status: Conforms**

Evidence:
- No daemons, no DB, no new runtimes. Toolchain confirmed: bash, curl,
  jq, git, gh. Action additionally relies on `yq` (Mike Farah,
  preinstalled on ubuntu-latest) per
  `templates/github-action.yml:99-100`. yq is constrained to the Action
  runtime only — not required on operator workstations.
- No `python|node|ruby|go|perl` shebangs in `src/`, `commands/`,
  `templates/`, or `scripts/`. The only `npx` reference is to
  `mcp-remote` in `src/install.sh:629`, which is an OPTIONAL operator
  remediation hint for OAuth recovery — not a dependency of the bridge
  itself.
- No `systemd`/`launchd`/`launchctl`/`nohup`/`&` long-running processes
  except the fire-and-forget post-checkout reconciler at
  `templates/git-hooks/post-checkout:104`, which is a single
  short-lived background invocation, not a daemon.
- No DB references (no sqlite/postgres/mysql/redis) anywhere in the
  tree.
- State lives in: filesystem (`specs/`, `.specify/extensions/linear/`),
  Linear, and per-invocation Action env. Constitution's three-place
  rule honoured.
- Data-model mapping intact: consumer repo → Linear Project; spec →
  Issue; task phase → sub-issue; tasks → checklist items; non-task
  artifacts → comments; lifecycle → workflow state + `phase:*` label.
  Confirmed in `src/reconcile.sh` `sync_spec_issue` and
  `sync_task_phase_subissues` callsites.

---

## Verdict & Recommended Actions

**Verdict: 7 Conform / 1 Conform-with-caveat / 0 Drift. Cleared for merge.**

The Plan B canonical-rebuild commit (`2979d96`) closed the only
non-trivial Principle II gap surfaced by the ACM-5 dogfood
regression — the splice-per-fence ordering bug. Post-refactor, the
description layer is a pure filesystem-to-Linear render that does not
read Linear's current description shape to decide what to write.

Recommended follow-ups (non-blocking, fix-later):
1. The Principle III caveat (Layer D owns sub-issue description body)
   is design-intent, not drift. If future operators expect Layer E to
   stay current independent of Layer D runs, document the "sub-issue
   description is Layer-D-fresh-only" expectation in
   `templates/github-action.yml` header comments.
2. T079/T080/T081 (coverage, CI integration matrix, final shellcheck
   pass) remain open per `specs/001-spec-kit-linear-bridge/tasks.md`.
   None are constitutional blockers, but ship them before merge to
   keep the Principle VIII "observable failure" surface honest.

No code changes required for constitutional conformance. T082 is
**PASS**.

— Audit completed 2026-05-28 against constitution v1.0.0 (ratified
2026-05-27).
