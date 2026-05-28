#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/install.sh — install ceremony for the speckit-linear bridge.
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
readonly INSTALL_GH_WORKFLOW_FILE=".github/workflows/speckit-linear-sync.yml"
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
# Set by --dev. Surfaces in the dependency report and biases the
# EXTENSION_ROOT lookup toward the current checkout (rather than the
# operator-host `~/.specify-extensions/linear/` path the spec-kit CLI
# would normally populate during `specify extension add linear`). See
# install::main where the flag drives a log marker so the operator
# knows they're running from a non-shipped tree.
INSTALL_FLAG_DEV=0
INSTALL_FLAG_HELP=0

# Set to 1 once we've determined the repo is the speckit-linear repo
# itself (T048 — dogfood guard). When set, the registered hooks are
# emitted with a `condition: "${SPECKIT_LINEAR_DOGFOOD_SAFE:-false}"`
# marker so they don't auto-fire during the bridge's own development.
INSTALL_DOGFOOD_DETECTED=0

# Aggregated has-error flag across the dependency report. Drives the
# final exit code: any `✗` row → exit 2 per command-shapes.md §5.7.
INSTALL_HAD_HARD_ERROR=0

# -----------------------------------------------------------------------------
# install::_log_info / install::_log_warn / install::_log_error
#
# Single-line, structured log emitters. All go to stderr so stdout
# stays clean for any future script that pipes install output (the
# dependency report block emits to stderr via summary::emit too).
# -----------------------------------------------------------------------------

install::_log_info() {
    printf 'speckit-linear: install: %s\n' "$*" >&2
}

install::_log_warn() {
    printf 'speckit-linear: install WARN  %s\n' "$*" >&2
}

install::_log_error() {
    printf 'speckit-linear: install ERROR %s\n' "$*" >&2
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

Per-consumer-repo install ceremony for the speckit-linear bridge.

Resolves the Linear Team + Project UUIDs (interactively or via flags),
writes .specify/extensions/linear/linear-config.yml, registers the six
after_* hooks in .specify/extensions.yml with optional: false (FR-031),
installs post-checkout / post-commit / post-merge git hooks per FR-033,
and (optionally) drops the GitHub Action template per FR-027 / FR-029.

OPTIONS
  --project <UUID>     Attach to an existing Linear Project by UUID.
                       Mutually exclusive with --auto-create.
  --auto-create        Create a new Linear Project named after the
                       current repo's directory name. Mutually
                       exclusive with --project.
  --team <UUID>        Linear Team UUID. Required in --non-interactive
                       mode; otherwise auto-detected (single team) or
                       prompted (multi-team workspace).
  --non-interactive    Refuse to prompt; require --project (or
                       --auto-create) and --team to be set on the CLI.
  --with-action        Drop templates/github-action.yml into
                       .github/workflows/speckit-linear-sync.yml and
                       print the gh secret set LINEAR_API_TOKEN command
                       per FR-029.
  --dev                Install from this repo's local checkout rather
                       than via `specify extension add`. Used for
                       dogfood development.
  --help               Print this help and exit.

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
            --non-interactive)
                INSTALL_FLAG_NON_INTERACTIVE=1
                shift
                ;;
            --with-action)
                INSTALL_FLAG_WITH_ACTION=1
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
    tmp="$(mktemp -t speckit-linear-mcp.XXXXXX)"
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
    tmp="$(mktemp -t speckit-linear-mcp.XXXXXX)"
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
    printf '\nspeckit-linear install dependency report\n' >&2

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
        printf '\nspeckit-linear: install: dependency report has unresolved errors (✗ rows above).\n' >&2
        printf '%s\n' "Resolve every ✗ row and re-run \`/speckit-linear-install\`." >&2
        return 1
    fi
    return 0
}

# =============================================================================
# T048 — Dogfood-loop guard.
#
# When the install target is the speckit-linear repo itself, register
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
    #   (b) the repo's basename starts with `speckit-linear` and the
    #       extension manifest at this very script's parent path matches
    #       the repo root — i.e. we're installing this extension into
    #       itself.
    if [[ "$repo_basename" == speckit-linear* ]] \
        && [[ -f "${repo_root}/extension.yml" ]] \
        && grep -q 'id: "linear"' "${repo_root}/extension.yml" 2>/dev/null; then
        INSTALL_DOGFOOD_DETECTED=1
    fi
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

