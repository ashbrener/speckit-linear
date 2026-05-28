#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/install.sh — install ceremony for the spec-kit-linear bridge.
#
# Implements `speckit.linear.install` per
# `specs/001-spec-kit-linear-bridge/contracts/command-shapes.md` §5
# (FR-002, FR-018, FR-018b, FR-019, FR-020, FR-027, FR-029, FR-031,
# FR-033). The script's role is the per-consumer-repo first-run
# ceremony — verify every dependency the bridge touches, resolve the
# Linear Team + Project UUIDs, write the per-repo config, register
# the six `after_*` hooks in `.specify/extensions.yml`, install the
# three local git hooks under `.git/hooks/`, and (optionally) drop
# the GitHub Action template under `.github/workflows/`.
#
# Constitutional alignment:
#   Principle V  (UUID-based binding) — resolves Team + Project UUIDs
#                interactively (or via flags) and writes them to a
#                committed per-repo config.
#   Principle VI (OAuth-first, keys-at-edges) — never prompts for an
#                API key; only surfaces the `gh secret set` command for
#                Layer E.
#   Principle VII (memory-just-works) — registers `after_*` hooks with
#                `optional: false`, honours pre-existing `enabled: false`.
#   Principle VIII (observable failure) — every dependency check fails
#                loud with copy-paste remediation; install never silently
#                skips a step.
#
# Exit codes (matched to contracts/command-shapes.md §5.6):
#   0 — install completed; report emitted; all required dependencies green.
#   1 — recoverable failure (Linear API transient, network blip). Re-run.
#   2 — workspace-level config error (bash 3.2, missing prerequisites,
#       --non-interactive without --project/--team, etc.). Fix and re-run.
#   3 — transport failure across the board (config OK, but Linear or
#       GitHub MCP unreachable). Re-run when connectivity is restored.
#
# This script is the ENTRY POINT for the install command — it is NOT
# sourced as a library. Functions defined here are local to this
# process; foundational modules under `src/*.sh` are sourced for their
# public APIs.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Module sourcing.
# Strict order: parser doesn't help us much here, but summary + git_helpers do.
# config.sh is sourced lazily AFTER we copy the template into place because
# `config::load` validates the file structure and we don't have the resolved
# UUIDs at the start of the run.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./summary.sh disable=SC1091
source "${SCRIPT_DIR}/summary.sh"
# shellcheck source=./git_helpers.sh disable=SC1091
source "${SCRIPT_DIR}/git_helpers.sh"
# shellcheck source=./graphql.sh disable=SC1091
source "${SCRIPT_DIR}/graphql.sh"

# -----------------------------------------------------------------------------
# Module constants.
# -----------------------------------------------------------------------------

# Where the per-repo config lives (data-model.md §2.5). The install step
# writes a copy of `config-template.yml` here with Team + Project UUIDs
# populated; `speckit.linear.seed` later fills `workflow_state_uuids`.
readonly INSTALL_CONFIG_PATH=".specify/extensions/linear/linear-config.yml"
readonly INSTALL_CONFIG_DIR=".specify/extensions/linear"
readonly INSTALL_EXTENSIONS_YML=".specify/extensions.yml"
readonly INSTALL_GIT_HOOKS_DIR=".git/hooks"
readonly INSTALL_GH_WORKFLOWS_DIR=".github/workflows"
readonly INSTALL_GH_WORKFLOW_FILE=".github/workflows/spec-kit-linear-sync.yml"
readonly INSTALL_MCP_JSON_PATH=".mcp.json"

# Local config template (lives in this extension's repo root). Copied
# into the consumer repo's INSTALL_CONFIG_PATH if no committed copy
# already exists.
readonly INSTALL_CONFIG_TEMPLATE="${EXTENSION_ROOT}/config-template.yml"

# Git-hook templates the bridge ships (T044/T045/T046). The install
# step copies these into `.git/hooks/` per FR-033. We only copy files
# that exist; templates not yet implemented in the bridge's own repo
# surface as a warning rather than a hard error so dogfood-time
# partial installs still complete.
readonly -a INSTALL_GIT_HOOK_NAMES=("post-checkout" "post-commit" "post-merge")

# The six `after_*` hooks auto-registered per FR-031 / Principle VII.
# All point at the same command (`speckit.linear.push`) because
# reconcile is the single convergent operation.
readonly -a INSTALL_AFTER_HOOK_NAMES=(
    "after_specify"
    "after_clarify"
    "after_plan"
    "after_tasks"
    "after_implement"
    "after_analyze"
)

# Minimum versions for runtime dependencies (FR-018b).
readonly INSTALL_MIN_BASH_MAJOR=4
readonly INSTALL_MIN_JQ_VERSION="1.6"
readonly INSTALL_MIN_GIT_VERSION="2.30"

# Linear MCP endpoint per `extension.yml` defaults.mcp_endpoint.
readonly INSTALL_LINEAR_MCP_URL="https://mcp.linear.app/mcp"

# -----------------------------------------------------------------------------
# Module-level state — flag parsing populates these.
# -----------------------------------------------------------------------------

INSTALL_FLAG_PROJECT=""
INSTALL_FLAG_TEAM=""
INSTALL_FLAG_AUTO_CREATE=0
INSTALL_FLAG_NON_INTERACTIVE=0
INSTALL_FLAG_WITH_ACTION=0
# Set when --with-action / --no-action are passed explicitly on the
# CLI. When unset (=-1), install::main asks the operator interactively
# per FR-027 (T064). Honoured only in interactive mode; non-interactive
# defaults to install-without-prompt when --with-action is not set.
INSTALL_FLAG_WITH_ACTION_EXPLICIT=0
# Set by --dev. Surfaces in the dependency report and biases the
# EXTENSION_ROOT lookup toward the current checkout (rather than the
# operator-host `~/.specify-extensions/linear/` path the spec-kit CLI
# would normally populate during `specify extension add linear`). See
# install::main where the flag drives a log marker so the operator
# knows they're running from a non-shipped tree.
INSTALL_FLAG_DEV=0
INSTALL_FLAG_HELP=0

# T063 — seed-prompt outcome captured for the summary block.
# 0 = no prompt issued (workspace already seeded or non-interactive halt path).
# 1 = operator accepted; seed ran inline during install.
# 2 = operator deferred; install completed but reconcile will halt per FR-022.
INSTALL_SEED_PROMPT_RESULT=0

# FR-033b — dogfood-safe mode. Set to 1 when the operator has exported
# SPECKIT_LINEAR_DOGFOOD_SAFE=1 to opt into installing the extension
# into a repo whose Linear workspace already carries spec issues for
# this project. Surfaces in the dependency report and the final summary
# so the operator can confirm at a glance that the safety override is
# in effect.
INSTALL_DOGFOOD_SAFE_MODE=0

# Set to 1 once we've determined the repo is the spec-kit-linear repo
# itself (T048 — dogfood guard). When set, the registered hooks are
# emitted with a `condition: "${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}"`
# marker so they don't auto-fire during the bridge's own development.
INSTALL_DOGFOOD_DETECTED=0

# Aggregated has-error flag across the dependency report. Drives the
# final exit code: any `✗` row → exit 2 per command-shapes.md §5.7.
INSTALL_HAD_HARD_ERROR=0

# Operator identity resolved by install::resolve_operator (FR-034). The
# bridge captures the authenticating Linear user's identity at install
# time via the `viewer { id name email }` query and writes it to
# linear.operator.{user_id,name,email} so the reconciler can pass
# `assigneeId` on every issueCreate mutation.
INSTALL_OPERATOR_USER_ID=""
INSTALL_OPERATOR_NAME=""
INSTALL_OPERATOR_EMAIL=""

# Project metadata captured by install::resolve_project_uuid when the
# --auto-create / attach-existing path lands on a real Linear Project
# (rather than the zero placeholder). The summary block surfaces the
# URL so the operator can click straight through.
INSTALL_RESOLVED_PROJECT_URL=""
INSTALL_RESOLVED_PROJECT_NAME=""

# -----------------------------------------------------------------------------
# install::_log_info / install::_log_warn / install::_log_error
#
# Single-line, structured log emitters. All go to stderr so stdout
# stays clean for any future script that pipes install output (the
# dependency report block emits to stderr via summary::emit too).
# -----------------------------------------------------------------------------

install::_log_info() {
    printf 'spec-kit-linear: install: %s\n' "$*" >&2
}

install::_log_warn() {
    printf 'spec-kit-linear: install WARN  %s\n' "$*" >&2
}

install::_log_error() {
    printf 'spec-kit-linear: install ERROR %s\n' "$*" >&2
}

# install::_die <exit-code> <message...>
# Print a structured, operator-actionable error to stderr and exit
# with the given code. Use exit 2 for FR-022 / workspace-config
# halts; exit 1 for transient failures the operator can re-run.
install::_die() {
    local code="$1"
    shift
    install::_log_error "$*"
    exit "$code"
}

# -----------------------------------------------------------------------------
# install::usage
#
# Operator-facing help text. Invoked by `--help` or by a bad-args
# parse failure. Kept verbatim with the contract in
# `contracts/command-shapes.md` §5.3 plus the dev-only flags spelled
# in this Phase 4 implementation.
# -----------------------------------------------------------------------------
install::usage() {
    cat <<'USAGE'
Usage: install.sh [OPTIONS]

Per-consumer-repo install ceremony for the spec-kit-linear bridge.

Resolves the Linear Team + Project UUIDs (interactively or via flags),
writes .specify/extensions/linear/linear-config.yml, registers the six
after_* hooks in .specify/extensions.yml with optional: false (FR-031),
installs post-checkout / post-commit / post-merge git hooks per FR-033,
and (optionally) drops the GitHub Action template per FR-027 / FR-029.

INTERACTIVE DEFAULT FLOW (v0.1.1+, FR-037..FR-041)
  With no UUID flags, install drives a discovery flow:
    1. Resolve LINEAR_API_KEY from env, .env, or interactive prompt.
    2. Verify the key with a `viewer` query (operator identity).
    3. Pick a team from the workspace (auto-pick if only one).
    4. Pick a project from the team — or create a new one.
    5. Write linear-config.yml with resolved UUIDs (operator never
       sees a raw UUID per SC-010).

OPTIONS
  --project <UUID>     Attach to an existing Linear Project by UUID.
                       Mutually exclusive with --auto-create. Skips
                       the interactive project picker.
  --auto-create        Create a new Linear Project named after the
                       current repo's directory name. Mutually
                       exclusive with --project. Deprecated in v0.1.1
                       — the interactive "Create new project" picker
                       option is the new ergonomic default; this flag
                       is retained bit-for-bit for CI / scripted
                       installs and will be removed in v0.2.0.
  --team <UUID>        Linear Team UUID. Required in --non-interactive
                       mode; otherwise auto-detected (single team) or
                       picked interactively (multi-team workspace).
                       Skips the interactive team picker.
  --non-interactive    Refuse to prompt; requires BOTH --team <UUID>
                       AND --project <UUID> (or --team + --auto-create
                       as the v0.1.0-compat combination). Tightened in
                       v0.1.1 per FR-045 — never falls through to the
                       interactive prompts. Also accepted as
                       --no-prompt.
  --with-action        Drop templates/github-action.yml into
                       .github/workflows/spec-kit-linear-sync.yml and
                       print the gh secret set LINEAR_API_TOKEN command
                       per FR-029. Without this flag (and without
                       --no-action), interactive installs prompt the
                       operator per T064.
  --no-action          Explicitly skip the Layer E Action install
                       (suppresses the interactive prompt).
  --dev                Install from this repo's local checkout rather
                       than via `specify extension add`. Used for
                       dogfood development. Subject to the FR-046
                       self-install guard: refuses to install into the
                       bridge's own checkout (exit 2). FR-049 surfaces
                       a warning if the source carries a vendored
                       .git/ directory.
  --help               Print this help and exit.

INSTALL VIA `specify extension add` (FR-047)
  Operator-facing path:
    specify extension add --from \
      https://github.com/<owner>/<repo>/archive/refs/heads/main.zip
  The plain --from <repo-url> form errors with BadZipFile — use the
  archive-zip URL or --dev <local-path>.

ENVIRONMENT
  SPECKIT_LINEAR_DOGFOOD_SAFE
                       When set to `1` / `true` / `yes`, the install
                       proceeds in dogfood-safe mode (FR-033b) even when
                       the target workspace already carries spec issues
                       for this project. Surfaces in the dependency
                       report and the final summary.

EXIT CODES (per contracts/command-shapes.md §5.6)
  0  Install complete; all required dependencies green.
  1  Recoverable transient failure (Linear API blip). Re-run.
  2  Workspace-level config error (bash 3.2, missing prereqs, or
     --non-interactive without --project / --team). Fix and re-run.
  3  Transport failure (Linear/GitHub unreachable). Re-run later.

SEE ALSO
  specs/001-spec-kit-linear-bridge/contracts/command-shapes.md §5
  specs/001-spec-kit-linear-bridge/quickstart.md Step 1
  .specify/memory/constitution.md (Principles V, VII, VIII)
USAGE
}

