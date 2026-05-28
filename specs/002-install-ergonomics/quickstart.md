# Quickstart: Interactive install (v0.1.1)

> Time required: under 2 minutes for a first-time operator with a
> Linear API key in hand (SC-009). The v0.1.0 baseline was 10-15
> minutes including the round trip to Linear's UI to dig up UUIDs.
>
> Audience: an operator with a Linear workspace and a git repo
> with `specify init`'d spec-kit. **You only bring a Linear API
> key.** The install discovers everything else (team, project,
> operator identity) by querying Linear with that key.

The new interactive install replaces v0.1.0's UUID-first flow per
spec 002. v0.1.0's `--team <UUID> --project <UUID>` /
`--non-interactive` path still works bit-for-bit for CI per
[`contracts/install-flags.md`](./contracts/install-flags.md); the
walkthrough below is the **interactive default** path 95% of
operators will take.

For the v0.1.0 baseline walkthrough (UUID-first, dependency
report, seed, push), see
[`specs/001-spec-kit-linear-bridge/quickstart.md`](../001-spec-kit-linear-bridge/quickstart.md)
— spec 002 changes Step 1 only.

## Prerequisites

Identical to v0.1.0 (FR-018b dependency gate is unchanged):

```bash
bash --version | head -1    # >= 4.x — macOS ships 3.2, brew install bash
curl --version  | head -1
jq --version                # >= 1.6
git --version               # >= 2.30
gh --version                # optional but recommended (Layer D fidelity)
specify --version           # spec-kit itself
```

You also need:

- A **Linear personal API key** from
  <https://linear.app/settings/api>. This is the **only**
  load-bearing operator input per FR-037.
- A consumer repo with `.specify/` scaffolded (run `specify init`
  first if needed).

## Step 1 — (Optional) drop your API key in `.env`

If you already have your Linear API key, paste it into `.env` at
the consumer repo's root **before** running the install — the
install will detect it there and skip the interactive key prompt
per FR-037 step (2).

```bash
cd path/to/your/consumer-repo
echo "LINEAR_API_KEY=lin_api_<your-key-here>" >> .env
```

If `.env` doesn't exist yet, the line above creates it. The
install verifies `.env` is in `.gitignore` and adds it if absent.

**You can skip this step** — the install ceremony will prompt for
the key interactively (with `read -s`, echo suppressed) and offer
to write it to `.env` for you.

## Step 2 — Install the extension and run the ceremony

```bash
specify extension add --from \
  https://github.com/ashbrener/spec-kit-linear/archive/refs/heads/main.zip
/speckit.linear.install
```

The `--from` URL is the **archive endpoint** per FR-047 — the
plain `https://github.com/<owner>/<repo>` form errors with
`BadZipFile: File is not a zip file` (the spec-kit CLI downloads
the URL as bytes and tries to open it as a ZIP directly without
GitHub-URL → archive-URL resolution). Once spec-kit-linear is
listed in the community catalog, `specify extension add linear`
will work as the simpler form.

## Step 3 — Observe the dependency report (FR-018b — unchanged)

The install opens with the same FR-018b dependency report from
v0.1.0:

```text
spec-kit-linear install dependency report

Runtime dependencies (FR-018b):
  ✓ bash 5.2.21(1)-release            (>= 4)
  ✓ curl 8.4.0                         (any version)
  ✓ jq 1.7.1                           (>= 1.6)
  ✓ git 2.43.0                         (>= 2.30)
  ✓ gh 2.40.0                          (authenticated)

Linear MCP wiring:
  ✓ .mcp.json                          linear entry present
  ✓ Linear MCP OAuth                   cached credentials present under ~/.mcp-auth/

Filesystem layout:
  ✓ git working tree                   /Users/.../your-repo
  ✓ .specify/                          present
  ✓ .specify/extensions.yml            writable

Secrets / .env:
  ✓ .env                               LINEAR_API_KEY present
```

Spec 002 adds two new rows that may appear here:

```text
Pre-install safety:
  ✓ source ≠ target                    install would not self-recurse (FR-046)
  ⚠ .specify/extensions/linear/.git/   vendored from --dev install;
                                       remediation: rm -rf .specify/extensions/linear/.git/
                                       (FR-049)
```

The vendored `.git/` warning is informational — install proceeds.
The self-install row appears as ✗ only when source and target
paths are equal (FR-046), at which point the install halts before
any other work.

## Step 4 — API key auto-detected from `.env`

If you completed Step 1, you'll see:

```text
[linear] Verifying LINEAR_API_KEY (from .env)…
[linear] Operator: Ash Brener <ash@example.com>  (FR-038, FR-048)
```

The install issues exactly **one** `viewer { id name email
organization { name urlKey } }` query (FR-048) and caches the
result for the rest of the discovery flow. No second viewer query
is issued — the same response feeds both the team-list
authorization and the `linear.operator` block written to
`linear-config.yml` per FR-034.

If you skipped Step 1 (no key in `.env`), the install prompts:

```text
[linear] Linear API key (input hidden — paste & enter):
[linear] Save LINEAR_API_KEY to .env at the repo root? .env is
         gitignored (the install will add it if missing).
         [Y/n] (default: Y):
```

Pasting the key (no echo) and pressing `Y` writes it to `.env` for
next time. Pressing `N` keeps the key in-memory for this install
run only.

## Step 5 — Pick a team (FR-039)

The install issues `teams(first: 21)` (FR-039) and presents the
result as a numbered list:

```text
[linear] Teams accessible to this API key:
  1) OSH      — OSH
  2) ENG      — Engineering
  3) DESIGN   — Design Studio
Pick a team [1-3]:
```

**Per SC-010, you never see a UUID.** The picker shows the team's
visible key + name; the UUID lookup happens internally.

