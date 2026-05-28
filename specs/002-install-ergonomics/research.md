# Phase 0 Research: Install Ergonomics Redesign

**Branch**: `002-install-ergonomics` | **Date**: 2026-05-28 | **Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Reference doc — one entry per design decision in `plan.md`. Each
decision resolves an open implementation question raised by the
spec's 13 functional requirements (FR-037..FR-049) and connects
back to existing v0.1.0 patterns where one applies.

Citations: `FR-NNN` → `spec.md`; `Principle N` → `.specify/memory/constitution.md`;
`src/install.sh:NNN` → line in the v0.1.0 install entry point;
`v0.1.0 contracts/<file>` → `specs/001-spec-kit-linear-bridge/contracts/<file>`.

---

### 1. Linear GraphQL `teams` query shape and pagination

**Decision**: Issue the teams query as
`teams(first: 21) { nodes { id name key } }` — 21 instead of 20 so
the bridge can detect "overflow" without a separate count query.
If exactly 21 nodes return, the picker displays the first 20 and
appends a warning row instructing the operator to pass `--team
<UUID>` (matches spec.md Edge Case bullet 2 + Clarifications Q2).
No `filter` argument is passed; Linear's default `teams` query
returns teams the API key's user is a member of, ordered by recent
activity — exactly the operator-facing set spec 002 wants.

**Rationale**:

- The official Linear MCP and direct GraphQL both expose the same
  `teams(first:, after:)` connection. v0.1.0's `src/seed.sh:512`
  already queries `team(id: $team) { states { nodes { id name
  type } } }` — the `team`-singular form. Spec 002 needs the
  plural `teams { nodes }` form, which is identical-style
  connection-based GraphQL.
- 21-node fetch is the cheapest "is overflow" signal that doesn't
  require a second query for `pageInfo.hasNextPage`. Saves one
  round trip.
- No filter on `joinedTeams` / `private` is needed — Linear's
  default `teams` already scopes to the API key's user-membership
  set (per the live Linear API docs at
  <https://linear.app/developers/graphql#teams>). For an API key
  issued from Linear's UI, the result set is exactly "teams I am
  a member of and can read".
- The display sort is whatever Linear's API returns (currently
  alphabetical by `name`); spec 002 does not impose a sort, so the
  operator sees the same order they see in Linear's sidebar.

**Alternatives considered**:

- `teams(first: 50)` — rejected; overshoots the 20-item display
  threshold significantly and gives the operator a noisier picker
  with no benefit. The 20-item threshold is the operator-visible
  cap; fetching 21 is the smallest "is there more?" probe.
- Add `filter: { canCreateProjects: { eq: true } }` to filter teams
  where the operator can create projects — rejected; Linear's
  `TeamFilter` does not expose this field. Permission-denied on
  `projectCreate` is surfaced as a verbatim error (FR-041 +
  spec.md Edge Case bullet 3) instead. Cheaper to let the operator
  hit the error and pick a different team than to query Linear's
  permission model up front.
- Paginated `teams(first: 20, after: $cursor)` with a "more" prompt
  — rejected for v0.1.1 per spec.md `## Out of scope` (pagination
  deferred to v0.2.0). The overflow warning + `--team <UUID>`
  escape hatch is the v0.1.1 affordance.

---

### 2. Linear GraphQL `projectCreate` shape and URL capture

**Decision**: Issue `projectCreate(input: { name: <name>, teamIds:
[<team-UUID>] })` exactly. Response schema is
`{ success, project { id name url } }`. Capture `project.url` into
a module global (`INSTALL_RESOLVED_PROJECT_URL`) — v0.1.0 already
does this at `src/install.sh:1060` and surfaces it in the install
summary's "next steps" block. Default `state` is whatever Linear's
workspace settings dictate (typically `Backlog` / `Planned`); the
bridge does NOT pass `state` on create — the v0.1.0 reconciler's
`resolve_project_status` flips it on first reconcile per
v0.1.0 FR-002 / data-model §6.2.

**Rationale**:

- The v0.1.0 install.sh already implements `projectCreate` at
  `src/install.sh:880` (`install::_create_project`) for the
  `--auto-create` flag — spec 002 keeps that function as-is and
  the new discovery flow calls into it. Same wire shape, same
  response handling, same error path.
- v0.1.0's `_create_project` passes `description: "Auto-created by
  speckit.linear.install for spec-kit lifecycle mirroring."`
  — spec 002 preserves that string verbatim for consistency.