# -----------------------------------------------------------------------------
# install::parse_args <args...>
#
# Populate the INSTALL_FLAG_* module-level variables from argv. We use
# a hand-rolled long-option parser rather than `getopt` because BSD
# getopt (the macOS default) does not support GNU long options.
# -----------------------------------------------------------------------------
install::parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --help|-h)
                INSTALL_FLAG_HELP=1
                shift
                ;;
            --project)
                if (( $# < 2 )); then
                    install::_log_error "--project requires a UUID argument"
                    install::usage >&2
                    exit 2
                fi
                INSTALL_FLAG_PROJECT="$2"
                shift 2
                ;;
            --project=*)
                INSTALL_FLAG_PROJECT="${1#--project=}"
                shift
                ;;
            --team)
                if (( $# < 2 )); then
                    install::_log_error "--team requires a UUID argument"
                    install::usage >&2
                    exit 2
                fi
                INSTALL_FLAG_TEAM="$2"
                shift 2
                ;;
            --team=*)
                INSTALL_FLAG_TEAM="${1#--team=}"
                shift
                ;;
            --auto-create)
                INSTALL_FLAG_AUTO_CREATE=1
                shift
                ;;
            --non-interactive|--no-prompt)
                # --no-prompt is an alias retained for parity with the
                # speckit-git command surface (the test scaffolding and
                # downstream automation reach for it interchangeably).
                INSTALL_FLAG_NON_INTERACTIVE=1
                shift
                ;;
            --with-action)
                INSTALL_FLAG_WITH_ACTION=1
                INSTALL_FLAG_WITH_ACTION_EXPLICIT=1
                shift
                ;;
            --no-action)
                # Explicit opt-out so the interactive prompt (T064) is
                # suppressed in scripted invocations that want install
                # but no Layer E template.
                INSTALL_FLAG_WITH_ACTION=0
                INSTALL_FLAG_WITH_ACTION_EXPLICIT=1
                shift
                ;;
            --dev)
                INSTALL_FLAG_DEV=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                install::_log_error "unknown flag: $1"
                install::usage >&2
                exit 2
                ;;
            *)
                install::_log_error "unexpected positional argument: $1"
                install::usage >&2
                exit 2
                ;;
        esac
    done

    # Mutual-exclusivity gate: --project and --auto-create can't both be set.
    if [[ -n "$INSTALL_FLAG_PROJECT" ]] && (( INSTALL_FLAG_AUTO_CREATE == 1 )); then
        install::_log_error "--project and --auto-create are mutually exclusive"
        install::usage >&2
        exit 2
    fi

    # Non-interactive mode requires either --project or --auto-create AND --team.
    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        if [[ -z "$INSTALL_FLAG_PROJECT" ]] && (( INSTALL_FLAG_AUTO_CREATE == 0 )); then
            install::_log_error \
                "--non-interactive requires either --project <UUID> or --auto-create"
            install::usage >&2
            exit 2
        fi
        if [[ -z "$INSTALL_FLAG_TEAM" ]]; then
            install::_log_error \
                "--non-interactive requires --team <UUID> (auto-detect is disabled)"
            install::usage >&2
            exit 2
        fi
    fi

    # T210 / FR-flags §2 — soft-deprecation notice for --auto-create when
    # used INTERACTIVELY. The flag remains bit-for-bit functional under
    # --non-interactive (load-bearing for CI / scripted installs); only
    # the interactive case logs the notice pointing operators at the new
    # "Create new project" picker option.
    if (( INSTALL_FLAG_AUTO_CREATE == 1 )) && (( INSTALL_FLAG_NON_INTERACTIVE == 0 )); then
        install::_log_warn \
            "--auto-create is deprecated; the \"Create new project\" picker option is the new ergonomic default (v0.1.1)"
    fi
}

# -----------------------------------------------------------------------------
# install::_status_row <symbol> <label> <detail>
#
# Emit one line of the structured dependency report (Principle VIII
# Rule 1 / FR-018b). <symbol> is one of:
#   "ok"   → printed as "✓" (verified)
#   "warn" → printed as "⚠" (warning; install continues)
#   "err"  → printed as "✗" (hard error; bumps INSTALL_HAD_HARD_ERROR)
#
# Lines go to stderr to match summary::emit's channel discipline.
# -----------------------------------------------------------------------------
install::_status_row() {
    local symbol="$1"
    local label="$2"
    local detail="$3"
    local glyph
    case "$symbol" in
        ok)   glyph="✓" ;;
        warn) glyph="⚠" ;;
        err)
            glyph="✗"
            INSTALL_HAD_HARD_ERROR=1
            ;;
        *)
            glyph="?"
            ;;
    esac
    printf '  %s %-32s %s\n' "$glyph" "$label" "$detail" >&2
}

# -----------------------------------------------------------------------------
# install::_section <title>
#
# Emit a section header in the dependency report.
# -----------------------------------------------------------------------------
install::_section() {
    printf '\n%s\n' "$1" >&2
}

# -----------------------------------------------------------------------------
# install::_version_ge <found> <minimum>
#
# Returns 0 iff <found> ≥ <minimum> under dotted-numeric ordering
# (1.6.0 ≥ 1.6, 2.43.0 ≥ 2.30). Both arguments are pre-stripped of any
# `v` prefix and trailing `-foo` suffix by the caller. Uses `sort -V`
# which is universally available on modern coreutils + macOS.
# -----------------------------------------------------------------------------
install::_version_ge() {
    local found="$1"
    local minimum="$2"
    if [[ "$found" == "$minimum" ]]; then
        return 0
    fi
    local lowest
    lowest="$(printf '%s\n%s\n' "$found" "$minimum" | sort -V | head -n1)"
    if [[ "$lowest" == "$minimum" ]]; then
        return 0
    fi
    return 1
}

# =============================================================================
# T040 — Dependency verification (FR-018b).
# =============================================================================

# install::check_bash
#
# Confirm bash major version ≥ 4. macOS ships the GPLv2 bash 3.2 by
# default; the bridge's associative-array and parser code requires 4+.
install::check_bash() {
    local bash_major bash_full
    bash_full="${BASH_VERSION:-unknown}"
    # BASH_VERSION is "5.2.21(1)-release" — split on '.' for the major.
    if [[ "$bash_full" =~ ^([0-9]+)\. ]]; then
        bash_major="${BASH_REMATCH[1]}"
    else
        bash_major=0
    fi

    if (( bash_major >= INSTALL_MIN_BASH_MAJOR )); then
        install::_status_row "ok" "bash ${bash_full}" "(>= ${INSTALL_MIN_BASH_MAJOR})"
    else
        install::_status_row "err" "bash ${bash_full}" \
            "needs >= ${INSTALL_MIN_BASH_MAJOR}; fix: brew install bash && export PATH=/opt/homebrew/bin:\$PATH"
    fi
}

# install::check_curl
install::check_curl() {
    if command -v curl >/dev/null 2>&1; then
        local curl_version
        curl_version="$(curl --version 2>/dev/null | head -n1 | awk '{ print $2 }')"
        install::_status_row "ok" "curl ${curl_version}" "(any version)"
    else
        install::_status_row "err" "curl" \
            "missing; fix: brew install curl  (macOS)  |  apt install curl  (Debian/Ubuntu)"
    fi
}

# install::check_jq
install::check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        install::_status_row "err" "jq" \
            "missing; fix: brew install jq  (macOS)  |  apt install jq  (Debian/Ubuntu)"
        return
    fi
    local jq_version raw
    raw="$(jq --version 2>/dev/null || printf 'jq-0')"
    # `jq --version` prints "jq-1.7" or "jq-1.6"; strip the prefix.
    jq_version="${raw#jq-}"
    # Some builds report "jq-1.7.1"; that's fine.
    if install::_version_ge "$jq_version" "$INSTALL_MIN_JQ_VERSION"; then
        install::_status_row "ok" "jq ${jq_version}" "(>= ${INSTALL_MIN_JQ_VERSION})"
    else
        install::_status_row "err" "jq ${jq_version}" \
            "needs >= ${INSTALL_MIN_JQ_VERSION}; fix: brew install jq"
    fi
}

# install::check_git
install::check_git() {
    if ! command -v git >/dev/null 2>&1; then
        install::_status_row "err" "git" \
            "missing; fix: install Apple Command-Line Tools (xcode-select --install) or apt install git"
        return
    fi
    local git_full git_version
    git_full="$(git --version 2>/dev/null || printf 'git version 0.0')"
    # "git version 2.43.0" or "git version 2.43.0 (Apple Git-145)"
    git_version="$(printf '%s' "$git_full" | awk '{ print $3 }')"
    # Strip any "-foo" or "(Apple…)" tail to keep sort -V happy.
    git_version="${git_version%%[^0-9.]*}"
    if install::_version_ge "$git_version" "$INSTALL_MIN_GIT_VERSION"; then
        install::_status_row "ok" "git ${git_version}" "(>= ${INSTALL_MIN_GIT_VERSION})"
    else
        install::_status_row "err" "git ${git_version}" \
            "needs >= ${INSTALL_MIN_GIT_VERSION}; fix: brew install git or apt install git"
    fi
}

# install::check_gh
#
# `gh` is OPTIONAL per FR-018b. Absence surfaces as a warning + the
# degraded Layer D fallback note, NOT an error. Authentication state
# is reported separately (warn if not authed).
install::check_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        install::_status_row "warn" "gh CLI" \
            "missing (optional); PR-state detection falls back to git branch reachability (FR-030). fix: brew install gh"
        return
    fi
    local gh_version
    gh_version="$(gh --version 2>/dev/null | head -n1 | awk '{ print $3 }')"
    if gh auth status >/dev/null 2>&1; then
        install::_status_row "ok" "gh ${gh_version}" "(authenticated)"
    else
        install::_status_row "warn" "gh ${gh_version}" \
            "not authenticated; fix: gh auth login --scopes repo"
    fi
}

# install::check_repo_layout
#
# Confirm we're in a git repo with a spec-kit `.specify/` directory.
# These are filesystem prerequisites the install can't proceed without
# (data-model.md §2.1 invariants).
install::check_repo_layout() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        install::_status_row "err" "git working tree" \
            "current directory is not inside a git repo; fix: cd into your consumer repo's root"
        return 1
    fi
    install::_status_row "ok" "git working tree" "$(git rev-parse --show-toplevel)"

    if [[ ! -d ".specify" ]]; then
        install::_status_row "err" ".specify/" \
            "missing; fix: run \`specify init\` in this repo first (this is a spec-kit consumer repo)"
        return 1
    fi
    install::_status_row "ok" ".specify/" "present"

    if [[ ! -f "$INSTALL_EXTENSIONS_YML" ]]; then
        install::_status_row "warn" "$INSTALL_EXTENSIONS_YML" \
            "missing; will be created during hook registration"
    elif [[ ! -w "$INSTALL_EXTENSIONS_YML" ]]; then
        install::_status_row "err" "$INSTALL_EXTENSIONS_YML" \
            "not writable; fix: chmod u+w $INSTALL_EXTENSIONS_YML"
        return 1
    else
        install::_status_row "ok" "$INSTALL_EXTENSIONS_YML" "writable"
    fi

    if [[ ! -d "$INSTALL_GIT_HOOKS_DIR" ]]; then
        install::_status_row "err" "$INSTALL_GIT_HOOKS_DIR" \
            "missing; fix: run \`git init\` if this isn't actually a git repo"
        return 1
    fi
    if [[ ! -w "$INSTALL_GIT_HOOKS_DIR" ]]; then
        install::_status_row "err" "$INSTALL_GIT_HOOKS_DIR" \
            "not writable; fix: chmod u+w $INSTALL_GIT_HOOKS_DIR"
        return 1
    fi
    install::_status_row "ok" "$INSTALL_GIT_HOOKS_DIR" "writable"

    return 0
}

