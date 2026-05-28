# Install Prompts — Operator Interaction Contract

**Status**: Phase 1 contract for spec 002. Locks the operator-facing
prompt surface for every interactive step in the discovery flow
(FR-037, FR-039, FR-040, FR-041). The exact prompt text, validation
rules, EOF behavior, and retry posture below are normative — any
implementation deviation MUST update this contract first.

**Companions**:
[`install-discovery-graphql.md`](./install-discovery-graphql.md)
documents the GraphQL operations that fire between prompts.
[`install-flags.md`](./install-flags.md) documents which prompts
each CLI flag suppresses.

## 1. Prompt mechanics — universal rules

These rules apply to EVERY prompt in §2-§5 unless explicitly
overridden.

| Rule | Behavior |
|---|---|
| **Output channel** | Prompts go to **stderr** via `printf '...' >&2`. Stdout is reserved for any caller piping install output. |
| **Read pattern** | `IFS= read -r <var>` for visible input. `IFS= read -r -s <var>` for the API key (echo suppressed per FR-037). |
| **Trimming** | Input is trimmed of surrounding whitespace via `${var#"${var%%[![:space:]]*}"}` style parameter expansion. Empty after trim → treated as "no input". |
| **EOF handling** | `read` returns non-zero on EOF (Ctrl-D, piped /dev/null, etc.). When this happens during a required prompt, the install halts with exit 2 + a structured error pointing at the non-interactive flag path. Match v0.1.0's `install::_die 2 "no input received for <thing>; pass --<flag> <value> or run interactively"` pattern. |
| **Ctrl-C handling** | Honored as a normal `SIGINT` exit. No cleanup needed before S6 (no files written yet). After S6, `linear-config.yml` is the durable artifact; subsequent hook-registration steps may be re-run independently per FR-042. |
| **Retry posture** | Invalid input (out-of-range number, malformed name) prints a structured error and re-prompts WITHOUT consuming a "retry budget". The operator has unlimited retries on every prompt — there is no max-retry cutoff. |
| **Default values** | Prompts that offer a default show it in square brackets: `[default]:`. Pressing enter on empty input accepts the default. |
| **Numbered list pickers** | Format: `%2d) <key-or-name>` (two-space indent + zero-padded number). Range check is `1 <= N <= len(options)`; out-of-range surfaces `invalid choice "<N>"; pick a number between 1 and <max>` and re-prompts. |
| **Vocabulary** | All prompts use canonical spec-kit vocabulary per Principle VIII. No "wave", "W0", etc. |
| **Non-interactive mode** | Every prompt in §2-§5 is SKIPPED when `--non-interactive` is in effect AND the corresponding flag (`--team`, `--project`) is set. Reaching a prompt under `--non-interactive` without the satisfying flag halts with exit 2. |

---

## 2. P1 — API key prompt (FR-037)

Fires only when neither `LINEAR_API_KEY` env var nor `.env` line
is present AND `--non-interactive` is NOT set.

### 2.1 Prompt text (verbatim)

```text
[linear] Linear API key (input hidden — paste & enter):
```

Followed by a blank stderr line + `read -r -s api_key`.

### 2.2 Validation

- Empty input → re-prompt with `[linear] API key cannot be empty; paste your key (or Ctrl-C to abort):`.
- Non-empty input → no further validation at prompt time;
  validity is verified by the immediately-following `viewer`
  query (P2 — implicit, not a prompt).

### 2.3 "Save to .env?" follow-up (FR-037)

If the key was supplied interactively (NOT from env var or
`.env`), the install immediately follows the key prompt with:

```text
[linear] Save LINEAR_API_KEY to .env at the repo root? .env is
         gitignored (the install will add it if missing).
         [Y/n] (default: Y):
```

- `Y` / `y` / empty (default) → write `LINEAR_API_KEY=<value>` to
  `.env`, ensure `.env` is in `.gitignore`. Per research.md §4:
  append if absent; prompt before overwriting an existing
  `LINEAR_API_KEY=` line per spec.md Edge Case bullet 8.
- `N` / `n` → skip write; key lives only in `INSTALL_SESSION_API_KEY`
  for this install's `graphql::query` calls. Operator will be
  re-prompted on the next install.
- Any other input → re-prompt with `[linear] Pick Y or n:`.

### 2.4 `.env` conflict sub-prompt (spec.md Edge Case bullet 8)

When `.env` already contains a `LINEAR_API_KEY=…` line that
differs from the just-entered key:

```text
[linear] .env already has a LINEAR_API_KEY (from another extension or
         a previous install). Overwrite with the key you just entered,
         or keep the existing one?
         [overwrite/keep/abort] (default: keep):
```

- `overwrite` → portable `awk`-rewrite of `.env` (per research.md §4).
- `keep` (default) / empty → discard the just-entered key, re-resolve
  from `.env` for the rest of the install.
