# Feature Specification: Install Ergonomics Redesign

**Feature Branch**: `002-install-ergonomics`

**Created**: 2026-05-28

**Status**: Draft

**Input**: User description: "Install ergonomics redesign — the API key is the only thing the operator should have to bring. The install ceremony must (1) prompt for or detect the API key in `.env`, (2) verify the key against Linear's `viewer` query, (3) query the teams the key has access to and present them as a numbered interactive list (auto-pick if single team, never require a UUID), (4) once a team is chosen, query its existing Projects and present them as a numbered list with a 'Create new' option, (5) if 'Create new' is chosen, prompt for project name and call `projectCreate` via GraphQL, (6) write the resolved team_id and project_id (real UUIDs, resolved by the install) into `linear-config.yml` along with operator identity, (7) only THEN run the hook registration / git hooks / Action layer steps. Replaces FR-002's UUID-first install flow with viewer-driven discovery. Also surfaces the `--from <archive-zip-url>` vs `--from <repo-url>` distinction (CLI requires a direct ZIP URL — repo URLs error with BadZipFile) and the `--dev` self-install recursion bug (CLI copies source into target when source == target, hitting macOS filename length limit). Backwards-compat: existing `--team <UUID> --project <UUID>` flags still work for non-interactive / CI installs. Driven by real operator feedback during the first dogfood of v0.1.0 into a downstream consumer repo."

## Overview

Spec 001 (v0.1.0) shipped an install ceremony that required the operator to bring their Linear Team UUID and Project UUID up front. Real operator feedback during the first community-style dogfood into a downstream consumer repo proved this is wrong UX in three concrete ways:

1. **Operators can only see team KEYS in URLs** (e.g. `https://linear.app/acme/team/ACM/all` → key=`ACM`). UUIDs aren't surfaced anywhere in Linear's web UI. The operator has to either query the API themselves or use a workaround.
2. **Operators have to create the Project in Linear's UI before they can install**, because `--auto-create` is documented as deferred and the install can't drive `projectCreate`. They flip back and forth between Linear, their terminal, and an API explorer.
3. **The API key gets demanded at the wrong moment** — the install today defers it to the seed step, but to resolve any Linear identity (team key → UUID, project name → UUID, project creation) you need the key first. The current flow asks for UUIDs the operator doesn't have, then asks for a key that would have let the install discover those UUIDs.

This spec redesigns the install ceremony around a single load-bearing assumption: **the API key is the only thing the operator brings, and everything else the install discovers interactively from what that key can see.** The operator never sees a UUID; the install does the resolution.

### Two install paths, one ergonomic contract

| Path | Trigger | Operator inputs |
|---|---|---|
| **Interactive (default)** | `/speckit.linear.install` or `bash src/install.sh` with no flags | API key (one prompt or one `.env` file), team pick (numbered list), project pick (numbered list with "Create new" option) |
| **Non-interactive (CI)** | `bash src/install.sh --team <UUID> --project <UUID>` | Pre-resolved UUIDs as flags; no prompts; for build pipelines / scripted installs |

Both write the same `linear-config.yml`. The interactive path is the operator's path; the non-interactive path is the backwards-compatibility / automation path.

### Three install-CLI traps to fix in operator-facing docs

These are not bridge bugs but operator-blocking footguns the first dogfood surfaced. All three are spec-kit CLI behaviors the bridge can either work around or warn the operator about:

- `specify extension add --from <repo-url>` fails with `BadZipFile: File is not a zip file` because the spec-kit CLI downloads the URL as bytes and tries to open it as a ZIP directly — there's no GitHub-URL → archive-URL resolution. **The correct URL is the archive endpoint** (`/archive/refs/heads/main.zip`). README must document this.
- `specify extension add <source-path> --dev` recurses infinitely when source == target. The CLI copies the entire source tree into the target dir, which now contains the same `.specify/extensions/linear/` path it just created — hits macOS filename length limit (255 chars per component) at ~30 levels of nesting. **The bridge's install.sh must detect this case and refuse with a clear message** before the CLI runs.
- `specify extension add <source-path> --dev` from a local path vendors the source's `.git/` directory into the consumer repo's `.specify/extensions/linear/.git/`. This creates a nested git repository inside the consumer repo, which makes git silently refuse to track files inside the extension directory (operators see `git add -f linear-config.yml` succeed quietly but the file isn't actually tracked). **The bridge's install.sh must detect a vendored `.git/` under its install path and surface a warning** instructing the operator to either delete the nested `.git/` or wait for the upstream CLI fix.

## Clarifications

### Session 2026-05-28

- Q: Where should the operator's Linear API key live during install? → A: Default to `.env` at the repo root (matches FR-029 pattern, gitignored). Honor `LINEAR_API_KEY` env var as override. If neither is present at install time, prompt interactively with `read -s` (no echo) and offer to write to `.env`. Never persist to a config file the user might commit.
- Q: What happens if the operator has >10 teams or >10 projects? → A: For v1, present the first 20 visible (no pagination, no filter). Linear's API returns teams/projects ordered by recent activity; for most operators (1-5 teams typical) this is fine. If the count exceeds the display threshold, surface a warning row in the install summary and instruct the operator to use the `--team <UUID>` flag for non-interactive selection. Pagination/filtering is v0.2.0 scope.
- Q: Should the bridge create the `agent:claude` and `agent:codex` labels at install time too, or wait for seed? → A: Wait for seed. Install only resolves Team / Project / operator. Labels (FR-021) are seed-step scope per the v0.1.0 separation. This keeps install's blast radius small and consistent with v0.1.0 behavior.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - First-time operator installs the bridge into a new repo (Priority: P1)

A developer who has heard about spec-kit-linear via the community catalog runs `specify extension add linear` (or the archive-URL form until catalog listing lands), opens Claude Code in their repo, and types `/speckit.linear.install`. They have their Linear API key open in another tab; they paste it when prompted (or had it in `.env` beforehand). The install asks them to pick a team from a numbered list, asks them to pick or create a project from a numbered list, then writes `linear-config.yml` and registers hooks. End state: their next `/speckit.specify` or `/speckit.tasks` command auto-syncs to Linear with no further setup.

**Why this priority**: This is the only path 95% of operators will ever take. The first dogfood surfaced that the current path is genuinely blocking; redesigning it is the single largest UX improvement on the v0.1.x roadmap.

**Independent Test**: Set up a fresh sandbox repo with `.specify/` scaffolded and a fresh Linear workspace seed. Install the bridge via `specify extension add`. Run `/speckit.linear.install`. Assert: no UUID prompts, no operator visits to Linear's UI, install completes in under 2 minutes (SC-009), `linear-config.yml` contains valid resolved UUIDs.

**Acceptance Scenarios**:

1. **Given** a fresh consumer repo with no `.env` and no `linear-config.yml`, **When** the operator runs `/speckit.linear.install`, **Then** the install first prompts for the API key (or detects it in `.env`), verifies it via the `viewer` query, presents a numbered team list (auto-picking if a single team), presents a numbered project list with a "Create new" option, and only after the operator has picked or created the project does it register hooks and install git hooks.
2. **Given** the operator's Linear key can only see one team, **When** they run the install, **Then** the team picker is skipped silently (auto-picked) and the install proceeds directly to the project picker.
3. **Given** the operator picks "Create new" at the project picker, **When** they type a name and confirm, **Then** the install issues a `projectCreate` mutation, surfaces the new project's URL in the summary, and writes the new project's UUID into `linear-config.yml`.
4. **Given** the operator's API key is invalid or missing required scopes, **When** the install runs `viewer`, **Then** the install halts before any prompts with a clear error pointing at Linear's API-key creation page.

---

### User Story 2 - CI / scripted install (Priority: P2)

A team adopting spec-kit-linear at scale wants to install the bridge via their provisioning automation. They pre-resolve the team and project UUIDs out-of-band (or via a one-time interactive install they save) and pass them as flags. End state: a non-interactive install completes silently in their CI pipeline without prompts.

**Why this priority**: Important for organizational rollout but a smaller audience than P1. Backwards-compatibility with v0.1.0's existing `--team`/`--project` flags must be preserved so the CI path doesn't break for early adopters who already wrote install scripts.

**Independent Test**: Given a sandbox repo, invoke `bash src/install.sh --team <known-UUID> --project <known-UUID> --non-interactive`. Assert: no prompts fired, install completes, `linear-config.yml` matches the passed UUIDs, exit code 0.

**Acceptance Scenarios**:

1. **Given** both `--team` and `--project` flags are passed as valid UUIDs, **When** install runs, **Then** the viewer-driven discovery flow is bypassed entirely and the install proceeds directly to writing `linear-config.yml` and registering hooks.
2. **Given** only `--team` is passed (no `--project`), **When** install runs with `--non-interactive`, **Then** the install halts with an FR-022-style error rather than prompting (preserves CI safety).

---

### User Story 3 - Operator-facing install docs match operator reality (Priority: P3)

A developer follows the README's Install section. The commands shown work on the first try. Specifically, the documented `--from` URL form actually installs (uses the archive endpoint), and if they try `--dev` from inside the bridge's own source tree, they get a clear "self-install detected" error rather than a 30-level recursive directory mess.

**Why this priority**: Lower priority than P1/P2 because it's a documentation + safety-guard problem, not a UX redesign. But still pre-merge scope because every new operator hits these footguns before they ever reach the install ceremony.

**Independent Test**: Run the exact commands from the Install section of the README in a sandbox. Assert: archive-URL form succeeds; local-path `--dev` from inside the bridge's source tree errors out with a clear self-install message rather than corrupting the filesystem.

**Acceptance Scenarios**:

1. **Given** the README's Install section, **When** an operator copy-pastes the `--from <archive-URL>` command, **Then** the extension installs without `BadZipFile` errors.
2. **Given** the operator invokes `specify extension add /path/to/spec-kit-linear --dev` from inside `/path/to/spec-kit-linear` itself, **When** install.sh runs, **Then** it detects the `source path is current consumer repo` case before any directory copy and exits with a clear remediation message ("install into a different consumer repo, or use `specify extension add linear` from the catalog").

---

### Edge Cases

- **Operator has zero teams** (API key was issued for a workspace the user is no longer in) → install halts with "no teams accessible to this API key" and points at Linear's workspace settings.
- **Operator has more than the display threshold (default 20) teams or projects** → install displays the first 20 + warns "more available; pass `--team <UUID>` to install non-interactively".
- **Operator picks a team they don't have project-create permission in** → projectCreate returns a permission error; install surfaces it verbatim, allows the operator to retry by picking a different team or an existing project.
- **`projectCreate` succeeds but the operator has chosen a name that already exists in the team** → Linear's API does allow duplicate names, but for clarity the install warns "a project named '<X>' already exists in this team; create anyway?" and lets the operator confirm or pick an existing one.
- **Network failure mid-`projectCreate`** → install errors out; on retry, the operator will see the just-created project in the picker (if creation actually landed despite the timeout) — no double-create.
- **Operator quits the install at the team picker** → no Linear writes have happened yet; `linear-config.yml` is not written; safe to retry.
- **Operator on macOS Apple-bash 3.2** → install halts at the existing FR-018b dependency check, same as v0.1.0.
- **`.env` already exists with an unrelated `LINEAR_API_KEY` from another extension** → install detects the conflict, warns, and asks the operator to confirm overwrite or use the existing value.
- **Operator installed via `specify extension add ... --dev <local-path>` from a path other than the bridge's own source, and the source had a `.git/` directory** → bridge detects the vendored `.git/` per FR-049, surfaces a warning, but proceeds with install. The operator runs `rm -rf .specify/extensions/linear/.git/` before committing `linear-config.yml`. The fix is documented as an upstream spec-kit CLI bug (the CLI's vendoring logic should skip `.git/` like a `.gitignore`-aware copy).

