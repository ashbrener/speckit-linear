# Extension Manifest Contract (`extension.yml`)

**Status**: Phase 1 contract. Documents every field in
`/Users/ashbrener/Code/AI/speckit-linear/extension.yml` and the
spec-kit CLI behaviour each field controls. Companion to the live
manifest; both files MUST stay in lockstep.

**Source of CLI behaviour**: `validation/extension-shape-recon.md`
§3 ("`specify extension add` mechanics"), traced from
`~/.local/share/uv/tools/specify-cli/lib/python3.13/site-packages/specify_cli/extensions.py`.
Line references below cite that source.

---

## 1. Identity (`extension.{id,name,version,description,...}`)

### `schema_version`

```yaml
schema_version: "1.0"
```

- **CLI behaviour**: extensions.py:119 hard-requires this to equal
  `"1.0"`. Any other value aborts `specify extension add` before
  the manifest is even fully parsed. Quoted string, not number.
- **Stability**: spec-kit framework-level field. The bridge cannot
  bump it unilaterally; bumps follow upstream spec-kit releases.

### `extension.id`

```yaml
extension:
  id: "linear"
```

- **CLI behaviour**: Validated against `^[a-z0-9-]+$` (extensions.py:157+).
  Becomes the directory name under
  `<consumer>/.specify/extensions/<id>/` (the literal `shutil.copytree`
  target at extensions.py:1175). All command names below MUST be
  prefixed `speckit.<id>.` per extensions.py:182.
- **Per-install effect**: A consumer repo invoking
  `specify extension add linear` gets
  `.specify/extensions/linear/` populated with the full source tree
  (minus `.extensionignore` matches).
- **Stability**: **Locked v1**. Renaming `id` breaks every existing
  install — the consumer's `.specify/extensions.yml` references
  hooks by `extension: linear`, and renaming orphans them. Treat as
  semver-major.

### `extension.name`

```yaml
extension:
  name: "speckit-linear"
```

- **CLI behaviour**: Display string surfaced in
  `specify extension list` and the community catalog UI. No
  validation beyond presence + string type. Distinct from `id` —
  `id` is the directory key, `name` is the human label.
- **Stability**: Cosmetic; change at will across minor bumps. The
  bridge keeps the `speckit-` prefix to make the extension's
  purpose obvious in catalog rows.

### `extension.version`

```yaml
extension:
  version: "0.1.0.dev0"
```

- **CLI behaviour**: Validated as PEP 440 (extensions.py:157+). Any
  non-PEP-440 string aborts install. Stored in
  `.specify/extensions/.registry` after install so the CLI can
  surface upgrade prompts.
- **Stability**: Bumped per **semver, not PEP 440 semantics**:
  patch for non-functional fixes, minor for additive (new
  command, new optional hook), major for breaking changes to
  `id`, hook semantics, config schema, or command shapes. PEP 440
  is just the wire format spec-kit enforces.

### `extension.description`

- One-line description shown in `specify extension list` and the
  catalog. No validation. The bridge keeps it identical to the
  GitHub repo's `description` field for symmetry.

### `extension.{author,repository,license,homepage}`

- Optional. extensions.py does not validate beyond string type.
  Operators read these in the catalog UI. The bridge populates all
  four for self-describing manifests.

---

## 2. `requires.speckit_version`

```yaml
requires:
  speckit_version: ">=0.1.0"
```

- **CLI behaviour**: REQUIRED per extensions.py:157+ — install
  aborts if missing. The only `requires.*` field the CLI validates;
  every other runtime dependency check (Linear MCP wiring, OAuth
  status, `gh` CLI presence, bash 4+, local git hook writability)
  is the bridge's own responsibility per FR-018b.
- **Per-install effect**: CLI parses the version spec (PEP 440
  range) and refuses to install if the running `specify` version
  doesn't satisfy it.
- **Stability**: Conservative `>=0.1.0` per sibling-extension
  norm. Bumping this locks out older spec-kit installs; only bump
  when a specific framework feature forces it.

---

## 3. `provides.commands` (the five `speckit.linear.*` entries)

