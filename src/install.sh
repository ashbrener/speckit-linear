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
# Resolved at runtime by install::check_repo_layout (FR-033). NOT a readonly
# constant: hardcoding `.git/hooks` is wrong in a linked git worktree, where
# `.git` is a FILE pointing at the real gitdir and hooks live in the common
# dir (or wherever `core.hooksPath` points), never at `.git/hooks`. We resolve
# the correct path portably with `git rev-parse --git-path hooks`, which is
# correct for both normal checkouts and linked worktrees and honours
# `core.hooksPath`. The default here is a safe placeholder for status messages
# before resolution.
INSTALL_GIT_HOOKS_DIR=".git/hooks"
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

# Set to 1 by `install::detect_vendored_git` (T204 / FR-049) when the
# install source carries a `.git/` directory at
# `<source>/.specify/extensions/linear/.git`. Drives the Next-steps
# remediation row per `install-prompts.md` §7 — the warning surfaces
# at the dependency-report stage (T259) and is mirrored in the final
# summary so the operator sees the remediation `rm -rf …` at both
# top-of-run and bottom-of-run.
INSTALL_VENDORED_GIT_DETECTED=0
INSTALL_VENDORED_GIT_PATH=""

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

    # FR-045 strict rule (T249) — `--non-interactive` MUST have both
    # `--team <UUID>` and `--project <UUID>` (or `--team <UUID>` +
    # `--auto-create` as the v0.1.0-compat combination). The v0.1.1
    # ergonomics path (interactive viewer-driven discovery) is
    # explicitly unavailable under `--non-interactive` so CI scripts
    # never fall through to a prompt that has no terminal to read from.
    #
    # The verbatim error message below is locked by install-flags.md
    # §3.3 and gated by the SC-011 integration test T244.
    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        local _missing=0
        if [[ -z "$INSTALL_FLAG_TEAM" ]]; then
            _missing=1
        elif [[ -z "$INSTALL_FLAG_PROJECT" ]] && (( INSTALL_FLAG_AUTO_CREATE == 0 )); then
            _missing=1
        fi
        if (( _missing == 1 )); then
            install::_log_error \
                "--non-interactive requires both --team <UUID>"
            {
                printf '                 and --project <UUID> (or --team <UUID> --auto-create).\n'
                printf '                 The v0.1.1 ergonomics path (interactive team + project\n'
                printf '                 picker) is unavailable under --non-interactive.\n'
                printf '                 Resolve UUIDs out-of-band or run interactively.\n'
            } >&2
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

    # Resolve the git hooks directory portably (FR-033). In a linked worktree
    # `.git` is a file and hooks do NOT live at `.git/hooks`; `git rev-parse
    # --git-path hooks` returns the correct directory for normal checkouts and
    # worktrees alike, and honours `core.hooksPath`. Falls back to the literal
    # default if rev-parse somehow fails (we're already inside a work tree here).
    if ! INSTALL_GIT_HOOKS_DIR="$(git rev-parse --git-path hooks 2>/dev/null)" \
        || [[ -z "$INSTALL_GIT_HOOKS_DIR" ]]; then
        INSTALL_GIT_HOOKS_DIR=".git/hooks"
    fi
    # Worktrees may not have the hooks dir materialised yet; create it before
    # the writability checks below so install can land hooks there.
    mkdir -p "$INSTALL_GIT_HOOKS_DIR" 2>/dev/null || true

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

    # ---- T259 / FR-049: vendored .git/ detection ---------------------------
    # Surface a warning row when the install SOURCE
    # (EXTENSION_ROOT — set near the top of this file) carries a
    # `.git/` directory at `.specify/extensions/linear/.git`. The
    # helper itself emits the row via `summary::add warned` +
    # `install::_log_warn`; install continues per Principle VIII
    # (operator consent — never auto-delete).
    install::_section "Install source (FR-049):"
    install::detect_vendored_git "$EXTENSION_ROOT"
    if (( INSTALL_VENDORED_GIT_DETECTED == 1 )); then
        printf '  ⚠ vendored .git/ at %s — remediation: rm -rf %s (FR-049)\n' \
            "$INSTALL_VENDORED_GIT_PATH" \
            "$INSTALL_VENDORED_GIT_PATH" >&2
    else
        printf '  ✓ install source clean — no vendored .git/ under .specify/extensions/linear/\n' >&2
    fi

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
    # T233 / FR-048 — single viewer query feeds:
    #   * FR-034 operator block (INSTALL_OPERATOR_*).
    #   * FR-038 API-key verification gate.
    #   * `linear.workspace.{name,url_key}` block in linear-config.yml.
    #   * The team-list authorization for the next `teams` query.
    # The same response is cached on INSTALL_SESSION_VIEWER_* module
    # globals; install::write_config reads them on its single write.
    local query='query InstallViewer { viewer { id name email organization { name urlKey } } }'

    # graphql::query halts the process (exit 2/3/4) on its own when the
    # API key is missing or the request fails. The keys-at-edges
    # boundary lives in graphql.sh; this caller just consumes the JSON.
    local response viewer_json
    if ! response="$(graphql::query "$query" '{}')"; then
        install::_die 2 \
            "LINEAR_API_KEY missing or invalid — operator identity required for FR-034 (viewer { id name email organization { name urlKey } })
hint: set LINEAR_API_KEY in .env or export it before re-running install"
    fi

    viewer_json="$(printf '%s' "$response" | jq -c '.data.viewer // null')"
    if [[ -z "$viewer_json" || "$viewer_json" == "null" ]]; then
        install::_die 2 \
            "LINEAR_API_KEY invalid; create a new key at https://linear.app/settings/api (FR-034 / FR-038: viewer query returned no data)"
    fi

    INSTALL_OPERATOR_USER_ID="$(printf '%s' "$viewer_json" | jq -r '.id // ""')"
    INSTALL_OPERATOR_NAME="$(printf '%s' "$viewer_json"   | jq -r '.name // ""')"
    INSTALL_OPERATOR_EMAIL="$(printf '%s' "$viewer_json"  | jq -r '.email // ""')"

    # Spec 002 session-scoped viewer state (FR-048).
    INSTALL_SESSION_VIEWER_ID="$INSTALL_OPERATOR_USER_ID"
    INSTALL_SESSION_VIEWER_NAME="$INSTALL_OPERATOR_NAME"
    INSTALL_SESSION_VIEWER_EMAIL="$INSTALL_OPERATOR_EMAIL"
    INSTALL_SESSION_VIEWER_ORG_NAME="$(printf '%s' "$viewer_json" | jq -r '.organization.name // ""')"
    INSTALL_SESSION_VIEWER_ORG_URL_KEY="$(printf '%s' "$viewer_json" | jq -r '.organization.urlKey // ""')"

    if [[ -z "$INSTALL_OPERATOR_USER_ID" ]]; then
        install::_die 2 \
            "LINEAR_API_KEY invalid; create a new key at https://linear.app/settings/api (FR-034: viewer.id absent from response)"
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
        install::_write_workspace_block "$INSTALL_CONFIG_PATH"
        install::_write_team_block "$INSTALL_CONFIG_PATH"
        install::_write_project_block "$INSTALL_CONFIG_PATH"
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
    install::_write_workspace_block "$INSTALL_CONFIG_PATH"
    # T233/T239 — spec 002: populate the linear.team and linear.project
    # informational fields (key, name) when the discovery flow resolved
    # them. The reconciler only reads UUIDs but operator-facing tools
    # like /spec-kit-linear-status surface the friendly names.
    install::_write_team_block "$INSTALL_CONFIG_PATH"
    install::_write_project_block "$INSTALL_CONFIG_PATH"
    install::_log_info "wrote ${INSTALL_CONFIG_PATH}"
}