## Requirements *(mandatory)*

### Functional Requirements

#### Install discovery flow

- **FR-037**: The install MUST resolve the operator's Linear API key BEFORE any other Linear-aware step. Resolution order: (1) `LINEAR_API_KEY` environment variable, (2) `LINEAR_API_KEY=…` line in `.env` at the consumer repo root, (3) interactive `read -s` prompt (echo suppressed). If the operator provides a key via the interactive prompt and confirms "save to .env?", the install MUST append the key to `.env` and ensure `.env` is in `.gitignore`. Non-interactive mode (`--non-interactive` or `--no-prompt`) MUST NOT fall through to (3); it halts with a clear remediation if (1) and (2) both fail.
- **FR-038**: Immediately after resolving the API key, the install MUST verify it by issuing the `viewer { id name email }` GraphQL query. A non-200 response, a `viewer = null` response, or a GraphQL `errors[]` payload MUST halt the install with the verbatim error and a link to Linear's API key creation page. The viewer's `id`, `name`, and `email` MUST be captured for FR-034 and persisted to `linear-config.yml.linear.operator` on success.
- **FR-039**: After the viewer verification succeeds, the install MUST query the teams visible to the API key (`teams(first: 50) { nodes { id name key } }`) and present them to the operator as a numbered list (`1) ACM — Acme`, `2) ENG — Engineering`, …). If the result set has exactly ONE team, the install MUST auto-pick it without prompting and surface the auto-pick in the install summary. If the result set has ZERO teams, the install MUST halt with a clear "no teams accessible" error. The team UUID resolution MUST NOT require the operator to see, type, or paste a UUID at any point in this flow.
- **FR-040**: After the team is picked, the install MUST query the team's existing Projects (`team(id: <UUID>).projects { nodes { id name } }`) and present them as a numbered list with a final "N+1) Create new project" option. The operator MUST be able to pick an existing Project by number to attach to it, or pick "Create new" to drive the projectCreate flow per FR-041. The project UUID resolution MUST NOT require the operator to see, type, or paste a UUID at any point.
- **FR-041**: When the operator picks "Create new project", the install MUST prompt for a project name (default: the consumer repo's directory name), confirm the name with the operator, then issue a `projectCreate(input: { name: <name>, teamIds: [<team-UUID>] })` GraphQL mutation. A `success: false` response MUST halt the install with the verbatim error. On `success: true`, the new project's `id` and `name` MUST be captured and the operator MUST see a link to the new Project in Linear's UI in the install summary.
- **FR-042**: ALL resolved UUIDs (team, project, operator) MUST be written to `linear-config.yml` BEFORE any hook registration, git-hook installation, or Action layer step runs. If the operator quits mid-flow before reaching this step, `linear-config.yml` MUST NOT be written, so a retried install starts clean. If the operator quits AFTER `linear-config.yml` is written, subsequent install steps (hook registration, etc.) MAY be re-run independently — `linear-config.yml` is the durable artifact.
- **FR-043**: The hook registration (`.specify/extensions.yml` merge per FR-031), the local git hooks install (per FR-033), and the optional GitHub Action installation (per FR-027) MUST only run AFTER the operator has confirmed the team and project picks via FR-039 + FR-040 (or FR-041). If any of these later steps fails, `linear-config.yml` MUST remain intact (it is the source of truth for subsequent reconciles).

#### Backwards-compatibility

- **FR-044**: The pre-existing `--team <UUID>` and `--project <UUID>` flags introduced in v0.1.0 MUST continue to work. When both flags are present, the install MUST skip FR-039 and FR-040 entirely and use the passed UUIDs verbatim (after a quick validity check via a single GraphQL query). When only `--team` is passed, the install MUST run FR-040's project picker scoped to that team. When only `--project` is passed (rare; possible when operator already knows the project belongs to a single team they're a member of), the install MUST resolve the team from the project's `team { id }` and skip FR-039.
- **FR-045**: A `--non-interactive` (alias: `--no-prompt`, already exists) flag MUST suppress all interactive prompts. With `--non-interactive`, either both `--team` and `--project` MUST be passed, OR the install MUST halt with a clear error pointing at the v0.1.1 ergonomics path (this preserves the CI / automation safety contract).

