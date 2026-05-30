# Install CLI Flags — Surface and Backwards Compatibility

**Status**: Phase 1 contract for spec 002. Documents the
`bash src/install.sh` flag surface for v0.1.1 and the
backwards-compatibility guarantee against v0.1.0
(FR-044, FR-045). Companion to
[`install-prompts.md`](./install-prompts.md) (which prompts each
flag suppresses) and
[`install-discovery-graphql.md`](./install-discovery-graphql.md)
(which GraphQL operations each flag short-circuits).

**Stability commitment**: Every v0.1.0 flag listed in this contract
MUST continue to work bit-for-bit in v0.1.1 per FR-044 and SC-011.
The non-interactive CI install path (`bash src/install.sh --team
<UUID> --project <UUID> --non-interactive`) is the canonical
regression test surface; spec 002 introduces a dedicated bats
integration test (`tests/integration/install_e2e_backwards_compat.bats`)
to gate every release on this guarantee.

## 1. Flag inventory

### 1.1 v0.1.0 flags (preserved verbatim in v0.1.1)

| Flag | Type | Default | Behavior | Status in v0.1.1 |
|---|---|---|---|---|
| `--project <UUID>` | UUID string | unset | Attach to an existing Linear Project by UUID. Skips P3 (project picker) and the `team(id).projects` query. | **Preserved** (FR-044) |
| `--team <UUID>` | UUID string | unset | Use the given Linear Team UUID. Skips P2 (team picker) and the `teams` query. | **Preserved** (FR-044) |
| `--auto-create` | flag | unset | Auto-create a new Linear Project named after the consumer repo's directory. v0.1.0 alternative to `--project`. | **Preserved** but **deprecated** — see §2 |
| `--non-interactive` | flag | false | Refuse to prompt; require sufficient flags. v0.1.0 required `--team` AND (`--project` OR `--auto-create`). | **Preserved** with **stricter rule** (FR-045) — see §3 |
| `--no-prompt` | alias | n/a | Alias for `--non-interactive`. Retained for parity with speckit-git command surface. | **Preserved** |
| `--with-action` | flag | unset | Drop `.github/workflows/spec-kit-linear-sync.yml` (Layer E). | **Preserved** (unchanged) |
| `--no-action` | flag | unset | Explicitly skip Layer E (suppresses interactive Action prompt). | **Preserved** (unchanged) |
| `--dev` | flag | unset | Install from the local source-tree checkout rather than `specify extension add linear`. | **Preserved** (but interacts with new FR-046 guard — see §4) |
| `--help` / `-h` | flag | unset | Print usage and exit 0. | **Preserved** (text updated for new flags) |

### 1.2 v0.1.1 flags (new in spec 002)

| Flag | Type | Default | Behavior | FR |
|---|---|---|---|---|
| (none — spec 002 introduces NO new CLI flags) | | | | |

Spec 002's discovery flow is driven entirely by the **absence** of
`--team` / `--project` / `--non-interactive`. The new prompt surface
in [`install-prompts.md`](./install-prompts.md) fires automatically
when those flags are not present. No new flag is needed because the
default-interactive path IS the new ergonomic flow.

### 1.3 Flags deferred to v0.2.0

| Flag | Rationale for deferral |
|---|---|
| `--list-teams` | Surface only the team picker without running the full install. Useful for "what teams does my key see?" inspection. Out of v0.1.1 scope per spec.md `## Out of scope`. |
| `--api-key <key>` | Pass the API key on the command line. **NOT added** — passing secrets via argv is an antipattern; the env-var path (`LINEAR_API_KEY=<key> bash src/install.sh`) already covers the CI use case without exposing the key to `ps`. |
| `--paginate-teams` / `--paginate-projects` | Pagination beyond 20. Deferred per spec.md `## Out of scope`. |
| `--filter-teams <substring>` | Substring filtering. Deferred per spec.md `## Out of scope`. |

---

## 2. `--auto-create` deprecation note