# -----------------------------------------------------------------------------
# install::_write_workspace_block <file>  (T233, FR-048)
#
# Substitute `linear.workspace.{name,url_key}` from
# INSTALL_SESSION_VIEWER_ORG_{NAME,URL_KEY} captured by
# install::resolve_operator. No-op when viewer has not run (test
# harness shortcuts) — preserves template placeholders verbatim.
# -----------------------------------------------------------------------------
install::_write_workspace_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    if [[ -n "${INSTALL_SESSION_VIEWER_ORG_NAME:-}" ]]; then
        install::_substitute_yaml_string_field "$file" "workspace" "name" \
            "$INSTALL_SESSION_VIEWER_ORG_NAME" "OSH-INFRA"
    fi
    if [[ -n "${INSTALL_SESSION_VIEWER_ORG_URL_KEY:-}" ]]; then
        install::_substitute_yaml_string_field "$file" "workspace" "url_key" \
            "$INSTALL_SESSION_VIEWER_ORG_URL_KEY" "osh-infra"
    fi
}

# -----------------------------------------------------------------------------
# install::_write_team_block <file>  (T233)
#
# Substitute `linear.team.{key,name}` from the spec-002 selected-team
# session state. UUID is already substituted by
# install::_substitute_uuid_placeholder.
# -----------------------------------------------------------------------------
install::_write_team_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    if [[ -n "${INSTALL_SESSION_SELECTED_TEAM_KEY:-}" ]]; then
        install::_substitute_yaml_string_field "$file" "team" "key" \
            "$INSTALL_SESSION_SELECTED_TEAM_KEY" "OSH"
    fi
    if [[ -n "${INSTALL_SESSION_SELECTED_TEAM_NAME:-}" ]]; then
        install::_substitute_yaml_string_field "$file" "team" "name" \
            "$INSTALL_SESSION_SELECTED_TEAM_NAME" "OSH-INFRA"
    fi
}

# -----------------------------------------------------------------------------
# install::_write_project_block <file>  (T233)
#
# Substitute `linear.project.name` from the spec-002 selected-project
# session state. UUID is already substituted by
# install::_substitute_uuid_placeholder.
# -----------------------------------------------------------------------------
install::_write_project_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    if [[ -n "${INSTALL_SESSION_SELECTED_PROJECT_NAME:-}" ]]; then
        install::_substitute_yaml_string_field "$file" "project" "name" \
            "$INSTALL_SESSION_SELECTED_PROJECT_NAME" "spec-kit-linear"
    fi
}

# -----------------------------------------------------------------------------
# install::_substitute_yaml_string_field <file> <block> <field> <new> <placeholder>
#
# Replace `<field>: "<placeholder>"` inside `<block>:` with `<field>:
# "<new>"`. Mirrors install::_substitute_operator_field but targets
# arbitrary one-level-nested string fields (team/project/workspace).
# -----------------------------------------------------------------------------
install::_substitute_yaml_string_field() {
    local file="$1"
    local block="$2"
    local field="$3"
    local new_value="$4"
    local placeholder="$5"

    [[ -f "$file" ]] || return 0

    local tmp
    tmp="$(mktemp -t spec-kit-linear-config.XXXXXX)"
    awk -v block="$block" \
        -v field="$field" \
        -v placeholder="$placeholder" \
        -v new_value="$new_value" '
        BEGIN { in_block = 0; replaced = 0 }
        {
            ltrim = $0
            sub(/^[[:space:]]+/, "", ltrim)
            if (ltrim == block ":") {
                in_block = 1
                print
                next
            }
            # Heuristic: a key line at the two-space indent (the indent
            # of block: itself) that is not a nested child closes the
            # block scope.
            if (in_block && $0 ~ /^  [a-zA-Z_].*:[[:space:]]*$/) {
                in_block = 0
            }
            if (in_block && replaced == 0) {
                pattern = "^[[:space:]]+" field ":[[:space:]]+\"" placeholder "\""
                if (match($0, pattern)) {
                    sub("\"" placeholder "\"", "\"" new_value "\"")
                    replaced = 1
                }
            }
            print
        }
    ' "$file" >"$tmp"
    mv "$tmp" "$file"
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

    # T232 / FR-048 — prefer the spec-002 session-scoped viewer state
    # when present (single-fire single-source-of-truth). Fall back to
    # the v0.1.0 INSTALL_OPERATOR_* globals to keep the legacy path
    # bit-for-bit identical when --team / --project / --auto-create
    # short-circuit the discovery flow.
    local user_id="${INSTALL_SESSION_VIEWER_ID:-$INSTALL_OPERATOR_USER_ID}"
    local user_name="${INSTALL_SESSION_VIEWER_NAME:-$INSTALL_OPERATOR_NAME}"
    local user_email="${INSTALL_SESSION_VIEWER_EMAIL:-$INSTALL_OPERATOR_EMAIL}"

    if [[ -z "$user_id" ]]; then
        return 0
    fi

    install::_substitute_operator_field "$file" "user_id" \
        "\"${user_id}\"" \
        '"00000000-0000-0000-0000-000000000000"'
    install::_substitute_operator_field "$file" "name" \
        "\"${user_name}\"" \
        '"Ash Brener"'
    install::_substitute_operator_field "$file" "email" \
        "\"${user_email}\"" \
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
        # shellcheck disable=SC2016
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
        # Module-level flag drives the Next-steps remediation row that
        # mirrors this warning at the bottom of the run per T259 +
        # install-prompts.md §7. The path is captured so the summary
        # row points at the same `rm -rf …` target.
        INSTALL_VENDORED_GIT_DETECTED=1
        INSTALL_VENDORED_GIT_PATH="$vendored_git"
        summary::add "warned" \
            "vendored .git/ detected at ${vendored_git}; remove with: rm -rf ${vendored_git} (FR-049)"
        install::_log_warn \
            "vendored .git/ detected under .specify/extensions/linear/ — remediation: rm -rf ${vendored_git} (FR-049)"
        return 0
    fi
    return 0
}

