#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/dogfood.sh — End-to-end dogfood driver for spec-kit-linear (T077).
#
# Chains src/install.sh -> src/seed.sh -> src/reconcile.sh --spec 001 against
# the operator's ACME Linear workspace (or any team UUID passed via
# --team) and captures every stdout/stderr stream plus structured metadata
# (timings, exit codes, Linear verification) into a Markdown report at
# validation/dogfood-001.md.
#
# Read-only against src/*.sh — if a bug is found during the run, the
# remediation lands in a separate commit per the T077 brief.
#
# Spec references:
#   - specs/001-spec-kit-linear-bridge/tasks.md T077
#   - specs/001-spec-kit-linear-bridge/spec.md User Story 4 + User Story 5,
#     FR-018b (preflight), FR-021 (seed idempotency), FR-022 (halt-on-unseeded)
#   - specs/001-spec-kit-linear-bridge/quickstart.md Steps 1-5
#
# The target Linear Team UUID is REQUIRED (no built-in default): supply it
# via --team <uuid>, or via SPECKIT_LINEAR_TEAM_ID / LINEAR_TEAM_ID in the
# operator-local .env.
#
# Exit codes:
#   0  Success — install + seed + reconcile + verification all green.
#   2  User error / missing prerequisite (bash 4+, curl, jq, git, gh, .env).
#   3  A wrapped sub-script (install/seed/reconcile) exited non-zero. The
#      report's `## Failure` section names the offending step.
#   4  Linear API verification failed (Project or Issue absent, or GraphQL
#      transport error during Step 4).
#   5  dogfood.sh internal error (e.g. cannot write report file).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants & defaults
# -----------------------------------------------------------------------------

# Team UUID is REQUIRED — there is no usable built-in default. Supply it
# via --team <uuid>, or via SPECKIT_LINEAR_TEAM_ID / LINEAR_TEAM_ID in the
# operator-local .env (sourced by load_env_file). The all-ones value shown
# in --help (11111111-1111-4111-8111-111111111111) is an INERT placeholder
# used in examples only — it is never the live default and would not
# resolve against any real workspace.
readonly DEFAULT_REPORT_PATH="validation/dogfood-001.md"
readonly LINEAR_GRAPHQL_ENDPOINT="https://api.linear.app/graphql"

# Report path for the spec-002 interactive-discovery flow (T262).
# Mirrors validation/dogfood-001.md per Assumption A12 in
# specs/002-install-ergonomics/tasks.md.
readonly DEFAULT_INTERACTIVE_REPORT_PATH="validation/dogfood-002.md"

# Required preflight binaries. Bash 4+ is checked separately (version-sensitive).
readonly -a REQUIRED_BINARIES=(curl jq git gh)

# -----------------------------------------------------------------------------
# Mutable globals (populated by parse_args / preflight / run_*).
# -----------------------------------------------------------------------------

# Empty until resolved from --team or the environment (see resolve_team_uuid).
# An empty value here is intentional: there is NO broken-but-plausible default.
TEAM_UUID=""
REPORT_PATH="$DEFAULT_REPORT_PATH"
DRY_RUN=0
SKIP_INSTALL=0
SKIP_SEED=0

# T262 — spec-002 interactive-discovery flow. When INTERACTIVE_FLOW=1
# the script runs ONLY the interactive block (it does not chain the
# original install/seed/reconcile sequence) and writes to
# INTERACTIVE_REPORT_PATH. Driven by --interactive-flow.
INTERACTIVE_FLOW=0
INTERACTIVE_REPORT_PATH="$DEFAULT_INTERACTIVE_REPORT_PATH"
# Path to the SANDBOX consumer repo the interactive flow installs into.
# MUST be a separate checkout from the bridge (FR-046 self-install guard
# refuses source == target). Empty → the script provisions a throwaway
# temp repo under $TMPDIR and tears it down on exit.
SANDBOX_REPO=""
# Pre-existing Project UUID to attach to (drives the "pick existing
# project" branch). Empty → the flow drives the "Create new project"
# picker tail instead.
INTERACTIVE_PROJECT_UUID=""

REPO_ROOT=""
REPORT_ABS_PATH=""

# Temp sandbox bookkeeping (populated by run_interactive_flow when no
# --sandbox-repo is supplied; cleaned up via the EXIT trap).
INTERACTIVE_SANDBOX_TMP=""

# Exit codes from each step (default 0 = skipped/clean).
INSTALL_EXIT=0
SEED_EXIT=0
RECONCILE_EXIT=0

# Per-step wall-clock seconds.
INSTALL_DURATION=0
SEED_DURATION=0
RECONCILE_DURATION=0
TOTAL_START_TS=0

# Linear verification results (filled by step 4).
LINEAR_PROJECT_OK="pending"
LINEAR_ISSUE_OK="pending"
LINEAR_ISSUE_URL=""
LINEAR_VIEWER_EMAIL=""
LINEAR_VIEWER_NAME=""

# Warnings surfaced across the run (newline-separated).
WARNINGS=""

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Usage: scripts/dogfood.sh [OPTIONS]

End-to-end dogfood driver for spec-kit-linear (T077). Chains the install
ceremony, the workspace seed, and a reconcile of spec 001, and captures
the full transcript plus a Linear verification pass to a Markdown report.

OPTIONS
  --team UUID       Linear Team UUID to target. REQUIRED — there is no
                    built-in default. Either pass --team, or set
                    SPECKIT_LINEAR_TEAM_ID (or LINEAR_TEAM_ID) in your
                    operator-local .env. Example (placeholder, not a real
                    team): --team 11111111-1111-4111-8111-111111111111
  --dry-run         Propagate --dry-run to src/seed.sh and src/reconcile.sh
                    so no Linear mutations fire. NOTE: src/install.sh does
                    NOT support --dry-run today; it is skipped under
                    --dry-run with a warning. Use --skip-install if you
                    need the seed/reconcile dry-run isolated.
  --skip-install    Skip Step 1 (use when the bridge is already installed
                    in this repo).
  --skip-seed       Skip Step 2 (the workspace seed is one-shot per
                    workspace per FR-021; re-running is a safe no-op but
                    can be skipped for speed).
  --report PATH     Override the report path. Default: validation/dogfood-001.md
  --interactive-flow
                    Run spec 002's INTERACTIVE discovery install instead of
                    the original install->seed->reconcile chain (T262). Drives
                    src/install.sh --dev with piped-stdin operator picks (API
                    key already in .env, team pick, project pick / create-new)
                    against a SANDBOX consumer repo SEPARATE from the bridge's
                    own checkout — FR-046's self-install guard refuses
                    source == target (tasks.md Assumption A12). Writes to
                    validation/dogfood-002.md unless --report overrides.
  --sandbox-repo DIR
                    Consumer repo the --interactive-flow installs into. MUST
                    be a separate checkout from this bridge. When omitted the
                    script provisions a throwaway git repo under TMPDIR and
                    removes it on exit. Only meaningful with --interactive-flow.
  --interactive-project UUID
                    With --interactive-flow, attach to this existing Project
                    UUID (drives the "pick existing project" branch, FR-040).
                    When omitted the flow drives the "Create new project"
                    picker tail (FR-041) so the projectCreate path is exercised.
  --help            Print this help and exit.