install::resolve_project_uuid() {
    if [[ -n "$INSTALL_FLAG_PROJECT" ]]; then
        printf '%s\n' "$INSTALL_FLAG_PROJECT"
        return 0
    fi
    if (( INSTALL_FLAG_AUTO_CREATE == 1 )); then
        # We defer the actual Linear `save_project` mutation to a future
        # T077 dogfood pass; for now we surface a clear marker so the
        # operator knows the install left a placeholder.
        printf '00000000-0000-0000-0000-000000000000\n'
        install::_log_warn "--auto-create requested; placeholder Project UUID written. Run /speckit-linear-install --project <UUID> after manually creating the Project in Linear, or wait for the T077 dogfood integration to land."
        return 0
    fi
    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        install::_die 2 "--non-interactive requires --project <UUID> or --auto-create"
    fi
    # Interactive Project picker — minimal stub.
    local repo_root repo_basename
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
    repo_basename="$(basename "${repo_root:-$(pwd)}")"
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
        create|rename)
            # Same path: we don't yet have the GraphQL plumbing to actually
            # create the Project, so we emit a placeholder UUID and warn
            # the operator that the next step is to re-run install with
            # `--project <UUID>` once the Project exists in Linear.
            printf '00000000-0000-0000-0000-000000000000\n'
            install::_log_warn "Project creation deferred to T077 dogfood; placeholder UUID written. Re-run with --project <UUID> after creating the Project in Linear."
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

# install::write_config <team_uuid> <project_uuid>
#
# Copy `config-template.yml` into `.specify/extensions/linear/linear-config.yml`
# (unless the file already exists with non-zero UUIDs) and substitute
# the resolved Team + Project UUIDs in-place. The seed step later
# fills `workflow_state_uuids`.
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
        return 0
    fi

    if [[ ! -f "$INSTALL_CONFIG_TEMPLATE" ]]; then
        install::_die 2 "config template missing: ${INSTALL_CONFIG_TEMPLATE}