# -----------------------------------------------------------------------------
# install::prompt_for_api_key  (T205 + T232, FR-037)
#
# Resolve LINEAR_API_KEY in priority order per install-prompts.md §2:
#   1. `LINEAR_API_KEY` env var (highest precedence).
#   2. `.env` line at repo root.
#   3. Interactive `read -r -s` prompt (echo suppressed).
#
# Populates `INSTALL_SESSION_API_KEY` and `INSTALL_SESSION_API_KEY_SOURCE`
# (∈ {env, dotenv, prompt, interactive_saved}). On (3) follow up with
# "Save to .env?" (§2.3), .env conflict triage (§2.4), and EOF
# handling (§2.5).
#
# Halts (exit 2) when (1) + (2) both miss under `--non-interactive`
# per FR-037 / FR-045.
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

    # Priority 3 — interactive prompt. Halt under --non-interactive per
    # FR-037 / FR-045.
    if (( INSTALL_FLAG_NON_INTERACTIVE == 1 )); then
        install::_die 2 \
            "--non-interactive without LINEAR_API_KEY in env or .env (FR-037 / FR-045)"
    fi

    # install-prompts.md §2.1 — prompt with echo suppressed.
    local api_key=""
    while :; do
        printf '[linear] Linear API key (input hidden — paste & enter): \n' >&2
        if ! IFS= read -r -s api_key; then
            # install-prompts.md §2.5 — EOF on the API key prompt halts.
            install::_die 2 \
                "no input received for API key; pass via .env or LINEAR_API_KEY env var, or run interactively. (FR-037)"
        fi
        # New-line after silent read so subsequent prompts line up.
        printf '\n' >&2
        # Trim surrounding whitespace.
        api_key="${api_key#"${api_key%%[![:space:]]*}"}"
        api_key="${api_key%"${api_key##*[![:space:]]}"}"
        if [[ -n "$api_key" ]]; then
            break
        fi
        printf '[linear] API key cannot be empty; paste your key (or Ctrl-C to abort).\n' >&2
    done

    INSTALL_SESSION_API_KEY="$api_key"
    INSTALL_SESSION_API_KEY_SOURCE="prompt"

    # install-prompts.md §2.3 — "Save to .env?" follow-up.
    install::_prompt_save_api_key_to_dotenv

    return 0
}

# -----------------------------------------------------------------------------
# install::_prompt_save_api_key_to_dotenv  (T232, FR-037 + plan.md A5)
#
# Follow-up after an interactive API-key read: ask the operator whether
# to write the key to `.env`. On Y (default), append + ensure `.env`
# is in `.gitignore`. On N, skip. On conflict (an existing
# `LINEAR_API_KEY=` line in `.env`), delegate to
# `install::_resolve_dotenv_conflict` per install-prompts.md §2.4.
# -----------------------------------------------------------------------------
install::_prompt_save_api_key_to_dotenv() {
    local reply=""
    while :; do
        printf '[linear] Save LINEAR_API_KEY to .env at the repo root? .env is\n' >&2
        printf '         gitignored (the install will add it if missing).\n' >&2
        printf '         [Y/n] (default: Y): ' >&2
        if ! IFS= read -r reply; then
            # install-prompts.md §2.5 — EOF on the save prompt is default-safe (N).
            reply="N"
        fi
        reply="${reply//[[:space:]]/}"
        : "${reply:=Y}"
        case "$reply" in
            Y|y|Yes|yes|YES) break ;;
            N|n|No|no|NO)
                # Operator declined save — keep key in-session only.
                return 0
                ;;
            *)
                printf '[linear] Pick Y or n:\n' >&2
                ;;
        esac
    done

    # Conflict triage (§2.4): existing LINEAR_API_KEY line in .env.
    if [[ -f .env ]] && grep -qE '^LINEAR_API_KEY=' .env; then
        install::_resolve_dotenv_conflict
        return 0
    fi

    install::_write_api_key_to_dotenv
    install::_ensure_dotenv_gitignored
    INSTALL_SESSION_API_KEY_SOURCE="interactive_saved"
}

# -----------------------------------------------------------------------------
# install::_resolve_dotenv_conflict  (T232, install-prompts.md §2.4)
#
# When `.env` already holds a different `LINEAR_API_KEY=` line and the
# operator chose to save the just-entered key, prompt:
#   * overwrite → portable awk-rewrite of .env (research.md §4).
#   * keep (default) / empty → discard the just-entered key,
#                              re-resolve from .env.
#   * abort → exit 0 (clean abort).
# -----------------------------------------------------------------------------
install::_resolve_dotenv_conflict() {
    local reply=""
    while :; do
        printf '[linear] .env already has a LINEAR_API_KEY (from another extension or\n' >&2
        printf '         a previous install). Overwrite with the key you just entered,\n' >&2
        printf '         or keep the existing one?\n' >&2
        printf '         [overwrite/keep/abort] (default: keep): ' >&2
        if ! IFS= read -r reply; then
            reply="keep"
        fi
        reply="${reply//[[:space:]]/}"
        : "${reply:=keep}"
        case "$reply" in
            overwrite)
                install::_rewrite_dotenv_api_key
                INSTALL_SESSION_API_KEY_SOURCE="interactive_saved"
                install::_ensure_dotenv_gitignored
                return 0
                ;;
            keep|"")
                # Discard the just-entered key — re-read from .env.
                local dotenv_value
                dotenv_value="$(grep -E '^LINEAR_API_KEY=' .env 2>/dev/null | tail -n 1 | sed -E 's/^LINEAR_API_KEY=//' | sed -E 's/^"(.*)"$/\1/' | sed -E "s/^'(.*)'\$/\\1/")"
                INSTALL_SESSION_API_KEY="$dotenv_value"
                INSTALL_SESSION_API_KEY_SOURCE="dotenv"
                return 0
                ;;
            abort)
                exit 0
                ;;
            *)
                printf '[linear] Pick overwrite, keep, or abort.\n' >&2
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# install::_write_api_key_to_dotenv  (T232)
# Append (creating the file if absent) a `LINEAR_API_KEY=<value>` line.
# -----------------------------------------------------------------------------
install::_write_api_key_to_dotenv() {
    if [[ -f .env ]] && [[ -s .env ]] && [[ "$(tail -c1 .env | wc -l)" -eq 0 ]]; then
        printf '\n' >> .env
    fi
    printf 'LINEAR_API_KEY=%s\n' "$INSTALL_SESSION_API_KEY" >> .env
    install::_log_info "wrote LINEAR_API_KEY to .env"
}

# -----------------------------------------------------------------------------
# install::_rewrite_dotenv_api_key  (T232, research.md §4)
# Portable awk-rewrite of `.env`: replace the existing LINEAR_API_KEY=
# line with the just-entered key, preserve all other lines verbatim.
# -----------------------------------------------------------------------------
install::_rewrite_dotenv_api_key() {
    local tmp
    tmp="$(mktemp -t spec-kit-linear-dotenv.XXXXXX)"
    awk -v new_key="$INSTALL_SESSION_API_KEY" '
        BEGIN { replaced = 0 }
        /^LINEAR_API_KEY=/ {
            if (!replaced) {
                printf "LINEAR_API_KEY=%s\n", new_key
                replaced = 1
                next
            }
            # Strip any subsequent duplicate lines silently.
            next
        }
        { print }
        END {
            if (!replaced) {
                printf "LINEAR_API_KEY=%s\n", new_key
            }
        }
    ' .env > "$tmp"
    mv "$tmp" .env
    install::_log_info "rewrote LINEAR_API_KEY in .env"
}

