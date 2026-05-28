---
name: speckit.linear.install
description: Install ceremony — verify dependencies, resolve Linear Team + Project UUIDs, register after_* hooks, install local git hooks
arguments:
  - name: project
    description: existing Linear Project UUID to attach to (mutually exclusive with auto-create)
    optional: true
  - name: auto-create
    description: create a new Linear Project named after the current repo directory (mutually exclusive with project)
    optional: true
  - name: team
    description: Linear Team UUID; required in non-interactive mode, otherwise auto-detected or prompted
    optional: true
  - name: non-interactive
    description: refuse interactive prompts; require project/auto-create + team to be passed
    optional: true
  - name: with-action
    description: also install the Layer E GitHub Action template at .github/workflows/speckit-linear-sync.yml
    optional: true
  - name: dev
    description: install from the local speckit-linear checkout rather than via `specify extension add` (dogfood)
    optional: true
---

# `/speckit.linear.install`

Run the per-consumer-repo install ceremony for the speckit-linear
bridge. This is the load-bearing one-shot step that wires a fresh
consumer repo to its Linear workspace: dependencies are verified, the
per-repo `linear-config.yml` is written, the six `after_*` hooks are
registered with `optional: false` (FR-031), and the three local git
hooks land under `.git/hooks/` (FR-033). The structured dependency
report it emits is the operator's contract per FR-018b — silent
failures are forbidden.

**Direction**: filesystem-side wiring only (Principle I).
**Idempotency**: re-running preserves operator edits — existing
`enabled: false` flags on registered hooks survive (Principle VII);
existing Project UUIDs are not overwritten without operator action.
**Authority**: this command never mutates Linear (other than the
optional `--auto-create` Project bootstrap, which is deferred to T077
dogfood). Workspace seeding (workflow states, labels) is a separate
command — `/speckit-linear-seed`.
**Layer**: implements the install side of Layer D. The optional
`--with-action` flag drops the Layer E template; the secret
provisioning (`gh secret set LINEAR_API_TOKEN`) stays with the
operator per FR-029.

The deterministic work happens in `src/install.sh`; this command is
the AI-agent entry point that runs the shell and surfaces its output.
The formal API contract is `contracts/command-shapes.md` §5
(`speckit.linear.install`). Operators reading this file are looking
at the markdown the AI agent reads — the same operations are
available via `bash src/install.sh` directly.

## Arguments

| Argument | Default | Meaning |
|---|---|---|
| `project` | (interactive prompt) | Existing Linear Project UUID. Mutually exclusive with `auto-create`. |
| `auto-create` | false | Create a new Linear Project named after the repo basename. Mutually exclusive with `project`. |
| `team` | auto-detect / prompt | Linear Team UUID. Required if `non-interactive=true`. |
| `non-interactive` | false | Refuse to prompt; require `project` (or `auto-create`) and `team` to be set on the CLI. Suitable for CI re-runs. |
| `with-action` | false | Also drop `templates/github-action.yml` into `.github/workflows/speckit-linear-sync.yml` per FR-027, and surface the FR-029 secret-provisioning command. |
| `dev` | false | Install from the local speckit-linear checkout — used when the bridge is dogfooding its own repo (T077). |

`project` and `auto-create` are mutually exclusive (passing both
exits 2). `non-interactive` without one of them, or without `team`,
also exits 2.

## Algorithm (what the AI agent executes)

1. **Compose the invocation.** Translate the user-facing arguments
   into `src/install.sh` flags:
   - `project=<UUID>` → `--project <UUID>`
   - `auto-create=true` → `--auto-create`
   - `team=<UUID>` → `--team <UUID>`
   - `non-interactive=true` → `--non-interactive`
   - `with-action=true` → `--with-action`
   - `dev=true` → `--dev`

2. **Execute the install ceremony.** Shell out:

   ```bash
   bash src/install.sh <flags>
   ```

   The script:
   - Emits the **dependency report** (FR-018b) to stderr. Each line
     is one of:
     - `✓ <label>  <detail>` — verified.
     - `⚠ <label>  <detail>` — warning; install proceeds.
     - `✗ <label>  <detail>` — hard error; install aborts with
       exit 2 after the full report is printed (so the operator sees
       every problem at once, not just the first).
     The covered surfaces are: bash, curl, jq, git, gh (optional),
     `.mcp.json` Linear MCP entry, Linear MCP OAuth cache,
     `.specify/` layout, `.git/hooks/` writability, `.env`.
   - Detects whether the target repo is the speckit-linear repo
     itself (the **dogfood guard**, T048). When detected, the hook
     entries are emitted with
     `condition: "${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}"` so they
     don't auto-fire during the bridge's own development unless the
     operator opts in by exporting that env var.
   - Resolves the Linear **Team** + **Project** UUIDs:
     - Non-interactive: trust `--team` + `--project` / `--auto-create`.
     - Interactive: prompt the operator. The Project picker offers
       `create` / `attach` / `rename` (default `create`).
     - Note: actual GraphQL-driven Team/Project queries are
       deferred to T077 dogfood; for Phase 4 the install records
       operator-supplied UUIDs or a clearly-marked zero placeholder
       that the operator must resolve before the first push.
   - Copies `config-template.yml` into
     `.specify/extensions/linear/linear-config.yml` (FR-002), substitutes the
     resolved Team + Project UUIDs in place. `workflow_state_uuids`
     remain zero — the seed step fills them.
   - Registers each of the six `after_*` hooks under
     `.specify/extensions.yml` per FR-031 / Principle VII. Each entry
     points at `speckit.linear.push`, with `optional: false` and
     `enabled: true`. Re-runs honour any pre-existing `enabled:
     false` operator edit (Principle VII rule 1).
   - Installs `post-checkout`, `post-commit`, `post-merge` git
     hooks per FR-033. If a hook of the same name already exists
     (non-bridge content), the install chains a marker block
     (`# >>> speckit-linear hook begin (FR-033) >>>`) onto the end of
     the existing hook rather than overwriting it. Re-installs are
     idempotent — the marker is the detection signal.
   - When `--with-action` is set, copies
     `templates/github-action.yml` into
     `.github/workflows/speckit-linear-sync.yml` (preserves an
     operator-customised file if one already exists). Surfaces the
     `gh secret set LINEAR_API_TOKEN -R <owner>/<repo>` command per
     FR-029. The bridge **does not** provision the secret on the
     operator's behalf.