hint: re-run \`specify extension add linear\` (or pass --dev with a checkout of speckit-linear)"
    fi

    cp "$INSTALL_CONFIG_TEMPLATE" "$INSTALL_CONFIG_PATH"
    install::_substitute_uuid_placeholder "$INSTALL_CONFIG_PATH" \
        "linear.team.id" "$team_uuid"
    install::_substitute_uuid_placeholder "$INSTALL_CONFIG_PATH" \
        "linear.project.id" "$project_uuid"
    install::_log_info "wrote ${INSTALL_CONFIG_PATH}"
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
    tmp="$(mktemp -t speckit-linear-config.XXXXXX)"
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
install::_append_under_hook() {
    local hook="$1"
    local block="$2"
    local tmp
    tmp="$(mktemp -t speckit-linear-ext-yml.XXXXXX)"

    # Strategy: walk the file. On hitting the header line we copy it
    # AND every line up to (and including) the last sub-entry of that
    # block, then emit our new block, then continue copying.
    awk -v hook="$hook" -v block="$block" '
        BEGIN { state = "before"; emitted = 0 }
        function flush_block() {
            if (block_buf != "") {
                printf "%s", block_buf
            }
            printf "%s\n", block
            emitted = 1
            block_buf = ""
        }
        {
            if (state == "before") {
                if ($0 ~ "^  " hook ":[[:space:]]*$") {
                    print
                    state = "in_hook"
                    block_buf = ""
                    next
                }
                print
                next
            }
            if (state == "in_hook") {
                # A new top-level hook header (two-space indent, key, colon).
                if ($0 ~ /^  [a-zA-Z_]+:[[:space:]]*$/) {
                    flush_block()
                    print
                    state = "after"
                    next
                }
                block_buf = block_buf $0 "\n"
                next
            }
            # state == "after"
            print
        }
        END {
            if (state == "in_hook" && emitted == 0) {
                flush_block()
            }
        }
    ' "$INSTALL_EXTENSIONS_YML" >"$tmp"
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

readonly INSTALL_HOOK_MARKER_BEGIN="# >>> speckit-linear hook begin (FR-033) >>>"
readonly INSTALL_HOOK_MARKER_END="# <<< speckit-linear hook end <<<"

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
#   2. Pre-existing speckit-linear marker → leave alone (idempotent).
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
        install::_log_info "${target} already has speckit-linear hook (idempotent)"
        return 0
    fi

    # Case 3: append our invocation in a clearly-marked block.
    {
        printf '\n%s\n' "$INSTALL_HOOK_MARKER_BEGIN"
        # The block invokes the bridge's reconciler with the right
        # arguments for the hook type. We avoid running the template
        # verbatim (it may have its own `set -e` / shebang) and
        # instead embed a minimal forwarding call.
        printf '# Added by speckit-linear install ceremony per FR-033.\n'
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
    install::_log_info "chained speckit-linear hook into existing ${target}"
}

# =============================================================================
# Optional: --with-action (FR-027 + FR-029).
#
# Copy `templates/github-action.yml` into the consumer's
# `.github/workflows/speckit-linear-sync.yml`, then print the
# `gh secret set LINEAR_API_TOKEN` provisioning instructions. The
# bridge MUST NOT provision the secret on the operator's behalf
# (FR-029).
# =============================================================================

install::install_github_action() {
    local template="${EXTENSION_ROOT}/templates/github-action.yml"

    if [[ ! -f "$template" ]]; then
        install::_log_warn "github-action template missing at ${template}; skipping (T062 may still be in flight)"
        return 0
    fi

    mkdir -p "$INSTALL_GH_WORKFLOWS_DIR"

    if [[ -f "$INSTALL_GH_WORKFLOW_FILE" ]]; then
        install::_log_info "${INSTALL_GH_WORKFLOW_FILE} already exists; preserving operator changes"
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
# install::main — top-level dispatcher.
# =============================================================================

install::main() {
    install::parse_args "$@"

    if (( INSTALL_FLAG_HELP == 1 )); then
        install::usage
        return 0
    fi

    summary::start "speckit-linear install ceremony"

    if (( INSTALL_FLAG_DEV == 1 )); then
        install::_log_info "--dev mode: installing from local checkout at ${EXTENSION_ROOT} (not the CLI-shipped extension tree)"
        summary::add "warned" "running in --dev mode; EXTENSION_ROOT=${EXTENSION_ROOT}"
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
        install::_log_warn "dogfood target detected (this is speckit-linear's own repo). Hooks will register with condition: \${SPECKIT_LINEAR_DOGFOOD_SAFE:-false} so they don't auto-fire during the bridge's own development."
        summary::add "warned" "dogfood-loop guard active (export SPECKIT_LINEAR_DOGFOOD_SAFE=true to enable hooks)"
    fi

    # ---- Step 2: resolve UUIDs (T041 / FR-002) -----------------------------
    local team_uuid project_uuid
    team_uuid="$(install::resolve_team_uuid)"
    project_uuid="$(install::resolve_project_uuid)"

    install::write_config "$team_uuid" "$project_uuid"
    summary::add "created" "linear-config.yml at ${INSTALL_CONFIG_PATH}"

    # ---- Step 3: register after_* hooks (T042 / FR-031) --------------------
    install::register_after_hooks
    summary::add "updated" "after_* hooks registered in ${INSTALL_EXTENSIONS_YML}"

    # ---- Step 4: install local git hooks (T043 / FR-033) -------------------
    install::install_git_hooks
    summary::add "updated" "local git hooks installed under ${INSTALL_GIT_HOOKS_DIR}"

    # ---- Step 5: optional GitHub Action (FR-027 / FR-029) ------------------
    if (( INSTALL_FLAG_WITH_ACTION == 1 )); then
        install::install_github_action
        summary::add "created" "GitHub Action template at ${INSTALL_GH_WORKFLOW_FILE}"
    else
        summary::add "skipped" "GitHub Action install (re-run with --with-action to enable Layer E)"
    fi

    # ---- Step 6: final summary + next-step pointer -------------------------
    {
        printf '\nNext steps:\n'
        printf '  1. Run /speckit-linear-seed to populate workflow_state_uuids.\n'
        printf '  2. Commit %s.\n' "$INSTALL_CONFIG_PATH"
        printf '  3. Verify by running /speckit-linear-push --dry-run.\n'
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