# install::check_mcp_json
#
# Verify the consumer's `.mcp.json` wiring for the Linear MCP. If the
# file is missing or the Linear entry is absent, auto-add it (FR-018b
# — "verify the presence of every external dependency it touches").
# This is the canonical place where the bridge writes operator-host
# MCP wiring on the consumer's behalf.
install::check_mcp_json() {
    if [[ ! -f "$INSTALL_MCP_JSON_PATH" ]]; then
        install::_status_row "warn" "$INSTALL_MCP_JSON_PATH" \
            "missing; creating with Linear MCP entry"
        install::_write_mcp_json_initial
        return
    fi

    # If jq is not present we've already errored above; just don't crash here.
    if ! command -v jq >/dev/null 2>&1; then
        install::_status_row "warn" "$INSTALL_MCP_JSON_PATH" \
            "jq missing; cannot verify Linear MCP entry"
        return
    fi

    if jq -e --arg url "$INSTALL_LINEAR_MCP_URL" \
        '(.mcpServers // {}) | to_entries[] | select(.value.url == $url or .value.transport.url == $url) | .key' \
        "$INSTALL_MCP_JSON_PATH" >/dev/null 2>&1; then
        install::_status_row "ok" "$INSTALL_MCP_JSON_PATH" \
            "Linear MCP entry present (${INSTALL_LINEAR_MCP_URL})"
        return
    fi

    install::_status_row "warn" "$INSTALL_MCP_JSON_PATH" \
        "Linear MCP entry absent; adding"
    install::_append_mcp_json_entry
}

# install::_write_mcp_json_initial
#
# Create a brand-new `.mcp.json` with the Linear MCP entry. Uses jq to
# build the document so quoting is bullet-proof.
install::_write_mcp_json_initial() {
    if ! command -v jq >/dev/null 2>&1; then
        install::_log_warn "cannot write .mcp.json without jq; skipping (already flagged above)"
        return
    fi
    local tmp
    tmp="$(mktemp -t spec-kit-linear-mcp.XXXXXX)"
    jq -n --arg url "$INSTALL_LINEAR_MCP_URL" \
        '{ mcpServers: { linear: { url: $url } } }' >"$tmp"
    mv "$tmp" "$INSTALL_MCP_JSON_PATH"
}

# install::_append_mcp_json_entry
#
# Merge a Linear MCP entry into an existing `.mcp.json` without
# disturbing the operator's other MCP server registrations. The merge
# preserves any unrelated keys.
install::_append_mcp_json_entry() {
    if ! command -v jq >/dev/null 2>&1; then
        install::_log_warn "cannot update .mcp.json without jq; skipping"
        return
    fi
    local tmp
    tmp="$(mktemp -t spec-kit-linear-mcp.XXXXXX)"
    jq --arg url "$INSTALL_LINEAR_MCP_URL" \
        '. as $root
         | ($root.mcpServers // {}) as $servers
         | $root
         | .mcpServers = ($servers + { linear: { url: $url } })' \
        "$INSTALL_MCP_JSON_PATH" >"$tmp"
    mv "$tmp" "$INSTALL_MCP_JSON_PATH"
}

# install::check_oauth
#
# We have no on-disk OAuth introspection surface — the bridge can't
# look inside the operator's MCP host keychain. The most we can do is
# warn the operator if no Linear OAuth artefacts exist under the
# `mcp-remote` cache dir (`~/.mcp-auth/mcp-remote-*/`) and surface the
# remediation command from `quickstart.md` Troubleshooting.
install::check_oauth() {
    local cache_dir="${HOME}/.mcp-auth"
    if [[ -d "$cache_dir" ]] \
        && find "$cache_dir" -mindepth 1 -maxdepth 2 -name 'mcp-remote-*' -print -quit 2>/dev/null | grep -q .; then
        install::_status_row "ok" "Linear MCP OAuth" \
            "cached credentials present under ~/.mcp-auth/"
    else
        install::_status_row "warn" "Linear MCP OAuth" \
            "no cached credentials; fix: npx -y mcp-remote ${INSTALL_LINEAR_MCP_URL} --transport http-only"
    fi
}

# install::check_env_file
#
# `.env` is OPTIONAL — only needed for direct-GraphQL paths (seed
# step, local git hooks, the GitHub Action's local-test mode). Absence
# is a warning, never an error.
install::check_env_file() {
    if [[ -f ".env" ]]; then
        if grep -q '^LINEAR_API_KEY=' .env 2>/dev/null; then
            install::_status_row "ok" ".env" "LINEAR_API_KEY present"
        else
            install::_status_row "warn" ".env" \
                "present but LINEAR_API_KEY not set; required for seed / git-hook / Action paths"
        fi
    else
        install::_status_row "warn" ".env" \
            "missing; LINEAR_API_KEY needed for direct-GraphQL paths. fix: echo 'LINEAR_API_KEY=lin_api_...' > .env"
    fi
}

# install::run_dependency_report
#
# Top-level dispatcher for the FR-018b dependency report. Aggregates
# every check above into a single emitted block per Principle VIII
# Rule 1. The function returns the cumulative hard-error count via
# INSTALL_HAD_HARD_ERROR; the caller decides whether to bail.
install::run_dependency_report() {
    printf '\nspec-kit-linear install dependency report\n' >&2

    install::_section "Runtime dependencies (FR-018b):"
    install::check_bash
    install::check_curl
    install::check_jq
    install::check_git
    install::check_gh

    install::_section "Linear MCP wiring:"
    install::check_mcp_json
    install::check_oauth

    install::_section "Filesystem layout:"
    if ! install::check_repo_layout; then
        # check_repo_layout already set INSTALL_HAD_HARD_ERROR via err rows.
        :
    fi

    install::_section "Secrets / .env:"
    install::check_env_file

    if (( INSTALL_HAD_HARD_ERROR == 1 )); then
        printf '\nspec-kit-linear: install: dependency report has unresolved errors (✗ rows above).\n' >&2
        printf '%s\n' "Resolve every ✗ row and re-run \`/spec-kit-linear-install\`." >&2
        return 1
    fi
    return 0
}

# =============================================================================
# T048 — Dogfood-loop guard.
#
# When the install target is the spec-kit-linear repo itself, register
# the after_* hooks with a `condition:` predicate so they don't
# auto-fire during the bridge's own development. The marker is
# `${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}` — the operator opts in by
# exporting that env var, which keeps the dogfood-on-itself path
# under explicit control.
# =============================================================================

install::detect_dogfood_target() {
    local repo_root repo_basename
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
    if [[ -z "$repo_root" ]]; then
        return 0
    fi
    repo_basename="$(basename "$repo_root")"

    # Two heuristics, EITHER triggering dogfood mode:
    #   (a) the config dir already exists AND we're inside this repo's tree —
    #       i.e. we're re-running install against an already-installed instance.
    #   (b) the repo's basename starts with `spec-kit-linear` and the
    #       extension manifest at this very script's parent path matches
    #       the repo root — i.e. we're installing this extension into
    #       itself.
    if [[ "$repo_basename" == spec-kit-linear* ]] \
        && [[ -f "${repo_root}/extension.yml" ]] \
        && grep -q 'id: "linear"' "${repo_root}/extension.yml" 2>/dev/null; then
        INSTALL_DOGFOOD_DETECTED=1
    fi
}

# =============================================================================
# FR-033b — dogfood-safe install override.
#
# Operators adopting the bridge into a repo whose Linear workspace
# ALREADY carries spec issues for this project (typical of the
# bridge's own dogfood cycle) need an explicit opt-in so install does
# not assume the workspace is virgin. Setting
# `SPECKIT_LINEAR_DOGFOOD_SAFE=1` in the environment toggles this
# acknowledged-collision mode. The install must surface the flag in
# its dependency report AND the final summary so the operator can see
# at a glance that the safety override is engaged.
#
# The env var is also the legacy condition marker for the dogfood hook
# guard (T048 / install::_render_hook_block) — same semantic surface;
# the difference here is that the install-time check honours the value
# as a one-shot install gate too.
# =============================================================================

install::detect_dogfood_safe_mode() {
    local raw="${SPECKIT_LINEAR_DOGFOOD_SAFE:-}"
    case "${raw,,}" in
        1|true|yes|on)
            INSTALL_DOGFOOD_SAFE_MODE=1
            ;;
        *)
            INSTALL_DOGFOOD_SAFE_MODE=0
            ;;
    esac
}

# =============================================================================
# T041 — Team + Project picker (FR-002, FR-019).
#
# In non-interactive mode we just trust the --team and --project (or
# --auto-create) flags. In interactive mode we'd normally call
# `graphql::query` to list teams / projects, but that requires a live
# Linear connection — out of scope for this Phase 4 implementation,
# which focuses on the install ceremony's filesystem-side wiring. We
# stub the interactive picker by recording the operator's flag-passed
# choices and surfacing a clear pointer to the seed step.
#
# The actual GraphQL-driven interactive picker is deferred to T077
# (dogfood polish) where it can be exercised against a real
# workspace.
# =============================================================================

install::resolve_team_uuid() {
    if [[ -n "$INSTALL_FLAG_TEAM" ]]; then
        printf '%s\n' "$INSTALL_FLAG_TEAM"
        return 0
    fi
    # Interactive prompt — no GraphQL yet; ask the operator for the UUID.
    # In the dogfood interactive flow this will be replaced by a Linear
    # MCP list_teams call.
    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        install::_die 2 "--non-interactive requires --team <UUID>"
    fi
    local team_uuid=""
    printf '\n[linear] Linear Team UUID? ' >&2
    if ! IFS= read -r team_uuid; then
        install::_die 2 "no input received for Team UUID; pass --team <UUID> or run interactively"
    fi
    team_uuid="${team_uuid//[[:space:]]/}"
    if [[ -z "$team_uuid" ]]; then
        install::_die 2 "Team UUID cannot be empty"
    fi
    printf '%s\n' "$team_uuid"
}

# install::_find_existing_project <team_uuid> <project_name>
#
# Query the Linear team for an existing Project whose name matches
# <project_name> exactly. Echoes a JSON array of `{id, name, url}`
# nodes (possibly empty) on stdout. Halts the process via graphql::
# on transport / auth failure — operator identity already passed in
# install::resolve_operator above so a failure here is genuinely a
# Linear-side problem worth surfacing.
install::_find_existing_project() {
    local team_uuid="$1"
    local project_name="$2"

    # shellcheck disable=SC2016
    local query='query FindProjectByName($team: ID!, $name: String!) {
        projects(filter: {
            accessibleTeams: { id: { eq: $team } }
            name: { eq: $name }
        }, first: 10) {
            nodes { id name url }
        }
    }'
    local vars response
    vars="$(jq -nc \
        --arg team "$team_uuid" \
        --arg name "$project_name" \
        '{team: $team, name: $name}')"

    if ! response="$(graphql::query "$query" "$vars" 2>/dev/null)"; then
        # Network/auth failure — return empty array so the caller can
        # continue with create. The graphql layer already surfaced
        # diagnostics on the way up.
        printf '[]\n'
        return 0
    fi
    printf '%s' "$response" | jq -c '.data.projects.nodes // []'
}

# install::_create_project <team_uuid> <project_name>
#
# Issue a `projectCreate` mutation against the resolved team and echo
# the newly-minted Project's `{id, name, url}` JSON. Halts (via
# graphql::) on transport / mutation failure — this is the
# happy-path target for --auto-create; failure here means the install
# can't proceed past write_config so we surface immediately rather
# than degrading.
install::_create_project() {
    local team_uuid="$1"
    local project_name="$2"

    # shellcheck disable=SC2016
    local mutation='mutation InstallProjectCreate($input: ProjectCreateInput!) {
        projectCreate(input: $input) {
            success
            project { id name url }
        }
    }'
    local input_json vars response
    input_json="$(jq -nc \
        --arg name "$project_name" \
        --arg team "$team_uuid" \
        --arg description "Auto-created by speckit.linear.install for spec-kit lifecycle mirroring." \
        '{
            name: $name,
            teamIds: [$team],
            description: $description
        }')"
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    if ! response="$(graphql::mutate "$mutation" "$vars" 2>/dev/null)"; then
        install::_die 1 \
            "projectCreate '${project_name}' on team ${team_uuid} failed (transport). Re-run when Linear is reachable, or pass --project <UUID> to skip auto-create."
    fi

    if ! printf '%s' "$response" | jq -e '.data.projectCreate.success == true' >/dev/null 2>&1; then
        install::_die 1 \
            "projectCreate '${project_name}' did not return success=true; response: $(printf '%s' "$response" | jq -c '.errors // .data.projectCreate // .')"
    fi

    printf '%s' "$response" | jq -c '.data.projectCreate.project'
}