v0.1.0's `--auto-create` flag instructed the install to create a
new Linear Project named after the consumer repo's basename when
no `--project <UUID>` was passed. Spec 002's new discovery flow
makes this behavior the default for the "Create new project"
picker option (P3 → P4).

**v0.1.1 status**: `--auto-create` continues to work bit-for-bit:
when present in `--non-interactive` mode it bypasses the project
picker and fires the same `projectCreate` mutation v0.1.0 did
(internally routed through the new discovery flow's S5 step
without P4 prompts). When the operator runs interactively, the
discovery flow's P3 picker presents "Create new project" as a
natural option — making `--auto-create` redundant.

**Deprecation path**: `--auto-create` will be removed in v0.2.0
once spec 002's interactive path has been the default for one
release cycle. v0.1.1 logs a soft notice when the flag is used
interactively (`[linear] --auto-create is deprecated; the
"Create new project" picker option is the new ergonomic
default`); CI/non-interactive usage emits no notice (the flag is
load-bearing for scripted installs).

---

## 3. `--non-interactive` rule changes (FR-045)

### 3.1 v0.1.0 rule (legacy)

`--non-interactive` requires **either** `--project <UUID>` **or**
`--auto-create`, **and** requires `--team <UUID>`. Validated at
`install::parse_args` (`src/install.sh:362-376`).

### 3.2 v0.1.1 rule (FR-045)

`--non-interactive` requires **both** `--team <UUID>` **and**
`--project <UUID>` (or `--auto-create`). Strictly: the install
MUST halt with exit 2 when `--non-interactive` is set without
both UUIDs (or `--team` + `--auto-create` as the v0.1.0-compat
combination).

The change tightens the v0.1.0 rule by NOT falling through to the
interactive prompts in `--non-interactive` mode under any
circumstance. v0.1.0 already enforced this for `--team`; v0.1.1
enforces it for the API key prompt too (FR-037 explicitly
mandates "Non-interactive mode (`--non-interactive` or
`--no-prompt`) MUST NOT fall through to [the interactive
read -s prompt]").

### 3.3 Error message (verbatim)

When `--non-interactive` is set without sufficient flags:

```text
spec-kit-linear: install ERROR --non-interactive requires both --team <UUID>
                 and --project <UUID> (or --team <UUID> --auto-create).
                 The v0.1.1 ergonomics path (interactive team + project
                 picker) is unavailable under --non-interactive.
                 Resolve UUIDs out-of-band or run interactively.
```

Exit code 2.

---

## 4. `--dev` flag interaction with FR-046 self-install guard

`--dev` (v0.1.0) instructs install to copy the source tree from the
current checkout into the consumer repo's
`.specify/extensions/linear/` rather than relying on `specify
extension add linear` to vendor the files. This is the
documented path for developing the bridge against a real consumer
repo.

**FR-046 interaction**: the new self-install guard (S0 in the
discovery state machine) compares the SOURCE path (the bridge's
own checkout) against the TARGET path (the consumer repo's git
root). When both resolve to the same canonical path, the install
halts with exit 2 **regardless of `--dev`**. `--dev` does NOT
bypass FR-046 — the guard exists specifically because v0.1.0's
`--dev` path enables the recursive self-copy bug spec.md
describes (the macOS filename length limit at ~30 levels of
nesting).

**Operator-facing remediation** (verbatim):

```text
spec-kit-linear: install ERROR source path equals target path.
                 Detected: this install would copy the bridge into itself.
                 fix: either
                   (a) install into a different consumer repo, or
                   (b) once the bridge is listed in the spec-kit community
                       catalog (v0.1.x+), use `specify extension add linear`
                       from the catalog form.
                 (FR-046 — self-install recursion guard)
```

Exit code 2.

---

## 5. Backwards-compatibility table (v0.1.0 → v0.1.1)

Canonical reference for which v0.1.0 invocation patterns continue
to work in v0.1.1 unmodified, which get strictly tighter behavior,
and which gain new optional surface.