#### Self-install safety

- **FR-046**: The bridge's `install.sh` MUST detect when the source extension path and the target consumer-repo path are the same directory (the `--dev` self-install recursion case). Detection: at install start, compute `realpath` of both sides and compare. If equal, the install MUST exit immediately with exit code 2 and a verbatim error message instructing the operator to either (a) install into a different consumer repo, or (b) use the catalog form `specify extension add linear` once it ships. The install MUST NOT write any files to the filesystem in this failure case.
- **FR-047**: The README's Install section MUST document the working `--from <archive-zip-URL>` form (`https://github.com/<owner>/<repo>/archive/refs/heads/main.zip`) as the primary install path until the extension is listed in the spec-kit community catalog, plus the working `--dev <path>` form for local development. The current `--from <repo-url>` form (without `/archive/...`) MUST NOT appear as documented usage because it errors with `BadZipFile` at install time.
- **FR-049**: The bridge's `install.sh` MUST detect a vendored `.git/` directory at `.specify/extensions/linear/.git/` (the spec-kit CLI's `--dev` install ships the source's `.git/` into the consumer repo). On detection, install MUST surface a warning row in the dependency-verification report instructing the operator to `rm -rf .specify/extensions/linear/.git/` before committing `linear-config.yml`, because git silently refuses to track files inside an embedded repo without a submodule binding. Install MUST NOT auto-delete the nested `.git/` (operator's own filesystem; explicit consent required). The operator-side workaround MUST appear in the install summary's "next steps" section.

#### Operator identity (consistency with v0.1.0)

- **FR-048**: The `viewer` query result captured per FR-038 MUST be reused to satisfy FR-034 (operator identity stamping). The install MUST NOT issue a second `viewer` query; the same response feeds `linear-config.yml.linear.operator.{user_id,name,email}` for assigneeId stamping per FR-034.

### Key Entities