# -----------------------------------------------------------------------------
# install::_ensure_dotenv_gitignored  (T232, plan.md A5)
# Append `.env` to `.gitignore` if not already present. Idempotent.
# -----------------------------------------------------------------------------
install::_ensure_dotenv_gitignored() {
    if [[ ! -f .gitignore ]]; then
        printf '.env\n' > .gitignore
        install::_log_info "created .gitignore with .env entry"
        return 0
    fi
    if grep -qE '^\.env$' .gitignore; then
        return 0
    fi
    if [[ -s .gitignore ]] && [[ "$(tail -c1 .gitignore | wc -l)" -eq 0 ]]; then
        printf '\n' >> .gitignore
    fi
    printf '.env\n' >> .gitignore
    install::_log_info "added .env to .gitignore"
}

# -----------------------------------------------------------------------------
# install::discover_teams  (T234, FR-039 + install-discovery-graphql.md §2)
#
# Step S3 of the discovery state machine. Issues the `teams(first: 21)`
# query and populates the INSTALL_SESSION_TEAMS_{IDS,NAMES,KEYS}
# parallel arrays for install::pick_team_interactively to consume.
#
# Behaviour:
#   * `--team <UUID>` short-circuits S3 entirely (fast-path; FR-044) —
#     populates INSTALL_SESSION_SELECTED_TEAM_ID directly.
#   * Otherwise issues the query, parses nodes, fills arrays.
#
# The `first: 21` window (one over the 20-shown ceiling) is the
# research.md §1 overflow-detection probe — the picker reads
# `len > 20` and appends the §3.3 warning row.
# -----------------------------------------------------------------------------
install::discover_teams() {
    # Reset arrays so re-invocations don't leak state.
    INSTALL_SESSION_TEAMS_IDS=()
    INSTALL_SESSION_TEAMS_NAMES=()
    INSTALL_SESSION_TEAMS_KEYS=()

    # FR-044 fast path — when --team is passed, skip the query entirely.
    if [[ -n "$INSTALL_FLAG_TEAM" ]]; then
        INSTALL_SESSION_SELECTED_TEAM_ID="$INSTALL_FLAG_TEAM"
        # key/name are not known without a query — populated lazily by
        # downstream consumers if they need them. For the picker path
        # (which is skipped), the operator already opted out of the
        # friendly display.
        return 0
    fi

    local query='query InstallTeams { teams(first: 21) { nodes { id name key } } }'
    local response
    if ! response="$(graphql::query "$query" '{}')"; then
        install::_die 3 \
            "failed to query Linear teams (FR-039); re-run when connectivity returns"
    fi

    # Parse nodes into parallel arrays. Use tab as a delimiter — Linear
    # team keys are alphanumeric, names are arbitrary (we read them
    # whole-line via jq's @tsv).
    local nodes_tsv id name key
    nodes_tsv="$(printf '%s' "$response" \
        | jq -r '.data.teams.nodes[]? | [.id, .name, .key] | @tsv')"
    if [[ -z "$nodes_tsv" ]]; then
        return 0
    fi
    while IFS=$'\t' read -r id name key; do
        INSTALL_SESSION_TEAMS_IDS+=("$id")
        INSTALL_SESSION_TEAMS_NAMES+=("$name")
        INSTALL_SESSION_TEAMS_KEYS+=("$key")
    done <<< "$nodes_tsv"
}