3. **Render the structured summary.** The script emits a
   `summary::emit` block to stderr at the end of every invocation
   (Principle VIII Rule 1 / FR-023). The block looks like:

   ```text
   ===== speckit.linear summary =====
   speckit-linear install ceremony
   Created: 2   Updated: 2   Archived: 0
   Skipped: 1   Warned: 0     Errors: 0
   ----- warnings -----
   - GitHub Action install (re-run with --with-action to enable Layer E)
   ==================================
   ```

   Surface this verbatim to the operator. The dependency report block
   that preceded the summary is also operator-visible — together they
   are the entire FR-018b contract.

4. **Handle the exit code.** Per `contracts/command-shapes.md` §5.6:
   - `0` — install completed; all required dependencies green.
     Show the summary and direct the operator to run
     `/speckit-linear-seed` next.
   - `1` — recoverable transient failure (e.g. Linear API blip
     during the deferred `--auto-create` Project bootstrap, when
     enabled). Re-run.
   - `2` — workspace-level config error. The script halted before
     mutation. Common causes (and the script prints exact
     remediation for each):
     - Bash 3.2 detected (`brew install bash`).
     - `jq` / `git` below minimum version.
     - Not inside a git repo, or `.specify/` missing.
     - `--non-interactive` without `--project` (or `--auto-create`)
       and `--team`.
   - `3` — transport failure. The MCP wiring step couldn't reach
     Linear / the operator's MCP host. Re-run when connectivity is
     restored.

## When this command fires

- **Operator-driven, one-shot.** This command is run **once per
  consumer repo** at adoption time. Subsequent invocations are
  idempotent (re-running just re-verifies dependencies and reports
  drift).
- **Not auto-fired.** Unlike `/speckit-linear-push`, this command is
  never wired to any `after_*` hook or git hook. It only runs when
  the operator explicitly invokes it.

## Output channel discipline

- `stdout` of `src/install.sh` is reserved for any future
  structured output (none in v1).
- `stderr` carries:
  - the per-step dependency report rows (`✓` / `⚠` / `✗`)
  - the next-steps pointer block
  - the final structured `summary::emit` block
- Filesystem writes are deliberate and documented:
  - `.specify/extensions/linear/linear-config.yml` (FR-002)
  - `.specify/extensions.yml` (FR-031 — `after_*` hooks)
  - `.git/hooks/{post-checkout,post-commit,post-merge}` (FR-033)
  - `.mcp.json` (FR-018b — Linear MCP entry, auto-added if absent)
  - `.github/workflows/speckit-linear-sync.yml` (FR-027 — only when
    `--with-action` is set)

No Linear-side mutations happen (other than the deferred
`--auto-create` Project bootstrap once T077 dogfood lands).

## Failure surface

Each failure mode is surfaced as a named warning or error row in
the dependency report (Principle VIII) before the install proceeds.
Selected named cases:

- `bash X.Y` — needs >= 4 → exit 2. Fix: `brew install bash`,
  re-open shell.
- `jq X.Y` — needs >= 1.6 → exit 2. Fix: `brew install jq`.
- `git working tree` — current directory is not inside a git repo
  → exit 2.
- `.specify/` — missing → exit 2. Fix: run `specify init` first.
- `.git/hooks/` — not writable → exit 2.
- `gh CLI` — missing → warning (install completes; degraded
  Layer D fidelity per FR-030).
- `Linear MCP OAuth` — no cached credentials → warning. Fix
  surfaced inline.
- `.env` — missing or `LINEAR_API_KEY` unset → warning. Required
  only for direct-GraphQL paths (seed, git hooks, Action local
  test).
- `--non-interactive requires --team <UUID>` — non-interactive
  guardrail per FR-002 → exit 2.
- `--auto-create requested; placeholder Project UUID written` —
  warning. The interactive GraphQL-driven Project create step is
  deferred to T077 dogfood. Re-run with `--project <UUID>` once
  the Project exists in Linear, or wait for the dogfood
  integration.
- `dogfood target detected` — warning. The repo is speckit-linear
  itself; hook entries get a `${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}`
  condition marker so they don't auto-fire during the bridge's own
  development.

## Related commands

- `/speckit.linear.seed` — one-shot per-workspace seed of workflow
  states + labels. Run after install but before the first push.
- `/speckit.linear.push` — the convergent reconcile. Runs
  automatically after every `/speckit-*` lifecycle command once the
  install has registered hooks.
- `/speckit.linear.pull` — read-only inspect Linear's current view
  (works from any worktree, never mutates).
- `/speckit.linear.status` — drift report (filesystem vs Linear)
  without actually issuing mutations.

See `contracts/command-shapes.md` for the formal contract on each
and `quickstart.md` for the operator's first-run walkthrough.
