#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/dogfood.sh — End-to-end dogfood driver for spec-kit-linear (T077).
#
# Chains src/install.sh -> src/seed.sh -> src/reconcile.sh --spec 001 against
# the operator's OSH-INFRA Linear workspace (or any team UUID passed via
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
#   - validation/linear-workspace-probe.md (default OSH team UUID)
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

# Default team UUID — OSH-INFRA per validation/linear-workspace-probe.md.
# Override with --team for other workspaces. Team key 'OSH', urlKey 'osh-infra'.
readonly DEFAULT_TEAM_UUID="6ab43461-6d22-4f02-bb1e-0be9859c7997"
readonly DEFAULT_REPORT_PATH="validation/dogfood-001.md"
readonly LINEAR_GRAPHQL_ENDPOINT="https://api.linear.app/graphql"

# Required preflight binaries. Bash 4+ is checked separately (version-sensitive).
readonly -a REQUIRED_BINARIES=(curl jq git gh)

# -----------------------------------------------------------------------------
# Mutable globals (populated by parse_args / preflight / run_*).
# -----------------------------------------------------------------------------

TEAM_UUID="$DEFAULT_TEAM_UUID"
REPORT_PATH="$DEFAULT_REPORT_PATH"
DRY_RUN=0
SKIP_INSTALL=0
SKIP_SEED=0

REPO_ROOT=""
REPORT_ABS_PATH=""

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
  --team UUID       Linear Team UUID to target. Default: OSH-INFRA
                    (6ab43461-6d22-4f02-bb1e-0be9859c7997 per
                    validation/linear-workspace-probe.md).
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

    cat > "$REPORT_ABS_PATH" <<EOF
# Dogfood report: spec-kit-linear -> OSH-INFRA (T077)

**Run**: ${timestamp}
**Operator**: ${operator_name} <${operator_email}>
**Workspace**: OSH-INFRA
**Team UUID**: ${TEAM_UUID}
**Repo**: ashbrener/spec-kit-linear
**Branch**: ${branch}
**Bridge commit**: ${commit}
**Flags**: dry-run=${DRY_RUN} skip-install=${SKIP_INSTALL} skip-seed=${SKIP_SEED}

## Overview

This report captures the first end-to-end dogfood of the bridge:
installing it into its own repo, seeding the OSH-INFRA workspace
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
#   Step 4 — query Linear to confirm the spec-kit-linear Project + OSH-1
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
    local project_query='query($teamId: String!) {
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
    local issue_query='query($teamId: String!) {
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
            "The reconcile reported success but Linear does not show the expected Project or Issue. Check the workspace via https://linear.app/osh-infra and confirm the team UUID matches OSH-INFRA."
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

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    resolve_repo_root
    load_env_file

    TOTAL_START_TS="$(date +%s)"

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