# -----------------------------------------------------------------------------
# install::pick_team_interactively  (T206 + T234, FR-039 + install-prompts.md §3)
#
# Consume the INSTALL_SESSION_TEAMS_* parallel arrays populated by
# install::discover_teams and produce a single operator pick stored on
# INSTALL_SESSION_SELECTED_TEAM_{ID,KEY,NAME}. Behaviour matrix:
#
#   len == 0  → halt exit 2 with §3.5 remediation.
#   len == 1  → auto-pick, emit §3.4 surface row.
#   len >= 2  → render `%2d) %-8s — %s` numbered list, prompt
#               `Pick a team [1-N]:`, range-validate, re-prompt on
#               invalid input.
#   len >  20 → render first 20 + §3.3 overflow warning row,
#               then prompt as `[1-20]`.
#
# EOF / Ctrl-C → halt exit 2 with §3.6 remediation.
# -----------------------------------------------------------------------------
install::pick_team_interactively() {
    # Fast-path: --team <UUID> already populated SELECTED_TEAM_ID.
    if [[ -n "${INSTALL_SESSION_SELECTED_TEAM_ID:-}" ]] && \
       (( ${#INSTALL_SESSION_TEAMS_IDS[@]} == 0 )); then
        return 0
    fi

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

    # Multi-team rendering per install-prompts.md §3.1.
    local visible_count=$team_count
    local overflow=0
    if (( team_count > 20 )); then
        visible_count=20
        overflow=$(( team_count - 20 ))
    fi

    printf '[linear] Teams accessible to this API key:\n' >&2
    local i
    for (( i = 0; i < visible_count; i++ )); do
        printf '  %2d) %-8s — %s\n' \
            "$(( i + 1 ))" \
            "${INSTALL_SESSION_TEAMS_KEYS[$i]}" \
            "${INSTALL_SESSION_TEAMS_NAMES[$i]}" >&2
    done
    if (( overflow > 0 )); then
        printf '  ... and %d more not shown.\n' "$overflow" >&2
        printf '  Pass --team <UUID> to install non-interactively. (FR-039 / SC-013)\n' >&2
    fi

    # Range-validated prompt loop.
    local reply choice
    while :; do
        printf 'Pick a team [1-%d]: ' "$visible_count" >&2
        if ! IFS= read -r reply; then
            install::_die 2 \
                "no team selected. Pass --team <UUID> or run interactively to pick from the list above. (FR-039 / FR-045)"
        fi
        reply="${reply//[[:space:]]/}"
        if ! [[ "$reply" =~ ^[0-9]+$ ]]; then
            printf '[linear] invalid choice "%s"; pick a number between 1 and %d:\n' \
                "$reply" "$visible_count" >&2
            continue
        fi
        choice=$reply
        if (( choice < 1 || choice > visible_count )); then
            printf '[linear] invalid choice "%s"; pick a number between 1 and %d:\n' \
                "$reply" "$visible_count" >&2
            continue
        fi
        break
    done

    local idx=$(( choice - 1 ))
    INSTALL_SESSION_SELECTED_TEAM_ID="${INSTALL_SESSION_TEAMS_IDS[$idx]}"
    INSTALL_SESSION_SELECTED_TEAM_KEY="${INSTALL_SESSION_TEAMS_KEYS[$idx]}"
    INSTALL_SESSION_SELECTED_TEAM_NAME="${INSTALL_SESSION_TEAMS_NAMES[$idx]}"
    return 0
}

# -----------------------------------------------------------------------------
# install::discover_projects  (T235, FR-040 + install-discovery-graphql.md §3)
#
# Step S4 of the discovery state machine. Issues the
# `team(id).projects(first: 21)` query with INSTALL_SESSION_SELECTED_TEAM_ID
# and populates the INSTALL_SESSION_PROJECTS_{IDS,NAMES} parallel arrays
# for install::pick_project_interactively to consume.
#
# Behaviour:
#   * `--project <UUID>` short-circuits S4 entirely (fast-path; FR-044).
#   * Otherwise issues the query and fills arrays.
# -----------------------------------------------------------------------------
install::discover_projects() {
    INSTALL_SESSION_PROJECTS_IDS=()
    INSTALL_SESSION_PROJECTS_NAMES=()

    # FR-044 fast path — --project bypasses S4 entirely.
    if [[ -n "$INSTALL_FLAG_PROJECT" ]]; then
        INSTALL_SESSION_SELECTED_PROJECT_ID="$INSTALL_FLAG_PROJECT"
        INSTALL_SESSION_PROJECT_CHOICE="attach"
        return 0
    fi

    local team_id="${INSTALL_SESSION_SELECTED_TEAM_ID:?install::discover_projects: selected team unset}"

    # shellcheck disable=SC2016
    local query='query InstallTeamProjects($teamId: String!) {
        team(id: $teamId) {
            id
            projects(first: 21) { nodes { id name } }
        }
    }'
    local vars
    vars="$(jq -nc --arg teamId "$team_id" '{teamId: $teamId}')"

    local response
    if ! response="$(graphql::query "$query" "$vars")"; then
        install::_die 3 \
            "failed to query Linear projects for selected team (FR-040); re-run when connectivity returns"
    fi

    local nodes_tsv id name
    nodes_tsv="$(printf '%s' "$response" \
        | jq -r '.data.team.projects.nodes[]? | [.id, .name] | @tsv')"
    if [[ -z "$nodes_tsv" ]]; then
        return 0
    fi
    while IFS=$'\t' read -r id name; do
        INSTALL_SESSION_PROJECTS_IDS+=("$id")
        INSTALL_SESSION_PROJECTS_NAMES+=("$name")
    done <<< "$nodes_tsv"
}

# -----------------------------------------------------------------------------
# install::pick_project_interactively  (T207 + T235, FR-040 + install-prompts.md §4)
#
# Same numbered-list rendering as the team picker, with two additions:
#   1. "Create new project" is ALWAYS appended as the FINAL option
#      (index N+1 where N == len(projects)).
#   2. Sets INSTALL_SESSION_PROJECT_CHOICE ∈ {attach, create}.
#
# Overflow warning (§4.3) appended when N > 20.
# -----------------------------------------------------------------------------
install::pick_project_interactively() {
    # Fast-path: --project <UUID> populated PROJECT_ID + CHOICE=attach.
    if [[ -n "${INSTALL_SESSION_SELECTED_PROJECT_ID:-}" ]] && \
       [[ "${INSTALL_SESSION_PROJECT_CHOICE:-}" == "attach" ]] && \
       (( ${#INSTALL_SESSION_PROJECTS_IDS[@]} == 0 )); then
        return 0
    fi

    local project_count="${#INSTALL_SESSION_PROJECTS_IDS[@]}"
    local visible_count=$project_count
    local overflow=0
    if (( project_count > 20 )); then
        visible_count=20
        overflow=$(( project_count - 20 ))
    fi
    # Total selectable options = visible projects + "Create new" tail.
    local total_options=$(( visible_count + 1 ))

    if (( project_count == 0 )); then
        printf '[linear] No existing projects in %s.\n' \
            "${INSTALL_SESSION_SELECTED_TEAM_KEY:-team}" >&2
    else
        printf '[linear] Projects in %s:\n' \
            "${INSTALL_SESSION_SELECTED_TEAM_KEY:-team}" >&2
    fi
    local i
    for (( i = 0; i < visible_count; i++ )); do
        printf '  %2d) %s\n' \
            "$(( i + 1 ))" \
            "${INSTALL_SESSION_PROJECTS_NAMES[$i]}" >&2
    done
    printf '  %2d) Create new project\n' "$total_options" >&2
    if (( overflow > 0 )); then
        printf '  ... and %d more not shown.\n' "$overflow" >&2
        printf '  Pass --project <UUID> to install non-interactively. (FR-040)\n' >&2
    fi

    local reply choice
    while :; do
        printf 'Pick a project [1-%d]: ' "$total_options" >&2
        if ! IFS= read -r reply; then
            install::_die 2 \
                "no project selected. Pass --project <UUID> or run interactively to pick from the list above. (FR-040 / FR-045)"
        fi
        reply="${reply//[[:space:]]/}"
        if ! [[ "$reply" =~ ^[0-9]+$ ]]; then
            printf '[linear] invalid choice "%s"; pick a number between 1 and %d:\n' \
                "$reply" "$total_options" >&2
            continue
        fi
        choice=$reply
        if (( choice < 1 || choice > total_options )); then
            printf '[linear] invalid choice "%s"; pick a number between 1 and %d:\n' \
                "$reply" "$total_options" >&2
            continue
        fi
        break
    done

    if (( choice == total_options )); then
        # "Create new project" tail.
        INSTALL_SESSION_PROJECT_CHOICE="create"
        return 0
    fi

    local idx=$(( choice - 1 ))
    INSTALL_SESSION_PROJECT_CHOICE="attach"
    INSTALL_SESSION_SELECTED_PROJECT_ID="${INSTALL_SESSION_PROJECTS_IDS[$idx]}"
    INSTALL_SESSION_SELECTED_PROJECT_NAME="${INSTALL_SESSION_PROJECTS_NAMES[$idx]}"
    return 0
}

# -----------------------------------------------------------------------------
# install::prompt_new_project_name  (T208 + T236, FR-041 + install-prompts.md §5)
#
# Prompt for the new project's name with the repo basename as the
# default per install-prompts.md §5.1 + plan.md A6. Echoes the chosen
# name to stdout; the caller drives the duplicate-name pre-check and
# the projectCreate mutation.
#
# Empty input accepts the default. EOF halts with exit 2.
# -----------------------------------------------------------------------------
install::prompt_new_project_name() {
    local default_name
    if ! default_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"; then
        default_name="$(basename "$(pwd)")"
    fi

    local name=""
    printf '[linear] New Linear Project name [%s]: ' "$default_name" >&2
    if ! IFS= read -r name; then
        install::_die 2 \
            "no input received for new Project name; pass --project <UUID> or run interactively. (FR-041 / FR-045)"
    fi
    # Trim whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    : "${name:=$default_name}"
    printf '%s\n' "$name"
}

# -----------------------------------------------------------------------------
# install::_handle_duplicate_name <team_uuid> <project_name>  (T236, FR-041 + §5.3)
#
# Called by install::run_create_project_branch when
# install::_find_existing_project returns a non-empty result. Renders
# the `[create-anyway/pick-existing/rename]` prompt and sets one of:
#   * INSTALL_SESSION_PROJECT_CHOICE=attach + selected UUID/name/url
#     when operator picks `pick-existing` (default).
#   * INSTALL_SESSION_PROJECT_CHOICE=create when operator picks
#     `create-anyway` (caller proceeds to confirm prompt + mutation).
#   * On `rename`, returns 10 so the caller loops back to the name prompt.
# -----------------------------------------------------------------------------
install::_handle_duplicate_name() {
    local team_uuid="$1"
    local project_name="$2"

    local existing
    existing="$(install::_find_existing_project "$team_uuid" "$project_name")"
    local match_count
    match_count="$(printf '%s' "$existing" | jq 'length' 2>/dev/null || printf '0')"
    if ! [[ "$match_count" =~ ^[0-9]+$ ]] || (( match_count == 0 )); then
        # No duplicate — caller proceeds to mutation directly.
        INSTALL_SESSION_PROJECT_CHOICE="create"
        return 0
    fi

    # Use the first match (Linear allows duplicates but `eq:` is rare
    # enough that the first is almost always THE match).
    local existing_id existing_url
    existing_id="$(printf '%s' "$existing" | jq -r '.[0].id // ""')"
    existing_url="$(printf '%s' "$existing" | jq -r '.[0].url // ""')"

    local reply
    while :; do
        printf '[linear] A project named "%s" already exists in %s.\n' \
            "$project_name" "${INSTALL_SESSION_SELECTED_TEAM_KEY:-the team}" >&2
        printf '         [create-anyway/pick-existing/rename] (default: pick-existing): ' >&2
        if ! IFS= read -r reply; then
            reply="pick-existing"
        fi
        reply="${reply//[[:space:]]/}"
        : "${reply:=pick-existing}"
        case "$reply" in
            pick-existing)
                INSTALL_SESSION_PROJECT_CHOICE="attach"
                INSTALL_SESSION_SELECTED_PROJECT_ID="$existing_id"
                INSTALL_SESSION_SELECTED_PROJECT_NAME="$project_name"
                INSTALL_SESSION_SELECTED_PROJECT_URL="$existing_url"
                summary::add "skipped" \
                    "projectCreate '${project_name}' — attached to existing match"
                return 0
                ;;
            create-anyway)
                INSTALL_SESSION_PROJECT_CHOICE="create"
                return 0
                ;;
            rename)
                return 10
                ;;
            *)
                printf '[linear] Pick create-anyway, pick-existing, or rename.\n' >&2
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# install::create_linear_project <team_uuid> <project_name>  (T236, FR-041)
#
# Issue the `projectCreate` mutation per install-discovery-graphql.md §4.
# On success populates INSTALL_SESSION_SELECTED_PROJECT_{ID,NAME,URL}
# and emits the §5.5 surface row. On failure halts with exit 1 +
# verbatim Linear error per §5.6.
# -----------------------------------------------------------------------------
install::create_linear_project() {
    local team_uuid="${1:?install::create_linear_project: team_uuid required}"
    local project_name="${2:?install::create_linear_project: project_name required}"

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
        '{ name: $name, teamIds: [$team], description: $description }')"
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    if ! response="$(graphql::mutate "$mutation" "$vars" 2>/dev/null)"; then
        install::_die 1 \
            "projectCreate '${project_name}' failed (transport). Re-run install when Linear is reachable. (FR-041)"
    fi

    local success
    success="$(printf '%s' "$response" | jq -r '.data.projectCreate.success // false')"
    if [[ "$success" != "true" ]]; then
        local verbatim_error
        verbatim_error="$(printf '%s' "$response" | jq -r '.errors[0].message // .data.projectCreate // "unknown error"' 2>/dev/null)"
        install::_die 1 \
            "projectCreate failed: ${verbatim_error}
Re-run install to try again (your team selection is remembered), or pick an existing project. (FR-041)"
    fi

    local new_id new_name new_url
    new_id="$(printf '%s' "$response" | jq -r '.data.projectCreate.project.id // ""')"
    new_name="$(printf '%s' "$response" | jq -r '.data.projectCreate.project.name // ""')"
    new_url="$(printf '%s' "$response" | jq -r '.data.projectCreate.project.url // ""')"

    if [[ -z "$new_id" ]]; then
        install::_die 1 \
            "projectCreate returned success but no project.id — please file a bug report (FR-041)"
    fi

    INSTALL_SESSION_SELECTED_PROJECT_ID="$new_id"
    INSTALL_SESSION_SELECTED_PROJECT_NAME="$new_name"
    INSTALL_SESSION_SELECTED_PROJECT_URL="$new_url"
    INSTALL_SESSION_PROJECT_CHOICE="create"

    # Mirror the legacy install::_create_project module globals so the
    # v0.1.0 summary block continues to surface "Project resolved" rows.
    INSTALL_RESOLVED_PROJECT_URL="$new_url"
    INSTALL_RESOLVED_PROJECT_NAME="$new_name"

    summary::add "created" "projectCreate '${new_name}' (URL recorded in summary)"
    if [[ -n "$new_url" ]]; then
        install::_log_info "Created Linear Project: ${new_url}"
    fi
    install::_log_info \
        "Project ID is recorded internally and written to .specify/extensions/linear/linear-config.yml."
}

# -----------------------------------------------------------------------------
# install::run_create_project_branch  (T236, FR-041 + install-prompts.md §5)
#
# Step S5 of the discovery state machine. Orchestrates the "Create new
# project" branch:
#   1. Prompt for name (§5.1, default = repo basename).
#   2. Duplicate-name pre-check + triage (§5.3).
#   3. Confirm prompt (§5.4).
#   4. Fire projectCreate mutation via install::create_linear_project.
#
# Loops on `rename` per §5.3 / §5.4. Honours the operator's CHOICE on
# exit: `attach` means the duplicate-name handler attached to an
# existing project, `create` means the mutation fired (or the loop
# completed cleanly).
# -----------------------------------------------------------------------------
install::run_create_project_branch() {
    local team_uuid="${INSTALL_SESSION_SELECTED_TEAM_ID:?install::run_create_project_branch: selected team unset}"

    while :; do
        local project_name
        project_name="$(install::prompt_new_project_name)"
        if [[ -z "$project_name" ]]; then
            continue
        fi

        # §5.3 duplicate-name pre-check.
        install::_handle_duplicate_name "$team_uuid" "$project_name"
        local rc=$?
        if (( rc == 10 )); then
            # `rename` — loop back to name prompt.
            continue
        fi
        if [[ "$INSTALL_SESSION_PROJECT_CHOICE" == "attach" ]]; then
            return 0
        fi

        # §5.4 confirm prompt.
        local confirm
        printf '[linear] Create new Linear Project "%s" in %s? [Y/n] (default: Y): ' \
            "$project_name" "${INSTALL_SESSION_SELECTED_TEAM_KEY:-team}" >&2
        if ! IFS= read -r confirm; then
            install::_die 2 \
                "no input received for project-create confirmation; pass --project <UUID> or run interactively. (FR-041 / FR-045)"
        fi
        confirm="${confirm//[[:space:]]/}"
        : "${confirm:=Y}"
        case "$confirm" in
            Y|y|Yes|yes|YES)
                install::create_linear_project "$team_uuid" "$project_name"
                return 0
                ;;
            N|n|No|no|NO)
                # Loop back to name prompt with the just-typed name as default.
                continue
                ;;
            *)
                # Treat any unrecognized input as Y per §5.4 default-safe.
                install::create_linear_project "$team_uuid" "$project_name"
                return 0
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# install::quick_validate_binding <team_uuid> <project_uuid>
#   (T209 + T248 + T251, FR-044)
#
# Issue a single combined `team(id){...} project(id){... teams{nodes{id}}}`
# query per install-discovery-graphql.md §5.5. Used in two FR-044 fast
# paths:
#
#   (a) `--team <UUID> --project <UUID>` (canonical CI path, T248) —
#       validates both UUIDs and the project-team membership in one
#       round trip. Failure modes:
#         * `data.team == null`        → halt exit 2 (team unreachable).
#         * `data.project == null`     → halt exit 2 (project
#                                         unreachable).
#         * `project.teams.nodes[].id` does NOT contain `team.id` →
#                                         halt exit 2 (mismatch).
#
#   (b) `--project <UUID>` alone (T251 / install-flags.md §5 row 6) —
#       caller passes `team_uuid=""`; the function resolves the owning
#       team from `project.teams.nodes[0]` and populates the session
#       team UUID + key + name without consulting `--team`. Skips the
#       team-membership check (the resolved team IS by definition a
#       team the project belongs to).
#
# On success populates `INSTALL_SESSION_SELECTED_TEAM_*` and
# `INSTALL_SESSION_SELECTED_PROJECT_*` directly (skips S3 + S4 +
# pickers). The captured project URL flows into the install summary's
# "Open in Linear" row (FR-041 / T239) so the v0.1.0-compat path
# enjoys the same operator-facing surface as the discovery path.
# -----------------------------------------------------------------------------
install::quick_validate_binding() {
    # team_uuid may legitimately be empty under the `--project`-alone
    # branch (T251); only project_uuid is strictly required.
    local team_uuid="${1-}"
    local project_uuid="${2:?install::quick_validate_binding: project_uuid required}"

    # Linear accepts `null` for the team(id:) variable when callers
    # only want the project leg — but the schema requires a String so
    # we pass an empty string and unconditionally compare against the
    # response's `data.team.id` (which will be null under the §5 row 6
    # fast path).
    # shellcheck disable=SC2016
    local query='query InstallValidateBinding($teamId: String!, $projectId: String!) {
        team(id: $teamId) { id name key }
        project(id: $projectId) {
            id
            name
            url
            teams { nodes { id name key } }
        }
    }'
    local vars
    vars="$(jq -nc \
        --arg teamId "$team_uuid" \
        --arg projectId "$project_uuid" \
        '{teamId: $teamId, projectId: $projectId}')"

    local response
    if ! response="$(graphql::query "$query" "$vars")"; then
        install::_die 3 \
            "failed to quick-validate --team/--project binding against Linear (FR-044 / §5.5); re-run when connectivity returns"
    fi

    local project_id
    project_id="$(printf '%s' "$response" | jq -r '.data.project.id // empty')"
    if [[ -z "$project_id" ]]; then
        install::_die 2 \
            "--project <UUID> not accessible to this API key (FR-044 / install-discovery-graphql.md §5.5)"
    fi

    local team_id team_key team_name
    if [[ -n "$team_uuid" ]]; then
        # Branch (a): both UUIDs passed — validate team leg + membership.
        team_id="$(printf '%s' "$response" | jq -r '.data.team.id // empty')"
        if [[ -z "$team_id" ]]; then
            install::_die 2 \
                "--team <UUID> not accessible to this API key (FR-044 / install-discovery-graphql.md §5.5)"
        fi
        local match
        match="$(printf '%s' "$response" \
            | jq -r --arg team_id "$team_id" \
                '.data.project.teams.nodes // [] | map(.id) | index($team_id) // empty')"
        if [[ -z "$match" ]]; then
            install::_die 2 \
                "--project does not belong to --team (FR-044 / install-discovery-graphql.md §5.5)"
        fi
        team_key="$(printf '%s' "$response" | jq -r '.data.team.key // empty')"
        team_name="$(printf '%s' "$response" | jq -r '.data.team.name // empty')"
    else
        # Branch (b): `--project` alone — resolve team from project leg.
        team_id="$(printf '%s' "$response" | jq -r '.data.project.teams.nodes[0].id // empty')"
        if [[ -z "$team_id" ]]; then
            install::_die 2 \
                "--project <UUID> has no owning team — Linear returned an empty teams connection (FR-044)"
        fi
        team_key="$(printf '%s' "$response" | jq -r '.data.project.teams.nodes[0].key // empty')"
        team_name="$(printf '%s' "$response" | jq -r '.data.project.teams.nodes[0].name // empty')"
    fi

    INSTALL_SESSION_SELECTED_TEAM_ID="$team_id"
    INSTALL_SESSION_SELECTED_TEAM_KEY="$team_key"
    INSTALL_SESSION_SELECTED_TEAM_NAME="$team_name"
    INSTALL_SESSION_SELECTED_PROJECT_ID="$project_id"
    INSTALL_SESSION_SELECTED_PROJECT_NAME="$(printf '%s' "$response" | jq -r '.data.project.name // empty')"
    INSTALL_SESSION_SELECTED_PROJECT_URL="$(printf '%s' "$response" | jq -r '.data.project.url // empty')"
    INSTALL_SESSION_PROJECT_CHOICE="attach"
    return 0
}