- `abort` → exit 0 (clean abort, no files written).

### 2.5 EOF behavior

EOF on the API key prompt halts with exit 2:

```text
[linear] no input received for API key; pass via .env or LINEAR_API_KEY
         env var, or run interactively.
```

EOF on the "save to .env?" prompt is treated as `N` (default-safe;
no write).

---

## 3. P2 — Team picker (FR-039)

Fires after `viewer` succeeds and `teams` query returns ≥2 nodes
(see §3.4 for the auto-pick branch). Skipped entirely when
`--team <UUID>` is passed.

### 3.1 Prompt text (verbatim)

```text
[linear] Teams accessible to this API key:
  1) OSH      — OSH
  2) ENG      — Engineering
  3) DESIGN   — Design Studio
Pick a team [1-3]:
```

(The team-key field is `%-8s` padded; max Linear team-key length is
5 characters per the Linear team URL constraint. The em-dash is
the locked separator per FR-039.)

### 3.2 Validation

- Non-numeric input → `[linear] invalid choice "<input>"; pick a
  number between 1 and <N>:` and re-prompt.
- Out-of-range number → same as above.
- Valid number → set `selected_team_id` / `selected_team_key` /
  `selected_team_name` from `available_teams[choice-1]`.

### 3.3 Overflow row (>20 teams)

When `teams.nodes.length > 20`, the picker displays the first 20
and appends BEFORE the `Pick a team [1-20]:` prompt:

```text
  ... and <N-20> more not shown.
  Pass --team <UUID> to install non-interactively (find the UUID at
  https://linear.app/<workspace>/settings/api or via
  `bash src/install.sh --list-teams` once that flag ships in v0.2.0).
```

### 3.4 Auto-pick (single team)

When `teams.nodes.length == 1`, no prompt fires. Instead:

```text
[linear] Found 1 team accessible — using OSH (OSH Infra) (auto-picked).
         Override with --team <UUID> on next install.
```

The install continues to the project picker immediately.

### 3.5 Zero teams (FR-039 / spec.md Edge Case 1)

When `teams.nodes.length == 0`, no prompt fires. Install halts:

```text
[linear] no teams accessible to this API key.
         fix: check workspace membership at
         https://linear.app/<workspace>/settings/teams or use a
         different API key.
```

Exit code 2.

### 3.6 EOF / Ctrl-C

EOF or Ctrl-C on the team picker → halt with exit 2 + the FR-045
non-interactive remediation pointer:

```text
[linear] no team selected. Pass --team <UUID> or run interactively
         to pick from the list above.
```

---

## 4. P3 — Project picker (FR-040)

Fires after team is selected (auto or interactive). Skipped when
`--project <UUID>` is passed.

### 4.1 Prompt text (verbatim)

When `projects.nodes.length >= 1`:

```text
[linear] Projects in OSH:
  1) spec-kit-linear
  2) acme-backend
  3) Create new project
Pick a project [1-3]:
```

When `projects.nodes.length == 0`:

```text
[linear] No existing projects in OSH.
  1) Create new project
Pick a project [1-1]:
```

### 4.2 Validation

Same range-check as P2. Valid number sets:

- If choice == `N+1` (the "Create new" tail): set
  `project_choice = "create"`; fall through to P4 (§5).
- Otherwise: set `project_choice = "attach"`;
  `selected_project_id` / `selected_project_name` from
  `available_projects[choice-1]`; jump to S6 (write config).

### 4.3 Overflow row (>20 projects)

When `projects.nodes.length > 20`, the picker displays the first
20 + the "Create new" tail (so the prompt is `Pick a project
[1-21]:`). Before the prompt:

```text
  ... and <N-20> more not shown.
  Pass --project <UUID> to install non-interactively.
```

### 4.4 EOF / Ctrl-C

Same as P2: halt with exit 2 + FR-045 remediation. No partial
state written.

---

## 5. P4 — New project name prompt (FR-041)

Fires only when operator picks "Create new project" at P3. The
prompt sequence has TWO steps: name input, then confirm.

### 5.1 Name prompt (verbatim)

```text
[linear] New Linear Project name [<repo-basename>]:
```

Where `<repo-basename>` is the consumer repo's directory name
(`basename "$(git rev-parse --show-toplevel)"`). Pressing enter on
empty input accepts the default.

### 5.2 Name validation

- Empty after trim AND no default available (theoretically
  impossible; repo basename is always set) → re-prompt.
- Linear's `Project.name` constraint is "1-128 chars, non-empty".
  Bridge does NOT enforce the upper bound — Linear's
  `projectCreate` will reject with a verbatim error and the
  install surfaces that per FR-041.

### 5.3 Duplicate-name pre-check (spec.md Edge Case 4)

Before issuing `projectCreate`, the install queries
`team(id).projects(filter: { name: { eq: <name> } })` per
[install-discovery-graphql.md §4](./install-discovery-graphql.md).
If a match exists:

```text
[linear] A project named "<name>" already exists in OSH.
         [create-anyway/pick-existing/rename] (default: pick-existing):
```

- `pick-existing` (default) / empty → set
  `selected_project_id` to the existing project's UUID; jump to S6.
- `create-anyway` → proceed to confirm (§5.4).
- `rename` → loop back to name prompt (§5.1).

### 5.4 Confirm prompt (verbatim)

```text
[linear] Create new Linear Project "<name>" in OSH? [Y/n] (default: Y):
```

- `Y` / `y` / empty (default) → fire `projectCreate` mutation.
- `N` / `n` → loop back to name prompt (§5.1) with the just-typed
  name as the new default.

### 5.5 Post-create surface (verbatim)

On `projectCreate.success == true`:

```text
[linear] Created Linear Project: <project.url>
         Project ID is recorded internally and written to
         .specify/extensions/linear/linear-config.yml.
```

The `project.url` is the operator's path back to Linear's UI to
verify the new project. Per SC-010, no UUID is printed.

### 5.6 Failure surface

On `projectCreate.success == false`:

```text
[linear] projectCreate failed: <verbatim Linear error>
         Re-run install to try again (your team selection is
         remembered), or pick an existing project.
```

Exit code 1 (recoverable).

### 5.7 EOF / Ctrl-C on any P4 step

Halt with exit 2; no `linear-config.yml` written.

---

## 6. P5 — Action install prompt (existing; unchanged from v0.1.0)

The optional GitHub Action installation prompt
(`install::prompt_action_install` at `src/install.sh:1934`) is
**unchanged from v0.1.0**. Spec 002 does not modify its text,
validation, or behavior. Documented here only so reviewers see
the full operator-facing prompt set in one place.

### 6.1 Prompt text (verbatim, from v0.1.0)

```text
[linear] Install Layer E (GitHub Action webhook)? Adds
         .github/workflows/spec-kit-linear-sync.yml and requires
         LINEAR_API_TOKEN GitHub secret. [y/N]
```

Suppressed by `--with-action` (auto-accept) or `--no-action`
(auto-decline). See [install-flags.md](./install-flags.md) §4.

---

## 7. Summary block (post-discovery)

Not a prompt, but the structured summary the install emits AFTER
S7 completes. Format mirrors v0.1.0's `summary::emit`. Includes
two new spec-002-specific rows:

| Row | Source | Example |
|---|---|---|
| `Key sourced from` | `InstallSession.api_key_source` | `Key sourced from: interactive_saved (written to .env)` |
| `Vendored .git/ warning` | conditional on FR-049 detection | `Vendored .git/ present: rm -rf .specify/extensions/linear/.git/ before committing` |
| `Open in Linear` | `InstallSession.selected_project_url` | `Open in Linear: https://linear.app/osh-infra/project/spec-kit-linear-97bca3d5ede3` |

All other summary rows are unchanged from v0.1.0.

---

## 8. Prompt index (for reviewers)

| # | Prompt | Fires when | Skippable via | FR |
|---|---|---|---|---|
| P1 | API key (`read -s`) | No env var, no `.env` line, NOT `--non-interactive` | `LINEAR_API_KEY` env var; `.env` line | FR-037 |
| P1a | "Save to .env?" | P1 fired and key was entered interactively | `--non-interactive` (P1 wouldn't have fired) | FR-037 |
| P1b | `.env` conflict | P1a got `Y` and `.env` already has a different key | none — explicit consent required per spec.md Edge Case 8 | FR-037 |
| P2 | Team picker | `teams.length >= 2` | `--team <UUID>` | FR-039 |
| P3 | Project picker | always (unless `--project`) | `--project <UUID>` | FR-040 |
| P4 | New project name + confirm | P3 chose "Create new" | `--project <UUID>` (P3 short-circuited) | FR-041 |
| P4a | Duplicate-name handler | P4's name already exists in team | none — explicit consent required per spec.md Edge Case 4 | FR-041 |
| P5 | Action install (v0.1.0) | unchanged | `--with-action` / `--no-action` | FR-027 |

**Total interactive prompts in spec 002: 7** (P1, P1a, P1b, P2,
P3, P4, P4a). P5 is unchanged.

---

## Cross-references

- [data-model.md §4](./data-model.md) — discovery state machine
  that orchestrates prompts.
- [install-discovery-graphql.md](./install-discovery-graphql.md)
  — GraphQL operations between prompts.
- [install-flags.md](./install-flags.md) — which CLI flags suppress
  which prompts.
- [research.md §3](./research.md) — rationale for `read` / numbered-list
  picker pattern choice.
- [research.md §4](./research.md) — rationale for `.env` editing
  posture.
- v0.1.0 quickstart [`Step 1`](../../001-spec-kit-linear-bridge/quickstart.md)
  — the v0.1.0 prompt baseline spec 002 extends.
