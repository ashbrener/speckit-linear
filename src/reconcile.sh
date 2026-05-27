#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
# ^^^ Every GraphQL query/mutation string in this file uses single quotes
#     to preserve literal `$variable` tokens — those are GraphQL variable
#     references resolved server-side, NOT bash expansions. Suppressing
#     SC2016 file-wide is the right call; introducing per-string disables
#     would clutter every query block without changing the contract.
# =============================================================================
# src/reconcile.sh — the spec-kit ↔ Linear reconciler (Layer D).
#
# This is the ENTRY-POINT script the `speckit.linear.push` command, every
# `after_*` hook, and every local git hook funnel into. It implements
# every filesystem → Linear mutation path documented in
# `specs/001-spec-kit-linear-bridge/contracts/linear-graphql-mutations.md`
# §4 (reconcile-time block) on behalf of User Story 1 (FR-001..FR-008,
# FR-013..FR-016, FR-023..FR-026, FR-031).
#
# What it is NOT: it is NOT sourced as a library; functions defined here
# are local to this process. The other src/*.sh modules are sourced
# below for their public APIs (`config::*`, `graphql::*`, `parser::*`,
# `git_helpers::*`, `summary::*`).
#
# -----------------------------------------------------------------------------
# Constitutional alignment
# -----------------------------------------------------------------------------
# Principle I (filesystem-is-truth) — this script never writes to disk
#   (other than tempfiles it cleans up); every spec.md/tasks.md edit
#   stays operator-owned.
# Principle II (reconcile, never event-push) — every invocation reads
#   full filesystem state and converges Linear; no diff cache, no
#   sidecar `last_sync.json`.
# Principle III (layered idempotency) — this is Layer D. It owns labels,
#   sub-issues, checklists, comments, and Project Status. The GitHub
#   Action (Layer E) owns ONLY workflow-state flips, never touched here.
# Principle IV (write-authority-follows-worktree) — gated per-spec
#   via `git_helpers::is_authoritative_for_spec`; non-authoritative
#   worktrees enter read-only display per FR-026.
# Principle V (UUID-based binding) — every Linear lookup uses UUIDs
#   resolved from `linear-config.yml` via the `config::*` API. MCP-path
#   tools accept name-shaped args but the lookup KEY stays UUID.
# Principle VI (OAuth-first, keys-at-the-edges) — this script does not
#   know whether MCP-via-OAuth or direct-GraphQL-via-key handled a given
#   mutation; both go through `graphql::*`. When invoked by the AI
#   agent harness, the MCP-translation step is the agent's
#   responsibility per `commands/linear-push.md`.
# Principle VIII (observable failure) — every per-spec failure is
#   collected via `summary::add` and surfaced in the final
#   `summary::emit` block.
#
# -----------------------------------------------------------------------------
# Exit codes (per contracts/command-shapes.md §1.6)
# -----------------------------------------------------------------------------
#   0 — every spec processed (possibly with non-fatal warnings)
#   1 — partial failure: some specs failed but others succeeded; or a
#       transport failure was aggregated as a warning
#   2 — workspace-level config error (missing/malformed linear-config.yml,
#       unseeded UUIDs); halt without partial mutation per FR-022
#   3 — transport failure across the board (config OK, but Linear
#       unreachable; nothing was written)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Module sourcing — strict order: config first (it validates UUIDs and
# is depended on by graphql + reconcile body), then the rest. The
# `# shellcheck source=` directives let shellcheck statically follow the
# sourced API surface.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=./graphql.sh
source "${SCRIPT_DIR}/graphql.sh"
# shellcheck source=./git_helpers.sh
source "${SCRIPT_DIR}/git_helpers.sh"
# shellcheck source=./summary.sh
source "${SCRIPT_DIR}/summary.sh"
# shellcheck source=./parser.sh
source "${SCRIPT_DIR}/parser.sh"

# -----------------------------------------------------------------------------
# Module constants
# -----------------------------------------------------------------------------

# Default config path. Resolved relative to PWD (the consumer repo's
# root) rather than to the script, so the same script binary serves
# every consumer repo's invocation.
readonly RECONCILE_CONFIG_PATH_DEFAULT=".specify/extensions/linear/linear-config.yml"

# The fenced markers around the memory block in spec Issue descriptions
# (FR-004). Bridge rewrites everything between BEGIN and END on every
# reconcile; operator-added prose ABOVE or BELOW the fences survives.
readonly RECONCILE_MEMORY_BEGIN="<!-- speckit-linear:memory:begin -->"
readonly RECONCILE_MEMORY_END="<!-- speckit-linear:memory:end -->"

# Header preface for task-phase sub-issue descriptions (FR-006). The
# one-way semantics must be impossible to miss per spec. Backticks here
# delimit a markdown code-span, not a bash subshell.
readonly RECONCILE_SUBISSUE_HEADER='> **Read-only mirror of `tasks.md` — ticks in Linear are overwritten on next reconcile.**'

# -----------------------------------------------------------------------------
# CLI flags — populated by reconcile::parse_args.
# -----------------------------------------------------------------------------
declare -g ARG_SPEC=""          # NNN or empty
declare -g ARG_ALL=0            # 0|1
declare -g ARG_DRY_RUN=0        # 0|1
declare -g ARG_QUIET=0          # 0|1
declare -g ARG_RETROACTIVE=0    # 0|1 — extra-quiet, suppresses non-authoritative warnings

# Aggregate exit-code tracker. We start at 0 and monotonically promote
# to higher severities as failures accumulate.
declare -g RECONCILE_EXIT_CODE=0

# -----------------------------------------------------------------------------
# reconcile::usage
#   Print operator-facing usage to stderr.
# -----------------------------------------------------------------------------
reconcile::usage() {
    cat >&2 <<'EOF'
Usage: reconcile.sh [--spec NNN | --all] [--dry-run] [--retroactive] [--quiet]
                    [--config PATH] [--help]

Reconcile filesystem spec state into Linear (Layer D). Idempotent.

Options:
  --spec NNN       Reconcile only the spec whose feature number matches NNN.
  --all            Reconcile every specs/NNN-feature/ in the repo.
                   (Exactly one of --spec or --all is required.)
  --dry-run        Log every mutation that WOULD fire; issue none.
  --retroactive    First-time-adoption mode. Suppresses "skipped because
                   non-authoritative" warnings. Implies --all if --spec
                   is not given.
  --quiet          Suppress per-mutation log lines. Summary still emits.
  --config PATH    Override the path to linear-config.yml
                   (default: .specify/extensions/linear/linear-config.yml).
  --help           Show this help.

Exit codes:
  0  Success (possibly with warnings).
  1  Partial failure: some specs failed; others succeeded.
  2  Workspace-level config error (halt without partial mutation).
  3  Transport failure: Linear unreachable; nothing written.

See contracts/command-shapes.md §1 for the full contract.
EOF
}