# install::resolve_project_uuid <team_uuid>
#
# Resolve the Linear Project UUID for the consumer repo. Precedence:
#   1. --project <UUID> on the CLI (operator override).
#   2. --auto-create: query for an existing Project on the team with
#      the target name. If exactly one match exists, attach (skip
#      create). If zero, mint a new Project via `projectCreate`. In
#      --non-interactive mode an exact-name match auto-attaches; in
#      interactive mode the operator is prompted (default: attach).
#   3. Interactive picker (create / attach / rename).
#
# Echoes ONLY the resolved UUID on stdout. URL / friendly metadata is
# stashed on module globals so write_config + the summary block can
# pick them up without re-querying.
install::resolve_project_uuid() {
    local team_uuid="$1"

    if [[ -n "$INSTALL_FLAG_PROJECT" ]]; then
        printf '%s\n' "$INSTALL_FLAG_PROJECT"
        return 0
    fi

    local repo_root repo_basename
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
    repo_basename="$(basename "${repo_root:-$(pwd)}")"

    if (( INSTALL_FLAG_AUTO_CREATE == 1 )); then
        install::_auto_create_or_attach "$team_uuid" "$repo_basename"
        return 0
    fi

    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        install::_die 2 "--non-interactive requires --project <UUID> or --auto-create"
    fi

    # Interactive Project picker.
    printf '\n[linear] Where should this repo'\''s specs land in Linear?\n' >&2
    printf '         Create new Project "%s", attach to an existing one, or rename?\n' \
        "$repo_basename" >&2
    printf '         [create/attach/rename] (default: create): ' >&2
    local choice=""
    if ! IFS= read -r choice; then
        install::_die 2 "no input received for Project choice"
    fi
    choice="${choice,,}"
    choice="${choice//[[:space:]]/}"
    : "${choice:=create}"

    case "$choice" in
        create)
            install::_auto_create_or_attach "$team_uuid" "$repo_basename"
            ;;
        rename)
            printf '         New Project name? ' >&2
            local renamed=""
            if ! IFS= read -r renamed; then
                install::_die 2 "no input received for Project name"
            fi
            renamed="$(printf '%s' "$renamed" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            if [[ -z "$renamed" ]]; then
                install::_die 2 "Project name cannot be empty"
            fi
            install::_auto_create_or_attach "$team_uuid" "$renamed"
            ;;
        attach)
            printf '         Existing Linear Project UUID? ' >&2
            local uuid=""
            if ! IFS= read -r uuid; then
                install::_die 2 "no input received for Project UUID"
            fi
            uuid="${uuid//[[:space:]]/}"
            if [[ -z "$uuid" ]]; then
                install::_die 2 "Project UUID cannot be empty"
            fi
            printf '%s\n' "$uuid"
            ;;
        *)
            install::_die 2 "unknown Project choice: '$choice' (expected create/attach/rename)"
            ;;
    esac
}

# install::_auto_create_or_attach <team_uuid> <project_name>
#
# Shared body for both --auto-create and the interactive create/rename
# paths. Pre-queries the team for an exact-name Project match:
#   * 1 match → attach (and surface the URL).
#   * 0 matches → projectCreate.
#   * >1 matches → halt; ambiguous, refuse to auto-pick.
# In --non-interactive mode a single existing match attaches silently
# (otherwise the operator is prompted with [y/N], default attach).
install::_auto_create_or_attach() {
    local team_uuid="$1"
    local project_name="$2"

    local existing
    existing="$(install::_find_existing_project "$team_uuid" "$project_name")"
    local match_count
    match_count="$(printf '%s' "$existing" | jq 'length')"

    if [[ "$match_count" =~ ^[0-9]+$ ]] && (( match_count == 1 )); then
        local existing_id existing_url
        existing_id="$(printf '%s' "$existing" | jq -r '.[0].id')"
        existing_url="$(printf '%s' "$existing" | jq -r '.[0].url // ""')"

        local attach_choice="y"
        if (( INSTALL_FLAG_NON_INTERACTIVE == 0 )); then
            printf '\n[linear] Project "%s" already exists in this team — attach?\n' \
                "$project_name" >&2
            if [[ -n "$existing_url" ]]; then
                printf '         URL: %s\n' "$existing_url" >&2
            fi
            printf '         [y/N] (default: y): ' >&2
            if ! IFS= read -r attach_choice; then
                attach_choice="y"
            fi
            attach_choice="${attach_choice,,}"
            attach_choice="${attach_choice//[[:space:]]/}"
            : "${attach_choice:=y}"
        else
            install::_log_info "--non-interactive: exactly one existing Project named '${project_name}' on team — auto-attaching"
        fi

        if [[ "$attach_choice" == "y" || "$attach_choice" == "yes" ]]; then
            INSTALL_RESOLVED_PROJECT_URL="$existing_url"
            INSTALL_RESOLVED_PROJECT_NAME="$project_name"
            summary::add "skipped" "projectCreate '${project_name}' — existing Project attached (${existing_id})"
            printf '%s\n' "$existing_id"
            return 0
        fi
        # Operator declined attach — fall through to create. Linear
        # allows duplicate names; we surface the situation as a warning.
        install::_log_warn "Operator declined attach to existing '${project_name}'; creating a duplicate"
    elif [[ "$match_count" =~ ^[0-9]+$ ]] && (( match_count > 1 )); then
        install::_die 2 \
            "found ${match_count} Projects named '${project_name}' on team ${team_uuid}; refusing to auto-pick. Pass --project <UUID> with the correct match."
    fi

    # 0 matches (or declined attach) → projectCreate.
    local created
    created="$(install::_create_project "$team_uuid" "$project_name")"
    local new_id new_url
    new_id="$(printf '%s' "$created" | jq -r '.id')"
    new_url="$(printf '%s' "$created" | jq -r '.url // ""')"
    INSTALL_RESOLVED_PROJECT_URL="$new_url"
    INSTALL_RESOLVED_PROJECT_NAME="$project_name"
    summary::add "created" "projectCreate '${project_name}' → ${new_id}"
    if [[ -n "$new_url" ]]; then
        install::_log_info "Created Linear Project: ${new_url}"
    fi
    printf '%s\n' "$new_id"
}

# =============================================================================
# FR-034 — Operator identity resolution.
#
# At `specify extension add linear` time, capture the authenticating
# Linear user's identity via the GraphQL `viewer { id name email }`
# query and stash the three fields on module globals so
# install::write_config can interpolate them into the `operator:` block
# of the per-repo linear-config.yml.
#
# This runs AFTER team/project resolution because the user UUID is a
# dependency the reconciler reads at every issueCreate to populate
# assigneeId per FR-034. Missing or invalid LINEAR_API_KEY at this
# point is a hard error (exit 2) — operator identity is a dependency
# the bridge touches per FR-018b, so silent skip is forbidden.
#
# Behaviour:
#   * Always runs (no flag opt-out) in both interactive and
#     --non-interactive modes — the query has no prompts.
#   * On dogfood / dev mode where Linear is genuinely unreachable, the
#     graphql:: layer's exit-2 / exit-3 surfaces actionable diagnostics
#     and halts; the install fails loud rather than producing a
#     half-populated config.
# =============================================================================

install::resolve_operator() {
    local query='query Me { viewer { id name email } }'

    # graphql::query halts the process (exit 2/3/4) on its own when the
    # API key is missing or the request fails. The keys-at-edges
    # boundary lives in graphql.sh; this caller just consumes the JSON.
    local response viewer_json
    if ! response="$(graphql::query "$query" '{}')"; then
        install::_die 2 \
            "LINEAR_API_KEY missing or invalid — operator identity required for FR-034 (viewer { id name email })
hint: set LINEAR_API_KEY in .env or export it before re-running install"
    fi

    viewer_json="$(printf '%s' "$response" | jq -c '.data.viewer // null')"
    if [[ -z "$viewer_json" || "$viewer_json" == "null" ]]; then
        install::_die 2 \
            "LINEAR_API_KEY missing or invalid — operator identity required for FR-034: viewer query returned no data"
    fi

    INSTALL_OPERATOR_USER_ID="$(printf '%s' "$viewer_json" | jq -r '.id // ""')"
    INSTALL_OPERATOR_NAME="$(printf '%s' "$viewer_json"   | jq -r '.name // ""')"
    INSTALL_OPERATOR_EMAIL="$(printf '%s' "$viewer_json"  | jq -r '.email // ""')"

    if [[ -z "$INSTALL_OPERATOR_USER_ID" ]]; then
        install::_die 2 \
            "LINEAR_API_KEY missing or invalid — operator identity required for FR-034: viewer.id absent from response"
    fi

    # FR-018b summary row — short the UUID to 8 chars for readability.
    local short_uuid="${INSTALL_OPERATOR_USER_ID:0:8}"
    install::_log_info \
        "Operator: ${INSTALL_OPERATOR_NAME:-<no name>} <${INSTALL_OPERATOR_EMAIL:-<no email>}> (${short_uuid}...)"
    summary::add "updated" \
        "operator resolved: ${INSTALL_OPERATOR_NAME:-<no name>} <${INSTALL_OPERATOR_EMAIL:-<no email>}> (${short_uuid}...)"
}

# install::write_config <team_uuid> <project_uuid>
#
# Copy `config-template.yml` into `.specify/extensions/linear/linear-config.yml`
# (unless the file already exists with non-zero UUIDs) and substitute
# the resolved Team + Project UUIDs in-place. The seed step later
# fills `workflow_state_uuids`. The operator identity (FR-034)
# captured by install::resolve_operator is also substituted into the
# `operator:` block on first-time writes; on re-installs the existing
# operator block is preserved unless it still holds the zero
# placeholder.
#
# Idempotency: re-running install against an already-populated config
# preserves any existing Project UUID — we only rewrite the
# placeholder zero-UUID and never overwrite a real one without explicit
# operator confirmation (FR-018b safety; matches command-shapes.md
# §5.7 "linear-config.yml already exists with mismatched Project UUID").
install::write_config() {
    local team_uuid="$1"
    local project_uuid="$2"

    mkdir -p "$INSTALL_CONFIG_DIR"

    # If the operator already committed a populated config, preserve their
    # values. We only mutate the zero placeholder.
    if [[ -f "$INSTALL_CONFIG_PATH" ]]; then
        install::_log_info "linear-config.yml already present; preserving existing UUIDs (override with --force in a future revision)"
        # Update only zero-placeholder lines.
        install::_substitute_uuid_placeholder "$INSTALL_CONFIG_PATH" \
            "linear.team.id" "$team_uuid"
        install::_substitute_uuid_placeholder "$INSTALL_CONFIG_PATH" \
            "linear.project.id" "$project_uuid"
        install::_write_operator_block "$INSTALL_CONFIG_PATH"
        return 0
    fi

    if [[ ! -f "$INSTALL_CONFIG_TEMPLATE" ]]; then
        install::_die 2 "config template missing: ${INSTALL_CONFIG_TEMPLATE}
hint: re-run \`specify extension add linear\` (or pass --dev with a checkout of spec-kit-linear)"
    fi

    cp "$INSTALL_CONFIG_TEMPLATE" "$INSTALL_CONFIG_PATH"
    install::_substitute_uuid_placeholder "$INSTALL_CONFIG_PATH" \
        "linear.team.id" "$team_uuid"
    install::_substitute_uuid_placeholder "$INSTALL_CONFIG_PATH" \
        "linear.project.id" "$project_uuid"
    install::_write_operator_block "$INSTALL_CONFIG_PATH"
    install::_log_info "wrote ${INSTALL_CONFIG_PATH}"
}

# install::_write_operator_block <file>
#
# Substitute the three operator-identity fields (user_id, name, email)
# captured by install::resolve_operator into the `operator:` block of
# the linear-config.yml at <file>. Per FR-034 we only overwrite the
# placeholder values that the template ships with — a re-install must
# never silently mutate an operator-edited config.
#
# The function is a no-op when INSTALL_OPERATOR_USER_ID is empty (the
# resolver was skipped or returned no data) — in that case
# config::get_operator_user_id will later report absence and the
# reconciler will degrade gracefully per FR-034.
install::_write_operator_block() {
    local file="$1"

    if [[ -z "$INSTALL_OPERATOR_USER_ID" ]]; then
        return 0
    fi

    install::_substitute_operator_field "$file" "user_id" \
        "\"${INSTALL_OPERATOR_USER_ID}\"" \
        '"00000000-0000-0000-0000-000000000000"'
    install::_substitute_operator_field "$file" "name" \
        "\"${INSTALL_OPERATOR_NAME}\"" \
        '"Ash Brener"'
    install::_substitute_operator_field "$file" "email" \
        "\"${INSTALL_OPERATOR_EMAIL}\"" \
        '"ash@example.com"'
}

# install::_substitute_operator_field <file> <field> <new_quoted> <placeholder_quoted>
#
# Replace the first occurrence of `<field>: <placeholder_quoted>` inside
# the `operator:` block with `<field>: <new_quoted>`. Idempotent — once
# the placeholder is gone, the function is a no-op so re-running install
# against an operator-edited config preserves the operator's values.
install::_substitute_operator_field() {
    local file="$1"
    local field="$2"
    local new_quoted="$3"
    local placeholder_quoted="$4"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local tmp
    tmp="$(mktemp -t spec-kit-linear-config.XXXXXX)"
    awk -v field="$field" \
        -v placeholder="$placeholder_quoted" \
        -v replacement="$new_quoted" '
        BEGIN { in_block = 0; replaced = 0 }
        {
            ltrim = $0
            sub(/^[[:space:]]+/, "", ltrim)
            if (ltrim == "operator:") {
                in_block = 1
                print
                next
            }
            # Sibling block opener at the same indent level closes the
            # operator: scope. Heuristic: a key line at the two-space
            # indent (the indent of operator: itself) that is not a
            # nested child.
            if (in_block && $0 ~ /^  [a-zA-Z_].*:[[:space:]]*$/) {
                in_block = 0
            }
            if (in_block && replaced == 0) {
                # Anchor on "    <field>:" so unrelated keys with
                # similar names dont match.
                pattern = "^[[:space:]]+" field ":[[:space:]]*" placeholder
                if (match($0, pattern)) {
                    # Replace just the placeholder; leave indent +
                    # trailing comment intact.
                    sub(placeholder, replacement)
                    replaced = 1
                }
            }
            print
        }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
}

# install::_substitute_uuid_placeholder <file> <key> <uuid>
#
# Replace the first occurrence of `id: "00000000-...-..."` immediately
# under <key>'s parent block with the resolved UUID. The substitution
# is anchored on the key name so unrelated zero-UUIDs (e.g. the
# workflow_state_uuids placeholders) survive untouched.
install::_substitute_uuid_placeholder() {
    local file="$1"
    local key="$2"      # dotted form, e.g. "linear.team.id"
    local uuid="$3"

    # Skip if the target file has no zero-UUIDs (operator-edited already).
    if ! grep -q '00000000-0000-0000-0000-000000000000' "$file" 2>/dev/null; then
        return 0
    fi

    # Map dotted key → YAML anchor block (the parent key whose `id:`
    # line we'll mutate). The team and project blocks are flat one-level
    # children of `linear:`.
    local parent_block=""
    case "$key" in
        linear.team.id)     parent_block="team:" ;;
        linear.project.id)  parent_block="project:" ;;
        *) return 0 ;;
    esac

    local tmp
    tmp="$(mktemp -t spec-kit-linear-config.XXXXXX)"
    awk -v block="$parent_block" -v new_uuid="$uuid" '
        BEGIN { in_block = 0; replaced = 0 }
        {
            # Detect entry into the target block (line ends with the
            # block label like "  team:"). Trim leading whitespace for
            # the match.
            ltrim = $0
            sub(/^[[:space:]]+/, "", ltrim)
            if (ltrim == block) {
                in_block = 1
                print
                next
            }
            # Exit the block on the next sibling at the same or lower
            # indent that contains a colon and is not a nested child.
            # Heuristic: any line with no leading space terminates a
            # nested block; any line whose first non-space char is `#`
            # is a comment and we keep `in_block` flag intact.
            if (in_block && ltrim ~ /^[a-zA-Z_].*:[[:space:]]*$/) {
                in_block = 0
            }
            if (in_block && replaced == 0 \
                && $0 ~ /id:[[:space:]]*"00000000-0000-0000-0000-000000000000"/) {
                sub(/"00000000-0000-0000-0000-000000000000"/, "\"" new_uuid "\"")
                replaced = 1
            }
            print
        }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
}

