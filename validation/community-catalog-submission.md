# Community-catalog submission — spec-kit-linear v0.1.1

Draft prepared for listing `spec-kit-linear` in the upstream spec-kit
community catalog so operators can run `specify extension add linear`
directly instead of the archive-ZIP `--from` workaround.

- Upstream catalog: <https://github.com/github/spec-kit/blob/main/extensions/catalog.community.json>
- Contribution guide: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md>
- Submission form: `extension_submission.yml` issue template in `github/spec-kit`

> Status: **draft only.** The upstream PR / issue is the operator's call.
> Do not submit until the blockers in the final section are cleared.

## How the catalog actually works

The community catalog is a single JSON file, `extensions/catalog.community.json`,
with all extensions keyed by `id` under a top-level `"extensions"` object.
The documented submission path is **not** a direct PR that edits the JSON —
it is a GitHub issue using the **Extension Submission** form. A maintainer
reviews the issue and adds the catalog entry. Submitters may still propose
the exact JSON entry in the form's "Proposed Catalog Entry" field (and a
PR is welcome), but the issue is the canonical entry point.

### Catalog entry schema (observed from live entries)

Each entry is an object keyed by its `id`. Fields observed on current
community entries:

| Field          | Type    | Notes                                                       |
|----------------|---------|-------------------------------------------------------------|
| `name`         | string  | Display name.                                               |
| `id`           | string  | Lowercase-kebab; the install handle.                        |
| `description`  | string  | One-line purpose.                                           |
| `author`       | string  | Creator.                                                    |
| `version`      | string  | Must match the released manifest version.                   |
| `download_url` | string  | **Release-tag ZIP** — `/archive/refs/tags/vX.Y.Z.zip`.      |
| `repository`   | string  | GitHub repo URL.                                            |
| `homepage`     | string  | Project homepage.                                           |
| `documentation`| string  | README or docs link.                                        |
| `changelog`    | string  | Releases page or CHANGELOG.                                 |
| `license`      | string  | e.g. `MIT`.                                                 |
| `requires`     | object  | `{ "speckit_version": ">=0.1.0" }` plus optional tools.     |
| `provides`     | object  | `{ "commands": N, "hooks": N }` (counts, not lists).        |
| `tags`         | array   | Searchable labels.                                          |
| `verified`     | boolean | Maintainer-set; submit as `false`.                          |
| `downloads`    | number  | Engagement metric; submit as `0`.                           |
| `stars`        | number  | Engagement metric; submit as `0`.                           |
| `created_at`   | string  | ISO 8601 timestamp.                                         |
| `updated_at`   | string  | ISO 8601 timestamp.                                         |

The install handle is the `id` (`linear`), so once listed the command is
`specify extension add linear`.

## Proposed catalog entry

Paste this object into the `"extensions"` map of `catalog.community.json`
(keyed by `linear`):

```json
"linear": {
  "name": "spec-kit-linear",
  "id": "linear",
  "description": "Mirror spec-kit feature directories into Linear (filesystem → Linear, reconcile-based, unidirectional).",
  "author": "Ash Brener",
  "version": "0.1.1",
  "download_url": "https://github.com/ashbrener/spec-kit-linear/archive/refs/tags/v0.1.1.zip",
  "repository": "https://github.com/ashbrener/spec-kit-linear",
  "homepage": "https://github.com/ashbrener/spec-kit-linear",
  "documentation": "https://github.com/ashbrener/spec-kit-linear/blob/main/README.md",
  "changelog": "https://github.com/ashbrener/spec-kit-linear/releases",
  "license": "MIT",
  "requires": { "speckit_version": ">=0.1.0" },
  "provides": { "commands": 5, "hooks": 6 },
  "tags": [
    "issue-tracker",
    "linear",
    "tasks-sync",
    "lifecycle-mirror",
    "memory",
    "cross-repo"
  ],
  "verified": false,
  "downloads": 0,
  "stars": 0,
  "created_at": "2026-05-28T15:42:14Z",
  "updated_at": "2026-05-28T21:27:03Z"
}
```

Field provenance (all derived from `extension.yml` unless noted):

- `name`, `id`, `description`, `author`, `license`, `repository`,
  `homepage`, `tags` — copied verbatim from the manifest's `extension:`
  and top-level `tags:` blocks.
- `version` — **`0.1.1`**, the released tag. See blocker B1: the
  manifest currently still says `0.1.0.dev0` and must be bumped to
  `0.1.1` before submission so the catalog and manifest agree.
- `download_url` — the **release-tag** ZIP for `v0.1.1` (a release
  already exists; see "Release-tag vs main").
- `requires` — `speckit_version: ">=0.1.0"` from the manifest's
  `requires:` block. No additional declarable tools (Linear MCP / OAuth /
  `gh` / git-hook checks are enforced at install time, not in `requires`).
- `provides` — counts: 5 commands (`push`, `pull`, `status`, `seed`,
  `install`) and 6 `after_*` hooks (`specify`, `clarify`, `plan`,
  `tasks`, `implement`, `analyze`).
- `created_at` / `updated_at` — `v0.1.0` and `v0.1.1` release publish
  timestamps. Maintainers may overwrite these; values are best-effort.

## Submission checklist

The documented flow is **issue-form-driven**, with an optional PR.