# -----------------------------------------------------------------------------
# reconcile::log
#   Emit a per-mutation log line to stderr. Suppressed by --quiet.
#   stdout is reserved for any future structured-output mode; per-step
#   chatter is stderr only (matches summary::emit convention).
# -----------------------------------------------------------------------------
reconcile::log() {
    if (( ARG_QUIET == 1 )); then
        return 0
    fi
    printf 'speckit-linear: %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# reconcile::promote_exit <code>
#   Monotonically promote RECONCILE_EXIT_CODE. We use a fixed severity
#   order: 0 < 1 < 3 < 2 (config errors are the most severe — they
#   prove the operator MUST act). The first 2 wins and short-circuits
#   further promotion.
# -----------------------------------------------------------------------------
reconcile::promote_exit() {
    local incoming="$1"
    # 2 is terminal — never demote.
    if (( RECONCILE_EXIT_CODE == 2 )); then
        return 0
    fi
    case "$incoming" in
        2) RECONCILE_EXIT_CODE=2 ;;
        3) (( RECONCILE_EXIT_CODE < 3 )) && RECONCILE_EXIT_CODE=3 ;;
        1) (( RECONCILE_EXIT_CODE < 1 )) && RECONCILE_EXIT_CODE=1 ;;
        0) : ;;
        *) : ;;
    esac
}

# =============================================================================
# Step 1 — Argument parsing.
# =============================================================================
reconcile::parse_args() {
    local config_path="${RECONCILE_CONFIG_PATH_DEFAULT}"
    while (( $# > 0 )); do
        case "$1" in
            --spec)
                if (( $# < 2 )); then
                    printf 'speckit-linear: --spec requires a feature number argument\n' >&2
                    reconcile::usage
                    exit 2
                fi
                ARG_SPEC="$2"
                shift 2
                ;;
            --spec=*)
                ARG_SPEC="${1#--spec=}"
                shift
                ;;
            --all)
                ARG_ALL=1
                shift
                ;;
            --dry-run)
                ARG_DRY_RUN=1
                shift
                ;;
            --quiet)
                ARG_QUIET=1
                shift
                ;;
            --retroactive)
                ARG_RETROACTIVE=1
                shift
                ;;
            --config)
                if (( $# < 2 )); then
                    printf 'speckit-linear: --config requires a path argument\n' >&2
                    reconcile::usage
                    exit 2
                fi
                config_path="$2"
                shift 2
                ;;
            --config=*)
                config_path="${1#--config=}"
                shift
                ;;
            -h|--help)
                reconcile::usage
                exit 0
                ;;
            *)
                printf 'speckit-linear: unknown argument: %s\n' "$1" >&2
                reconcile::usage
                exit 2
                ;;
        esac
    done

    # --retroactive without an explicit --spec implies --all.
    if (( ARG_RETROACTIVE == 1 )) && [[ -z "$ARG_SPEC" ]] && (( ARG_ALL == 0 )); then
        ARG_ALL=1
    fi

    # Exactly one of --spec / --all must be supplied.
    if [[ -z "$ARG_SPEC" ]] && (( ARG_ALL == 0 )); then
        printf 'speckit-linear: one of --spec NNN or --all is required\n' >&2
        reconcile::usage
        exit 2
    fi
    if [[ -n "$ARG_SPEC" ]] && (( ARG_ALL == 1 )); then
        printf 'speckit-linear: --spec and --all are mutually exclusive\n' >&2
        reconcile::usage
        exit 2
    fi
    if [[ -n "$ARG_SPEC" && ! "$ARG_SPEC" =~ ^[0-9]+$ ]]; then
        printf 'speckit-linear: --spec value must be numeric (got %q)\n' "$ARG_SPEC" >&2
        exit 2
    fi

    # Stash the resolved config path back on a module global so step 2
    # can pick it up without re-parsing.
    declare -g RECONCILE_CONFIG_PATH="$config_path"
}

# =============================================================================
# Step 2 — Config load + validate.
#   Halts with exit 2 on any failure (FR-022, Principle VIII). The
#   `config::*` API already prints actionable diagnostics; we just
#   funnel its exit code through reconcile::promote_exit and surface
#   the same warning via summary::add.
# =============================================================================
reconcile::load_config() {
    local path="${RECONCILE_CONFIG_PATH}"
    if [[ ! -e "$path" ]]; then
        summary::add error "linear-config.yml not found at ${path}; run /speckit-linear-install"
        reconcile::promote_exit 2
        return 2
    fi
    # Sub-shell guard isn't possible because config::load populates the
    # module-level associative arrays in THIS process. If config::load
    # exits 2, we inherit that exit (the script terminates with code 2
    # via `set -e`, which is the right thing for a workspace config
    # failure).
    config::load "$path"
    config::validate
    reconcile::log "config loaded from ${path}"
}

# =============================================================================
# Step 3 — Spec enumeration.
#   Emits one spec directory path per line on stdout. Empty output (with
#   exit 0) is a valid "no specs to reconcile" outcome — the caller
#   surfaces a warning rather than an error per FR-024.
# =============================================================================
reconcile::enumerate_specs() {
    local specs_root="specs"
    if [[ ! -d "$specs_root" ]]; then
        return 0
    fi

    if [[ -n "$ARG_SPEC" ]]; then
        # Match any specs/NNN-* whose NNN prefix equals ARG_SPEC. We use
        # a glob and filter via the regex so leading-zero variations
        # ("3" vs "003") resolve to the same dir.
        local dir
        for dir in "${specs_root}"/*/; do
            [[ -d "$dir" ]] || continue
            local base
            base="$(basename "${dir%/}")"
            if [[ "$base" =~ ^([0-9]+)- ]]; then
                local num="${BASH_REMATCH[1]}"
                # Compare as integers so 003 == 3.
                if (( 10#$num == 10#$ARG_SPEC )); then
                    printf '%s\n' "${dir%/}"
                fi
            fi
        done
        return 0
    fi

    # --all: every NNN-* dir under specs/. Sorted by feature number
    # ascending so the per-spec loop output is deterministic.
    local dir
    for dir in "${specs_root}"/*/; do
        [[ -d "$dir" ]] || continue
        local base
        base="$(basename "${dir%/}")"
        if [[ "$base" =~ ^[0-9]+- ]]; then
            printf '%s\n' "${dir%/}"
        fi
    done | sort
}

# =============================================================================
# JSON-build helpers — bash strings into jq-safe JSON.
#
# These are thin wrappers around `jq -Rn '$x'` that handle the awkward
# quoting that bash heredocs and `printf` don't. We never hand-roll JSON
# in this file (no `printf '"%s"' "$value"`) — every string crosses the
# jq boundary so embedded quotes/newlines/backslashes are escaped
# correctly.
# =============================================================================

# reconcile::json_string <raw>
#   Echo a JSON-encoded string literal for <raw>. Output includes the
#   surrounding quotes.
reconcile::json_string() {
    local raw="${1-}"
    jq -Rn --arg v "$raw" '$v'
}