**Single-team workspaces auto-pick** — no prompt fires:

```text
[linear] Found 1 team accessible — using OSH (OSH Infra) (auto-picked).
         Override with --team <UUID> on next install.
```

**Zero teams** halts the install with a workspace-settings link
(spec.md Edge Case bullet 1).

## Step 6 — Pick or create a project (FR-040, FR-041)

After the team is selected, the install issues
`team(id).projects(first: 21)` (FR-040) and presents:

```text
[linear] Projects in OSH:
  1) spec-kit-linear
  2) hurri-backend
  3) Create new project
Pick a project [1-3]:
```

Pick an existing project number to **attach** (the install writes
its UUID to `linear-config.yml` and continues). Pick the "Create
new project" tail option to **create** — the install prompts for
a name (FR-041, default = repo basename):

```text
[linear] New Linear Project name [my-consumer-repo]:
[linear] Create new Linear Project "my-consumer-repo" in OSH? [Y/n] (default: Y):
[linear] Created Linear Project: https://linear.app/osh-infra/project/my-consumer-repo-abc123
         Project ID is recorded internally and written to
         .specify/extensions/linear/linear-config.yml.
```

The `projectCreate` mutation (FR-041) fires once; on success the
new project's URL is printed (so you can click through to verify
in Linear's UI).

**Duplicate-name pre-check**: if a project with the chosen name
already exists in the team, you'll see:

```text
[linear] A project named "my-consumer-repo" already exists in OSH.
         [create-anyway/pick-existing/rename] (default: pick-existing):
```

Picking `pick-existing` (default) attaches to the existing project
— no double-create.

## Step 7 — `linear-config.yml` written; hooks register (FR-042, FR-043)

Once the team and project are resolved, the install writes
`linear-config.yml` (FR-042) BEFORE any hook registration. If you
quit at any point before this step (Ctrl-C, EOF on a prompt), no
config is written and a retry starts clean.

After config write, the install proceeds with v0.1.0's
unchanged hook registration / git-hooks install / optional Action
prompt (FR-043). These are documented in v0.1.0's
[`quickstart.md`](../001-spec-kit-linear-bridge/quickstart.md) §Step 1
sub-steps 4-5 and aren't repeated here.

## Step 8 — Install summary + next steps

```text
spec-kit-linear: install: complete
===== speckit.linear install summary =====
  Workspace          OSH Infra (osh-infra)
  Team               OSH — OSH
  Project            my-consumer-repo
  Operator           Ash Brener <ash@example.com>
  Key sourced from   dotenv (no write needed)
  Open in Linear     https://linear.app/osh-infra/project/my-consumer-repo-abc123
  Hooks registered   6 after_* + 3 git hooks (FR-031, FR-033)
  GitHub Action      installed (LINEAR_API_TOKEN secret required — see below)

Next steps:
  1. Run /speckit.linear.seed to populate workflow_state_uuids (one-shot per workspace).
  2. Set the LINEAR_API_TOKEN GitHub repo secret:
       gh secret set LINEAR_API_TOKEN -R ashbrener/my-consumer-repo
  3. Commit linear-config.yml + .github/workflows/spec-kit-linear-sync.yml + .gitignore (.env added).
==========================================
```

If FR-049 fired earlier, the summary also includes:

```text
  ⚠ Vendored .git/   rm -rf .specify/extensions/linear/.git/ before committing
                     (spec-kit CLI bug: --dev install ships source .git/ into target)
```

## Total time

For a first-time operator (key on hand, multi-team workspace,
"Create new" project):

- Step 1: 5s (paste key into `.env`) — optional
- Step 2: 10s (`specify extension add` + `/speckit.linear.install`)
- Step 3: 10s (read dependency report)
- Step 4: 5s (viewer query)
- Step 5: 15s (pick team from list)
- Step 6: 30s (pick "Create new", confirm name, projectCreate fires)
- Step 7: 5s (config write + hook registration)
- Step 8: 10s (read summary)

**Total: ~90 seconds** (well under SC-009's 2-minute budget).

Single-team workspaces with an existing project skip Step 5's
prompt and shorten Step 6 to ~10s — comfortably under 60s total.

## CI / scripted install (preserved v0.1.0 path)

For automation, the v0.1.0 non-interactive surface continues to
work bit-for-bit per FR-044 + SC-011:

```bash
bash src/install.sh \
  --team <KNOWN-TEAM-UUID> \
  --project <KNOWN-PROJECT-UUID> \
  --non-interactive
```

No prompts fire; install completes silently; `linear-config.yml`
matches the passed UUIDs. See
[`contracts/install-flags.md`](./contracts/install-flags.md) §5
for the full backwards-compatibility table.

## Cross-references

- [`spec.md`](./spec.md) — 13 FRs + 5 SCs + 3 user stories.
- [`plan.md`](./plan.md) — implementation plan, Constitution
  Check.
- [`research.md`](./research.md) — 6 design decisions (incl. why
  `first: 21`, why `pwd -P` over `realpath`).
- [`data-model.md`](./data-model.md) — InstallSession +
  AvailableTeam + AvailableProject + discovery state machine.
- [`contracts/install-discovery-graphql.md`](./contracts/install-discovery-graphql.md)
  — exact GraphQL operations.
- [`contracts/install-prompts.md`](./contracts/install-prompts.md)
  — exact prompt text + validation rules.
- [`contracts/install-flags.md`](./contracts/install-flags.md)
  — CLI flag surface + v0.1.0 → v0.1.1 backcompat table.
- v0.1.0 baseline:
  [`specs/001-spec-kit-linear-bridge/quickstart.md`](../001-spec-kit-linear-bridge/quickstart.md).
