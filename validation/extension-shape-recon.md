# Spec-Kit Extension Shape — Recon for spec-kit-linear

Source-of-truth research for the file/directory contract `specify extension add linear` requires. Built from (1) `a sibling extension repo/` as the sibling extension, (2) the bundled `speckit-taskstoissues` skill, (3) the specify-cli Python source at `~/.local/share/uv/tools/specify-cli/lib/python3.13/site-packages/specify_cli/`.

---

## 1. speckit-red-team — full extension shape

Found at `a sibling extension repo/` (the a local path path didn't exist).

### Top-level layout

```
spec-kit-red-team/
├── extension.yml             # manifest — CLI validates this
├── config-template.yml       # shipped catalog template (NOT auto-renamed by CLI)
├── README.md
├── LICENSE                   # MIT
├── CHANGELOG.md              # Keep-a-Changelog format
├── .gitignore                # ignores *.zip, dist/, .scratch/, OS junk
├── commands/
│   ├── red-team.md           # 23.8 KB — main command body
│   └── red-team-gate.md      # 6.6 KB — before_plan hook command
└── docs/
    └── protocol.md           # 13 KB — extended ref doc (not packaged contractually)
```

No `package.json`, no `pyproject.toml`. The extension *is* the directory: `specify extension add` `shutil.copytree`'s it wholesale into `.specify/extensions/<id>/` (extensions.py:1175). Optional `.extensionignore` (gitignore-syntax) trims docs/tests from the copy — red-team ships none, so `docs/` and `LICENSE` end up in the consumer repo.

### `extension.yml` — the manifest contract

```yaml
schema_version: "1.0"                  # MUST == "1.0" (extensions.py:119)

extension:                             # all four fields required
  id: "red-team"                       # MUST match ^[a-z0-9-]+$
  name: "Red Team"
  version: "1.0.2"                     # MUST be valid PEP 440
  description: "Adversarial review of functional specs before /speckit.plan..."
  author: "Ash Brener"                 # optional
  repository: "https://github.com/..."  # optional
  license: "MIT"                       # optional
  homepage: "..."                      # optional

requires:
  speckit_version: ">=0.1.0"           # REQUIRED. Use ">=0.1.0" (community norm)

provides:                              # MUST have at least one of commands/hooks
  commands:
    - name: "speckit.red-team.run"     # MUST match speckit.<ext-id>.<sub> pattern
      file: "commands/red-team.md"     # path relative to extension root
      description: "..."
    - name: "speckit.red-team.gate"
      file: "commands/red-team-gate.md"
      description: "..."

  hooks:                               # OPTIONAL — registers into .specify/extensions.yml
    before_plan:
      - command: "speckit.red-team.gate"
        description: "..."             # echoed to user when hook fires
        prompt: "Running red team gate check..."
        optional: false                # true → user-prompted, false → auto-executed
        enabled: true                  # default true if omitted

  config:                              # INFORMATIONAL ONLY — NOT auto-scaffolded
    - name: "red-team-lenses.yml"
      template: "config-template.yml"
      description: "..."
      required: true

tags: [...]                            # optional, free-form
defaults:                              # optional, surfaced via ConfigManager
  finding_bound: 5
  severity_weight: 5
```

**Key finding**: `provides.config` is documentation only — the CLI never reads `config[].template` to rename/copy it. The README's "scaffolds the catalog" claim is aspirational: at runtime `red-team.md` looks for `.specify/extensions/red-team/red-team-lenses.yml` and errors if missing. User (or first-run command logic) does the `config-template.yml → red-team-lenses.yml` copy. The template ships next to the command thanks to copytree, so the copy is path-relative.

### Command file shape

`commands/*.md` are plain Markdown with optional YAML frontmatter. Minimal shape (from `red-team-gate.md`): `--- description: ... ---`, then `## User Input` containing `$ARGUMENTS`, then `## Outline` numbered steps. No shell scripts — the host AI agent executes the markdown directly as instructions.

---

## 2. speckit-taskstoissues — built-in skill, NOT an extension

File: `/Users/ashbrener/Code/AI/spec-kit-linear/.claude/skills/speckit-taskstoissues/SKILL.md` (107 lines).

### Shape differences from a red-team-style extension

| Aspect | Built-in skill (`speckit-taskstoissues`) | Extension (`red-team`) |
|---|---|---|
| Install path | `.claude/skills/<name>/SKILL.md` (single file) | `.specify/extensions/<id>/` (full dir) |
| Manifest | None — frontmatter on SKILL.md itself | Separate `extension.yml` |
| Frontmatter keys | `name`, `description`, `argument-hint`, `compatibility`, `metadata.author`, `metadata.source`, `user-invocable`, `disable-model-invocation` | None on command files — meta lives in `extension.yml` |
| Hook namespace | Reads `.specify/extensions.yml` under `hooks.before_taskstoissues` / `hooks.after_taskstoissues` — i.e. consumes other extensions' hooks | Writes into `.specify/extensions.yml` |
| Installation source | Bundled by `specify init` (lives in `templates/commands/taskstoissues.md` upstream) | `specify extension add` from catalog / `--from URL` / `--dev <path>` |
| Skill auto-generated? | N/A — it IS the skill | YES — extensions.py:836 `_register_extension_skills()` writes a SKILL.md per command into `.claude/skills/speckit-<ext-id>-<sub>/SKILL.md` when `--ai-skills` was set at init time |

Critical mechanism (SKILL.md lines 24-55 and 75-106): every core speckit command runs Pre/Post-Execution blocks that (1) read `.specify/extensions.yml`, (2) look up `hooks.before_<name>` / `hooks.after_<name>`, (3) for each enabled hook print an `EXECUTE_COMMAND` directive — mandatory (`optional: false`) MUST be awaited, optional asks the user, (4) translate manifest dot-names (`speckit.red-team.gate`) to slash-command form (`/speckit-red-team-gate`).

So red-team's `before_plan` fires via: `/speckit-plan` reads `.specify/extensions.yml`, sees the hook entry, emits `EXECUTE_COMMAND: speckit.red-team.gate`, host agent invokes `/speckit-red-team-gate`. **Implication for spec-kit-linear**: a `hooks.after_tasks` entry auto-fires post-tasks; omitting hooks gives on-demand only. No patching of core skills required either way.

---

## 3. `specify extension add` mechanics

CLI source: `/Users/ashbrener/.local/share/uv/tools/specify-cli/lib/python3.13/site-packages/specify_cli/extensions.py` (2918 lines, Python 3.13).

### Help output

```
Usage: specify extension add [OPTIONS] EXTENSION
  Install an extension.

Options:
  --dev                  Install from local directory
  --from        TEXT     Install from custom URL
  --priority    INTEGER  Resolution priority (default 10)
```

### Three install paths

1. **Catalog by name**: `specify extension add linear` → fetches `https://raw.githubusercontent.com/github/spec-kit/main/extensions/catalog.community.json`, finds entry with `id: linear`, downloads the listed `download_url` ZIP over HTTPS (extensions.py:1669, 2081-2092). Requires a catalog PR upstream.
2. **Direct URL**: `specify extension add --from <https-url>` → same as catalog path but skips the lookup. URL must be HTTPS (or http://localhost).
3. **Local dir (dev)**: `specify extension add --dev <path>` → `install_from_directory()` (extensions.py:1126) — `shutil.copytree(<path>, .specify/extensions/<id>/, ignore=.extensionignore)`. This is how we'll iterate during development.

### What `install_from_directory` writes/mutates (extensions.py:1126-1205)

For an extension with `id: linear`, installing into project root `<repo>/`:

```
<repo>/.specify/
├── extensions/
│   ├── .registry                       # JSON written by ExtensionRegistry
│   │                                   # { "schema_version":"1.0",
│   │                                   #   "extensions": { "linear": {...} } }
│   └── linear/                         # shutil.copytree of source dir
│       ├── extension.yml
│       ├── config-template.yml
│       ├── commands/*.md
│       ├── README.md
│       ├── LICENSE
│       └── ...everything not matched by .extensionignore
└── extensions.yml                      # mutated by HookExecutor.register_hooks()
                                        # adds installed: [linear] and any hooks
```

And, when project was initialised with `--ai-skills` (Kimi auto-qualifies), `_register_extension_skills()` writes one SKILL.md per command at `<repo>/.claude/skills/spec-kit-linear-<sub>/SKILL.md` — won't overwrite if file exists. Generated frontmatter contains `name: spec-kit-linear-<sub>`, `description` (from command frontmatter, else `"Extension command: ..."`), `metadata.source: extension:linear`, plus integration keys.

### `.specify/extensions.yml` shape (project-level config, written by HookExecutor)

```yaml
schema_version: "1.0"
installed:
  - red-team
  - linear
settings:
  auto_execute_hooks: true
hooks:
  before_plan:
    - extension: red-team
      command: speckit.red-team.gate
      enabled: true
      optional: false
      prompt: "Running red team gate check..."
      description: "..."
      condition: null
  after_tasks:                          # example for spec-kit-linear
    - extension: linear
      command: speckit.linear.push
      enabled: true
      optional: true
      ...
```

Each `(extension, hook_name)` is deduplicated on register (extensions.py:2607-2614) so re-install is idempotent.

### Manifest validation (extensions.py:157-298) — install aborts on first failure

`schema_version == "1.0"`; `extension.id` matches `^[a-z0-9-]+$`; `extension.version` is PEP 440; `extension.{id,name,version,description}` present; `requires.speckit_version` present; `provides` has ≥1 command OR hook; command `name` matches `speckit.<ext_id>.<sub>` (auto-corrects `speckit.foo` / `<ext_id>.foo`); each hook is a mapping with `command`; command names don't shadow core commands or other installed extensions.

### Other CLI write paths
- `.specify/extensions/.backup/<ext_id>/*-config.yml` — created on `remove`, preserves config
- `.specify/extensions/<ext_id>/local-config.yml` — gitignored convention for user secrets (ConfigManager; extensions.py:2197)

---

## 4. Concrete file layout we should ship in `spec-kit-linear`

```
spec-kit-linear/                                 # repo root (this directory)
├── extension.yml                               # REQUIRED — manifest, schema_version: "1.0"
├── config-template.yml                         # ships per-project Linear config skeleton
│                                               # (team_id, project_id, status mappings, etc.)
├── README.md                                   # install + usage
├── LICENSE                                     # MIT
├── CHANGELOG.md                                # Keep-a-Changelog
├── .gitignore                                  # *.zip, dist/, .scratch/, OS junk
├── .extensionignore                            # OPTIONAL — excludes BRIEF.md, validation/,
│                                               # specs/, CLAUDE.md, .claude/ from the
│                                               # copytree into consumer projects
├── commands/
│   ├── linear-push.md                          # /spec-kit-linear-push — convert tasks → Linear issues
│   ├── linear-pull.md                          # /spec-kit-linear-pull — sync state from Linear (if in spec)
│   └── linear-status.md                        # /spec-kit-linear-status — show sync state (if in spec)
└── docs/
    └── protocol.md                             # optional extended docs (ignored via .extensionignore)
```

### Minimal `extension.yml` skeleton for spec-kit-linear

```yaml
schema_version: "1.0"
extension:
  id: "linear"
  name: "Linear"
  version: "0.1.0"
  description: "Sync spec-kit tasks to Linear issues (sibling to GitHub Issues skill)."
  author: "Ash Brener"
  repository: "https://github.com/ashbrener/spec-kit-linear"
  license: "MIT"
requires:
  speckit_version: ">=0.1.0"
provides:
  commands:
    - name: "speckit.linear.push"
      file: "commands/linear-push.md"
      description: "Convert tasks.md into Linear issues."
    # add pull/status per spec
  # OPTIONAL hooks block — drop if on-demand only:
  # hooks:
  #   after_tasks:
  #     - command: "speckit.linear.push"
  #       prompt: "Push these tasks to Linear?"
  #       optional: true
  #       enabled: true
  config:
    - name: "linear-config.yml"
      template: "config-template.yml"
      description: "Per-project Linear workspace mapping."
      required: true
tags: ["issue-tracker", "linear", "tasks-sync"]
```

### Install flow for the consumer

```bash
# Dev iteration (this repo, before catalog PR):
specify extension add --dev /Users/ashbrener/Code/AI/spec-kit-linear

# Eventually (after PR to github/spec-kit extensions/catalog.community.json):
specify extension add linear

# Or one-shot from a tag without catalog:
specify extension add --from https://github.com/ashbrener/spec-kit-linear/archive/refs/tags/v0.1.0.zip
```

After install, consumer repo gains: `.specify/extensions/linear/` (the full tree), `.specify/extensions/.registry` (JSON, linear entry added), `.specify/extensions.yml` (hook entry if we ship `hooks:`), and — if they used `--ai-skills` at init — `.claude/skills/spec-kit-linear-push/SKILL.md` auto-generated.

---

## 5. Open questions for `/speckit-plan`

1. **Config bootstrap UX.** CLI does NOT copy `config-template.yml → linear-config.yml`. Red-team errors at runtime pointing at the template. Should `/spec-kit-linear-push` do the same, or copy-on-first-run with a confirm prompt?
2. **Hook integration scope.** Wire `hooks.after_tasks` as mandatory (`optional: false` — auto-fires on every `/speckit-tasks`), optional (user confirms), or no hook (manual only)? Decides whether the extension mutates the default tasks flow.
3. **Secrets path.** Linear API needs an OAuth token / API key. ConfigManager supports `local-config.yml` (gitignored) and `SPECKIT_LINEAR_*` env vars (extensions.py:2200-2236). Mandate env, document local-config, or both?
4. **MCP dependency declaration.** `requires:` only validates `speckit_version`. A Linear MCP dependency has no first-class declaration — must assert at command runtime (like red-team asserts the lens catalog exists).
5. **Catalog publication.** Catalog-by-name (`specify extension add linear`) needs a PR to `github/spec-kit:extensions/catalog.community.json` with `id`, `version`, `download_url` (HTTPS release ZIP). v0.1.0 ships `--from URL` only, or include the catalog PR?