# -----------------------------------------------------------------------------
# install::_should_use_discovery_flow  (T232 + T250 + T251, spec 002 dispatch gate)
#
# Returns 0 (true) when the new spec-002 viewer-driven discovery flow
# should run; returns non-zero when the legacy v0.1.0 path should run.
#
# Truth table (post-Phase-4 — install-flags.md §5):
#   --team SET, --project SET, no --auto-create  → discovery (T248 fast path
#                                                  via quick_validate_binding)
#   --team SET, no --project, no --auto-create   → discovery (T250 — runs
#                                                  P3 project picker scoped
#                                                  to passed team)
#   no --team, --project SET, no --auto-create   → discovery (T251 — team
#                                                  auto-resolves from
#                                                  project.teams.nodes[0])
#   --auto-create SET (with or without --team)   → legacy (v0.1.0
#                                                  --auto-create preserved
#                                                  bit-for-bit per FR-044
#                                                  / install-flags.md §2)
#   No flags                                     → discovery (default)
#
# `--auto-create` is the sole hold-out on the legacy path during Phase 4
# because spec 002's discovery flow's "Create new project" picker
# option is its semantic replacement; preserving the legacy branch
# keeps the SC-011 regression contract intact for CI scripts that
# still pass the flag.
# -----------------------------------------------------------------------------
install::_should_use_discovery_flow() {
    # `--auto-create` always routes through the legacy v0.1.0 path so
    # the install::_auto_create_or_attach branch (with its existing
    # duplicate-name pre-check) stays bit-for-bit identical to v0.1.0.
    if (( INSTALL_FLAG_AUTO_CREATE == 1 )); then
        return 1
    fi
    # Every other flag combination routes through the discovery flow,
    # which internally fast-paths via quick_validate_binding (both
    # UUIDs), resolve_team_from_project (--project alone), or runs the
    # full S3+S4 pickers (no flags / --team alone).
    return 0
}