```yaml
provides:
  commands:
    - name: "speckit.linear.push"
      file: "commands/linear-push.md"
      description: "..."
    - name: "speckit.linear.pull"
      file: "commands/linear-pull.md"
      description: "..."
    - name: "speckit.linear.status"
      file: "commands/linear-status.md"
      description: "..."
    - name: "speckit.linear.seed"
      file: "commands/linear-seed.md"
      description: "..."
    - name: "speckit.linear.install"
      file: "commands/linear-install.md"
      description: "..."
```

### 3.1 Three-dot naming rule

- **CLI behaviour**: Each `name` MUST match
  `speckit.<extension.id>.<sub>` (extensions.py:182+). The CLI
  auto-corrects bare `speckit.foo` or `<id>.foo` to the canonical
  form but **rejects** any other shape (e.g. `linear-push`,
  `speckit-linear.push`, `speckit.linear-push`). The bridge spells
  every name in the full three-dot form so nothing depends on
  auto-correction.
- **Skill auto-generation**: When the consumer ran
  `specify init --ai-skills`, extensions.py:836
  `_register_extension_skills()` writes one SKILL.md per command
  at `.claude/skills/speckit-linear-<sub>/SKILL.md`. The dot-name
  (`speckit.linear.push`) becomes the slash-command form
  (`/speckit-linear-push`) by replacing dots with dashes.
- **Hook dispatch**: speckit-taskstoissues's Pre/Post-Execution
  blocks (`validation/extension-shape-recon.md` §2) translate
  dot-name → slash-name when firing `EXECUTE_COMMAND` directives.

### 3.2 `file` paths

- **CLI behaviour**: Paths relative to the extension root. After
  `shutil.copytree`, the path is preserved verbatim under
  `.specify/extensions/linear/`. The host AI agent (Claude Code,
  etc.) reads the markdown body and executes the algorithmic
  steps inline.