# =============================================================================
# T042 — `after_*` hook registration (FR-031 / Principle VII).
#
# Append each of the six `after_*` hook entries into the consumer's
# `.specify/extensions.yml`. Strategy:
#   - If the file is missing, create it with a minimal `hooks:` block.
#   - If the file exists but the `after_*` block has no `linear` entry,
#     append our entry to that block.
#   - If the entry already exists, preserve any `enabled: false` the
#     operator set by hand (Principle VII rule 1).
#   - When INSTALL_DOGFOOD_DETECTED == 1, add a `condition:` field with
#     the `${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}` marker.
#
# YAML manipulation uses awk + grep — yq is NOT a required dep
# (plan.md Technical Context).
# =============================================================================

install::register_after_hooks() {
    if [[ ! -f "$INSTALL_EXTENSIONS_YML" ]]; then
        install::_create_minimal_extensions_yml
    fi

    local hook
    for hook in "${INSTALL_AFTER_HOOK_NAMES[@]}"; do
        install::_register_one_hook "$hook"
    done
}

install::_create_minimal_extensions_yml() {
    mkdir -p "$(dirname "$INSTALL_EXTENSIONS_YML")"
    cat >"$INSTALL_EXTENSIONS_YML" <<'YAML'
installed:
- linear
settings:
  auto_execute_hooks: true
hooks:
YAML
    install::_log_info "created ${INSTALL_EXTENSIONS_YML}"
}

# install::_register_one_hook <hook_name>
#
# Idempotently insert (or update) the `linear` entry under <hook_name>
# in `.specify/extensions.yml`. Re-registration honours any existing
# `enabled: false` per Principle VII.
install::_register_one_hook() {
    local hook="$1"

    # Already-registered? If so, leave any `enabled: false` flag the
    # operator chose intact and return.
    if install::_hook_already_registered "$hook"; then
        install::_log_info "hook ${hook} already registered; preserving existing entry"
        return 0
    fi

    # Build the YAML block we're about to append. The shape mirrors
    # speckit-git's entries so spec-kit's host agent parses our block
    # the same way as every other extension's.
    local block
    block="$(install::_render_hook_block "$hook")"

    # Two append paths:
    #   (a) The `hook:` key already exists with at least one entry —
    #       append the linear block under it.
    #   (b) The `hook:` key is missing entirely — create it with the
    #       linear block underneath.
    if grep -qE "^[[:space:]]{2}${hook}:[[:space:]]*$" "$INSTALL_EXTENSIONS_YML"; then
        install::_append_under_hook "$hook" "$block"
    else
        install::_create_hook_section "$hook" "$block"
    fi
}

# install::_hook_already_registered <hook_name>
#
# Returns 0 iff the named after_* hook already has a `linear` extension
# entry. The match is anchored on `extension: linear` appearing inside
# the block.
install::_hook_already_registered() {
    local hook="$1"
    [[ -f "$INSTALL_EXTENSIONS_YML" ]] || return 1
    awk -v want="$hook" '
        BEGIN { in_block = 0; found = 0 }
        $0 ~ "^  " want ":" {
            in_block = 1
            next
        }
        in_block && /^  [a-zA-Z_]+:[[:space:]]*$/ {
            in_block = 0
        }
        in_block && /extension:[[:space:]]*linear/ {
            found = 1
            exit
        }
        END { exit (found ? 0 : 1) }
    ' "$INSTALL_EXTENSIONS_YML"
}

# install::_render_hook_block <hook_name>
#
# Emit the YAML for a single `linear` entry under a hook block. When
# INSTALL_DOGFOOD_DETECTED == 1, include the `condition:` marker that
# gates auto-fire on `${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}`.
install::_render_hook_block() {
    local hook="$1"
    local description prompt
    case "$hook" in
        after_specify)
            description="Reconcile after /speckit-specify so the new spec Issue exists in Linear with the correct initial phase."
            prompt="Reconciling spec.md to Linear..."
            ;;
        after_clarify)
            description="Reconcile after /speckit-clarify so ratified Q/A bullets appear as comments on the spec Issue."
            prompt="Reconciling clarification rounds to Linear comments..."
            ;;
        after_plan)
            description="Reconcile after /speckit-plan so the spec Issue advances to Planning and plan summaries appear as comments."
            prompt="Reconciling plan.md to Linear..."
            ;;
        after_tasks)
            description="Reconcile after /speckit-tasks so each Phase N becomes a Linear sub-issue with the right checklist and blocking relations."
            prompt="Reconciling tasks.md to Linear sub-issues..."
            ;;
        after_implement)
            description="Reconcile after /speckit-implement so checklist completion state and current-task memory refresh in Linear."
            prompt="Reconciling implementation progress to Linear..."
            ;;
        after_analyze)
            description="Reconcile after /speckit-analyze so analyze findings appear as comments on the spec Issue."
            prompt="Reconciling analyze findings to Linear comments..."
            ;;
        *)
            description="Reconcile after /${hook#after_} so Linear stays in sync."
            prompt="Reconciling to Linear..."
            ;;
    esac

    {
        printf '  - extension: linear\n'
        printf '    command: speckit.linear.push\n'
        printf '    enabled: true\n'
        printf '    optional: false\n'
        printf '    prompt: %s\n' "$prompt"
        printf '    description: %s\n' "$description"
        if (( INSTALL_DOGFOOD_DETECTED == 1 )); then
            # SC2016 suppressed: the `${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}`
            # text is meant to be written verbatim into the YAML file; it
            # is the host agent (not us) that evaluates it at hook-fire
            # time. We want literal text, not bash expansion here.
            # shellcheck disable=SC2016
            printf '    condition: "${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}"\n'
        else
            printf '    condition: null\n'
        fi
    }
}

# install::_append_under_hook <hook_name> <block_text>
#
# Insert the rendered block immediately after the named hook header,
# before the next sibling hook or end-of-file. Preserves any existing
# entries (e.g. speckit-git's `commit` entry under after_specify).
#
# Implementation note (BSD awk on macOS rejects multi-line `-v`
# values — the dogfood run surfaced `awk: newline in string`):
# rather than splice with awk -v block=, we use a pure-bash state
# machine that walks the file line-by-line and emits the multi-line
# <block_text> verbatim at the insertion point. Mirrors seed.sh's
# write_config_uuids approach and keeps the awk dependency surface
# limited to single-line variables.
install::_append_under_hook() {
    local hook="$1"
    local block="$2"
    local tmp
    tmp="$(mktemp -t spec-kit-linear-ext-yml.XXXXXX)"

    # Per-line state machine:
    #   state="before"  — copy verbatim until we hit the hook header.
    #   state="in_hook" — buffer every line of the hook's child block
    #                     until we see the next sibling hook header
    #                     (two-space indent + key + colon) or EOF.
    #   state="after"   — copy the rest verbatim.
    # On exit-from-in_hook (sibling header or EOF) we flush the
    # buffered children, then printf the new block, then resume.
    local state="before"
    local -a block_buf=()
    local emitted=0
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$state" == "before" ]]; then
            if [[ "$line" =~ ^[[:space:]]{2}${hook}:[[:space:]]*$ ]]; then
                printf '%s\n' "$line" >>"$tmp"
                state="in_hook"
                block_buf=()
                continue
            fi
            printf '%s\n' "$line" >>"$tmp"
            continue
        fi
        if [[ "$state" == "in_hook" ]]; then
            # Next sibling at the two-space hook indent — flush, emit, switch state.
            if [[ "$line" =~ ^\ {2}[a-zA-Z_]+:[[:space:]]*$ ]]; then
                local buf_line
                for buf_line in "${block_buf[@]+"${block_buf[@]}"}"; do
                    printf '%s\n' "$buf_line" >>"$tmp"
                done
                printf '%s\n' "$block" >>"$tmp"
                emitted=1
                printf '%s\n' "$line" >>"$tmp"
                state="after"
                continue
            fi
            block_buf+=("$line")
            continue
        fi
        # state == "after"
        printf '%s\n' "$line" >>"$tmp"
    done < "$INSTALL_EXTENSIONS_YML"

    # Drained the whole file while still inside the hook block — flush
    # buffered children + emit the new block at EOF.
    if [[ "$state" == "in_hook" ]] && (( emitted == 0 )); then
        local buf_line
        for buf_line in "${block_buf[@]+"${block_buf[@]}"}"; do
            printf '%s\n' "$buf_line" >>"$tmp"
        done
        printf '%s\n' "$block" >>"$tmp"
    fi

    mv "$tmp" "$INSTALL_EXTENSIONS_YML"
}

# install::_create_hook_section <hook_name> <block_text>
#
# Append a brand-new hook section (`  <hook>:` plus the block) to the
# tail of `.specify/extensions.yml`. Used when the host file has no
# entry for the hook at all.
install::_create_hook_section() {
    local hook="$1"
    local block="$2"
    # Read the file's hooks-key presence BEFORE opening the append redirect
    # so shellcheck SC2094 (read-and-write same file in pipeline) stays
    # clean. Buffer the work into a temp variable, then redirect once.
    local needs_hooks_header=0
    if ! grep -qE '^hooks:[[:space:]]*$' "$INSTALL_EXTENSIONS_YML"; then
        needs_hooks_header=1
    fi
    {
        if (( needs_hooks_header == 1 )); then
            printf 'hooks:\n'
        fi
        printf '  %s:\n' "$hook"
        printf '%s\n' "$block"
    } >>"$INSTALL_EXTENSIONS_YML"
}