1. **Clear the blockers below first** (manifest version bump is mandatory).
2. **Confirm the release exists.** `v0.1.1` is already published
   (`gh release view v0.1.1 -R ashbrener/spec-kit-linear`). The catalog's
   `download_url` resolves to
   `https://github.com/ashbrener/spec-kit-linear/archive/refs/tags/v0.1.1.zip`.
3. **Smoke-test the install from the release URL** (the form requires
   attesting to this):

   ```bash
   specify extension add linear \
     --from https://github.com/ashbrener/spec-kit-linear/archive/refs/tags/v0.1.1.zip
   ```

4. **Open the Extension Submission issue** in `github/spec-kit` using the
   `extension_submission.yml` form. Required fields map to our values:

   | Form field          | Value                                                            |
   |---------------------|------------------------------------------------------------------|
   | Extension ID        | `linear`                                                         |
   | Extension Name      | `spec-kit-linear`                                                |
   | Version             | `0.1.1`                                                          |
   | Description         | (manifest description above)                                     |
   | Author              | `Ash Brener`                                                     |
   | Repository URL      | `https://github.com/ashbrener/spec-kit-linear`                  |
   | Download URL        | `.../archive/refs/tags/v0.1.1.zip`                              |
   | License             | `MIT`                                                            |
   | Required Spec Kit   | `>=0.1.0`                                                        |
   | Number of Commands  | `5`                                                             |
   | Number of Hooks     | `6` (optional field)                                            |
   | Tags                | the six tags above                                              |
   | Key Features        | summarise reconcile / sub-issues / hooks / GitHub Action        |
   | Proposed Catalog Entry | paste the JSON object above                                  |

5. **Tick the Testing + Submission Requirements checkboxes** (5 + 6
   items) — these attest the manifest is valid, README + LICENSE exist,
   the ID is kebab-case, command files are well-formed, and there are no
   security issues. All true for this repo once B1 is fixed.
6. **(Optional) open the PR** that adds the JSON entry, linking the issue.
7. **Maintainer review.** They verify: valid `extension.yml`, README with
   install/usage, LICENSE present, kebab-case ID, well-formed command
   files, no security vulnerabilities. On approval the entry merges and
   `specify extension add linear` works.

## Release-tag vs main — recommendation

The live catalog pins `download_url` to a **release tag**
(`/archive/refs/tags/vX.Y.Z.zip`), and the submission form explicitly
instructs submitters to "create a GitHub release with a version tag" and
test against the release URL.

**Recommendation: pin to the release tag, not `main`.**

- A `v0.1.1` release already exists, so the tagged ZIP is available today.
- Tagged ZIPs are immutable — operators get a reproducible install, and
  the catalog `version` field stays truthful.
- `main` would drift away from the advertised `version` on every commit
  and break reproducibility.

Recommended `download_url`:
`https://github.com/ashbrener/spec-kit-linear/archive/refs/tags/v0.1.1.zip`

(The current operator workaround pins to
`.../archive/refs/heads/main.zip`; the catalog entry should **not** reuse
that — switch to the tag.)

## Repo readiness vs catalog requirements

| Requirement (maintainer verification)      | Repo state                              | Status |
|--------------------------------------------|-----------------------------------------|--------|
| Valid `extension.yml` manifest             | `schema_version: "1.0"`, validated      | OK     |
| README with install + usage                | `## Install`, `## Usage`, `## Adopt`     | OK     |
| LICENSE file                               | MIT `LICENSE` present                    | OK     |
| Kebab-case extension ID                    | `id: linear`                             | OK     |
| Command files well-formed                  | 5 files under `commands/`                | OK     |
| CHANGELOG                                  | `CHANGELOG.md` present                    | OK     |
| Tagged release exists                      | `v0.1.0`, `v0.1.1` released              | OK     |
| Manifest `version` matches release         | manifest says `0.1.0.dev0`               | **FAIL** |
| No secrets in manifest                     | secret-free (verified in `extension.yml`) | OK     |

## Blockers / pre-submission TODO

- **B1 (blocker) — manifest version mismatch.** `extension.yml` declares
  `version: "0.1.0.dev0"` but the released tag and the proposed catalog
  entry are `0.1.1`. The maintainer review checks the manifest against
  the submitted version. **Bump `extension.yml` `extension.version` to
  `0.1.1`** (and, if the bump lands after `v0.1.1` was cut, re-tag /
  re-release so the ZIP contains the corrected manifest). This must be
  fixed before submitting — it is out of scope for this docs-only branch.

- **B2 (minor) — description divergence.** The GitHub repo description
  ("spec-kit ↔ Linear bridge — one Linear Issue per spec, sub-issues for
  task phases, automatic sync via spec-kit hooks + GitHub Actions
  webhook") differs from the manifest/catalog description
  ("Mirror spec-kit feature directories into Linear ..."). Not a hard
  failure, but align them so the catalog UI and repo read the same. The
  catalog should follow the **manifest** description (used above).

- **B3 (verify) — schema confirmation.** The catalog schema above was
  inferred from live entries (the EXTENSION-DEVELOPMENT-GUIDE does not
  publish an explicit JSON schema). Diff the proposed entry against a
  current `catalog.community.json` entry at submission time in case
  upstream adds/renames fields.

- **B4 (nice-to-have) — `provides` granularity.** Live entries use
  integer counts (`{"commands": 5, "hooks": 6}`), not command lists.
  The entry above follows that convention; confirm upstream has not
  switched to listing command names.