| v0.1.0 invocation | v0.1.1 behavior | Reason |
|---|---|---|
| `bash src/install.sh --team <UUID> --project <UUID>` | **Identical** — discovery flow short-circuits at S3 + S4 via FR-044 fast path | FR-044 preservation, SC-011 |
| `bash src/install.sh --team <UUID> --project <UUID> --non-interactive` | **Identical** — same as above, no prompts | FR-044 + FR-045 |
| `bash src/install.sh --team <UUID> --auto-create` | **Identical** — auto-create fires `projectCreate` with repo basename | FR-044 preservation; `--auto-create` deprecated but functional |
| `bash src/install.sh --team <UUID> --auto-create --non-interactive` | **Identical** — same as above, no prompts | FR-044 + FR-045 (legacy combination preserved) |
| `bash src/install.sh --team <UUID>` (no --project) | **NEW: interactive project picker** — v0.1.0 would have prompted for project; v0.1.1 runs the new P3 picker (FR-040). | Net UX improvement; semantically same outcome (project selected). |
| `bash src/install.sh --project <UUID>` (no --team) | **NEW: team auto-resolves from project** — v0.1.0 would have prompted for team UUID; v0.1.1 resolves the team from the project's `team { id }` field per FR-044 (no operator interaction). | Net UX improvement. |
| `bash src/install.sh` (no UUID flags, interactive) | **NEW: full discovery flow** — v0.1.0 would have prompted for raw UUIDs; v0.1.1 runs the API key → viewer → teams picker → projects picker flow per FR-037..FR-041. | Spec 002's headline feature. |
| `bash src/install.sh --non-interactive` (no UUID flags) | **HALT exit 2** with FR-045 message. v0.1.0 already halted here; v0.1.1 halt message is updated to point at the new interactive flow. | FR-045 tightens but does not contradict v0.1.0 behavior. |
| `bash src/install.sh --with-action` | **Identical** | FR-027 unchanged. |
| `bash src/install.sh --no-action` | **Identical** | FR-027 unchanged. |
| `bash src/install.sh --dev` (from inside bridge's own source tree) | **NEW: HALT exit 2** with FR-046 self-install guard message. v0.1.0 would have proceeded (recursive copy bug). | FR-046 safety guard — net UX improvement. |
| `bash src/install.sh --dev` (from a path OTHER than bridge's own source) | **Identical** path-resolution behavior; new FR-049 warning may surface if the source had `.git/` vendored | FR-049 adds a warning, does not halt. |
| `bash src/install.sh --help` | Same usage text, updated to document the interactive default + FR-049 warning + FR-046 guard | Cosmetic doc update; flag inventory unchanged. |

**Acceptance test surface**:
`tests/integration/install_e2e_backwards_compat.bats` (NEW in spec
002) exercises rows 1-4 of the table above against the live
`ACME` test workspace with `RUN_INTEGRATION_TESTS=1`. SC-011
gates v0.1.1 release on these tests passing.

---

## 6. Exit code stability (per command-shapes.md §5.6)

v0.1.1 preserves v0.1.0's exit code semantics:

| Code | Meaning | Spec 002 additions |
|---|---|---|
| `0` | Install completed; all required dependencies green. Warnings (FR-049 vendored `.git/`) DO surface in stderr but do NOT change exit code. | FR-049 warning emits at code 0 |
| `1` | Recoverable transient failure (Linear API blip, projectCreate 5xx). Re-run. | FR-041 mutation failures, FR-038 5xx all surface as exit 1 |
| `2` | Workspace-level config error: bash 3.2, missing prereqs, `--non-interactive` without UUIDs, invalid API key, no teams accessible, **self-install detected (FR-046)**. Fix and re-run. | New: FR-046, FR-037 (`--non-interactive` no key), FR-038 (auth fail) |
| `3` | Transport failure (Linear unreachable). Re-run when connectivity restored. | New: FR-038 network failure surfaces here too |

No new exit codes. The semantics map cleanly onto v0.1.0's
existing classification.

---

## 7. ENV-var surface

| Variable | Type | When honored | Purpose |
|---|---|---|---|
| `LINEAR_API_KEY` | string | FR-037 resolution order step (1) | Operator's Linear API key. Highest precedence; overrides `.env`. |
| `SPECKIT_LINEAR_DOGFOOD_SAFE` | string `1`/`true`/`yes` | v0.1.0 carry-over | Dogfood-safe mode. Unchanged by spec 002. |
| `RUN_INTEGRATION_TESTS` | string `1` | bats integration tests | Gates the test suite; not consumed by install.sh itself. |

Spec 002 does NOT introduce new ENV variables. The `LINEAR_API_KEY`
surface above is v0.1.0 (used by `src/graphql.sh:106` already);
spec 002 only extends WHERE in the install flow it is consulted.

---

## 8. Flag interaction matrix (for reviewers)

The complete combinatorial truth table for which flags do what at
parse time:

| `--team` | `--project` | `--auto-create` | `--non-interactive` | Outcome |
|---|---|---|---|---|
| ✗ | ✗ | ✗ | ✗ | Full discovery flow (P1, P2, P3, possibly P4). |
| ✓ | ✗ | ✗ | ✗ | Skip P2; run P3 (+ possibly P4). |
| ✗ | ✓ | ✗ | ✗ | Resolve team from project; skip P2 and P3. |
| ✓ | ✓ | ✗ | ✗ | Skip P2, P3, P4 entirely; quick-validate both UUIDs per FR-044 §5.5. |
| ✓ | ✗ | ✓ | ✗ | Skip P2; fire projectCreate with repo basename name (no P4 prompt). |
| ✗ | ✗ | ✗ | ✓ | HALT exit 2 (FR-045). |
| ✓ | ✗ | ✗ | ✓ | HALT exit 2 (FR-045 — no `--project` or `--auto-create`). |
| ✗ | ✓ | ✗ | ✓ | HALT exit 2 (FR-045 — no `--team` is a v0.1.0 rule preserved). |
| ✓ | ✓ | ✗ | ✓ | Validate UUIDs; write config; no prompts. **Canonical CI path.** |
| ✓ | ✗ | ✓ | ✓ | Auto-create project; no prompts. **Canonical CI auto-create path.** |
| ✓ | ✓ | ✓ | * | HALT exit 2 (`--project` + `--auto-create` mutually exclusive — v0.1.0 rule preserved at `src/install.sh:355-360`). |

(`✓` = flag present; `✗` = flag absent; `*` = either; outcome
applies regardless.)

---

## 9. Usage text (operator-facing, FR-047 + spec.md User Story 3)

The `install::usage` block (`src/install.sh:211-267`) is updated
for v0.1.1 to document:

1. The interactive default flow (the new ergonomic path).
2. The flag surface (same as v0.1.0 plus the deprecation notice).
3. The FR-049 vendored `.git/` warning and remediation.
4. The FR-046 self-install guard.
5. The FR-047 archive-URL form for `specify extension add --from`.

The exact text is NOT pinned in this contract (it can drift for
clarity without breaking any operator or CI script). The
**behavior** specified in §1-§8 is what's pinned.

---

## Cross-references

- [data-model.md §4](./data-model.md) — discovery state machine
  showing which flags short-circuit which states.
- [install-prompts.md](./install-prompts.md) — operator prompts
  each flag suppresses.
- [install-discovery-graphql.md](./install-discovery-graphql.md)
  — GraphQL operations each flag suppresses.
- [v0.1.0 command-shapes.md §5](../../001-spec-kit-linear-bridge/contracts/command-shapes.md)
  — v0.1.0 `speckit.linear.install` command shape (the contract
  spec 002 extends).
- [v0.1.0 quickstart.md Step 1](../../001-spec-kit-linear-bridge/quickstart.md)
  — v0.1.0 install ceremony walkthrough.