EXIT CODES
  0  All steps green.
  2  Missing prerequisite (bash 4+, curl, jq, git, gh, or .env LINEAR_API_KEY).
  3  A sub-script (install/seed/reconcile) exited non-zero.
  4  Linear API verification failed.
  5  Internal error (cannot write report, unexpected condition).

SEE ALSO
  specs/001-spec-kit-linear-bridge/tasks.md T077
  specs/001-spec-kit-linear-bridge/quickstart.md
USAGE
}

# -----------------------------------------------------------------------------
# log <message>
#   Emit a dogfood-prefixed line to stderr. The report itself receives
#   richer structure via the section writers below.
# -----------------------------------------------------------------------------
log() {
    printf 'dogfood: %s\n' "$*" >&2
}

warn() {
    local msg="$1"
    printf 'dogfood: WARN: %s\n' "$msg" >&2
    if [[ -z "$WARNINGS" ]]; then
        WARNINGS="$msg"
    else
        WARNINGS="${WARNINGS}"$'\n'"${msg}"
    fi
}

die() {
    local code="$1"
    shift
    printf 'dogfood: ERROR: %s\n' "$*" >&2
    exit "$code"
}

# -----------------------------------------------------------------------------
# parse_args <args...>
# -----------------------------------------------------------------------------
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --team)
                if (( $# < 2 )); then
                    die 2 "--team requires a UUID argument"
                fi
                TEAM_UUID="$2"
                shift 2
                ;;
            --team=*)
                TEAM_UUID="${1#--team=}"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --skip-install)
                SKIP_INSTALL=1
                shift
                ;;
            --skip-seed)
                SKIP_SEED=1
                shift
                ;;
            --report)
                if (( $# < 2 )); then
                    die 2 "--report requires a PATH argument"
                fi
                REPORT_PATH="$2"
                shift 2
                ;;
            --report=*)
                REPORT_PATH="${1#--report=}"
                shift
                ;;
            --interactive-flow)
                INTERACTIVE_FLOW=1
                shift
                ;;
            --sandbox-repo)
                if (( $# < 2 )); then
                    die 2 "--sandbox-repo requires a DIR argument"
                fi
                SANDBOX_REPO="$2"
                shift 2
                ;;
            --sandbox-repo=*)
                SANDBOX_REPO="${1#--sandbox-repo=}"
                shift
                ;;
            --interactive-project)
                if (( $# < 2 )); then
                    die 2 "--interactive-project requires a UUID argument"
                fi
                INTERACTIVE_PROJECT_UUID="$2"
                shift 2
                ;;
            --interactive-project=*)
                INTERACTIVE_PROJECT_UUID="${1#--interactive-project=}"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf 'dogfood: unknown argument: %s\n' "$1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# resolve_repo_root
#   Anchor everything to the repo root so the script works regardless of
#   the operator's CWD. Sets REPO_ROOT and REPORT_ABS_PATH.
# -----------------------------------------------------------------------------
resolve_repo_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${script_dir}/.." && pwd)"

    # In --interactive-flow mode, the default report target is
    # validation/dogfood-002.md (A12). An explicit --report still wins.
    if (( INTERACTIVE_FLOW == 1 )) && [[ "$REPORT_PATH" == "$DEFAULT_REPORT_PATH" ]]; then
        REPORT_PATH="$INTERACTIVE_REPORT_PATH"
    fi

    # REPORT_PATH is interpreted relative to REPO_ROOT unless absolute.
    if [[ "$REPORT_PATH" = /* ]]; then
        REPORT_ABS_PATH="$REPORT_PATH"
    else
        REPORT_ABS_PATH="${REPO_ROOT}/${REPORT_PATH}"
    fi
}

# -----------------------------------------------------------------------------
# load_env_file
#   Source <repo>/.env if present, exporting LINEAR_API_KEY into the
#   environment so curl-based verification can authenticate.
#   .env presence is enforced separately by preflight().
# -----------------------------------------------------------------------------
load_env_file() {
    local env_file="${REPO_ROOT}/.env"
    if [[ ! -f "$env_file" ]]; then
        return 0
    fi
    # Read line-by-line — avoids `set -a; source` which can choke on
    # comments containing shell metacharacters in .env.example-style files.
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        # Only handle KEY=VALUE pairs (no spaces around =).
        if [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            val="${line#*=}"
            # Strip surrounding quotes if present.
            val="${val%\"}"
            val="${val#\"}"
            val="${val%\'}"
            val="${val#\'}"
            export "${key}=${val}"
        fi
    done < "$env_file"
}

# -----------------------------------------------------------------------------
# resolve_team_uuid
#   Determine the Linear Team UUID to target. Precedence:
#     1. --team <uuid> on the CLI (already parsed into TEAM_UUID).
#     2. SPECKIT_LINEAR_TEAM_ID in the environment (e.g. from .env).
#     3. LINEAR_TEAM_ID in the environment (e.g. from .env).
#   If none resolve, die with exit 2 (user error) and a copy-paste hint.
#   There is deliberately NO fallback default: a non-existent placeholder
#   team would only POST to Linear and fail confusingly.
#   Must run AFTER load_env_file so .env-sourced vars are visible.
# -----------------------------------------------------------------------------
resolve_team_uuid() {
    if [[ -z "$TEAM_UUID" ]]; then
        TEAM_UUID="${SPECKIT_LINEAR_TEAM_ID:-${LINEAR_TEAM_ID:-}}"
    fi
    if [[ -z "$TEAM_UUID" ]]; then
        printf 'dogfood: ERROR: no Linear Team UUID supplied.\n' >&2
        printf '  Pass --team <uuid>, or set SPECKIT_LINEAR_TEAM_ID (or\n' >&2
        printf '  LINEAR_TEAM_ID) in your operator-local .env. There is no\n' >&2
        printf '  built-in default — see scripts/dogfood.sh --help.\n' >&2
        usage >&2
        exit 2
    fi
}

# -----------------------------------------------------------------------------
# preflight
#   FR-018b-style check: every external dependency the dogfood touches is
#   verified before Step 1 mutates anything. Failure surfaces copy-paste
#   remediation and bails with exit 2.
# -----------------------------------------------------------------------------
preflight() {
    local -a missing=()
    local -a remediation=()

    # Bash 4+ (associative arrays, ${var,,} downcase, etc. all assume bash 4).
    if (( BASH_VERSINFO[0] < 4 )); then
        missing+=("bash (need 4+, found ${BASH_VERSION})")
        remediation+=("brew install bash   # then re-open your shell or prepend /opt/homebrew/bin to PATH")
    fi

    local bin
    for bin in "${REQUIRED_BINARIES[@]}"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing+=("$bin")
            case "$bin" in
                curl) remediation+=("brew install curl") ;;
                jq)   remediation+=("brew install jq") ;;
                git)  remediation+=("brew install git") ;;
                gh)   remediation+=("brew install gh && gh auth login") ;;
            esac
        fi
    done

    # .env must exist with a non-empty LINEAR_API_KEY for the GraphQL
    # verification (Step 4). The bridge proper uses the OAuth MCP path; the
    # dogfood verification uses the personal-token GraphQL fallback per
    # .env.example.
    if [[ ! -f "${REPO_ROOT}/.env" ]]; then
        missing+=(".env file")
        remediation+=("cp .env.example .env && \$EDITOR .env   # fill in LINEAR_API_KEY")
    elif [[ -z "${LINEAR_API_KEY:-}" ]]; then
        missing+=("LINEAR_API_KEY in .env")
        remediation+=("Add LINEAR_API_KEY=<your-personal-token> to .env (https://linear.app/settings/api)")
    fi

    write_preflight_section "${missing[@]+"${missing[@]}"}"

    if (( ${#missing[@]} > 0 )); then
        printf 'dogfood: preflight failed. Missing:\n' >&2
        local i
        for i in "${!missing[@]}"; do
            printf '  - %s\n' "${missing[$i]}" >&2
            printf '    fix: %s\n' "${remediation[$i]:-(see docs)}" >&2
        done
        exit 2
    fi
}

# -----------------------------------------------------------------------------
# write_preflight_section <missing...>
#   Append the `## Pre-flight checks` section to the report. Called by
#   preflight() AFTER it has determined the missing-set, so the section
#   reflects the actual state.
# -----------------------------------------------------------------------------
write_preflight_section() {
    local -a missing=("$@")

    {
        printf '## Pre-flight checks\n\n'
        printf '| Check | Status | Detail |\n'
        printf '|---|---|---|\n'
        printf '| bash 4+ | %s | %s |\n' \
            "$(status_emoji_for "$( (( BASH_VERSINFO[0] >= 4 )) && echo ok || echo fail )" )" \
            "${BASH_VERSION}"
        local bin status_label detail
        for bin in "${REQUIRED_BINARIES[@]}"; do
            if command -v "$bin" >/dev/null 2>&1; then
                status_label="ok"
                detail="$(command -v "$bin")"
            else
                status_label="fail"
                detail="not on PATH"
            fi
            printf '| %s | %s | %s |\n' "$bin" "$(status_emoji_for "$status_label")" "$detail"
        done
        # .env presence + LINEAR_API_KEY.
        if [[ -f "${REPO_ROOT}/.env" ]]; then
            printf '| .env file | %s | %s |\n' "$(status_emoji_for ok)" "${REPO_ROOT}/.env"
        else
            printf '| .env file | %s | missing — copy .env.example |\n' "$(status_emoji_for fail)"
        fi
        if [[ -n "${LINEAR_API_KEY:-}" ]]; then
            printf '| LINEAR_API_KEY | %s | length=%d |\n' \
                "$(status_emoji_for ok)" "${#LINEAR_API_KEY}"
        else
            printf '| LINEAR_API_KEY | %s | empty or unset |\n' \
                "$(status_emoji_for fail)"
        fi
        printf '\n'
        if (( ${#missing[@]} > 0 )); then
            printf 'Pre-flight FAILED — see operator stderr for copy-paste remediation. '
            printf 'Halting before any Linear mutation (FR-018b).\n\n'
        else
            printf 'Pre-flight green. Proceeding.\n\n'
        fi
    } >> "$REPORT_ABS_PATH"
}

# -----------------------------------------------------------------------------
# status_emoji_for <ok|fail|warn|pending>
#   Map a status label to a stable Markdown-safe glyph. Plain ASCII so
#   markdownlint and downstream tooling don't trip on grapheme width.
# -----------------------------------------------------------------------------
status_emoji_for() {
    case "$1" in
        ok)      printf 'PASS' ;;
        fail)    printf 'FAIL' ;;
        warn)    printf 'WARN' ;;
        pending) printf '...' ;;
        *)       printf '?' ;;
    esac
}

# -----------------------------------------------------------------------------
# status_for_nonempty <value>
#   Emit PASS if the value is non-empty, FAIL otherwise. Used by the
#   Linear verification table to keep the printf calls flat (avoids
#   ShellCheck SC2015 on `A && B || C` patterns).
# -----------------------------------------------------------------------------
status_for_nonempty() {
    if [[ -n "$1" ]]; then
        status_emoji_for ok
    else
        status_emoji_for fail
    fi
}

# -----------------------------------------------------------------------------
# write_header
#   Truncate the report and write the front-matter block. Called once at
#   the start of the run after preflight has CONFIRMED .env loaded.
# -----------------------------------------------------------------------------
write_header() {
    local timestamp branch commit operator_name operator_email
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')"
    commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

    # Best-effort viewer query; fail open so a transient Linear blip doesn't
    # block the rest of the dogfood. The result is also re-queried in Step 4.
    if linear_viewer_probe; then
        operator_name="${LINEAR_VIEWER_NAME:-unknown}"
        operator_email="${LINEAR_VIEWER_EMAIL:-unknown}"
    else
        operator_name="unknown"
        operator_email="unknown"
    fi

    mkdir -p "$(dirname "$REPORT_ABS_PATH")"

    if (( INTERACTIVE_FLOW == 1 )); then
        cat > "$REPORT_ABS_PATH" <<EOF
# Dogfood report: spec-kit-linear interactive install (spec 002 — T262)

**Run**: ${timestamp}
**Operator**: ${operator_name} <${operator_email}>
**Workspace**: ACME
**Team UUID**: ${TEAM_UUID}
**Repo**: ashbrener/spec-kit-linear
**Branch**: ${branch}
**Bridge commit**: ${commit}
**Flags**: dry-run=${DRY_RUN} interactive-flow=1 sandbox-repo=${SANDBOX_REPO:-<temp>}

## Overview

This report captures spec 002's interactive discovery install: driving
\`src/install.sh\`'s prompt state machine (API key → viewer → team pick →
project pick / create-new → seed prompt) with piped-stdin operator picks
against a SANDBOX consumer repo that is a SEPARATE checkout from the
bridge (FR-046 self-install guard forbids source == target — tasks.md
Assumption A12). Findings are appended by \`scripts/dogfood.sh\`.

EOF
        return 0
    fi

    cat > "$REPORT_ABS_PATH" <<EOF
# Dogfood report: spec-kit-linear -> ACME (T077)

**Run**: ${timestamp}
**Operator**: ${operator_name} <${operator_email}>
**Workspace**: ACME
**Team UUID**: ${TEAM_UUID}
**Repo**: ashbrener/spec-kit-linear
**Branch**: ${branch}
**Bridge commit**: ${commit}
**Flags**: dry-run=${DRY_RUN} skip-install=${SKIP_INSTALL} skip-seed=${SKIP_SEED}

## Overview

This report captures the first end-to-end dogfood of the bridge:
installing it into its own repo, seeding the ACME workspace
with the 9 lifecycle workflow states + labels, and reconciling
spec 001 to the resulting Linear Project. Findings are appended to
each section by \`scripts/dogfood.sh\` on each invocation.

EOF
}

# -----------------------------------------------------------------------------
# linear_viewer_probe
#   Read-only Linear GraphQL probe to confirm LINEAR_API_KEY authenticates
#   and identify the operator. Sets LINEAR_VIEWER_NAME and LINEAR_VIEWER_EMAIL.
#   Returns 0 on success, non-zero on transport/auth failure.
# -----------------------------------------------------------------------------
linear_viewer_probe() {
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        return 1
    fi
    local response
    if ! response="$(linear_graphql '{ viewer { name email } }' '{}' 2>/dev/null)"; then
        return 1
    fi
    LINEAR_VIEWER_NAME="$(printf '%s' "$response" | jq -r '.data.viewer.name // empty' 2>/dev/null || printf '')"
    LINEAR_VIEWER_EMAIL="$(printf '%s' "$response" | jq -r '.data.viewer.email // empty' 2>/dev/null || printf '')"
    if [[ -z "$LINEAR_VIEWER_NAME" && -z "$LINEAR_VIEWER_EMAIL" ]]; then
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# linear_graphql <query> <variables-json>
#   Thin curl wrapper. Echoes the raw response body on stdout, returns
#   non-zero only on curl transport failure. GraphQL-level errors are left
#   to the caller to inspect via jq.
# -----------------------------------------------------------------------------
linear_graphql() {
    local query="$1"
    local variables="${2:-{\}}"
    local body
    body="$(jq -nc --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')"
    curl --silent --show-error --fail-with-body \
        --max-time 30 \
        --request POST "$LINEAR_GRAPHQL_ENDPOINT" \
        --header "Authorization: ${LINEAR_API_KEY}" \
        --header "Content-Type: application/json" \
        --data "$body"
}

# -----------------------------------------------------------------------------
# write_section_header <step-number> <title>
#   Helper to keep section formatting consistent.
# -----------------------------------------------------------------------------
write_section_header() {
    local step="$1"
    local title="$2"
    {
        printf '## Step %s — %s\n\n' "$step" "$title"
    } >> "$REPORT_ABS_PATH"
}

# -----------------------------------------------------------------------------
# write_step_outcome <exit-code> <duration-seconds>
#   Append a status footer to a step section.
# -----------------------------------------------------------------------------
write_step_outcome() {
    local code="$1"
    local duration="$2"
    local glyph
    if (( code == 0 )); then
        glyph="$(status_emoji_for ok)"
    else
        glyph="$(status_emoji_for fail)"
    fi
    {
        printf '\n**Outcome**: %s (exit %s) — duration %ss\n\n' "$glyph" "$code" "$duration"
    } >> "$REPORT_ABS_PATH"
}

# -----------------------------------------------------------------------------
# run_install
#   Step 1 — bash src/install.sh --dev --auto-create --team <UUID>
#            --non-interactive --with-action
#
#   install.sh does NOT accept --dry-run as of this commit. Under --dry-run
#   we skip the install entirely with a logged warning so seed/reconcile
#   still get their dry-run signal exercised.
# -----------------------------------------------------------------------------
run_install() {
    if (( SKIP_INSTALL == 1 )); then
        {
            printf '## Step 1 — Install ceremony\n\n'
            printf '_Skipped via --skip-install._\n\n'
        } >> "$REPORT_ABS_PATH"
        log "step 1 (install) skipped"
        return 0
    fi
    if (( DRY_RUN == 1 )); then
        warn "src/install.sh does not support --dry-run; skipping install under --dry-run. Use --skip-install to make this explicit."
        {
            printf '## Step 1 — Install ceremony\n\n'
            printf '_Skipped because --dry-run was passed and src/install.sh does not currently support --dry-run._\n\n'
        } >> "$REPORT_ABS_PATH"
        return 0
    fi

    write_section_header 1 "Install ceremony"
    local install_cmd
    install_cmd="bash src/install.sh --dev --auto-create --team ${TEAM_UUID} --non-interactive --with-action"
    {
        printf 'Command: %s%s%s\n\n' '`' "$install_cmd" '`'
        printf '%s\n' '```text'
    } >> "$REPORT_ABS_PATH"

    local start_ts end_ts
    start_ts="$(date +%s)"
    set +e
    (
        cd "$REPO_ROOT" && \
        bash src/install.sh \
            --dev \
            --auto-create \
            --team "$TEAM_UUID" \
            --non-interactive \
            --with-action
    ) >> "$REPORT_ABS_PATH" 2>&1
    INSTALL_EXIT=$?
    set -e
    end_ts="$(date +%s)"
    INSTALL_DURATION=$(( end_ts - start_ts ))

    printf '```\n' >> "$REPORT_ABS_PATH"
    write_step_outcome "$INSTALL_EXIT" "$INSTALL_DURATION"

    if (( INSTALL_EXIT != 0 )); then
        write_failure_section "Step 1 (install)" "$INSTALL_EXIT" \
            "Inspect src/install.sh logs above. Common causes: --non-interactive without a valid --team UUID, .specify/extensions.yml malformed, gh CLI not authenticated."
        log "install failed (exit $INSTALL_EXIT)"
        exit 3
    fi
    log "install ok in ${INSTALL_DURATION}s"
}

# -----------------------------------------------------------------------------
# run_seed
#   Step 2 — bash src/seed.sh --team <UUID> [--dry-run]
#
#   Per FR-021 this is idempotent: re-running writes the same UUIDs. We use
#   --workspace-only here because the install (Step 1) is what owns writing
#   linear-config.yml; the seed just needs to mutate workspace state.
# -----------------------------------------------------------------------------
run_seed() {
    if (( SKIP_SEED == 1 )); then
        {
            printf '## Step 2 — Workspace seed\n\n'
            printf '_Skipped via --skip-seed._\n\n'
        } >> "$REPORT_ABS_PATH"
        log "step 2 (seed) skipped"
        return 0
    fi

    write_section_header 2 "Workspace seed"
    local cmd_label
    if (( DRY_RUN == 1 )); then
        cmd_label="bash src/seed.sh --team ${TEAM_UUID} --dry-run"
    else
        cmd_label="bash src/seed.sh --team ${TEAM_UUID}"
    fi
    {
        printf 'Command: %s%s%s\n\n' '`' "$cmd_label" '`'
        printf '%s\n' '```text'
    } >> "$REPORT_ABS_PATH"

    local start_ts end_ts
    start_ts="$(date +%s)"
    set +e
    if (( DRY_RUN == 1 )); then
        (
            cd "$REPO_ROOT" && \
            bash src/seed.sh --team "$TEAM_UUID" --dry-run
        ) >> "$REPORT_ABS_PATH" 2>&1
    else
        (
            cd "$REPO_ROOT" && \
            bash src/seed.sh --team "$TEAM_UUID"
        ) >> "$REPORT_ABS_PATH" 2>&1
    fi
    SEED_EXIT=$?
    set -e
    end_ts="$(date +%s)"
    SEED_DURATION=$(( end_ts - start_ts ))

    printf '```\n' >> "$REPORT_ABS_PATH"
    write_step_outcome "$SEED_EXIT" "$SEED_DURATION"

    if (( SEED_EXIT != 0 )); then
        write_failure_section "Step 2 (seed)" "$SEED_EXIT" \
            "Inspect src/seed.sh logs above. Per FR-021 the seed is idempotent; transient 5xx from Linear is the most common cause — re-run. Workspace-level halts (exit 2) usually mean the team UUID is wrong or linear-config.yml is malformed."
        log "seed failed (exit $SEED_EXIT)"
        exit 3
    fi
    log "seed ok in ${SEED_DURATION}s"
}

# -----------------------------------------------------------------------------
# run_reconcile
#   Step 3 — bash src/reconcile.sh --spec 001 [--dry-run]
# -----------------------------------------------------------------------------
run_reconcile() {
    write_section_header 3 "Reconcile spec 001 -> Linear"
    local cmd_label
    if (( DRY_RUN == 1 )); then
        cmd_label="bash src/reconcile.sh --spec 001 --dry-run"
    else
        cmd_label="bash src/reconcile.sh --spec 001"
    fi
    {
        printf 'Command: %s%s%s\n\n' '`' "$cmd_label" '`'
        printf '%s\n' '```text'
    } >> "$REPORT_ABS_PATH"

    local start_ts end_ts
    start_ts="$(date +%s)"
    set +e
    if (( DRY_RUN == 1 )); then
        (
            cd "$REPO_ROOT" && \
            bash src/reconcile.sh --spec 001 --dry-run
        ) >> "$REPORT_ABS_PATH" 2>&1
    else
        (
            cd "$REPO_ROOT" && \
            bash src/reconcile.sh --spec 001
        ) >> "$REPORT_ABS_PATH" 2>&1
    fi
    RECONCILE_EXIT=$?
    set -e
    end_ts="$(date +%s)"
    RECONCILE_DURATION=$(( end_ts - start_ts ))

    printf '```\n' >> "$REPORT_ABS_PATH"
    write_step_outcome "$RECONCILE_EXIT" "$RECONCILE_DURATION"

    if (( RECONCILE_EXIT != 0 )); then
        write_failure_section "Step 3 (reconcile)" "$RECONCILE_EXIT" \
            "Inspect src/reconcile.sh logs above. Exit 2 means halt-for-config (e.g. workspace not seeded — FR-022). Exit 1 means partial failure; some spec mutations landed. Exit 3 is transport failure."
        log "reconcile failed (exit $RECONCILE_EXIT)"
        exit 3
    fi
    log "reconcile ok in ${RECONCILE_DURATION}s"
}

# -----------------------------------------------------------------------------
# run_linear_verification
#   Step 4 — query Linear to confirm the spec-kit-linear Project + ACM-1
#   Issue exist with the expected labels and workflow state.
# -----------------------------------------------------------------------------
run_linear_verification() {
    write_section_header 4 "Linear verification"

    if (( DRY_RUN == 1 )); then
        {
            printf '_Skipped under --dry-run (no mutations fired, so nothing to verify)._\n\n'
        } >> "$REPORT_ABS_PATH"
        log "step 4 (linear verification) skipped under --dry-run"
        return 0
    fi

    # shellcheck disable=SC2016 # GraphQL literal: $teamId is a GraphQL variable, not a shell var.
    # Linear's schema uses ID for UUID lookups — passing String! to a
    # filter that expects ID! fails with GRAPHQL_VALIDATION_FAILED.
    local project_query='query($teamId: ID!) {
      projects(filter: { accessibleTeams: { id: { eq: $teamId } } }, first: 50) {
        nodes { id name url state }
      }
    }'
    local project_vars
    project_vars="$(jq -nc --arg t "$TEAM_UUID" '{teamId: $t}')"

    local project_response
    if ! project_response="$(linear_graphql "$project_query" "$project_vars" 2>&1)"; then
        warn "Linear project query failed: ${project_response}"
        LINEAR_PROJECT_OK="fail"
        {
            printf '| Check | Status | Detail |\n'
            printf '|---|---|---|\n'
            printf '| Project exists | %s | transport failure |\n' "$(status_emoji_for fail)"
            printf '\n'
        } >> "$REPORT_ABS_PATH"
        exit 4
    fi

    local project_node
    project_node="$(printf '%s' "$project_response" \
        | jq -c '.data.projects.nodes[]? | select(.name == "spec-kit-linear")' \
        | head -1)"
    local project_url=""
    if [[ -n "$project_node" ]]; then
        LINEAR_PROJECT_OK="ok"
        project_url="$(printf '%s' "$project_node" | jq -r '.url // empty')"
    else
        LINEAR_PROJECT_OK="fail"
    fi

    # Issue probe — look up by team + by speckit-spec:001 label OR title fragment.
    # shellcheck disable=SC2016 # GraphQL literal: $teamId is a GraphQL variable, not a shell var.
    # ID! (not String!) — Linear schema uses ID for UUID filters.
    local issue_query='query($teamId: ID!) {
      issues(
        filter: {
          team: { id: { eq: $teamId } }
          labels: { name: { eq: "speckit-spec:001" } }
        },
        first: 5
      ) {
        nodes {
          id
          identifier
          title
          url
          state { name type }
          labels { nodes { name } }
        }
      }
    }'
    local issue_response
    if ! issue_response="$(linear_graphql "$issue_query" "$project_vars" 2>&1)"; then
        warn "Linear issue query failed: ${issue_response}"
        LINEAR_ISSUE_OK="fail"
    fi

    local issue_node identifier title state_name state_type labels_csv
    issue_node="$(printf '%s' "${issue_response:-}" \
        | jq -c '.data.issues.nodes[0] // empty' 2>/dev/null || printf '')"
    if [[ -n "$issue_node" && "$issue_node" != "null" ]]; then
        LINEAR_ISSUE_OK="ok"
        identifier="$(printf '%s' "$issue_node" | jq -r '.identifier // empty')"
        title="$(printf '%s' "$issue_node" | jq -r '.title // empty')"
        state_name="$(printf '%s' "$issue_node" | jq -r '.state.name // empty')"
        state_type="$(printf '%s' "$issue_node" | jq -r '.state.type // empty')"
        labels_csv="$(printf '%s' "$issue_node" | jq -r '[.labels.nodes[].name] | join(", ")')"
        LINEAR_ISSUE_URL="$(printf '%s' "$issue_node" | jq -r '.url // empty')"
    else
        LINEAR_ISSUE_OK="fail"
        identifier=""
        title=""
        state_name=""
        state_type=""
        labels_csv=""
    fi

    local title_status state_status labels_status
    title_status="$(status_for_nonempty "$title")"
    state_status="$(status_for_nonempty "$state_name")"
    labels_status="$(status_for_nonempty "$labels_csv")"

    {
        printf '| Check | Status | Detail |\n'
        printf '|---|---|---|\n'
        printf '| Project "spec-kit-linear" exists on team %s | %s | %s |\n' \
            "$TEAM_UUID" \
            "$(status_emoji_for "$LINEAR_PROJECT_OK")" \
            "${project_url:-not found}"
        printf '| Issue with label %sspeckit-spec:001%s exists | %s | %s |\n' \
            '`' '`' \
            "$(status_emoji_for "$LINEAR_ISSUE_OK")" \
            "${identifier:-not found}"
        printf '| Issue title | %s | %s |\n' \
            "$title_status" "${title:-not found}"
        printf '| Issue workflow state | %s | %s (%s) |\n' \
            "$state_status" "${state_name:-unknown}" "${state_type:-unknown}"
        printf '| Issue labels | %s | %s |\n' \
            "$labels_status" "${labels_csv:-none}"
        printf '\n'
    } >> "$REPORT_ABS_PATH"

    if [[ "$LINEAR_PROJECT_OK" != "ok" || "$LINEAR_ISSUE_OK" != "ok" ]]; then
        write_failure_section "Step 4 (Linear verification)" "4" \
            "The reconcile reported success but Linear does not show the expected Project or Issue. Check the workspace via https://linear.app/acme and confirm the team UUID matches ACME."
        log "linear verification failed"
        exit 4
    fi
    log "linear verification ok"
}

# -----------------------------------------------------------------------------
# write_summary
#   Final section — overall pass/fail, total wall-clock, warnings, Linear URL.
# -----------------------------------------------------------------------------
write_summary() {
    local end_ts total
    end_ts="$(date +%s)"
    total=$(( end_ts - TOTAL_START_TS ))

    local overall
    if (( INSTALL_EXIT == 0 && SEED_EXIT == 0 && RECONCILE_EXIT == 0 )) \
        && [[ "$LINEAR_PROJECT_OK" != "fail" && "$LINEAR_ISSUE_OK" != "fail" ]]; then
        overall="$(status_emoji_for ok)"
    else
        overall="$(status_emoji_for fail)"
    fi

    if (( INTERACTIVE_FLOW == 1 )); then
        # The interactive flow tracks its own outcome inline via
        # write_step_outcome; reaching here means it did not exit non-zero.
        {
            printf '## Summary\n\n'
            printf '| Field | Value |\n'
            printf '|---|---|\n'
            printf '| Overall | %s |\n' "$(status_emoji_for ok)"
            printf '| Total wall-clock | %ss |\n' "$total"
            printf '| Mode | interactive discovery (T262) |\n'
            printf '| Sandbox repo | %s |\n' "${SANDBOX_REPO:-<temp> (provisioned + torn down)}"
            printf '\n'
            if [[ -n "$WARNINGS" ]]; then
                printf '### Warnings\n\n'
                local iw
                while IFS= read -r iw; do
                    [[ -z "$iw" ]] && continue
                    printf '- %s\n' "$iw"
                done <<< "$WARNINGS"
                printf '\n'
            fi
            printf '## Rough edges & follow-ups\n\n'
            printf '<!-- Operator-authored after run: SC-009 2-min budget, SC-010 zero-UUID surface, picker UX. -->\n'
        } >> "$REPORT_ABS_PATH"
        return 0
    fi

    {
        printf '## Summary\n\n'
        printf '| Field | Value |\n'
        printf '|---|---|\n'
        printf '| Overall | %s |\n' "$overall"
        printf '| Total wall-clock | %ss |\n' "$total"
        printf '| Step 1 (install) | exit %s in %ss |\n' "$INSTALL_EXIT" "$INSTALL_DURATION"
        printf '| Step 2 (seed) | exit %s in %ss |\n' "$SEED_EXIT" "$SEED_DURATION"
        printf '| Step 3 (reconcile) | exit %s in %ss |\n' "$RECONCILE_EXIT" "$RECONCILE_DURATION"
        printf '| Step 4 (Linear verify) | project=%s issue=%s |\n' \
            "$LINEAR_PROJECT_OK" "$LINEAR_ISSUE_OK"
        if [[ -n "$LINEAR_ISSUE_URL" ]]; then
            printf '| Linear spec Issue | <%s> |\n' "$LINEAR_ISSUE_URL"
        fi
        printf '\n'
        if [[ -n "$WARNINGS" ]]; then
            printf '### Warnings\n\n'
            local w
            while IFS= read -r w; do
                [[ -z "$w" ]] && continue
                printf '- %s\n' "$w"
            done <<< "$WARNINGS"
            printf '\n'
        fi
        printf '## Rough edges & follow-ups\n\n'
        printf '<!-- Operator-authored after run: what worked, what surprised, what needs polishing in v0.1.x. -->\n'
    } >> "$REPORT_ABS_PATH"
}

# -----------------------------------------------------------------------------
# write_failure_section <step-label> <exit-code> <hint>
#   Append a `## Failure` section to the report, then exit. Caller is
#   responsible for the final `exit` so the exit code maps correctly.
# -----------------------------------------------------------------------------
write_failure_section() {
    local step="$1"
    local code="$2"
    local hint="$3"
    {
        printf '\n## Failure\n\n'
        printf '**Failing step**: %s\n\n' "$step"
        printf '**Exit code**: %s\n\n' "$code"
        printf '**Hint**: %s\n\n' "$hint"
        printf 'See the corresponding step section above for the full transcript.\n\n'
    } >> "$REPORT_ABS_PATH"
}

# =============================================================================
# T262 — spec-002 interactive-discovery flow
#
# Drives src/install.sh's interactive state machine (S1 API key -> S2 viewer
# -> S3 team pick -> S4 project pick / S5 create-new -> T063 seed prompt) by
# piping the operator's picks on stdin against a SANDBOX consumer repo that is
# a SEPARATE checkout from the bridge. This separation is mandatory: FR-046's
# self-install guard (install::detect_self_install) halts exit 2 when SOURCE
# (the bridge) == TARGET, so the dogfood MUST install into another repo
# (tasks.md Assumption A12 + plan.md A12).
#
# Like the rest of dogfood.sh this is operator-run, NOT a CI step. The live
# install only fires when neither --dry-run nor --skip-install is set; under
# --dry-run the block reports the planned invocation + scripted stdin and
# performs NO Linear mutation, so CI / `bash -n` / shellcheck can exercise the
# code path without a key.
# =============================================================================

# -----------------------------------------------------------------------------
# cleanup_interactive_sandbox
#   EXIT-trap callback. Removes the throwaway sandbox repo the flow created
#   (only when the script provisioned it — an operator-supplied
#   --sandbox-repo is never deleted; Principle VIII operator consent).
# -----------------------------------------------------------------------------
cleanup_interactive_sandbox() {
    if [[ -n "$INTERACTIVE_SANDBOX_TMP" && -d "$INTERACTIVE_SANDBOX_TMP" ]]; then
        rm -rf "$INTERACTIVE_SANDBOX_TMP"
        log "removed throwaway sandbox repo at ${INTERACTIVE_SANDBOX_TMP}"
    fi
}

# -----------------------------------------------------------------------------
# provision_sandbox_repo
#   Resolve the sandbox consumer repo the interactive install targets.
#   - --sandbox-repo DIR supplied: canonicalise it, assert it is NOT the
#     bridge root (mirror of FR-046 — fail before install rather than rely on
#     the guard), and reuse it as-is.
#   - omitted: mkdir a throwaway repo under TMPDIR, `git init` it, and lay
#     down the minimal `.specify/` skeleton a consumer repo needs so the
#     install's preflight (`.specify/` present) passes.
#   Echoes the absolute sandbox path on stdout.
# -----------------------------------------------------------------------------
provision_sandbox_repo() {
    local sandbox
    if [[ -n "$SANDBOX_REPO" ]]; then
        if [[ ! -d "$SANDBOX_REPO" ]]; then
            die 2 "--sandbox-repo path does not exist: ${SANDBOX_REPO}"
        fi
        sandbox="$(cd "$SANDBOX_REPO" && pwd -P)"
        # FR-046 mirror: refuse source == target before invoking install.
        if [[ "$sandbox" == "$REPO_ROOT" ]]; then
            die 2 "--sandbox-repo resolves to the bridge's own checkout (${REPO_ROOT}); FR-046 self-install guard forbids source == target. Point --sandbox-repo at a separate consumer repo."
        fi
        printf '%s\n' "$sandbox"
        return 0
    fi

    # No sandbox supplied — provision a throwaway under TMPDIR.
    local tmp_base="${TMPDIR:-/tmp}"
    INTERACTIVE_SANDBOX_TMP="$(mktemp -d "${tmp_base%/}/dogfood-002-sandbox.XXXXXX")"
    sandbox="$(cd "$INTERACTIVE_SANDBOX_TMP" && pwd -P)"
    (
        cd "$sandbox" || exit 5
        git init --quiet
        # Minimal consumer-repo skeleton so install preflight's `.specify/`
        # check passes. A real `specify init` would lay down more; the
        # install only requires the directory to exist + be writable.
        mkdir -p .specify/extensions
        printf 'extensions: {}\n' > .specify/extensions.yml
        printf '# dogfood-002 sandbox consumer repo\n' > README.md
        git add -A >/dev/null 2>&1 || true
        git -c user.email=dogfood@example.com -c user.name=dogfood \
            commit --quiet -m "chore: dogfood-002 sandbox skeleton" >/dev/null 2>&1 || true
    )
    log "provisioned throwaway sandbox repo at ${sandbox}"
    printf '%s\n' "$sandbox"
}

# -----------------------------------------------------------------------------
# build_interactive_stdin
#   Compose the newline-separated operator picks fed to src/install.sh's
#   prompts, in the exact order the install reads them:
#     1. API key prompt (S1) — SKIPPED here: per A12 the key is already in the
#        sandbox's .env (priority 2 of FR-037), so install::prompt_for_api_key
#        returns before reading stdin. No line emitted.
#     2. Team pick (S3, FR-039) — `1` selects the first team. A single-team
#        workspace auto-picks and reads NO line; we still emit `1` because a
#        surplus stdin line is harmless (the next reader consumes it).
#     3a. Existing-project attach (S4, FR-040): omitted here — the
#         create-new path is the default so the projectCreate mutation
#         (FR-041) is exercised. When --interactive-project is set the
#         project picker is short-circuited by --project on the CLI, so no
#         project-pick line is emitted either way.
#     3b. Create-new project (S5, FR-041): pick the "Create new project"
#         tail, accept the repo-basename default name (blank line), and
#         confirm with `Y`.
#     4. Seed prompt (T063, FR-022): `n` defers the inline seed so the
#        dogfood does not mutate workspace state during the picker exercise;
#        dogfood-001 owns the seed+reconcile leg.
#   The T064 Action prompt is removed from the stdin sequence by passing
#   --no-action on the CLI (keeps the scripted stdin deterministic).
# -----------------------------------------------------------------------------
build_interactive_stdin() {
    if [[ -n "$INTERACTIVE_PROJECT_UUID" ]]; then
        # --project short-circuits S4; only the team pick + seed answer remain.
        printf '1\n'      # S3 team pick
        printf 'n\n'      # T063 seed prompt: defer
    else
        printf '1\n'      # S3 team pick
        printf '1\n'      # S4: select the "Create new project" tail
        printf '\n'       # S5: accept repo-basename default project name
        printf 'Y\n'      # S5: confirm projectCreate
        printf 'n\n'      # T063 seed prompt: defer
    fi
}

# -----------------------------------------------------------------------------
# run_interactive_flow
#   The T262 block. Provisions/validates the sandbox repo, composes the
#   install invocation + scripted stdin, and (live runs only) drives the
#   interactive install, capturing the transcript into the report.
# -----------------------------------------------------------------------------
run_interactive_flow() {
    local sandbox
    sandbox="$(provision_sandbox_repo)"

    write_section_header 1 "Interactive discovery install (spec 002 — T262)"

    # Compose the install flags. --dev installs from the bridge checkout;
    # --no-action removes the T064 prompt from the stdin sequence. --team is
    # passed so the dogfood targets the known ACME team deterministically
    # while STILL exercising the project picker / create-new path. When
    # --interactive-project is set, --project short-circuits S4 (FR-044).
    local -a install_flags
    install_flags=(--dev "$REPO_ROOT" --team "$TEAM_UUID" --no-action)
    if [[ -n "$INTERACTIVE_PROJECT_UUID" ]]; then
        install_flags+=(--project "$INTERACTIVE_PROJECT_UUID")
    fi

    local install_cmd
    install_cmd="bash ${REPO_ROOT}/src/install.sh ${install_flags[*]}"

    local stdin_script
    stdin_script="$(build_interactive_stdin)"

    {
        printf 'Sandbox consumer repo: %s%s%s\n\n' '`' "$sandbox" '`'
        printf 'Command (run from the sandbox repo cwd):\n\n'
        printf '%s\n' '```bash'
        printf '%s\n' "$install_cmd"
        printf '%s\n\n' '```'
        printf 'Scripted operator picks piped on stdin (FR-037/039/040/041/022):\n\n'
        printf '%s\n' '```text'
        printf '%s\n' "$stdin_script"
        printf '%s\n\n' '```'
    } >> "$REPORT_ABS_PATH"

    if (( DRY_RUN == 1 )); then
        warn "interactive-flow under --dry-run: NOT invoking src/install.sh (no live install / no Linear mutation). The planned command + scripted stdin are recorded above."
        {
            printf '_Skipped the live install under --dry-run. '
            printf 'Re-run without --dry-run (and with a sandbox repo carrying '
            printf 'LINEAR_API_KEY in its .env) to drive the interactive flow._\n\n'
        } >> "$REPORT_ABS_PATH"
        log "interactive-flow dry-run: live install skipped"
        return 0
    fi

    {
        printf 'Live transcript:\n\n'
        printf '%s\n' '```text'
    } >> "$REPORT_ABS_PATH"

    local start_ts end_ts duration exit_code
    start_ts="$(date +%s)"
    set +e
    (
        cd "$sandbox" \
            && build_interactive_stdin | bash "${REPO_ROOT}/src/install.sh" "${install_flags[@]}"
    ) >> "$REPORT_ABS_PATH" 2>&1
    exit_code=$?
    set -e
    end_ts="$(date +%s)"
    duration=$(( end_ts - start_ts ))

    printf '```\n' >> "$REPORT_ABS_PATH"
    write_step_outcome "$exit_code" "$duration"

    if (( exit_code != 0 )); then
        write_failure_section "Interactive discovery install (T262)" "$exit_code" \
            "Inspect the transcript above. Exit 2 is usually a missing LINEAR_API_KEY in the sandbox repo's .env (S1/FR-037) or the FR-046 self-install guard firing (sandbox == bridge). Exit 1 is a projectCreate failure (FR-041) — Linear surfaced the verbatim error. Confirm the sandbox repo carries .env with a valid key and is a SEPARATE checkout from the bridge."
        log "interactive-flow install failed (exit ${exit_code})"
        exit 3
    fi
    log "interactive-flow install ok in ${duration}s"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    resolve_repo_root
    load_env_file
    resolve_team_uuid

    TOTAL_START_TS="$(date +%s)"

    if (( INTERACTIVE_FLOW == 1 )); then
        trap cleanup_interactive_sandbox EXIT
        write_header
        preflight
        run_interactive_flow
        write_summary
        log "dogfood report written to ${REPORT_ABS_PATH}"
        return 0
    fi

    # Truncate + header BEFORE preflight so the preflight section has a
    # file to append to.
    write_header
    preflight

    run_install
    run_seed
    run_reconcile
    run_linear_verification
    write_summary

    log "dogfood report written to ${REPORT_ABS_PATH}"
}

main "$@"