- The `project.url` field is part of the standard `Project` GraphQL
  type. The install summary surfaces this URL as a clickable link
  in the "next steps" block so the operator can verify the new
  Project in Linear's UI before running `/speckit-specify`. v0.1.0
  contracts/linear-graphql-mutations.md §3.1 documents this
  pattern for the `save_project` MCP path; spec 002 mirrors it on
  the direct-GraphQL path used by install.
- Passing `state: "Started"` on create would be premature — at
  install time there are zero specs in the repo (or all specs are
  pre-existing and the reconciler will flip on its first run).
  Let Linear's default state win at create; let the reconciler
  flip on its first pass per v0.1.0 FR-002.

**Alternatives considered**:

- Passing `state: "Backlog"` explicitly on create — rejected;
  workspace state names vary (some workspaces don't have a
  "Backlog" status). Trust Linear's default.
- Calling `projectUpdate` immediately after `projectCreate` to set
  initial state — rejected; would duplicate the reconciler's
  job (Principle II / v0.1.0 FR-011 — install is install, sync is
  sync; don't mix layers).
- Pre-checking via `team(id).projects(filter: { name: { eq: $name }
  })` and warning on duplicate — accepted as a sub-step of FR-041
  ("warn 'a project named <X> already exists in this team; create
  anyway?'"). v0.1.0's `install::_find_existing_project`
  (`src/install.sh:843`) already does this lookup; spec 002 reuses
  it.

---

### 3. Interactive bash prompts — numbered list picker pattern

**Decision**: Adopt v0.1.0's existing prompt pattern (verbatim
style match): `IFS= read -r <var>` for visible input,
`IFS= read -r -s <var>` for the API key (no echo per FR-037),
prompts written to stderr (`printf '...' >&2`), validation loops
with a re-prompt on bad input + a clear error message,
EOF handling that halts with a structured error (`install::_die 2
"no input received for <thing>; ..."`). Numbered lists are
emitted as `printf '  %2d) %-8s — %s\n' "$idx" "$key" "$name" >&2`
— two-space indent + zero-padded number + left-aligned 8-char team
key + em-dash + name. The "Create new project" tail option uses
the same formatting with the literal text `Create new project`.

**Rationale**:

- v0.1.0's `src/install.sh:825` (`install::resolve_team_uuid`)
  already uses `IFS= read -r team_uuid` with EOF handling. Spec
  002 keeps the exact pattern so the operator's terminal
  experience is consistent across v0.1.0 and v0.1.1. The "press
  enter to confirm" / "press a number then enter" affordance is
  identical.
- `read -s` (no echo) is mandated by FR-037 for the API key prompt
  specifically. v0.1.0 does not use `-s` anywhere (no v0.1.0
  prompt is for a secret); spec 002 is the first user.
- The numbered-list format mirrors `git branch` and `gh repo list`
  conventions operators already know. Spec.md FR-039 shows the
  literal format `1) HUR — Hurri.AI` — spec 002's emission code
  matches this byte-for-byte (the `printf '%-8s' "$key"` width is
  the max team-key length observed in OSH-INFRA;
  v0.2.0 may raise it to terminal-aware).
- All prompt output goes to stderr so stdout stays clean for any
  caller that pipes install output. Matches v0.1.0's stderr
  discipline (see `install::_log_info` at `src/install.sh:180`).
- Terminal-width detection and color (ANSI sequences) are
  out-of-scope for v0.1.1 per spec.md `## Out of scope` bullet 6.
  The picker is plain text on a typical terminal.

**Alternatives considered**:

- `select` (bash builtin) — rejected; less control over output
  formatting, harder to add the "Create new" tail with a custom
  index, harder to retry on invalid input without an outer loop.
  `select` is also poorly understood by most operators; the
  explicit numbered-list + `read` pattern is more legible.
- `gum choose` or `fzf`-based picker — rejected; introduces a new
  runtime dep contrary to plan.md Technical Context constraint
  "no new runtime deps".
- Color output gated on `[[ -t 2 ]]` (isatty check) — deferred to
  v0.2.0 per spec.md `## Out of scope` bullet 6.

---

### 4. `.env` file editing — append-or-update without clobber

**Decision**: When the operator confirms "save API key to .env?"
per FR-037, the install creates `.env` if absent (`touch .env`),
checks for an existing `LINEAR_API_KEY=…` line via
`grep -q '^LINEAR_API_KEY=' .env`, and:

- **No existing line**: appends `LINEAR_API_KEY=<key>` to `.env`
  with a leading newline if the file is non-empty.
- **Existing line**: prompts the operator to confirm overwrite per
  spec.md Edge Case bullet 8 (`.env conflict`). On confirm, uses
  a portable `awk` rewrite (read all lines, replace the one
  starting with `LINEAR_API_KEY=`, write back) — does NOT use
  GNU `sed -i` (BSD sed on macOS requires `-i ''` which breaks
  portability). On decline, the install proceeds with the
  existing value and the operator's input is discarded.

After write, the install verifies `.env` is in `.gitignore` (via
`grep -q '^\.env$' .gitignore`) and appends `.env` if absent.
Creates `.gitignore` if it doesn't exist. This matches v0.1.0's
existing safety posture (`src/install.sh:684` already checks
`.env` for `LINEAR_API_KEY` but doesn't write — spec 002 adds the
write path).

**Rationale**:

- v0.1.0's `install::check_env_file` (`src/install.sh:682`) is the
  reference for `.env` read patterns. Spec 002's write path mirrors
  it exactly: same grep pattern (`^LINEAR_API_KEY=`), same `.env`
  filename, same gitignored-by-default assumption.
- `awk`-based rewrite is BSD- and GNU-portable. `sed -i` is the
  obvious shorthand but the BSD/GNU divergence is a maintenance
  trap.
- The "ensure .env is in .gitignore" step is mandated by FR-037
  ("MUST append the key to .env and ensure .env is in
  .gitignore"). The bridge appending to `.gitignore` is a
  filesystem mutation under the operator's repo; spec 002 surfaces
  this in the install summary so the operator sees what the
  bridge wrote (Principle VIII / Surface, Don't Enforce).

**Alternatives considered**:

- Writing the key to a separate file (`linear-config.yml.secret`,
  `.env.linear`, etc.) — rejected; multiplies the secret surface
  and contradicts spec.md Clarifications Q1 ("Default to `.env` at
  the repo root").
- Using a `.env.linear` shim that's sourced from `.env` — rejected;
  same multiplication problem and operator confusion (why is
  there an extra file?).
- Always overwriting an existing `LINEAR_API_KEY=` line without
  confirmation — rejected; spec.md Edge Case bullet 8 explicitly
  requires a confirm prompt on conflict.
- Refusing to write to `.env` if any other `LINEAR_API_KEY` is
  already present — rejected; the operator may legitimately want
  to rotate a key during install.

---

### 5. Self-install detection (FR-046) — portable `realpath`

**Decision**: Compute the canonical path of both the source
(extension's checkout) and target (consumer repo's root) via the
portable shell idiom
`(cd "<path>" 2>/dev/null && pwd -P)` — captured into module-local
variables and compared as strings. No GNU `realpath` dependency
(macOS's BSD userland does not ship `realpath` by default; the
`pwd -P` trick is POSIX 2001 and works on every supported
platform). The source path is the directory containing the install
script when it was invoked (`EXTENSION_ROOT` constant in
`src/install.sh:53`); the target path is the consumer repo root
(`git rev-parse --show-toplevel`). If they match, the install
exits with exit code 2 (workspace-config error per v0.1.0
`command-shapes.md` §5.6) and a structured error pointing at
catalog form / different-repo remediation. No files are written
to the target before the comparison runs — the check happens at
the very top of `install::main`, before
`install::run_dependency_report`.

**Rationale**:

- v0.1.0 already uses `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd`
  at `src/install.sh:52-53` to resolve `SCRIPT_DIR` and
  `EXTENSION_ROOT`. Adding `-P` (resolve symlinks) makes the
  comparison robust against operators who installed via a symlink.
- The early-exit posture matches FR-046's mandate ("The install
  MUST NOT write any files to the filesystem in this failure
  case"). Placing the check ABOVE `install::run_dependency_report`
  means even the dependency report doesn't print — the operator
  gets a single, focused error message.
- Exit code 2 matches v0.1.0's "workspace-level config error"
  classification (FR-022 / command-shapes.md §5.6); a CI pipeline
  detecting exit 2 already knows to surface to a human, which is
  the right escalation for a self-install attempt.

**Alternatives considered**:

- `realpath "<path>"` — rejected; not portable across macOS
  default userland. Operators on `brew install coreutils` (GNU
  realpath via `grealpath`) are not the install ceremony's
  audience.
- `readlink -f "<path>"` — rejected; BSD readlink lacks `-f`. Same
  portability problem.
- Python `os.path.realpath` via a one-liner — rejected; introduces
  a Python runtime dep contrary to plan.md constraints.
- Comparing `EXTENSION_ROOT` against `$(git rev-parse
  --show-toplevel)` directly without `pwd -P` — rejected; misses
  the symlink case (operator with a symlinked dev checkout would
  bypass the guard).

---

### 6. Vendored `.git/` detection (FR-049) — operator-actionable warning

**Decision**: After the self-install guard passes and before the
team-discovery flow runs, check
`[ -d ".specify/extensions/linear/.git" ]` from the consumer repo
root. If present, emit a `warn` row in
`install::run_dependency_report` with the exact text:

```text
.specify/extensions/linear/.git/ vendored from --dev install;
remediation: rm -rf .specify/extensions/linear/.git/
(spec-kit CLI bug: --dev install ships source .git/ into target;
git silently refuses to track files inside an embedded repo)
```

The warning is also re-surfaced in the install summary's "next
steps" block (FR-049: "operator-side workaround MUST appear in the
install summary's 'next steps' section"). The install proceeds —
does NOT halt — because the operator may have legitimate reasons
to keep the nested `.git/` (e.g. they vendored intentionally and
will set up a submodule). Auto-deletion is explicitly forbidden
per Principle VIII / Surface, Don't Enforce.

**Rationale**:

- v0.1.0's `install::run_dependency_report` (`src/install.sh:702`)
  is the canonical dispatcher for FR-018b dependency rows. Adding
  a vendored-`.git/` row there keeps the operator's
  status-checking surface consistent — they already scan this
  report at install start.
- The warning format (`install::_status_row "warn" ...` at
  `src/install.sh:390`) is v0.1.0's locked `[ok|warn|err]` row
  pattern. Spec 002 reuses it without modification.
- Re-emitting the warning in the install summary's "next steps"
  block is FR-049's explicit mandate. The dependency report is
  the *early* surface (operator sees it before pickers run); the
  summary's "next steps" is the *late* surface (operator sees it
  after install succeeds and is about to commit).

**Alternatives considered**:

- Auto-deleting the nested `.git/` after operator confirmation —
  rejected per FR-049 ("Install MUST NOT auto-delete the nested
  `.git/` (operator's own filesystem; explicit consent required)")
  and Principle VIII / Surface, Don't Enforce.
- Failing the install outright when a vendored `.git/` is
  detected — rejected; the operator may have intentionally
  vendored and would face a chicken-and-egg blocker. Warning +
  proceed is the conservative path.
- Adding a `--ignore-vendored-git` flag to silence the warning —
  rejected; introduces a flag for a one-off operator state. The
  remediation (`rm -rf .specify/extensions/linear/.git/`) is the
  operator's one-liner; no flag needed.

---

## Remaining unknowns

None. Every implementation question raised by spec 002's 13 FRs
resolves to a v0.1.0 pattern already in `src/install.sh` or a
direct extension of that pattern. The `tasks.md` step (Phase 2)
will lay out the work in dependency order, but no further research
is blocked.

## Research artifact index

- `src/install.sh` (v0.1.0, 2087 lines) — the entry point spec 002
  extends. Key reference points:
  - `:52-53` — SCRIPT_DIR / EXTENSION_ROOT resolution (for FR-046)
  - `:284-377` — `install::parse_args` (extended in spec 002)
  - `:682-694` — `install::check_env_file` (read pattern for FR-037)
  - `:702-731` — `install::run_dependency_report` (extended for FR-049)
  - `:843-870` — `install::_find_existing_project` (reused by FR-040)
  - `:880-914` — `install::_create_project` (reused by FR-041)
  - `:1093-1127` — `install::resolve_operator` (reused by FR-038, FR-048)
- `src/graphql.sh` (v0.1.0, 457 lines) — `graphql::query` and
  `graphql::mutate` are the only HTTP surface used by spec 002.
- `v0.1.0 contracts/config-schema.json` — JSON schema for
  `linear-config.yml`. UUID patterns + `linear.operator` block
  unchanged by spec 002.
- `v0.1.0 contracts/linear-graphql-mutations.md` §2 + §3 — direct
  GraphQL surface spec 002 reuses.
- `v0.1.0 quickstart.md` Step 1 — the install ceremony's existing
  shape; spec 002's quickstart mirrors its structure.
- Live Linear GraphQL docs at <https://linear.app/developers/graphql>
  — authoritative reference for `viewer`, `teams`, `team(id).projects`,
  `projectCreate` field shapes.
- `validation/dogfood-001.md` — origin point of spec 002 (real
  operator feedback during the first dogfood into
  `~/Code/HURRI_AI/backend`).