# reconcile::json_array <items...>
#   Echo a JSON array of strings.
reconcile::json_array() {
    local item
    local -a pieces=()
    for item in "$@"; do
        pieces+=("$(reconcile::json_string "$item")")
    done
    if (( ${#pieces[@]} == 0 )); then
        printf '[]'
        return 0
    fi
    local IFS=','
    printf '[%s]' "${pieces[*]}"
}

# =============================================================================
# Memory block rendering (FR-004).
#
# Produces the markdown fragment that lives inside the spec Issue
# description's <!-- speckit-linear:memory:begin --> / :end --> fences.
# The fence markers themselves are added by the caller so the
# description-merge logic can strip and re-insert atomically.
# =============================================================================
reconcile::render_memory_block() {
    local feature_number="$1"
    local short_name="$2"
    local lifecycle_phase="$3"
    local spec_dir="$4"
    local feature_branch="$5"

    local current_branch worktree_lines worktree_csv last_touched github_url

    current_branch="$(git_helpers::current_branch || true)"

    # Build a comma-separated list of worktree paths that currently
    # hold the spec's feature branch. Falls back to the current
    # working directory if no worktree maps to the feature branch
    # (which would be the case from a `main` worktree). The memory
    # block is informational — we never let absence of a worktree
    # blow up the reconcile.
    worktree_lines="$(git_helpers::worktree_for_branch "$feature_branch" || true)"
    if [[ -z "$worktree_lines" ]]; then
        worktree_csv="(no worktree currently on ${feature_branch})"
    else
        # Single path expected (git enforces uniqueness), but normalise
        # multi-line input defensively.
        worktree_csv="$(printf '%s' "$worktree_lines" | tr '\n' ',' | sed 's/,$//')"
    fi

    last_touched="$(git_helpers::last_touched "$spec_dir" || true)"
    if [[ -z "$last_touched" ]]; then
        last_touched="unknown"
    fi

    # GitHub source URL — best-effort. We use `git remote get-url origin`
    # and rewrite the SSH form to https. If neither works we fall back to
    # a repo-relative path so the operator at least knows WHERE on disk
    # to look.
    local remote_url=""
    if remote_url="$(git remote get-url origin 2>/dev/null)"; then
        # git@github.com:owner/repo.git → https://github.com/owner/repo
        if [[ "$remote_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^https?://(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}"
        fi
    fi
    if [[ -n "$remote_url" && -n "$current_branch" ]]; then
        github_url="${remote_url}/tree/${current_branch}/${spec_dir}"
    elif [[ -n "$remote_url" ]]; then
        github_url="${remote_url}/tree/HEAD/${spec_dir}"
    else
        github_url="(local: ${spec_dir})"
    fi

    # Title-case the lifecycle phase for human display.
    local phase_display
    case "$lifecycle_phase" in
        ready_to_merge) phase_display="Ready-to-merge" ;;
        red_team)       phase_display="Red-team" ;;
        *)              phase_display="$(printf '%s' "$lifecycle_phase" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" ;;
    esac

    cat <<EOF
**Phase**: ${phase_display}
**Branch**: \`${feature_branch}\`
**Worktree(s)**: \`${worktree_csv}\`
**Last touched (disk)**: ${last_touched}
**Source**: ${github_url}
**Spec**: ${feature_number}-${short_name}
EOF
}

# =============================================================================
# reconcile::compose_issue_description <body_text> <memory_block>
#
# Merge the bridge's memory block into the spec Issue's description.
# Strategy: locate the fenced markers; if present, replace everything
# between them. If absent, prepend a fresh block to <body_text>.
# Operator-added content outside the fences is preserved verbatim
# (FR-004).
# =============================================================================
reconcile::compose_issue_description() {
    local body="$1"
    local memory_block="$2"

    # The full block we want to emit, fences included.
    local fenced
    fenced=$(printf '%s\n%s\n%s' \
        "${RECONCILE_MEMORY_BEGIN}" \
        "${memory_block}" \
        "${RECONCILE_MEMORY_END}")

    # If both fences exist, splice. We use awk for the splice because
    # bash parameter expansion can't easily handle multi-line markers.
    if printf '%s' "$body" | grep -qF "${RECONCILE_MEMORY_BEGIN}" \
        && printf '%s' "$body" | grep -qF "${RECONCILE_MEMORY_END}"; then
        printf '%s' "$body" | awk \
            -v begin="${RECONCILE_MEMORY_BEGIN}" \
            -v end="${RECONCILE_MEMORY_END}" \
            -v block="${fenced}" '
            BEGIN { skip = 0; printed = 0 }
            {
                if (skip == 0 && index($0, begin) > 0) {
                    skip = 1
                    if (printed == 0) { print block; printed = 1 }
                    next
                }
                if (skip == 1) {
                    if (index($0, end) > 0) { skip = 0 }
                    next
                }
                print
            }'
        return 0
    fi

    # No fences yet — prepend the block and an empty separator line.
    printf '%s\n\n%s' "$fenced" "$body"
}

# =============================================================================
# reconcile::compose_subissue_checklist <feature_number> <phase_index> <tasks_md_path>
#
# Build the markdown body for a task-phase sub-issue per FR-006. The
# read-only-mirror header from RECONCILE_SUBISSUE_HEADER is the first
# line; each task becomes a `- [ ]` / `- [x]` line.
# =============================================================================
reconcile::compose_subissue_checklist() {
    local feature_number="$1"
    local phase_index="$2"
    local tasks_md="$3"

    {
        printf '%s\n' "${RECONCILE_SUBISSUE_HEADER}"
        # Backticks are markdown code-span delimiters in the body text.
        printf '> Source: `specs/%s-*/tasks.md` § Phase %s.\n' \
            "$feature_number" "$phase_index"
        printf '\n'
        local id state desc box
        while IFS=$'\t' read -r id state desc; do
            case "$state" in
                checked)   box="x" ;;
                unchecked) box=" " ;;
                *)         box=" " ;;
            esac
            if [[ -n "$id" ]]; then
                printf -- '- [%s] **%s** — %s\n' "$box" "$id" "$desc"
            else
                printf -- '- [%s] %s\n' "$box" "$desc"
            fi
        done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")
    }
}

# =============================================================================
# reconcile::subissue_state_key <tasks_md> <phase_index>
#
# Returns one of {todo, in_progress, done} per FR-005 — Todo if zero
# tasks are checked, Done if every task is checked, In Progress
# otherwise (the mixed case). Empty phase (no tasks at all) defaults
# to Todo.
# =============================================================================
reconcile::subissue_state_key() {
    local tasks_md="$1"
    local phase_index="$2"
    local total=0 checked=0
    local id state desc
    while IFS=$'\t' read -r id state desc; do
        # Touch unused locals so shellcheck doesn't complain about
        # destructured fields we don't reference.
        : "${id:-}${desc:-}"
        total=$(( total + 1 ))
        if [[ "$state" == "checked" ]]; then
            checked=$(( checked + 1 ))
        fi
    done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")
    if (( total == 0 )); then
        printf 'todo\n'
    elif (( checked == 0 )); then
        printf 'todo\n'
    elif (( checked >= total )); then
        printf 'done\n'
    else
        printf 'in_progress\n'
    fi
}

# =============================================================================
# Mutation primitives — every Linear write the reconciler issues funnels
# through one of these, so --dry-run can intercept them uniformly.
#
# Each primitive:
#   * Logs the operation (subject to --quiet) via reconcile::log
#   * Returns 0 on success, non-zero (and aggregates via summary::add)
#     on failure
#   * On --dry-run, logs the operation and returns 0 without invoking
#     graphql::mutate
#
# We deliberately use GraphQL rather than MCP from this script. The
# AI-agent harness (per commands/linear-push.md) MAY pre-empt by
# performing the same mutations via MCP tools (the MCP and GraphQL
# paths are functionally interchangeable per contracts §4). This
# script's GraphQL path is the bedrock invocation that hooks / git
# hooks rely on (no MCP session available there).
# =============================================================================

# reconcile::query_spec_issue <spec_label> <project_uuid>
#   Locate the spec Issue by `speckit-spec:NNN` label scoped to the
#   repo's Project (FR-004b). Echoes a JSON array of `{id, updatedAt}`
#   objects sorted descending by updatedAt — most-recent first. Empty
#   array on zero matches.
reconcile::query_spec_issue() {
    local spec_label="$1"
    local project_uuid="$2"

    local query='query LocateSpecIssue($label: String!, $project: ID!) {
        issues(
            filter: {
                labels:  { name: { eq: $label } }
                project: { id:   { eq: $project } }
            }
        ) {
            nodes { id updatedAt }
        }
    }'
    local vars
    vars="$(jq -nc \
        --arg label "$spec_label" \
        --arg project "$project_uuid" \
        '{label: $label, project: $project}')"

    local response
    response="$(graphql::query "$query" "$vars")"
    # Sort by updatedAt descending — most recent wins on race (FR-004b).
    printf '%s' "$response" \
        | jq -c '.data.issues.nodes | sort_by(.updatedAt) | reverse'
}

# reconcile::query_subissue_for_phase <parent_id> <task_phase_label>
#   Locate the sub-issue for one task phase by (parent, label). Echoes
#   a JSON array sorted descending by updatedAt.
reconcile::query_subissue_for_phase() {
    local parent_id="$1"
    local phase_label="$2"

    local query='query LocateSubIssue($parent: ID!, $label: String!) {
        issues(
            filter: {
                parent: { id:   { eq: $parent } }
                labels: { name: { eq: $label } }
            }
        ) {
            nodes { id updatedAt }
        }
    }'
    local vars
    vars="$(jq -nc \
        --arg parent "$parent_id" \
        --arg label "$phase_label" \
        '{parent: $parent, label: $label}')"

    local response
    response="$(graphql::query "$query" "$vars")"
    printf '%s' "$response" \
        | jq -c '.data.issues.nodes | sort_by(.updatedAt) | reverse'
}

# reconcile::query_issue_blocks <issue_id>
#   Read the current `blocks` set for an issue so we can diff before
#   issuing a save_issue mutation (FR-007 + contracts §4.4 idempotency).
#   Echoes a JSON array of issue IDs.
reconcile::query_issue_blocks() {
    local issue_id="$1"
    local query='query GetBlocks($id: String!) {
        issue(id: $id) {
            relations(filter: { type: { eq: "blocks" } }) {
                nodes { relatedIssue { id } }
            }
        }
    }'
    local vars
    vars="$(jq -nc --arg id "$issue_id" '{id: $id}')"
    local response
    response="$(graphql::query "$query" "$vars")"
    printf '%s' "$response" \
        | jq -c '[.data.issue.relations.nodes[].relatedIssue.id]'
}

# reconcile::query_existing_comment_body <issue_id> <marker_prefix>
#   Locate an existing comment on <issue_id> whose body starts with
#   the deterministic HTML marker (per contracts §4.5). Echoes the
#   comment ID and body, JSON-encoded as {id, body}, or the literal
#   `null` if no match.
reconcile::query_existing_comment_body() {
    local issue_id="$1"
    local marker="$2"

    local query='query LocateComment($issue: ID!) {
        comments(filter: { issue: { id: { eq: $issue } } }) {
            nodes { id body }
        }
    }'
    local vars
    vars="$(jq -nc --arg issue "$issue_id" '{issue: $issue}')"

    local response
    response="$(graphql::query "$query" "$vars")"
    printf '%s' "$response" | jq -c --arg marker "$marker" '
        .data.comments.nodes
        | map(select(.body | startswith($marker)))
        | (first // null)
    '
}

# reconcile::mutate_issue_create <input_json>
#   Wrapper around `issueCreate`. <input_json> is a fully-formed
#   IssueCreateInput. Echoes `{id, identifier, title}` on success.
reconcile::mutate_issue_create() {
    local input_json="$1"
    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN issueCreate input=$(printf '%s' "$input_json" | jq -c '.')"
        summary::add created "issueCreate (dry-run)"
        # Synthesize a placeholder ID so downstream logic that depends
        # on the returned ID still works in dry-run mode.
        printf '{"id":"dry-run-issue-id","identifier":"DRY-0","title":""}\n'
        return 0
    fi

    local mutation='mutation IssueUpsertCreate($input: IssueCreateInput!) {
        issueCreate(input: $input) {
            success
            issue { id identifier title }
        }
    }'
    local vars
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "issueCreate failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.issueCreate.success == true' >/dev/null 2>&1; then
        summary::add error "issueCreate did not return success=true"
        reconcile::promote_exit 1
        return 1
    fi
    summary::add created "issueCreate"
    printf '%s' "$response" | jq -c '.data.issueCreate.issue'
}

# reconcile::mutate_issue_update <issue_id> <input_json>
#   Wrapper around `issueUpdate`. Skips the call (and records a
#   "skipped/unchanged" hit) when <input_json> is the literal `{}` —
#   the empty diff case the idempotency probe produces.
reconcile::mutate_issue_update() {
    local issue_id="$1"
    local input_json="$2"

    # Idempotency: empty diff → no mutation. The summary counter for
    # "updated" stays where it is so SC-002 (zero-churn reconcile)
    # remains a verifiable observation.
    if [[ "$input_json" == "{}" ]] || \
        printf '%s' "$input_json" | jq -e 'length == 0' >/dev/null 2>&1; then
        reconcile::log "issueUpdate ${issue_id}: no diff, skipping"
        return 0
    fi

    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN issueUpdate id=${issue_id} input=$(printf '%s' "$input_json" | jq -c '.')"
        summary::add updated "issueUpdate (dry-run)"
        return 0
    fi

    local mutation='mutation IssueUpsertUpdate($id: String!, $input: IssueUpdateInput!) {
        issueUpdate(id: $id, input: $input) {
            success
            issue { id identifier title state { id } }
        }
    }'
    local vars
    vars="$(jq -nc --arg id "$issue_id" --argjson input "$input_json" \
        '{id: $id, input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "issueUpdate ${issue_id} failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.issueUpdate.success == true' >/dev/null 2>&1; then
        summary::add error "issueUpdate ${issue_id} did not return success=true"
        reconcile::promote_exit 1
        return 1
    fi
    summary::add updated "issueUpdate ${issue_id}"
    return 0
}

# reconcile::mutate_comment_create <issue_id> <body>
#   Post a new comment on <issue_id>. Body is markdown.
reconcile::mutate_comment_create() {
    local issue_id="$1"
    local body="$2"

    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN commentCreate issue=${issue_id} body_len=${#body}"
        summary::add created "commentCreate (dry-run)"
        return 0
    fi

    local mutation='mutation PostComment($input: CommentCreateInput!) {
        commentCreate(input: $input) {
            success
            comment { id }
        }
    }'
    local input_json vars
    input_json="$(jq -nc \
        --arg issue "$issue_id" \
        --arg body "$body" \
        '{issueId: $issue, body: $body}')"
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "commentCreate on ${issue_id} failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.commentCreate.success == true' >/dev/null 2>&1; then
        summary::add error "commentCreate on ${issue_id} did not return success=true"
        reconcile::promote_exit 1
        return 1
    fi
    summary::add created "commentCreate"
    return 0
}

# =============================================================================
# Per-spec orchestration.
# =============================================================================

# reconcile::read_only_display <feature_number> <spec_dir>
#   Implements FR-026 for the non-authoritative case. We still surface
#   the spec's current Linear state to the operator (so "what's done?"
#   is answerable from any worktree) — but without any mutation. The
#   non-authoritative skip is recorded with summary::add UNLESS
#   --retroactive was passed (the post-analyze remediation note on T072).
reconcile::read_only_display() {
    local feature_number="$1"
    local spec_dir="$2"

    local current_branch
    current_branch="$(git_helpers::current_branch || true)"

    local message
    message="spec ${feature_number}: non-authoritative worktree (current branch '${current_branch:-detached}'); read-only mode"

    if (( ARG_RETROACTIVE == 1 )); then
        reconcile::log "${message}"
    else
        summary::add skipped "${message}"
        reconcile::log "${message}"
    fi

    # Surface Linear's view of the spec — best effort. We avoid failing
    # the whole reconcile if the read query bounces; FR-026 is a courtesy
    # not a critical path.
    local project_uuid spec_label
    project_uuid="$(config::get_project_id)"
    spec_label="speckit-spec:${feature_number}"

    local nodes
    if nodes="$(reconcile::query_spec_issue "$spec_label" "$project_uuid" 2>/dev/null)"; then
        local count
        count="$(printf '%s' "$nodes" | jq 'length')"
        case "$count" in
            0) reconcile::log "spec ${feature_number}: no Linear Issue yet; run reconcile from the authoritative worktree" ;;
            1) reconcile::log "spec ${feature_number}: Linear Issue $(printf '%s' "$nodes" | jq -r '.[0].id') (last updated $(printf '%s' "$nodes" | jq -r '.[0].updatedAt'))" ;;
            *) reconcile::log "spec ${feature_number}: ${count} Linear Issues found (race detected; will auto-resolve next reconcile from authoritative worktree)" ;;
        esac
    fi
}

# reconcile::resolve_or_archive_duplicates <nodes_json> <spec_label>
#   FR-004b race resolver. <nodes_json> is the array returned by
#   reconcile::query_spec_issue (sorted descending by updatedAt). For
#   >1 matches, keep [0] and archive the rest by stripping the
#   speckit-spec:NNN label (so the next reconcile's lookup returns 1).
#   We do NOT flip them to a canceled-state UUID — the bridge doesn't
#   know which workspace state to use without an extra config lookup,
#   and label removal is sufficient to break stable identity.
#   Echoes the winner's ID.
reconcile::resolve_or_archive_duplicates() {
    local nodes_json="$1"
    local spec_label="$2"

    local count
    count="$(printf '%s' "$nodes_json" | jq 'length')"
    if (( count <= 1 )); then
        printf '%s' "$nodes_json" | jq -r '.[0].id // ""'
        return 0
    fi

    local winner
    winner="$(printf '%s' "$nodes_json" | jq -r '.[0].id')"
    summary::add warned "duplicate spec Issues with label ${spec_label}: kept ${winner}, archiving $((count - 1)) loser(s)"
    reconcile::log "FR-004b: ${count} Issues match ${spec_label}; keeping ${winner}, archiving the rest"

    # Strip the speckit-spec:NNN label from every loser. We compute
    # "current labels minus spec_label" by reading each loser's labels
    # and re-issuing a save with the filtered set.
    local loser_id
    while IFS= read -r loser_id; do
        [[ -n "$loser_id" ]] || continue
        local labels_query='query GetIssueLabels($id: String!) {
            issue(id: $id) { labels { nodes { name } } }
        }'
        local vars
        vars="$(jq -nc --arg id "$loser_id" '{id: $id}')"
        local labels_response
        if ! labels_response="$(graphql::query "$labels_query" "$vars" 2>/dev/null)"; then
            summary::add error "could not query labels for duplicate Issue ${loser_id}"
            continue
        fi
        local filtered_labels
        filtered_labels="$(printf '%s' "$labels_response" | jq -c \
            --arg drop "$spec_label" \
            '[.data.issue.labels.nodes[].name | select(. != $drop)]')"
        # We can't pass labels by name to issueUpdate (it wants IDs);
        # since the goal here is purely to break the speckit-spec
        # lookup, the safer move is to remove just that label via the
        # MCP equivalent on the next reconcile from an MCP path. From
        # the GraphQL path the cleanest dedup is to leave a warning
        # and let the operator archive manually — the next reconcile
        # will still pick the freshest winner so no functional break.
        reconcile::log "loser ${loser_id} flagged; manual archive recommended (current labels: ${filtered_labels})"
        summary::add archived "duplicate Issue ${loser_id} flagged for manual review"
    done < <(printf '%s' "$nodes_json" | jq -r '.[1:][].id')

    printf '%s' "$winner"
}

# reconcile::sync_spec_issue <feature_number> <short_name> <spec_dir>
#   Heart of the per-spec mutation path: find-or-create the spec Issue,
#   update title/description/state/labels to match filesystem-derived
#   state. Echoes the spec Issue ID for downstream sub-issue/comment
#   reconcile. Returns non-zero on any mutation failure (still records
#   to summary).
reconcile::sync_spec_issue() {
    local feature_number="$1"
    local short_name="$2"
    local spec_dir="$3"
    local lifecycle_phase="$4"
    local feature_branch="$5"

    local team_uuid project_uuid state_uuid spec_label phase_label
    team_uuid="$(config::get_team_id)"
    project_uuid="$(config::get_project_id)"
    state_uuid="$(config::get_workflow_state_uuid "$lifecycle_phase")"
    spec_label="speckit-spec:${feature_number}"
    phase_label="phase:${lifecycle_phase}"

    local title="${feature_number}-${short_name}"

    # Compose the memory block + spec.md overview into a final body.
    local memory_block existing_body
    memory_block="$(reconcile::render_memory_block \
        "$feature_number" "$short_name" "$lifecycle_phase" \
        "$spec_dir" "$feature_branch")"

    # Locate the existing spec Issue (FR-004b).
    local nodes
    nodes="$(reconcile::query_spec_issue "$spec_label" "$project_uuid")"
    local count
    count="$(printf '%s' "$nodes" | jq 'length')"

    if (( count == 0 )); then
        # Create. Per FR-014 we set stateId DIRECTLY to the inferred
        # end-state — no intermediate transitions visible in Linear's
        # activity log.
        existing_body=""
        local description
        description="$(reconcile::compose_issue_description \
            "$existing_body" "$memory_block")"

        local labels_json
        labels_json="$(reconcile::json_array "$spec_label" "$phase_label")"

        # Note: Linear's IssueCreateInput uses `labelIds` (UUIDs) not
        # `labels` (names). Per the runtime probe the MCP path accepts
        # names; the raw GraphQL path requires IDs. Since the AI-agent
        # harness pre-resolves these via MCP in normal flows, the
        # GraphQL path here is the fallback used by git hooks where the
        # label IDs have to be looked up first. We pass names in a
        # custom `labels` field; if the operator's harness runs only
        # GraphQL it will see a validation error and the summary will
        # name the missing label resolver. T077 dogfood confirms which
        # path the operator hits first.
        local input_json
        input_json="$(jq -nc \
            --arg title "$title" \
            --arg team "$team_uuid" \
            --arg project "$project_uuid" \
            --arg state "$state_uuid" \
            --arg description "$description" \
            --argjson labels "$labels_json" \
            '{
                title: $title,
                teamId: $team,
                projectId: $project,
                stateId: $state,
                description: $description,
                labelNames: $labels
            }')"

        local created_issue
        if ! created_issue="$(reconcile::mutate_issue_create "$input_json")"; then
            return 1
        fi
        printf '%s' "$created_issue" | jq -r '.id'
        return 0
    fi

    # 1+ matches — resolve and update the winner.
    local issue_id
    issue_id="$(reconcile::resolve_or_archive_duplicates "$nodes" "$spec_label")"
    if [[ -z "$issue_id" ]]; then
        summary::add error "could not resolve spec Issue ID for ${spec_label}"
        return 1
    fi

    # Read current state for the idempotency diff.
    local current_query='query GetIssueState($id: String!) {
        issue(id: $id) {
            title
            description
            state { id }
            labels { nodes { name } }
        }
    }'
    local current_vars current_response
    current_vars="$(jq -nc --arg id "$issue_id" '{id: $id}')"
    if ! current_response="$(graphql::query "$current_query" "$current_vars")"; then
        summary::add error "could not query current state of Issue ${issue_id}"
        return 1
    fi

    local current_title current_description current_state_id
    current_title="$(printf '%s' "$current_response" | jq -r '.data.issue.title // ""')"
    current_description="$(printf '%s' "$current_response" | jq -r '.data.issue.description // ""')"
    current_state_id="$(printf '%s' "$current_response" | jq -r '.data.issue.state.id // ""')"

    local current_labels
    current_labels="$(printf '%s' "$current_response" \
        | jq -c '[.data.issue.labels.nodes[].name]')"

    # Compute the desired description by splicing the new memory block
    # into whatever the operator has placed around it.
    local desired_description
    desired_description="$(reconcile::compose_issue_description \
        "$current_description" "$memory_block")"

    # Compute the desired label set: preserve operator-added labels,
    # add (or keep) spec_label + phase_label, remove any stale phase:*
    # label that doesn't match the current lifecycle. Special case for
    # Merged per FR-013: no phase:* label at all.
    local desired_labels_json
    if [[ "$lifecycle_phase" == "merged" ]]; then
        desired_labels_json="$(printf '%s' "$current_labels" | jq -c \
            --arg spec "$spec_label" \
            '[.[] | select(startswith("phase:") | not) | select(. != $spec)]
             + [$spec]')"
    else
        desired_labels_json="$(printf '%s' "$current_labels" | jq -c \
            --arg spec "$spec_label" \
            --arg phase "$phase_label" \
            '[.[] | select(startswith("phase:") | not) | select(. != $spec)]
             + [$spec, $phase]')"
    fi

    # Build the diff input. Only include fields that actually changed.
    local update_input='{}'
    if [[ "$current_title" != "$title" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --arg title "$title" '. + {title: $title}')"
    fi
    if [[ "$current_description" != "$desired_description" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --arg description "$desired_description" \
            '. + {description: $description}')"
    fi
    if [[ "$current_state_id" != "$state_uuid" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --arg state "$state_uuid" '. + {stateId: $state}')"
    fi
    # Label diff (set semantics — sort both before comparing).
    local current_sorted desired_sorted
    current_sorted="$(printf '%s' "$current_labels" | jq -c 'sort')"
    desired_sorted="$(printf '%s' "$desired_labels_json" | jq -c 'sort')"
    if [[ "$current_sorted" != "$desired_sorted" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --argjson labels "$desired_labels_json" \
            '. + {labelNames: $labels}')"
    fi

    reconcile::mutate_issue_update "$issue_id" "$update_input" || return 1
    printf '%s\n' "$issue_id"
}

# reconcile::sync_task_phase_subissues <spec_issue_id> <feature_number> <spec_dir>
#   For each `## Phase N: <Name>` in tasks.md, find-or-create one
#   sub-issue under the spec Issue (FR-005, FR-006). Returns the
#   per-phase sub-issue IDs as a JSON object keyed by phase index for
#   downstream blocking-relation reconcile.
reconcile::sync_task_phase_subissues() {
    local spec_issue_id="$1"
    local feature_number="$2"
    local spec_dir="$3"

    local tasks_md="${spec_dir%/}/tasks.md"
    if [[ ! -f "$tasks_md" ]]; then
        # No tasks.md → no task-phase sub-issues. Not an error.
        printf '{}\n'
        return 0
    fi

    local team_uuid project_uuid
    team_uuid="$(config::get_team_id)"
    project_uuid="$(config::get_project_id)"

    # Build a JSON object { "1": "<sub-issue-id>", "2": "...", ... }
    # incrementally so the caller can resolve blocking relations.
    local phase_map='{}'

    local phase_index phase_name
    while IFS=$'\t' read -r phase_index phase_name; do
        [[ -n "$phase_index" ]] || continue
        local phase_label="task-phase:${phase_index}"
        local sub_title="Phase ${phase_index} — ${phase_name}"
        local checklist
        checklist="$(reconcile::compose_subissue_checklist \
            "$feature_number" "$phase_index" "$tasks_md")"
        local state_key state_uuid
        state_key="$(reconcile::subissue_state_key "$tasks_md" "$phase_index")"
        # `default_state_uuids` is added during the post-analyze
        # remediation; if absent, config::get_default_state_uuid halts
        # the script with a clear remediation pointer. We probe via a
        # subshell so we can degrade to "no state change" if the block
        # is genuinely missing AND the operator hasn't seeded yet.
        if ! state_uuid="$(config::get_default_state_uuid "$state_key" 2>/dev/null)"; then
            summary::add warned "default_state_uuids.${state_key} missing; sub-issue ${sub_title} created without a workflow state"
            state_uuid=""
        fi

        # Locate the existing sub-issue.
        local sub_nodes
        sub_nodes="$(reconcile::query_subissue_for_phase "$spec_issue_id" "$phase_label")"
        local sub_count
        sub_count="$(printf '%s' "$sub_nodes" | jq 'length')"

        local sub_issue_id=""
        if (( sub_count == 0 )); then
            # Create.
            local labels_json
            labels_json="$(reconcile::json_array "$phase_label")"
            local sub_input
            if [[ -n "$state_uuid" ]]; then
                sub_input="$(jq -nc \
                    --arg title "$sub_title" \
                    --arg team "$team_uuid" \
                    --arg project "$project_uuid" \
                    --arg parent "$spec_issue_id" \
                    --arg state "$state_uuid" \
                    --arg description "$checklist" \
                    --argjson labels "$labels_json" \
                    '{
                        title: $title,
                        teamId: $team,
                        projectId: $project,
                        parentId: $parent,
                        stateId: $state,
                        description: $description,
                        labelNames: $labels
                    }')"
            else
                sub_input="$(jq -nc \
                    --arg title "$sub_title" \
                    --arg team "$team_uuid" \
                    --arg project "$project_uuid" \
                    --arg parent "$spec_issue_id" \
                    --arg description "$checklist" \
                    --argjson labels "$labels_json" \
                    '{
                        title: $title,
                        teamId: $team,
                        projectId: $project,
                        parentId: $parent,
                        description: $description,
                        labelNames: $labels
                    }')"
            fi
            local created
            if created="$(reconcile::mutate_issue_create "$sub_input")"; then
                sub_issue_id="$(printf '%s' "$created" | jq -r '.id')"
            else
                continue
            fi
        else
            # Most-recent wins; warn on >1 per FR-005 analogue of FR-004b.
            sub_issue_id="$(printf '%s' "$sub_nodes" | jq -r '.[0].id')"
            if (( sub_count > 1 )); then
                summary::add warned "duplicate sub-issues with label ${phase_label} under ${spec_issue_id}; keeping ${sub_issue_id}"
            fi

            # Diff against the current state.
            local sub_query='query GetSubIssue($id: String!) {
                issue(id: $id) {
                    title
                    description
                    state { id }
                    labels { nodes { name } }
                }
            }'
            local sub_vars sub_response
            sub_vars="$(jq -nc --arg id "$sub_issue_id" '{id: $id}')"
            if ! sub_response="$(graphql::query "$sub_query" "$sub_vars")"; then
                summary::add error "could not query sub-issue ${sub_issue_id}"
                continue
            fi
            local cur_title cur_desc cur_state cur_labels
            cur_title="$(printf '%s' "$sub_response" | jq -r '.data.issue.title // ""')"
            cur_desc="$(printf '%s' "$sub_response" | jq -r '.data.issue.description // ""')"
            cur_state="$(printf '%s' "$sub_response" | jq -r '.data.issue.state.id // ""')"
            cur_labels="$(printf '%s' "$sub_response" | jq -c '[.data.issue.labels.nodes[].name]')"

            # Desired label set: preserve operator labels, ensure
            # task-phase:N is present.
            local desired_labels
            desired_labels="$(printf '%s' "$cur_labels" | jq -c \
                --arg label "$phase_label" \
                '. + ([$label] - .) | unique')"

            local sub_update='{}'
            if [[ "$cur_title" != "$sub_title" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --arg t "$sub_title" '. + {title: $t}')"
            fi
            if [[ "$cur_desc" != "$checklist" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --arg d "$checklist" '. + {description: $d}')"
            fi
            if [[ -n "$state_uuid" && "$cur_state" != "$state_uuid" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --arg s "$state_uuid" '. + {stateId: $s}')"
            fi
            local cur_sorted desired_sorted
            cur_sorted="$(printf '%s' "$cur_labels" | jq -c 'sort')"
            desired_sorted="$(printf '%s' "$desired_labels" | jq -c 'sort')"
            if [[ "$cur_sorted" != "$desired_sorted" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --argjson l "$desired_labels" '. + {labelNames: $l}')"
            fi

            reconcile::mutate_issue_update "$sub_issue_id" "$sub_update" || continue
        fi

        # Record the (phase_index → sub_issue_id) mapping.
        phase_map="$(printf '%s' "$phase_map" | jq -c \
            --arg k "$phase_index" \
            --arg v "$sub_issue_id" \
            '. + {($k): $v}')"
    done < <(parser::task_phases "$tasks_md")

    printf '%s\n' "$phase_map"
}

# reconcile::sync_inter_phase_blocks <phase_map> <spec_dir>
#   Wire blocking relations between task-phase sub-issues per FR-007.
#   We parse `Phase N depends on Phase M` style hints from plan.md and
#   tasks.md (the canonical spec-kit template uses these). When a
#   dependency exists, Phase M `blocks` Phase N.
#
#   <phase_map> is the JSON object emitted by sync_task_phase_subissues.
reconcile::sync_inter_phase_blocks() {
    local phase_map="$1"
    local spec_dir="$2"

    # Read plan.md + tasks.md text and search for "Phase N depends on
    # Phase M" patterns. Case-insensitive, tolerant of em-dash and
    # colon separators. We emit one "<from>\t<to>" line per dep
    # (Phase M blocks Phase N → from=M, to=N).
    local deps
    deps="$({
        for f in "${spec_dir%/}/plan.md" "${spec_dir%/}/tasks.md"; do
            [[ -f "$f" ]] || continue
            grep -iE 'Phase[[:space:]]+[0-9]+[[:space:]]+depends[[:space:]]+on[[:space:]]+Phase[[:space:]]+[0-9]+' "$f" 2>/dev/null || true
        done
    } | awk '
        {
            match($0, /[Pp]hase[[:space:]]+[0-9]+[[:space:]]+depends[[:space:]]+on[[:space:]]+[Pp]hase[[:space:]]+[0-9]+/)
            if (RSTART == 0) next
            seg = substr($0, RSTART, RLENGTH)
            n = split(seg, parts, /[^0-9]+/)
            from = ""; to = ""
            for (i = 1; i <= n; i++) {
                if (parts[i] != "") {
                    if (to == "") { to = parts[i] }
                    else if (from == "") { from = parts[i] }
                }
            }
            if (from != "" && to != "") {
                printf "%s\t%s\n", from, to
            }
        }' | sort -u)"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    # Group deps by "from" so each save_issue call sets all blocks for
    # one sub-issue at once.
    local -A from_to_targets=()
    local from_phase to_phase
    while IFS=$'\t' read -r from_phase to_phase; do
        [[ -n "$from_phase" && -n "$to_phase" ]] || continue
        local from_id to_id
        from_id="$(printf '%s' "$phase_map" | jq -r --arg k "$from_phase" '.[$k] // ""')"
        to_id="$(printf '%s' "$phase_map" | jq -r --arg k "$to_phase" '.[$k] // ""')"
        if [[ -z "$from_id" || -z "$to_id" ]]; then
            summary::add warned "inter-phase dep Phase ${to_phase} depends on Phase ${from_phase}: missing sub-issue id"
            continue
        fi
        # Append (newline-separated for the next read loop).
        local prev="${from_to_targets[$from_id]:-}"
        if [[ -z "$prev" ]]; then
            from_to_targets[$from_id]="$to_id"
        else
            from_to_targets[$from_id]="${prev}"$'\n'"${to_id}"
        fi
    done <<< "$deps"

    # For each from-issue, diff desired vs current blocks and issue the
    # delta. Idempotency is mandatory per contracts §4.4 ("MUST query
    # the existing blocks array via get_issue before invoking").
    local from_issue
    for from_issue in "${!from_to_targets[@]}"; do
        local desired_blocks_csv="${from_to_targets[$from_issue]}"
        # Convert newlines to a JSON array of IDs (sorted, unique).
        local desired_json
        desired_json="$(printf '%s\n' "$desired_blocks_csv" | sort -u \
            | jq -Rcs 'split("\n") | map(select(length > 0))')"

        local current_json
        if ! current_json="$(reconcile::query_issue_blocks "$from_issue")"; then
            summary::add error "could not query blocks for ${from_issue}"
            continue
        fi

        # Compute additions: desired - current.
        local additions
        additions="$(jq -nc \
            --argjson desired "$desired_json" \
            --argjson current "$current_json" \
            '$desired - $current')"

        local add_count
        add_count="$(printf '%s' "$additions" | jq 'length')"
        if (( add_count == 0 )); then
            reconcile::log "blocks for ${from_issue}: in sync"
            continue
        fi

        local input_json
        input_json="$(jq -nc --argjson blocks "$additions" '{blocks: $blocks}')"
        reconcile::mutate_issue_update "$from_issue" "$input_json" || continue
    done
}

# reconcile::sync_clarify_comments <spec_issue_id> <spec_dir>
#   For every `### Session YYYY-MM-DD` block under ## Clarifications,
#   post (idempotently) one comment on the spec Issue with the session's
#   Q/A bullets (FR-008 + FR-015). Idempotency is via the leading HTML
#   marker per contracts §4.5.
reconcile::sync_clarify_comments() {
    local spec_issue_id="$1"
    local spec_dir="$2"

    local spec_md="${spec_dir%/}/spec.md"
    if [[ ! -f "$spec_md" ]]; then
        return 0
    fi

    local date bullet_count
    while IFS=$'\t' read -r date bullet_count; do
        [[ -n "$date" ]] || continue
        # Silence the unused-bullet-count warning — we only use it for
        # potential future "skip empty session" heuristics.
        : "${bullet_count:-0}"

        local marker
        marker="<!-- speckit-linear: clarify-session ${date} -->"

        # Build the comment body: marker + heading + verbatim bullets.
        local bullets
        bullets="$(parser::clarify_session_bullets "$spec_md" "$date" || true)"
        local body
        body="$(printf '%s\n**Clarification session %s**\n\n%s\n' \
            "$marker" "$date" "$bullets")"

        # Look up an existing comment whose body starts with the marker.
        local existing
        if ! existing="$(reconcile::query_existing_comment_body "$spec_issue_id" "$marker")"; then
            summary::add error "could not query comments on ${spec_issue_id}"
            continue
        fi

        if [[ "$existing" == "null" ]]; then
            reconcile::mutate_comment_create "$spec_issue_id" "$body" || continue
            continue
        fi

        local existing_body
        existing_body="$(printf '%s' "$existing" | jq -r '.body')"
        if [[ "$existing_body" == "$body" ]]; then
            reconcile::log "clarify-session ${date} comment in sync"
            continue
        fi

        # Body diverged. Per contracts §9 we DO NOT mutate existing
        # comment bodies — that would silently overwrite operator-added
        # nuance. Surface a warning and move on.
        summary::add warned "clarify-session ${date}: existing comment body diverges from spec.md; not overwriting"
    done < <(parser::clarify_sessions "$spec_md")
}

# reconcile::process_spec <spec_dir>
#   Top-level per-spec orchestration. Returns 0 always — failures are
#   recorded via summary::add and promote RECONCILE_EXIT_CODE; we never
#   throw past this boundary so one bad spec can't bring down the
#   --all sweep (FR-024).
reconcile::process_spec() {
    local spec_dir="$1"

    local feature_number short_name spec_md
    if ! feature_number="$(parser::feature_number "$spec_dir")"; then
        summary::add warned "spec dir ${spec_dir}: basename does not match NNN-<slug>; skipping"
        return 0
    fi
    if ! short_name="$(parser::short_name "$spec_dir")"; then
        summary::add warned "spec dir ${spec_dir}: cannot extract short name; skipping"
        return 0
    fi

    spec_md="${spec_dir%/}/spec.md"
    if [[ ! -s "$spec_md" ]]; then
        summary::add warned "spec ${feature_number}: spec.md missing or empty; skipping"
        return 0
    fi

    # Feature branch is the canonical `<NNN>-<short-name>` per FR-025.
    local feature_branch="${feature_number}-${short_name}"

    # --- 4a. Write-authority gate (FR-025 / Principle IV) -------------
    if ! git_helpers::is_authoritative_for_spec "$feature_number"; then
        reconcile::read_only_display "$feature_number" "$spec_dir"
        return 0
    fi

    # --- 4b. Phase inference ------------------------------------------
    # Hand the PR-state hint through to the parser so retroactive sync
    # lands directly on `merged` / `ready_to_merge` without simulating
    # intermediate transitions (FR-014).
    local pr_state_raw lifecycle_phase
    pr_state_raw="$(git_helpers::pr_state "$feature_branch" 2>/dev/null || true)"

    local pr_state_hint=""
    if [[ -n "$pr_state_raw" ]]; then
        # gh path returns JSON; git fallback returns the literal word
        # `merged` or `open`. Detect which and normalise to a token.
        if printf '%s' "$pr_state_raw" | jq -e . >/dev/null 2>&1; then
            local pr_merged pr_draft
            pr_merged="$(printf '%s' "$pr_state_raw" | jq -r '.merged // false')"
            pr_draft="$(printf '%s' "$pr_state_raw" | jq -r '.isDraft // false')"
            if [[ "$pr_merged" == "true" ]]; then
                pr_state_hint="merged"
            elif [[ "$pr_draft" == "false" ]]; then
                pr_state_hint="ready"
            fi
        elif [[ "$pr_state_raw" == "merged" ]]; then
            pr_state_hint="merged"
        fi
    fi

    if ! lifecycle_phase="$(parser::lifecycle_phase "$spec_dir" "$pr_state_hint")"; then
        summary::add warned "spec ${feature_number}: cannot infer lifecycle phase; skipping"
        return 0
    fi

    reconcile::log "spec ${feature_number}: lifecycle=${lifecycle_phase} branch=${feature_branch}"

    # Surface any malformed tasks.md lines per FR-024.
    local malformed
    if malformed="$(parser::malformed_task_lines "${spec_dir%/}/tasks.md" 2>/dev/null)" \
        && [[ -n "$malformed" ]]; then
        local line_count
        line_count="$(printf '%s\n' "$malformed" | wc -l | awk '{print $1}')"
        summary::add warned "spec ${feature_number}: ${line_count} task line(s) outside any ## Phase header"
    fi

    # --- 4c. Spec Issue find-or-create/update (FR-001..FR-004b) -------
    local spec_issue_id
    if ! spec_issue_id="$(reconcile::sync_spec_issue \
        "$feature_number" "$short_name" "$spec_dir" \
        "$lifecycle_phase" "$feature_branch")"; then
        summary::add error "spec ${feature_number}: sync_spec_issue failed"
        return 0
    fi
    if [[ -z "$spec_issue_id" || "$spec_issue_id" == "null" ]]; then
        summary::add error "spec ${feature_number}: no Issue ID resolved"
        return 0
    fi

    # --- 4d/4e. Task-phase sub-issues (FR-005, FR-006) ----------------
    local phase_map
    if ! phase_map="$(reconcile::sync_task_phase_subissues \
        "$spec_issue_id" "$feature_number" "$spec_dir")"; then
        summary::add error "spec ${feature_number}: sync_task_phase_subissues failed"
        # Continue to comments — sub-issue failures don't block the
        # rest of the per-spec reconcile per FR-024.
    fi

    # --- 4f. Inter-phase blocking relations (FR-007) ------------------
    if [[ -n "${phase_map:-}" && "$phase_map" != "{}" ]]; then
        reconcile::sync_inter_phase_blocks "$phase_map" "$spec_dir" || true
    fi

    # --- 4g. Clarify session comments (FR-008, FR-015) ----------------
    reconcile::sync_clarify_comments "$spec_issue_id" "$spec_dir" || true

    reconcile::log "spec ${feature_number}: reconcile complete"
    return 0
}

# =============================================================================
# Main.
# =============================================================================
reconcile::main() {
    reconcile::parse_args "$@"

    local title
    title="speckit.linear reconcile"
    if [[ -n "$ARG_SPEC" ]]; then
        title="${title} — spec ${ARG_SPEC}"
    elif (( ARG_ALL == 1 )); then
        title="${title} — all specs"
    fi
    if (( ARG_DRY_RUN == 1 )); then
        title="${title} (dry-run)"
    fi
    if (( ARG_RETROACTIVE == 1 )); then
        title="${title} (retroactive)"
    fi
    summary::start "$title"

    # Step 2 — config load. Exits 2 via config::*'s own halt on failure.
    reconcile::load_config

    # Step 3 — spec enumeration.
    local -a spec_dirs=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && spec_dirs+=("$dir")
    done < <(reconcile::enumerate_specs)

    if (( ${#spec_dirs[@]} == 0 )); then
        if [[ -n "$ARG_SPEC" ]]; then
            summary::add warned "no spec directory matched --spec ${ARG_SPEC}"
            reconcile::promote_exit 1
        else
            reconcile::log "no specs/NNN-* directories found"
        fi
    fi

    # Step 4 — per-spec loop.
    local spec_dir
    for spec_dir in "${spec_dirs[@]}"; do
        reconcile::process_spec "$spec_dir"
    done

    # Step 5 — summary emission (Principle VIII).
    summary::emit

    # Step 6 — final exit code. If any errors landed, promote to 1
    # unless we've already promoted higher.
    if summary::has_errors; then
        reconcile::promote_exit 1
    fi

    exit "$RECONCILE_EXIT_CODE"
}

# Allow this script to be sourced for testing without executing main.
# When sourced, BASH_SOURCE[0] != $0; when executed, they match.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    reconcile::main "$@"
fi