# =============================================================================
# T043 — Local git hook installation (FR-033).
#
# Copy `templates/git-hooks/{post-checkout,post-commit,post-merge}` into
# the consumer's `.git/hooks/`, chaining onto any pre-existing hooks
# rather than overwriting (FR-033). The chain mechanism: if a hook
# file already exists, we append a marker block and our invocation to
# its end. If no hook exists, we drop our template directly.
#
# Templates that don't yet exist in the bridge's own repo (T044-T046
# may still be in flight) surface a per-hook warning rather than a
# hard error so partial Phase 4 installs still progress.
# =============================================================================

readonly INSTALL_HOOK_MARKER_BEGIN="# >>> spec-kit-linear hook begin (FR-033) >>>"
readonly INSTALL_HOOK_MARKER_END="# <<< spec-kit-linear hook end <<<"

install::install_git_hooks() {
    local hook_name
    for hook_name in "${INSTALL_GIT_HOOK_NAMES[@]}"; do
        install::_install_one_git_hook "$hook_name"
    done
}

# install::_install_one_git_hook <hook_name>
#
# Idempotent install of a single git hook. Handles three cases:
#   1. No pre-existing hook  → drop our template verbatim.
#   2. Pre-existing spec-kit-linear marker → leave alone (idempotent).
#   3. Pre-existing non-bridge hook → append our invocation in a
#      MARKER_BEGIN ... MARKER_END block at the file's end.
install::_install_one_git_hook() {
    local hook_name="$1"
    local target="${INSTALL_GIT_HOOKS_DIR}/${hook_name}"
    local template="${EXTENSION_ROOT}/templates/git-hooks/${hook_name}"

    if [[ ! -f "$template" ]]; then
        install::_log_warn "git-hook template missing: ${template}; skipping (T044-T046 may still be in flight)"
        return 0
    fi

    if [[ ! -f "$target" ]]; then
        # Case 1: fresh install. Copy template + chmod +x.
        cp "$template" "$target"
        chmod +x "$target"
        install::_log_info "installed ${target} (FR-033)"
        return 0
    fi

    if grep -qF "$INSTALL_HOOK_MARKER_BEGIN" "$target" 2>/dev/null; then
        # Case 2: already chained / installed. Re-run is a no-op.
        install::_log_info "${target} already has spec-kit-linear hook (idempotent)"
        return 0
    fi

    # Case 3: append our invocation in a clearly-marked block.
    {
        printf '\n%s\n' "$INSTALL_HOOK_MARKER_BEGIN"
        # The block invokes the bridge's reconciler with the right
        # arguments for the hook type. We avoid running the template
        # verbatim (it may have its own `set -e` / shebang) and
        # instead embed a minimal forwarding call.
        printf '# Added by spec-kit-linear install ceremony per FR-033.\n'
        printf '# Honour SPECKIT_LINEAR_DOGFOOD_SAFE in the bridge'\''s own repo.\n'
        case "$hook_name" in
            post-checkout)
                printf '"%s/templates/git-hooks/%s" "$@" || true\n' \
                    "$EXTENSION_ROOT" "$hook_name"
                ;;
            post-commit|post-merge)
                printf '"%s/templates/git-hooks/%s" || true\n' \
                    "$EXTENSION_ROOT" "$hook_name"
                ;;
            *)
                printf '"%s/templates/git-hooks/%s" || true\n' \
                    "$EXTENSION_ROOT" "$hook_name"
                ;;
        esac
        printf '%s\n' "$INSTALL_HOOK_MARKER_END"
    } >>"$target"
    install::_log_info "chained spec-kit-linear hook into existing ${target}"
}

# =============================================================================
# Optional: --with-action (FR-027 + FR-029).
#
# Copy `templates/github-action.yml` into the consumer's
# `.github/workflows/spec-kit-linear-sync.yml`, then print the
# `gh secret set LINEAR_API_TOKEN` provisioning instructions. The
# bridge MUST NOT provision the secret on the operator's behalf
# (FR-029).
# =============================================================================

install::install_github_action() {
    local template="${EXTENSION_ROOT}/templates/github-action.yml"

    if [[ ! -f "$template" ]]; then
        # T064: per the contract, a missing template is an ERROR — the
        # operator opted into Layer E and the bridge couldn't deliver.
        # Surface loud, then bail so the summary block reflects the
        # gap rather than silently degrading.
        install::_log_error "github-action template missing at ${template}; cannot install Layer E"
        summary::add "error" "github-action template missing at ${template} (FR-027)"
        return 1
    fi

    mkdir -p "$INSTALL_GH_WORKFLOWS_DIR"

    if [[ -f "$INSTALL_GH_WORKFLOW_FILE" ]]; then
        # T064: idempotent overwrite-protection. Interactive runs ask
        # before clobbering an operator-customised workflow file;
        # non-interactive runs always preserve in place (the operator
        # can re-run with --with-action after manually deleting the
        # file if they truly want a fresh copy).
        local overwrite="n"
        if (( INSTALL_FLAG_NON_INTERACTIVE == 0 )); then
            printf '\n[linear] %s already exists. Overwrite? [y/N]: ' \
                "$INSTALL_GH_WORKFLOW_FILE" >&2
            if ! IFS= read -r overwrite; then
                overwrite="n"
            fi
            overwrite="${overwrite,,}"
            overwrite="${overwrite//[[:space:]]/}"
            : "${overwrite:=n}"
        else
            install::_log_info "${INSTALL_GH_WORKFLOW_FILE} already exists; --non-interactive preserves operator changes"
        fi

        if [[ "$overwrite" == "y" || "$overwrite" == "yes" ]]; then
            cp "$template" "$INSTALL_GH_WORKFLOW_FILE"
            install::_log_info "overwrote ${INSTALL_GH_WORKFLOW_FILE} per operator confirmation"
        else
            install::_log_info "${INSTALL_GH_WORKFLOW_FILE} preserved; skipping copy"
        fi
    else
        cp "$template" "$INSTALL_GH_WORKFLOW_FILE"
        install::_log_info "installed ${INSTALL_GH_WORKFLOW_FILE} (FR-027)"
    fi

    # FR-029 token provisioning instructions.
    local repo_root repo_basename owner_hint=""
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
    repo_basename="$(basename "${repo_root:-$(pwd)}")"
    if command -v gh >/dev/null 2>&1; then
        owner_hint="$(gh repo view --json owner -q '.owner.login' 2>/dev/null || printf '')"
    fi

    {
        printf '\n[linear] FR-029 — Layer E secret provisioning required.\n'
        printf '         Create a Linear API key at: https://linear.app/settings/api\n'
        if [[ -n "$owner_hint" ]]; then
            printf '         Then run: gh secret set LINEAR_API_TOKEN -R %s/%s\n' \
                "$owner_hint" "$repo_basename"
        else
            printf '         Then run: gh secret set LINEAR_API_TOKEN -R <owner>/<repo>\n'
        fi
        printf '         The bridge will NOT provision the secret on your behalf (FR-029).\n'
    } >&2
}

# =============================================================================
# T063 — Seeded-state detection + first-install seed prompt.
#
# Inspect the resolved consumer-repo linear-config.yml for the
# `workflow_state_uuids` map. The workspace is considered "seeded"
# when every key under that map carries a non-zero UUID (per the
# FR-022 contract — placeholder zero-UUIDs signal an unseeded
# workspace). If the map is absent or every entry holds the
# placeholder zero-UUID, the install offers the operator three paths:
#   (1) default: invoke `src/seed.sh` inline so the same install
#       invocation leaves a fully-seeded workspace,
#   (2) defer: complete install but warn that subsequent reconciles
#       will halt per FR-022 until /spec-kit-linear-seed runs,
#   (3) non-interactive: halt with the FR-022 error so CI does not
#       silently leave an unseeded workspace.
#
# Returns 0 in all happy-path branches (including operator defer);
# returns non-zero only when the inline seed itself failed in a way
# that should fail the install too.
# =============================================================================

# install::_workspace_is_seeded <config-path>
#   Echo nothing; exit 0 iff every workflow_state_uuids.* entry in the
#   given config file is a non-zero UUID. Exit 1 if any entry is the
#   placeholder zero-UUID or missing.
install::_workspace_is_seeded() {
    local config_path="$1"
    if [[ ! -f "$config_path" ]]; then
        return 1
    fi
    # Pull every quoted UUID under the workflow_state_uuids: block.
    # If any of them is the zero placeholder, the workspace is
    # unseeded. Same parser shape as install::_substitute_uuid_placeholder
    # (awk state machine; no yq dep).
    local zero_count
    zero_count="$(awk '
        BEGIN { in_block = 0; zero = 0 }
        {
            ltrim = $0
            sub(/^[[:space:]]+/, "", ltrim)
            if (ltrim == "workflow_state_uuids:") {
                in_block = 1
                next
            }
            if (in_block && $0 ~ /^[[:space:]]{0,2}[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ \
                && $0 !~ /^[[:space:]]{4,}/) {
                in_block = 0
            }
            if (in_block && $0 ~ /"00000000-0000-0000-0000-000000000000"/) {
                zero += 1
            }
        }
        END { print zero }
    ' "$config_path")"

    if [[ "$zero_count" =~ ^[0-9]+$ ]] && (( zero_count == 0 )); then
        # Also require the key to exist at all — a config that omits
        # workflow_state_uuids entirely is unseeded by definition.
        if grep -qE '^[[:space:]]*workflow_state_uuids:[[:space:]]*$' "$config_path" 2>/dev/null; then
            return 0
        fi
        return 1
    fi
    return 1
}

# install::prompt_seed_run <team_uuid>
#   Detect whether the consumer repo's config has a populated
#   workflow_state_uuids map. If not, route per the prompt-or-halt
#   policy above. Always invoked AFTER write_config so the on-disk
#   config the seed step reads carries the resolved team/project UUIDs.
install::prompt_seed_run() {
    local team_uuid="$1"

    if install::_workspace_is_seeded "$INSTALL_CONFIG_PATH"; then
        install::_log_info "workspace already seeded (workflow_state_uuids populated); skipping seed prompt"
        summary::add "skipped" "workspace already seeded — no /spec-kit-linear-seed prompt issued"
        return 0
    fi

    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        # FR-022: non-interactive mode MUST NOT silently leave the
        # workspace unseeded. Halt with the same diagnostic the
        # reconciler would emit on first push so CI fails loud at
        # install time rather than at first reconcile.
        install::_log_error \
            "workspace unseeded (workflow_state_uuids placeholder zero-UUIDs); --non-interactive cannot prompt"
        install::_log_error \
            "Run \`bash src/seed.sh --team ${team_uuid}\` (or /spec-kit-linear-seed) before invoking /spec-kit-linear-push (FR-022)"
        summary::add "error" \
            "workspace unseeded (FR-022); run /spec-kit-linear-seed before /spec-kit-linear-push"
        INSTALL_SEED_PROMPT_RESULT=2
        return 1
    fi

    # Interactive: prompt the operator. Default is RUN (Enter accepts).
    printf '\n[linear] Linear workspace is unseeded for this repo (no workflow_state_uuids).\n' >&2
    printf '         Run /spec-kit-linear-seed now? [Y/n] (default: Y, "n" defers per FR-022): ' >&2
    local choice=""
    if ! IFS= read -r choice; then
        # No stdin (e.g. piped install with no answer) — treat as defer
        # so we don't accidentally run seed against a workspace the
        # operator hasn't reviewed.
        choice="n"
    fi
    choice="${choice,,}"
    choice="${choice//[[:space:]]/}"
    : "${choice:=y}"

    case "$choice" in
        y|yes)
            install::_log_info "operator accepted seed prompt; invoking src/seed.sh inline"
            install::_run_seed_inline "$team_uuid"
            return $?
            ;;
        n|no|defer)
            install::_log_warn "operator deferred seed (FR-022): /spec-kit-linear-push will halt until /spec-kit-linear-seed runs"
            summary::add "warned" \
                "workspace seed deferred; run /spec-kit-linear-seed before /spec-kit-linear-push (FR-022)"
            INSTALL_SEED_PROMPT_RESULT=2
            return 0
            ;;
        *)
            install::_log_warn "unknown seed-prompt choice '${choice}'; treating as defer (FR-022)"
            summary::add "warned" \
                "workspace seed deferred (unrecognised choice); run /spec-kit-linear-seed before /spec-kit-linear-push (FR-022)"
            INSTALL_SEED_PROMPT_RESULT=2
            return 0
            ;;
    esac
}