- **Per-install effect**: Every `file` MUST exist in the source
  tree (the bridge's CI lints this). Missing files don't abort
  install (the CLI doesn't validate file existence) — they
  surface as a runtime error when the operator invokes the
  command.

### 3.3 The five commands

| Command | Role | FR |
|---|---|---|
| `speckit.linear.push` | Core reconcile entry point (filesystem → Linear). The only path that mutates Linear. Target of every `after_*` hook below. | FR-001, FR-010 |
| `speckit.linear.pull` | Read-only inspection of Linear state. Used from non-authoritative worktrees per FR-026 where push is forbidden. | FR-026 |
| `speckit.linear.status` | Structured sync-status report (drift detection, per-spec phase, worktree write-authority). | FR-023, FR-024 |
| `speckit.linear.seed` | One-shot workspace seed (labels + workflow states). Safe to re-run. Required before first push per FR-022. | FR-021, FR-032 |
| `speckit.linear.install` | Install ceremony with structured dependency report. NOT silent per FR-018b. | FR-018, FR-018b |

Detailed shapes in `command-shapes.md`.

### 3.4 Stability

- Adding a new command: **minor** bump.
- Removing a command: **major** bump (existing operators have
  the slash-command in muscle memory and hooks may reference it).
- Renaming a command: **major** bump.
- Tweaking a command's description: **patch** bump.

---

## 4. `provides.hooks` (the six `after_*` entries)

```yaml
provides:
  hooks:
    after_specify:
      - command: "speckit.linear.push"
        description: "..."
        prompt: "Reconciling spec.md → Linear..."
        optional: false
        enabled: true
    after_clarify:   [...]
    after_plan:      [...]
    after_tasks:     [...]
    after_implement: [...]
    after_analyze:   [...]
```

### 4.1 CLI behaviour at install

- extensions.py `HookExecutor.register_hooks()` mutates the
  consumer's `.specify/extensions.yml` to add one entry per hook,
  keyed by `(extension, hook_name)` and **deduplicated** on
  re-install (extensions.py:2607-2614). Re-running
  `specify extension add linear` is naturally idempotent.
- The consumer's `.specify/extensions.yml` after install looks
  like (per recon §3):

```yaml
schema_version: "1.0"
installed:
  - linear
hooks:
  after_specify:
    - extension: linear
      command: speckit.linear.push
      enabled: true
      optional: false
      prompt: "Reconciling spec.md → Linear..."
      description: "..."
```

### 4.2 `optional: false` semantics (FR-031)

- **`optional: false`** means: the hook fires automatically with
  NO operator prompt. The host agent enforces this by awaiting
  the dispatched command before returning control. This is the
  "memory just works" default per Principle VII.
- **`optional: true`** would prompt the operator each fire. The
  bridge never ships this; opt-out is via `enabled: false`, not
  via prompt fatigue.

### 4.3 `enabled: true` and operator opt-out

- **`enabled: true`** is the default at register time.
- The operator MAY disable any hook by editing
  `.specify/extensions.yml` to `enabled: false`. The bridge MUST
  honour that on re-install (extensions.py dedup preserves the
  operator's `enabled` value rather than reverting to `true`).
- A future re-enable requires the operator to flip it back
  manually; the bridge MUST NOT silently re-enable.

### 4.4 Why all six hooks point at `speckit.linear.push`

The reconciler is the single convergent operation per Principle II
("Reconcile, Never Event-Push"). There is no per-phase
specialisation; each hook re-runs the full reconcile against
filesystem state, which always converges to the correct Linear
state regardless of which hook fired. This is what makes the
bridge cheap to re-trigger.

### 4.5 NO `before_*` hooks

The bridge never pre-empts a lifecycle step. Contrast with
speckit-red-team's `before_plan` gate (per recon §1). The bridge
follows lifecycle commands; it does not gate them.

### 4.6 Stability

- Adding a new `after_*` hook (e.g. `after_red_team` when
  speckit-red-team standardises that hook name): **minor** bump.
- Removing an `after_*` hook: **major** bump (operators may rely
  on the auto-sync).
- Changing `optional: false` → `true`: **major** bump (changes
  operator-visible UX).
- Tweaking `prompt:` or `description:`: **patch** bump.

---

## 5. `provides.config` (informational only)

```yaml
provides:
  config:
    - name: "linear-config.yml"
      template: "config-template.yml"
      description: "..."
      required: true
```

### 5.1 What the CLI does

**Nothing automatic.** Per `validation/extension-shape-recon.md`
§1 ("Key finding"), the CLI does NOT read `config[].template` to
copy `config-template.yml` → `linear-config.yml`. The README's
"scaffolds the catalog" claim in sibling extensions is
aspirational. extensions.py never auto-renames or copies config
templates.

### 5.2 What the bridge does instead

`speckit.linear.install` (FR-018) performs the copy itself:

1. Detects whether `.specify/extensions/linear/linear-config.yml`
   exists.
2. If absent: copies the shipped `config-template.yml` to
   `linear-config.yml`, runs the prompt flow (FR-002) to fill in
   `linear.team.id` + `linear.project.id`, and writes the result.
3. If present: re-validates the schema (per
   `contracts/config-schema.json`), warns on drift, never
   overwrites.

`speckit.linear.seed` populates `linear.workflow_state_uuids`
(FR-021, FR-032) after creating the nine workflow states.

### 5.3 Why we still ship `provides.config`

Operators reading the manifest expect to see the runtime config
file declared. The block makes the contract self-describing —
"which file do I need, where does its template live, is it
required at runtime" — even though no framework code consumes
the metadata.

### 5.4 `required: true`

Informational. Enforced by `src/config.sh` at runtime: a reconcile
invoked against a repo lacking `linear-config.yml` exits with code
2 (workspace-level config error per FR-022) and points the
operator at `speckit.linear.install`.

### 5.5 Stability

- Renaming `name: "linear-config.yml"`: **major** bump (operators
  may have committed git history under the old name).
- Changing `template: "config-template.yml"`: **major** bump
  (breaks the install copy step).

---

## 6. `tags`

```yaml
tags:
  - "issue-tracker"
  - "linear"
  - "tasks-sync"
  - "lifecycle-mirror"
  - "memory"
  - "cross-repo"
```

- **CLI behaviour**: Free-form; no validation. Used by the
  community catalog for keyword search and faceted filters.
- **Stability**: Add/remove tags freely on **patch** bumps.

---

## 7. `defaults`

```yaml
defaults:
  mcp_endpoint: "https://mcp.linear.app/mcp"
  oauth_scopes:
    - "read"
    - "write"
    - "issues:create"
    - "comments:create"
```

### 7.1 CLI behaviour

- extensions.py exposes `defaults` to the bridge's commands via
  the `ConfigManager` (extensions.py:2197+). The bridge's command
  markdowns / shell scripts may read these values at runtime.
- No validation beyond YAML well-formedness. The CLI does NOT
  cross-check `mcp_endpoint` against `.mcp.json` or verify OAuth
  scopes — those checks are the bridge's responsibility per
  FR-018b.

### 7.2 `defaults.mcp_endpoint`

- The Linear MCP HTTP endpoint per
  `validation/linear-mcp-tool-signatures.md` §"Server". The
  install step writes this into the consumer's `.mcp.json`
  (creating the file if absent) and confirms the operator has
  authed against it at least once before completing.
- **Stability**: Linear has explicitly deprecated the SSE
  endpoint (`/sse`) in favour of `/mcp`
  (`linear-mcp-tool-signatures.md` §5). The bridge tracks the
  Linear-side URL; bumps here are **minor** (operators re-auth
  on install) unless Linear introduces a breaking surface
  change, in which case **major**.

### 7.3 `defaults.oauth_scopes`

- Best-guess scope set per `linear-mcp-tool-signatures.md` §4.
  The install command verifies the actual granted scopes via an
  introspection query and warns on any missing scope rather than
  silently proceeding (FR-018b).
- **Stability**: Adding scopes (e.g. if Linear surfaces a new
  read scope the bridge wants) is **minor**. Removing a scope
  the operator had granted is **patch** (operators may re-auth
  on next install for cleanliness but their existing token still
  works).

### 7.4 No secrets in `defaults`

This block is committed to a public repo and MUST stay
secret-free. The bridge's two real secrets live elsewhere:

- `LINEAR_API_TOKEN` (GitHub repo secret, FR-029) — Layer E only.
- `LINEAR_API_KEY` (consumer's `.env`, FR-020, gitignored) —
  direct-GraphQL paths (git hooks, seed step, local Action run).

The bridge's MCP OAuth credentials live in the operator's MCP-host
keychain (Principle VI); the manifest never references them.

---

## 8. Fields the manifest deliberately OMITS

| Field | Why omitted |
|---|---|
| `provides.skills` | Not a real extensions.py field. SKILL.md generation is automatic per command (extensions.py:836) when `--ai-skills` was set at consumer init. |
| `requires.bash` / `requires.gh` / `requires.curl` | extensions.py only validates `requires.speckit_version`. Every other runtime dep is checked at install-time by `speckit.linear.install` per FR-018b. |
| `provides.hooks.before_*` | The bridge never gates lifecycle commands (Principle VIII — Surface, Don't Enforce). |
| `provides.scripts` | Not a real field. Scripts live in `src/` and are invoked by command markdowns; the CLI does not register them. |
| `dependencies` | Reserved for spec-kit framework use; community extensions leave it unset. |

---

## 9. Stability commitment

### What semver-major means for this manifest

- Renaming `extension.id`.
- Removing or renaming any `provides.commands` entry.
- Removing any `provides.hooks` entry, or flipping `optional: false` → `true`.
- Renaming `linear-config.yml` or `config-template.yml`.
- Removing any workflow-state key from the implicit lifecycle
  contract (the seven `after_*` hooks plus the
  `workflow_state_uuids` keys — those are coupled).

### What semver-minor means

- Adding a new `provides.commands` entry.
- Adding a new `after_*` hook (e.g. `after_red_team` when the
  upstream framework standardises that hook name).
- Adding fields to `defaults`.
- Adding `tags`.
- Adding OAuth scopes to `defaults.oauth_scopes`.

### What semver-patch means

- Tweaking any `description` or `prompt` string.
- Bumping `author` / `repository` / `homepage` / `license` metadata.
- Removing / re-ordering `tags`.
- Removing an unused OAuth scope.

### Validation in CI

The bridge's own `.github/workflows/ci.yml` runs:

- `yamllint extension.yml` (well-formed YAML).
- A custom check that every `provides.commands[*].file` exists.
- A custom check that every `provides.hooks.*[*].command` is in
  the `provides.commands` set.
- A custom check that this contract file lists every field
  present in `extension.yml` (no drift between the manifest and
  the contract).

The fourth check is the load-bearing one: this contract must
stay in lockstep with the live manifest. If a contributor adds a
new field to `extension.yml`, CI fails until this file gets the
matching entry.