- **Linear API key**: An operator's personal API token. Lives in `.env` at the consumer-repo root (gitignored) or in the `LINEAR_API_KEY` environment variable. The single load-bearing input from the operator.
- **Viewer identity**: The `viewer { id name email }` response from the API. Reused for operator UUID (FR-034), display name, and contact in the install summary.
- **Available teams**: The teams the API key has read access to. Presented as a numbered list in the install picker. The first team (single-team workspaces) is auto-picked silently.
- **Available projects (per team)**: The projects of the picked team. Presented as a numbered list with a "Create new" option appended.
- **Resolved binding**: The trio (`team_id`, `project_id`, `operator.user_id`) written to `linear-config.yml`. Once written, all subsequent reconciles read from here — the discovery flow is install-time only.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-009**: A first-time operator with only a Linear API key can complete `/speckit.linear.install` end-to-end in under 2 minutes (measured: time from typing the slash command to seeing the "install complete" summary). v0.1.0 baseline: ~10-15 minutes including the round trip to Linear's UI to dig up UUIDs.
- **SC-010**: ZERO UUIDs are surfaced to the operator at any point in the interactive install flow. A UUID appearing in any prompt, status line, or remediation message is a failed acceptance.
- **SC-011**: The v0.1.0 non-interactive install (`bash src/install.sh --team <UUID> --project <UUID>`) MUST continue to succeed end-to-end with identical behavior to v0.1.0 (regression test). The CI / automation operator path MUST NOT break.
- **SC-012**: An operator following the README's Install section MUST succeed on the first command they run, without errors. Specifically: both the `--from <archive-URL>` form and the `--dev <path>` form (from a path OTHER than the bridge's own source) MUST install cleanly. The self-install case MUST exit with the safety guard rather than corrupting the filesystem.
- **SC-013**: An operator on a workspace with multiple teams, asked to pick a team, MUST be able to identify the right team from the list using ONLY information the install presents (team key + team name). They MUST NOT need to consult Linear's UI to disambiguate.

## Assumptions

- Linear's GraphQL `teams` query returns at least 1 team for any non-empty API key that has at least one workspace membership. (Standard Linear personal API key behavior.)
- Operators have permission to create Projects in the teams they belong to. If not, FR-041 surfaces Linear's permission-denied error verbatim; the operator can fall back to picking an existing project.
- The display threshold for team and project pickers is 20 items. Operators with more than 20 teams or projects use the `--team` / `--project` flags for non-interactive selection. Pagination is v0.2.0 scope.
- `.env` is the canonical secret storage location at the consumer-repo root. Operators using alternative secret stores (1Password CLI, Bitwarden CLI, vault) can `export LINEAR_API_KEY=$(op read …)` in their shell rc; the install honors the env var per FR-037.
- The `viewer` query is sufficient to verify both API key validity and operator identity in a single round-trip. No separate "is this key valid" probe is needed.
- The `projectCreate` mutation's default Project status (Backlog / Planned) is fine for v0.1.1. Setting the initial status to "Started" is handled by FR-002's existing Project Status logic on first reconcile.

## Dependencies

- Linear's GraphQL API endpoints `viewer`, `teams`, `team(id).projects`, `projectCreate` (all already used elsewhere in the bridge — no new external surface).
- The existing `src/install.sh` skeleton (extends it; does not rewrite).
- The existing FR-034 operator identity capture (reused; no duplicate query).
- README's Install section (the operator-facing edit is part of this spec).

## Out of scope

- Pagination of team / project pickers (deferred to v0.2.0 — see Assumptions).
- Filtering of team / project lists by substring (deferred to v0.2.0).
- Per-key OAuth flow (FR-020's OAuth-first principle is honored at runtime; the install ceremony's API-key prompt is the operator-set bootstrap mechanism).
- Updating the install for non-Linear MCP integrations (out of scope; this spec is Linear-specific).
- Migration tooling for operators with v0.1.0 `linear-config.yml` files where UUIDs were entered manually (their config still works — no migration needed because the format is unchanged).
- The team / project picker's display formatting in non-TTY environments (terminal width detection, color etc.) — adopted from existing `summary::emit` patterns; not a v0.1.1 feature.

## Bootstrapping note

This spec is being authored using the v0.1.0 bridge installed against the spec-kit-linear repo itself (meta-dogfood). Each `/speckit.*` command run during the lifecycle of spec 002 will exercise the v0.1.0 bridge's auto-fire path against OSH-INFRA's Linear workspace — the new spec Issue (OSH-15 or similar) tracks 002's progress in real time. The install-ergonomics redesign shipped here will land in v0.1.1, at which point spec 003 onwards will use the new flow.