# install::_run_seed_inline <team_uuid>
#   Invoke src/seed.sh inside this install invocation. Honours the
#   operator's --dev flag (passes through SPECKIT_LINEAR_ROOT) and the
#   resolved team UUID so the seed never has to re-resolve the config.
#   Returns the seed's exit code, but the install's own exit code is
#   computed by install::main from the summary aggregate so a seed
#   failure surfaces as a hard error rather than silently dropping.
install::_run_seed_inline() {
    local team_uuid="$1"
    local seed_sh="${EXTENSION_ROOT}/src/seed.sh"

    if [[ ! -f "$seed_sh" ]]; then
        install::_log_error "seed script missing at ${seed_sh}; cannot run inline"
        summary::add "error" "src/seed.sh missing; cannot run inline seed"
        INSTALL_SEED_PROMPT_RESULT=2
        return 1
    fi

    install::_log_info "running ${seed_sh} --team ${team_uuid}"
    if bash "$seed_sh" --team "$team_uuid"; then
        install::_log_info "inline seed completed"
        summary::add "created" "workspace seed completed inline (workflow_state_uuids populated)"
        INSTALL_SEED_PROMPT_RESULT=1
        return 0
    fi
    install::_log_error "inline seed failed; install will surface the error"
    summary::add "error" "inline seed failed; re-run /spec-kit-linear-seed manually before /spec-kit-linear-push"
    INSTALL_SEED_PROMPT_RESULT=2
    return 1
}

# =============================================================================
# T064 — Interactive Action installation prompt (FR-027).
#
# After Project UUID resolution + seed prompt, offer to drop the
# Layer E workflow into `.github/workflows/spec-kit-linear-sync.yml`.
# The prompt is suppressed when:
#   * --with-action / --no-action was passed explicitly on the CLI
#     (operator already chose), OR
#   * --non-interactive is set (default: install at canonical path).
# Honours operator-customised destinations via the idempotent
# overwrite-protection in install::install_github_action.
# =============================================================================

install::maybe_prompt_action() {
    if (( INSTALL_FLAG_WITH_ACTION_EXPLICIT == 1 )); then
        # Operator already decided via --with-action / --no-action; nothing
        # to ask. The eventual install::install_github_action call (or its
        # omission) honours that.
        return 0
    fi

    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        # FR-027 + T064 contract: non-interactive runs install the Action
        # at the default path WITHOUT prompting. Operators that don't
        # want the Action in scripted invocations must pass --no-action.
        install::_log_info "--non-interactive: defaulting to Action install (per T064 contract)"
        INSTALL_FLAG_WITH_ACTION=1
        return 0
    fi

    printf '\n[linear] Install GitHub Action layer? [Y/n] (default: Y): ' >&2
    local choice=""
    if ! IFS= read -r choice; then
        choice="y"
    fi
    choice="${choice,,}"
    choice="${choice//[[:space:]]/}"
    : "${choice:=y}"

    case "$choice" in
        y|yes)
            INSTALL_FLAG_WITH_ACTION=1
            install::_log_info "operator accepted Action install prompt"
            ;;
        n|no)
            INSTALL_FLAG_WITH_ACTION=0
            install::_log_info "operator declined Action install; skipping Layer E"
            ;;
        *)
            INSTALL_FLAG_WITH_ACTION=0
            install::_log_warn "unknown Action-prompt choice '${choice}'; skipping Layer E (re-run with --with-action to install)"
            ;;
    esac
}

# =============================================================================
# Spec 002 — install ergonomics redesign (v0.1.1)
#
# The helpers below are the building blocks of the new discovery state
# machine (S0 → S7) described in `specs/002-install-ergonomics/data-model.md`
# §4. They are foundational STUBS at this phase (Phase 2) — full
# behaviour lands incrementally in Phase 3 (US1 — interactive install),
# Phase 4 (US2 — CI / scripted regression), and Phase 5 (US3 — operator
# safety guards).
#
# Each stub carries its signature, exit-code contract, and module-global
# write surface. They MUST NOT be wired into `install::run` until US1
# (T232..T239). At Phase 2 the unit-test harness asserts only that the
# functions exist with the right signature — call them with a typed
# argument vector and the test passes.
#
# All session state lives on `INSTALL_SESSION_*` module globals so the
# bats harness can inspect them after each helper invocation without
# round-tripping through stdout (operator-visible surface is reserved
# for the prompts themselves — never internal UUIDs per SC-010).
# =============================================================================

# -----------------------------------------------------------------------------
# Spec 002 module-level session state (populated by the helpers below).
# Declared up-front so `set -u` doesn't bite at first read in the stubs
# or the bats harness's call-count assertions.
# -----------------------------------------------------------------------------

# FR-037 — API key resolution outcome.
INSTALL_SESSION_API_KEY=""
# api_key_source ∈ {env, dotenv, prompt} — surfaced in the install
# summary's "Key sourced from:" row per install-prompts.md §7.
INSTALL_SESSION_API_KEY_SOURCE=""

# FR-038 / FR-048 — viewer query response (captured exactly ONCE per
# install invocation; consumed by both FR-034 operator block and the
# FR-039 team picker authorization).
INSTALL_SESSION_VIEWER_ID=""
INSTALL_SESSION_VIEWER_NAME=""
INSTALL_SESSION_VIEWER_EMAIL=""
INSTALL_SESSION_VIEWER_ORG_NAME=""
INSTALL_SESSION_VIEWER_ORG_URL_KEY=""

# FR-039 — team picker. Parallel arrays (bash 4+) keyed by index
# 0..N-1 matching the teams query's `nodes[]` order.
INSTALL_SESSION_TEAMS_IDS=()
INSTALL_SESSION_TEAMS_NAMES=()
INSTALL_SESSION_TEAMS_KEYS=()

# FR-040 — project picker. Parallel arrays keyed by index 0..N-1
# matching the team(id).projects query's `nodes[]` order.
INSTALL_SESSION_PROJECTS_IDS=()
INSTALL_SESSION_PROJECTS_NAMES=()

# FR-039 / FR-040 — operator picks. Internal UUIDs (NEVER surfaced
# on stdout/stderr per SC-010; the picker prompts reference index +
# key + name only).
INSTALL_SESSION_SELECTED_TEAM_ID=""
INSTALL_SESSION_SELECTED_TEAM_KEY=""
INSTALL_SESSION_SELECTED_TEAM_NAME=""
INSTALL_SESSION_SELECTED_PROJECT_ID=""
INSTALL_SESSION_SELECTED_PROJECT_NAME=""
INSTALL_SESSION_SELECTED_PROJECT_URL=""
# project_choice ∈ {attach, create} — distinguishes S4 → S6 (attach)
# from S4 → S5 → S6 (create) per data-model.md §4.
INSTALL_SESSION_PROJECT_CHOICE=""

# -----------------------------------------------------------------------------
# install::detect_self_install <src_path> <target_path>  (T203, FR-046)
#
# Compare the canonical (`pwd -P`) representations of SOURCE (the
# bridge's own checkout) and TARGET (the consumer repo). When the two
# resolve to the same canonical path the install MUST halt with exit 2
# WITHOUT writing anything to the filesystem — this catches the
# `--dev` recursive-self-copy bug spec.md describes (macOS filename
# length limit at ~30 levels of nesting).
#
# Uses `cd … && pwd -P` rather than `realpath` to avoid the GNU
# coreutils dependency per plan.md A7. Restores cwd via subshell.
#
# Returns:
#   0 — paths differ; install can proceed.
#   2 — paths equal; emits verbatim FR-046 / install-flags.md §4
#       message and exits the process.
#
# Phase 2 status: STUB. Path comparison + exit 0/2 wired; verbatim
# message text matches install-flags.md §4. Wired into `install::run`
# at S0 in Phase 5 task T258.
# -----------------------------------------------------------------------------
install::detect_self_install() {
    local src_path="${1:?install::detect_self_install: src_path required}"
    local target_path="${2:?install::detect_self_install: target_path required}"

    local src_canon target_canon
    if ! src_canon="$(cd "$src_path" 2>/dev/null && pwd -P)"; then
        # Source path is unreadable — can't compare; do not halt.
        # Phase 3 wiring may decide this is itself a hard error, but
        # the FR-046 guard is specifically about path equality.
        return 0
    fi
    if ! target_canon="$(cd "$target_path" 2>/dev/null && pwd -P)"; then
        # Target path is unreadable — likewise not the FR-046 case.
        return 0
    fi

    if [[ "$src_canon" == "$target_canon" ]]; then
        # Verbatim message from contracts/install-flags.md §4.
        install::_log_error "source path equals target path."
        printf '                 Detected: this install would copy the bridge into itself.\n' >&2
        printf '                 fix: either\n' >&2
        printf '                   (a) install into a different consumer repo, or\n' >&2
        printf '                   (b) once the bridge is listed in the spec-kit community\n' >&2
        printf '                       catalog (v0.1.x+), use `specify extension add linear`\n' >&2
        printf '                       from the catalog form.\n' >&2
        printf '                 (FR-046 — self-install recursion guard)\n' >&2
        exit 2
    fi
    return 0
}

# -----------------------------------------------------------------------------
# install::detect_vendored_git <source_path>  (T204, FR-049)
#
# Check whether the install source carries a vendored `.git/`
# directory under `<source>/.specify/extensions/linear/`. When present,
# emit a `summary::add warned` row with the `rm -rf …` remediation
# string and CONTINUE the install (Principle VIII — operator consent;
# do NOT auto-delete).
#
# Phase 2 status: STUB. Detection + warning emit wired. Wired into
# `install::run_dependency_report` in Phase 5 task T259.
# -----------------------------------------------------------------------------
install::detect_vendored_git() {
    local source_path="${1:?install::detect_vendored_git: source_path required}"
    local vendored_git="${source_path}/.specify/extensions/linear/.git"

    if [[ -d "$vendored_git" ]]; then
        summary::add "warned" \
            "vendored .git/ detected at ${vendored_git}; remove with: rm -rf ${vendored_git} (FR-049)"
        install::_log_warn \
            "vendored .git/ detected under .specify/extensions/linear/ — remediation: rm -rf ${vendored_git} (FR-049)"
        return 0
    fi
    return 0
}

# -----------------------------------------------------------------------------
# install::prompt_for_api_key  (T205, FR-037)
#
# Resolve LINEAR_API_KEY in priority order per install-prompts.md §2:
#   1. `LINEAR_API_KEY` env var (highest precedence).
#   2. `.env` line at repo root.
#   3. Interactive `read -r -s` prompt (echo suppressed).
#
# Populates `INSTALL_SESSION_API_KEY` and `INSTALL_SESSION_API_KEY_SOURCE`
# (∈ {env, dotenv, prompt}). On (3) follow up with "Save to .env?"
# (§2.3), .env conflict triage (§2.4), and EOF handling (§2.5).
#
# Halts (exit 2) when (1) + (2) both miss under `--non-interactive`
# per FR-037 / FR-045.
#
# Phase 2 status: STUB. Reads env var if present, otherwise tries
# `.env`. Interactive prompt + save flow + conflict triage land in
# Phase 3 task T232 (US1 wiring) — the bats unit tests in T221..T223
# drive the full FR-037 resolution order through a controlled stdin.
# -----------------------------------------------------------------------------
install::prompt_for_api_key() {
    # Priority 1 — env var.
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        INSTALL_SESSION_API_KEY="$LINEAR_API_KEY"
        INSTALL_SESSION_API_KEY_SOURCE="env"
        return 0
    fi

    # Priority 2 — .env line at repo root.
    if [[ -f ".env" ]]; then
        local dotenv_value
        dotenv_value="$(grep -E '^LINEAR_API_KEY=' .env 2>/dev/null | tail -n 1 | sed -E 's/^LINEAR_API_KEY=//' | sed -E 's/^"(.*)"$/\1/' | sed -E "s/^'(.*)'\$/\\1/")"
        if [[ -n "$dotenv_value" ]]; then
            INSTALL_SESSION_API_KEY="$dotenv_value"
            INSTALL_SESSION_API_KEY_SOURCE="dotenv"
            return 0
        fi
    fi

    # Priority 3 — interactive prompt. STUB: full FR-037 prompt loop
    # (save-to-.env, conflict triage, EOF handling) lands in Phase 3
    # task T232. For Phase 2 we honour FR-045: halt under
    # --non-interactive when (1)+(2) both miss.
    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        install::_die 2 \
            "--non-interactive without LINEAR_API_KEY in env or .env (FR-037 / FR-045)"
    fi

    # Phase 2 stub: signal that interactive resolution is needed but
    # not yet implemented. Phase 3 wiring replaces this with the full
    # `read -r -s` flow per install-prompts.md §2.
    INSTALL_SESSION_API_KEY_SOURCE="prompt"
    return 0
}