# -----------------------------------------------------------------------------
# install::run_discovery_flow  (T232 + T234..T236 + T248 + T250 + T251,
#                               FR-037..FR-041 / FR-044 / FR-048)
#
# Drives the spec 002 viewer-driven discovery state machine end-to-end:
#   S1 → install::prompt_for_api_key            (FR-037)
#   S2 → install::resolve_operator              (FR-038 + FR-048)
#   S3 → install::discover_teams                (FR-039)
#         + install::pick_team_interactively   (FR-039 picker)
#   S4 → install::discover_projects             (FR-040)
#         + install::pick_project_interactively (FR-040 picker)
#   S5 → install::run_create_project_branch    (FR-041; only when
#                                                operator picked
#                                                "Create new project")
#
# FR-044 fast paths (T248 / T250 / T251) — wired BETWEEN S2 and S3:
#   * --team SET, --project SET → install::quick_validate_binding
#     (single combined query; skips S3 + S4 entirely; CI canonical path)
#   * --team SET, no --project  → install::discover_teams's --team
#     short-circuit populates SELECTED_TEAM_ID without a query; S4 still
#     runs against that team. (install-flags.md §5 row 5)
#   * no --team, --project SET  → install::resolve_team_from_project
#     resolves the owning team from the project's teams connection;
#     skips both S3 and S4. (install-flags.md §5 row 6)
#
# On exit:
#   * INSTALL_SESSION_SELECTED_TEAM_ID is populated.
#   * INSTALL_SESSION_SELECTED_PROJECT_ID is populated.
#   * The operator never sees a Linear UUID (SC-010).
# -----------------------------------------------------------------------------
install::run_discovery_flow() {
    install::prompt_for_api_key
    # The viewer query is the FR-048 single-fire authorization probe.
    # It populates INSTALL_OPERATOR_* (FR-034), INSTALL_SESSION_VIEWER_*
    # (workspace block), and validates the API key BEFORE any picker
    # fires (US1 scenario 4).
    install::resolve_operator

    # ---- FR-044 fast paths (T248 / T251) ---------------------------------
    # Both --team and --project passed → quick-validate the binding in
    # a single round trip and skip the team + project pickers entirely.
    # The captured project URL feeds the install summary's "Open in
    # Linear" row.
    if [[ -n "$INSTALL_FLAG_TEAM" ]] && [[ -n "$INSTALL_FLAG_PROJECT" ]]; then
        install::quick_validate_binding \
            "$INSTALL_FLAG_TEAM" "$INSTALL_FLAG_PROJECT"
        return 0
    fi
    # Only --project passed → resolve the owning team from the
    # project's teams connection; skip both pickers. We thread an empty
    # team_uuid to install::quick_validate_binding which takes the
    # `--project`-alone branch and reads `data.project.teams.nodes[0]`.
    if [[ -z "$INSTALL_FLAG_TEAM" ]] && [[ -n "$INSTALL_FLAG_PROJECT" ]]; then
        install::quick_validate_binding "" "$INSTALL_FLAG_PROJECT"
        return 0
    fi

    # ---- Default path (no flags) and --team-only (T250) ------------------
    # install::discover_teams + install::pick_team_interactively short-
    # circuit when --team is set (populating SELECTED_TEAM_ID without a
    # query or prompt); install::discover_projects then runs the P3
    # picker scoped to that team per install-flags.md §5 row 5.
    install::discover_teams
    install::pick_team_interactively

    install::discover_projects
    install::pick_project_interactively

    if [[ "$INSTALL_SESSION_PROJECT_CHOICE" == "create" ]]; then
        install::run_create_project_branch
    fi
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

    # ---- S0: FR-046 self-install guard (T258) ------------------------------
    # Compare the bridge's SOURCE (EXTENSION_ROOT — the directory the
    # caller is running install from) against the TARGET (the
    # consumer-repo cwd). When the two canonical paths collide, halt
    # exit 2 BEFORE any filesystem mutation or dependency-check work
    # per install-flags.md §4 + FR-046. The helper itself emits the
    # verbatim message and calls `exit 2`.
    install::detect_self_install "$EXTENSION_ROOT" "$PWD"

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

    # ---- Step 2: resolve UUIDs (T041 / FR-002 + spec 002 T232..T237) -------
    # Spec 002 routes the install through one of three paths:
    #   1. No UUID flags → new viewer-driven discovery (S1..S5 + write).
    #   2. --team and/or --project / --auto-create → legacy v0.1.0 path
    #      preserved bit-for-bit so SC-011 stays GREEN.
    #
    # The new path resolves operator identity FIRST (so the viewer call
    # feeds FR-034 + FR-038 + FR-039 authorization per FR-048's single
    # fire mandate). The legacy path resolves operator LAST so existing
    # CI invocations short-circuit on team/project failures before the
    # viewer round trip — bit-for-bit identical to v0.1.0.
    local team_uuid project_uuid
    if install::_should_use_discovery_flow; then
        install::run_discovery_flow
        team_uuid="$INSTALL_SESSION_SELECTED_TEAM_ID"
        project_uuid="$INSTALL_SESSION_SELECTED_PROJECT_ID"
    else
        team_uuid="$(install::resolve_team_uuid)"
        project_uuid="$(install::resolve_project_uuid "$team_uuid")"
        # ---- Step 2b: resolve operator identity (FR-034) -------------------
        # Capture `viewer { id name email organization }` so the
        # reconciler can pass assigneeId on every issueCreate. Runs
        # AFTER team/project so any team/project failure short-circuits
        # before we hit the network for the viewer query; runs BEFORE
        # write_config so the operator block is populated in the same
        # single write of linear-config.yml.
        install::resolve_operator
    fi

    # ---- Step 2c (spec 002 FR-042) — gate write_config on resolved IDs ----
    if [[ -z "$team_uuid" || -z "$project_uuid" ]]; then
        install::_die 2 \
            "discovery flow did not resolve both Team and Project UUIDs (FR-042); cannot proceed with config write"
    fi

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
        # T239 / install-prompts.md §7 — "Key sourced from" row, surfaced
        # whenever the spec-002 discovery flow resolved the API key.
        if [[ -n "$INSTALL_SESSION_API_KEY_SOURCE" ]]; then
            printf '\n[linear] Key sourced from: %s\n' \
                "$INSTALL_SESSION_API_KEY_SOURCE"
        fi
        # T239 — surface the projectCreate URL (no UUID per SC-010).
        if [[ -n "$INSTALL_SESSION_SELECTED_PROJECT_URL" ]]; then
            printf '[linear] Open in Linear: %s\n' \
                "$INSTALL_SESSION_SELECTED_PROJECT_URL"
        elif [[ -n "$INSTALL_RESOLVED_PROJECT_URL" ]]; then
            # Legacy v0.1.0 path (--auto-create / attach-existing).
            # NOTE: do NOT print project_uuid here per SC-010 — the URL
            # alone is the operator's path back to Linear.
            printf '\n[linear] Project resolved: %s\n' "$INSTALL_RESOLVED_PROJECT_URL"
            printf '         (name: %s)\n' "${INSTALL_RESOLVED_PROJECT_NAME:-unknown}"
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
        # T259 / FR-049: mirror the vendored-`.git/` warning into the
        # Next-steps block per install-prompts.md §7 so the operator
        # sees the `rm -rf …` remediation at the bottom of the run too.
        if (( INSTALL_VENDORED_GIT_DETECTED == 1 )); then
            printf '  *. Remove vendored .git/: rm -rf %s (FR-049)\n' "$INSTALL_VENDORED_GIT_PATH"
        fi
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