# -----------------------------------------------------------------------------
# install::pick_team_interactively  (T206, FR-039)
#
# Consume the `INSTALL_SESSION_TEAMS_*` parallel arrays populated by
# the S3 `teams` query and produce a single operator pick stored on
# `INSTALL_SESSION_SELECTED_TEAM_{ID,KEY,NAME}`. Behaviour matrix per
# install-prompts.md §3:
#
#   len == 0  → halt exit 2 with §3.5 remediation.
#   len == 1  → auto-pick, emit §3.4 surface row.
#   len >= 2  → render `%2d) %-8s — %s` numbered list, prompt
#               `Pick a team [1-N]:`, range-validate, re-prompt
#               on invalid.
#   len >  20 → render first 20 + §3.3 overflow warning row,
#               then prompt as `[1-20]`.
#
# EOF / Ctrl-C → halt exit 2 with §3.6 remediation.
#
# Phase 2 status: STUB. Signature + array consumption + auto-pick (len
# == 1) wired so the bats harness can assert the picker exists.
# Numbered-list rendering, overflow warning, range validation, and EOF
# handling all land in Phase 3 task T234.
# -----------------------------------------------------------------------------
install::pick_team_interactively() {
    local team_count="${#INSTALL_SESSION_TEAMS_IDS[@]}"

    if (( team_count == 0 )); then
        install::_die 2 \
            "no teams accessible to this API key. fix: check workspace membership at https://linear.app/settings/teams or use a different API key. (FR-039)"
    fi

    if (( team_count == 1 )); then
        INSTALL_SESSION_SELECTED_TEAM_ID="${INSTALL_SESSION_TEAMS_IDS[0]}"
        INSTALL_SESSION_SELECTED_TEAM_KEY="${INSTALL_SESSION_TEAMS_KEYS[0]}"
        INSTALL_SESSION_SELECTED_TEAM_NAME="${INSTALL_SESSION_TEAMS_NAMES[0]}"
        install::_log_info \
            "Found 1 team accessible — using ${INSTALL_SESSION_SELECTED_TEAM_KEY} (${INSTALL_SESSION_SELECTED_TEAM_NAME}) (auto-picked). Override with --team <UUID> on next install."
        return 0
    fi

    # Phase 2 stub: multi-team rendering + range-validated prompt is
    # implemented in Phase 3 task T234. For now default to the first
    # team so the test harness can assert the helper completed without
    # error; Phase 3 tests (T225) replace this stub with the full
    # interactive flow.
    INSTALL_SESSION_SELECTED_TEAM_ID="${INSTALL_SESSION_TEAMS_IDS[0]}"
    INSTALL_SESSION_SELECTED_TEAM_KEY="${INSTALL_SESSION_TEAMS_KEYS[0]}"
    INSTALL_SESSION_SELECTED_TEAM_NAME="${INSTALL_SESSION_TEAMS_NAMES[0]}"
    return 0
}

# -----------------------------------------------------------------------------
# install::pick_project_interactively  (T207, FR-040)
#
# Same numbered-list rendering as the team picker, with two
# additions per install-prompts.md §4:
#
#   1. "Create new project" is ALWAYS appended as the FINAL option
#      (index N+1 where N == len(projects)). Even when N == 0,
#      "Create new project" is option `1)`.
#   2. Sets `INSTALL_SESSION_PROJECT_CHOICE` ∈ {attach, create} per
#      the operator's pick.
#
# Overflow warning (§4.3) appended when N > 20.
#
# Phase 2 status: STUB. Signature + array consumption + the empty-list
# "Create new is the only option" branch wired so the bats harness can
# assert the picker exists. Full multi-project rendering + range
# validation lands in Phase 3 task T235.
# -----------------------------------------------------------------------------
install::pick_project_interactively() {
    local project_count="${#INSTALL_SESSION_PROJECTS_IDS[@]}"

    if (( project_count == 0 )); then
        # FR-040: zero projects → "Create new project" is the only
        # option (and effectively automatic in Phase 2).
        INSTALL_SESSION_PROJECT_CHOICE="create"
        return 0
    fi

    # Phase 2 stub: multi-project rendering + Create-new tail + range
    # validation are implemented in Phase 3 task T235. Default to the
    # first project (attach branch) so the harness can verify the
    # helper exists; Phase 3 tests (T226) drive the full flow.
    INSTALL_SESSION_PROJECT_CHOICE="attach"
    INSTALL_SESSION_SELECTED_PROJECT_ID="${INSTALL_SESSION_PROJECTS_IDS[0]}"
    INSTALL_SESSION_SELECTED_PROJECT_NAME="${INSTALL_SESSION_PROJECTS_NAMES[0]}"
    return 0
}

# -----------------------------------------------------------------------------
# install::prompt_new_project_name  (T208, FR-041)
#
# Prompt for the new project's name with the repo basename as the
# default per install-prompts.md §5 + plan.md A6. Runs the
# duplicate-name pre-check via the existing `install::_find_existing_project`
# (`src/install.sh:843`) and renders the `[create-anyway/pick-existing/rename]`
# triage prompt on a hit (§5.3). Loops on `rename`.
#
# On accept (no duplicate, or operator picked `create-anyway`), echoes
# the chosen name to stdout for the caller's S5 `projectCreate`
# mutation.
#
# Phase 2 status: STUB. Returns the repo basename without prompting
# or duplicate-checking — the full interactive prompt loop lands in
# Phase 3 task T236. Bats tests (T227) drive the full flow with
# fixture-mocked duplicate-name responses.
# -----------------------------------------------------------------------------
install::prompt_new_project_name() {
    local default_name
    if ! default_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"; then
        default_name="$(basename "$(pwd)")"
    fi

    # Phase 2 stub: echo the default name; Phase 3 task T236 adds the
    # `read -r` prompt + duplicate-name pre-check + triage loop per
    # install-prompts.md §5.
    printf '%s\n' "$default_name"
}

# -----------------------------------------------------------------------------
# install::quick_validate_binding <team_uuid> <project_uuid>  (T209, FR-044)
#
# When both `--team` and `--project` are passed, issue a single
# combined `team(id){...} project(id){... teams{nodes{id}}}` query per
# install-discovery-graphql.md §5.5 and validate:
#
#   * `data.team == null`        → halt exit 2 (team unreachable).
#   * `data.project == null`     → halt exit 2 (project unreachable).
#   * `project.teams.nodes[].id` does NOT contain `team.id` →
#     halt exit 2 (project does not belong to team).
#
# On success populates `INSTALL_SESSION_SELECTED_TEAM_*` and
# `INSTALL_SESSION_SELECTED_PROJECT_*` directly (skips S3 + S4 +
# pickers).
#
# Phase 2 status: STUB. Signature + arg validation wired. Full
# GraphQL query + null/mismatch validation lands in Phase 4 task T248
# (US2 — CI / scripted install). Bats tests (T245) drive the failure
# modes.
# -----------------------------------------------------------------------------
install::quick_validate_binding() {
    local team_uuid="${1:?install::quick_validate_binding: team_uuid required}"
    local project_uuid="${2:?install::quick_validate_binding: project_uuid required}"

    # Phase 2 stub: the full validation query lands in Phase 4 task
    # T248. For now, accept the inputs verbatim so the helper exists.
    INSTALL_SESSION_SELECTED_TEAM_ID="$team_uuid"
    INSTALL_SESSION_SELECTED_PROJECT_ID="$project_uuid"
    return 0
}

# =============================================================================
# install::main — top-level dispatcher.
# =============================================================================

install::main() {
    install::parse_args "$@"

    if (( INSTALL_FLAG_HELP == 1 )); then
        install::usage
        return 0
    fi

    summary::start "spec-kit-linear install ceremony"

    if (( INSTALL_FLAG_DEV == 1 )); then
        install::_log_info "--dev mode: installing from local checkout at ${EXTENSION_ROOT} (not the CLI-shipped extension tree)"
        summary::add "warned" "running in --dev mode; EXTENSION_ROOT=${EXTENSION_ROOT}"
    fi

    # ---- FR-033b: dogfood-safe acknowledgement (env var) -------------------
    install::detect_dogfood_safe_mode
    if (( INSTALL_DOGFOOD_SAFE_MODE == 1 )); then
        install::_log_warn "SPECKIT_LINEAR_DOGFOOD_SAFE=1 — dogfood-safe install mode engaged (FR-033b)"
        summary::add "warned" "dogfood-safe mode active (SPECKIT_LINEAR_DOGFOOD_SAFE=1): install proceeding into a workspace that may already have spec issues for this project (FR-033b)"
    fi

    # ---- Step 1: dependency report (T040 / FR-018b) ------------------------
    if ! install::run_dependency_report; then
        summary::add "error" "dependency report had unresolved errors (see above)"
        summary::emit
        return 2
    fi
    summary::add "updated" "dependency report green"

    # ---- Detect dogfood target (T048) before any registration --------------
    install::detect_dogfood_target
    if (( INSTALL_DOGFOOD_DETECTED == 1 )); then
        install::_log_warn "dogfood target detected (this is spec-kit-linear's own repo). Hooks will register with condition: \${SPECKIT_LINEAR_DOGFOOD_SAFE:-false} so they don't auto-fire during the bridge's own development."
        summary::add "warned" "dogfood-loop guard active (export SPECKIT_LINEAR_DOGFOOD_SAFE=true to enable hooks)"
    fi

    # ---- Step 2: resolve UUIDs (T041 / FR-002) -----------------------------
    local team_uuid project_uuid
    team_uuid="$(install::resolve_team_uuid)"
    project_uuid="$(install::resolve_project_uuid "$team_uuid")"

    # ---- Step 2b: resolve operator identity (FR-034) -----------------------
    # Capture `viewer { id name email }` so the reconciler can pass
    # assigneeId on every issueCreate. Runs AFTER team/project so any
    # team/project failure short-circuits before we hit the network for
    # the viewer query; runs BEFORE write_config so the operator block
    # is populated in the same single write of linear-config.yml.
    install::resolve_operator

    install::write_config "$team_uuid" "$project_uuid"
    summary::add "created" "linear-config.yml at ${INSTALL_CONFIG_PATH}"

    # ---- Step 3: register after_* hooks (T042 / FR-031) --------------------
    install::register_after_hooks
    summary::add "updated" "after_* hooks registered in ${INSTALL_EXTENSIONS_YML}"

    # ---- Step 4: install local git hooks (T043 / FR-033) -------------------
    install::install_git_hooks
    summary::add "updated" "local git hooks installed under ${INSTALL_GIT_HOOKS_DIR}"

    # ---- Step 4b: T063 — workspace seed-state check ------------------------
    # Runs AFTER write_config (so the seed step sees the resolved team
    # UUID inside linear-config.yml) and BEFORE the Action prompt so
    # the operator can confirm both prompts back-to-back. We let a
    # halt from prompt_seed_run propagate to install::main's exit
    # code via summary::has_errors below.
    install::prompt_seed_run "$team_uuid" || true

    # ---- Step 5: optional GitHub Action (FR-027 / FR-029) ------------------
    install::maybe_prompt_action
    if (( INSTALL_FLAG_WITH_ACTION == 1 )); then
        if install::install_github_action; then
            summary::add "created" "GitHub Action template at ${INSTALL_GH_WORKFLOW_FILE}"
        fi
    else
        summary::add "skipped" "GitHub Action install (re-run with --with-action to enable Layer E)"
    fi

    # ---- Step 6: final summary + next-step pointer -------------------------
    {
        if [[ -n "$INSTALL_RESOLVED_PROJECT_URL" ]]; then
            printf '\n[linear] Project resolved: %s\n' "$INSTALL_RESOLVED_PROJECT_URL"
            printf '         (name: %s, uuid: %s)\n' \
                "${INSTALL_RESOLVED_PROJECT_NAME:-unknown}" \
                "$project_uuid"
        fi
        if (( INSTALL_DOGFOOD_SAFE_MODE == 1 )); then
            printf '\n[linear] dogfood-safe mode is engaged (FR-033b).\n'
            printf '         The install proceeded into a workspace that may already carry spec issues for this project.\n'
        fi
        printf '\nNext steps:\n'
        case "$INSTALL_SEED_PROMPT_RESULT" in
            1)
                printf '  1. Seed completed inline — workflow_state_uuids populated.\n'
                printf '  2. Commit %s.\n' "$INSTALL_CONFIG_PATH"
                printf '  3. Verify by running /spec-kit-linear-push --dry-run.\n'
                ;;
            2)
                printf '  1. Run /spec-kit-linear-seed before /spec-kit-linear-push (FR-022).\n'
                printf '  2. Commit %s.\n' "$INSTALL_CONFIG_PATH"
                printf '  3. Verify by running /spec-kit-linear-push --dry-run.\n'
                ;;
            *)
                printf '  1. Workspace already seeded — skipping /spec-kit-linear-seed.\n'
                printf '  2. Commit %s.\n' "$INSTALL_CONFIG_PATH"
                printf '  3. Verify by running /spec-kit-linear-push --dry-run.\n'
                ;;
        esac
    } >&2

    summary::emit

    if summary::has_errors; then
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Entry point. Only run main when the script is the top-level invocation —
# this lets bats unit tests source the script to exercise individual
# functions without launching the full install ceremony.
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install::main "$@"
fi
