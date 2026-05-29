#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
# ^^^ Every GraphQL query string in this file uses single quotes so
#     `$variable` tokens remain literal — those are GraphQL variable
#     references resolved server-side, NOT bash expansions. Suppressing
#     SC2016 file-wide mirrors the convention in src/reconcile.sh and
#     src/seed.sh.
# =============================================================================
# src/status.sh — per-spec drift report (Layer D, READ-ONLY inspect command).
#
# Implements User Story 3 (P2 — "Cross-repo unified view"; T051) and the
# `speckit.linear.status` slice of `contracts/command-shapes.md`. Surfaces
# disk-side facts (lifecycle phase, current branch, worktree authority,
# last-touched timestamp), Linear-side facts (workflow state, phase label,
# sub-issue completion counts, last activity), and the drift signals
# between the two — WITHOUT ever issuing a write mutation.
#
# Touched filesystem requirements:
#   `specs/NNN-feature/` (one or more)
#   `.specify/extensions/linear/linear-config.yml`
#   `.env` (only when LINEAR_API_KEY is not already exported)
#
# The command is the inverse of `src/reconcile.sh`: same module surface,
# same wire format, but every Linear interaction is a `graphql::query`
# call. No `graphql::mutate`. No `issueCreate` / `issueUpdate` /
# `commentCreate`. Even from an authoritative worktree, this command
# MUST NOT write — it is an inspect tool, full stop.
#
# -----------------------------------------------------------------------------
# Constitutional alignment
# -----------------------------------------------------------------------------
# Principle I (filesystem-is-truth) — read-only; surfaces drift, does not
#   reconcile it. Operators see what's out-of-sync and can choose to run
#   `speckit.linear.push` (which has its own write-authority gate).
# Principle II (reconcile, never event-push) — every invocation reads
#   full filesystem state and queries Linear; no diff cache, no sidecar.
# Principle III (layered idempotency) — read-only by definition; no
#   layer ownership questions arise.
# Principle IV (write-authority-follows-worktree) — surfaces authority
#   status per spec (Yes / No / N/A) so the operator knows whether a
#   later `push` from the current worktree would mutate or be silent.
# Principle V (UUID-based binding) — every Linear lookup uses UUIDs
#   resolved from `linear-config.yml` via the `config::*` API.
# Principle VIII (observable failure) — per-spec query failures are
#   collected via `summary::add` and surfaced; the JSON envelope still
#   emits even when one spec's Linear-side fetch fails so the operator
#   sees both the disk view and the failure reason.
#
# -----------------------------------------------------------------------------
# CLI surface (per task brief T051)
# -----------------------------------------------------------------------------
#   speckit.linear.status [--spec NNN | --all] [--json | --human] [--no-color]
#
# Defaults: `--all --human`.
#
# Exit codes (matching the rest of the bridge):
#   0  success (possibly with non-fatal warnings)
#   1  partial failure: at least one spec's Linear-side fetch failed
#      but disk-side facts surfaced for it. Other specs may still be OK.
#   2  workspace-level config error (missing config, malformed UUIDs);
#      halt without surfacing partial output per FR-022.
#   3  transport failure across the board (config OK, but Linear
#      unreachable; the disk-side report still emits to stderr).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Module sourcing — order matches src/reconcile.sh so a single shellcheck
# pass behaves identically across both entrypoints.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./config.sh disable=SC1091
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=./graphql.sh disable=SC1091
source "${SCRIPT_DIR}/graphql.sh"
# shellcheck source=./git_helpers.sh disable=SC1091
source "${SCRIPT_DIR}/git_helpers.sh"
# shellcheck source=./summary.sh disable=SC1091
source "${SCRIPT_DIR}/summary.sh"
# shellcheck source=./parser.sh disable=SC1091
source "${SCRIPT_DIR}/parser.sh"

# -----------------------------------------------------------------------------
# Module constants.
# -----------------------------------------------------------------------------

# Default config path. Resolved relative to PWD (the consumer repo's
# root) — matches the convention in reconcile.sh and seed.sh.
readonly STATUS_CONFIG_PATH_DEFAULT=".specify/extensions/linear/linear-config.yml"

# Spec-directory glob used when --all is in effect. Matches the canonical
# `specs/NNN-feature/` layout (three or more leading digits, dash, slug).
readonly STATUS_SPEC_GLOB="specs"

# Memory-block fences (copied from reconcile.sh — same contract). Used
# to extract the branch / worktree pointers Linear last recorded so we
# can diff against the disk-side current branch / worktree map.
readonly STATUS_MEMORY_BEGIN="<!-- spec-kit-linear:memory:begin -->"
readonly STATUS_MEMORY_END="<!-- spec-kit-linear:memory:end -->"

# -----------------------------------------------------------------------------
# CLI-flag globals — populated by status::parse_args.
# -----------------------------------------------------------------------------
declare -g ARG_SPEC=""           # NNN or empty
declare -g ARG_ALL=0             # 0|1
declare -g ARG_FORMAT="human"    # human|json
declare -g ARG_NO_COLOR=0        # 0|1 — force monochrome regardless of tty
declare -g STATUS_CONFIG_PATH="" # resolved after parse_args

# Aggregate exit-code tracker — monotonic promotion to higher severities.
declare -g STATUS_EXIT_CODE=0

# Accumulator for the per-spec JSON objects rendered by status::process_spec.
# Concatenated into a single array for `--json` output at the end.
declare -g STATUS_JSON_ROWS=""

# Same accumulator but for human rendering — tab-separated columns one row
# per spec, formatted into a table by status::emit_human at the end.
declare -g STATUS_HUMAN_ROWS=""

# -----------------------------------------------------------------------------
# status::usage
#   Print operator-facing usage to stderr.
# -----------------------------------------------------------------------------
status::usage() {
    cat >&2 <<'EOF'
Usage: status.sh [--spec NNN | --all] [--json | --human] [--no-color]
                 [--config PATH] [--help]

Inspect per-spec sync state (disk vs Linear) — READ-ONLY. Never mutates.

Options:
  --spec NNN       Report only the spec whose feature number matches NNN.
  --all            Report every specs/NNN-feature/ in the repo (default).
  --json           Emit a JSON array of per-spec objects on stdout.
  --human          Emit a coloured table on stdout (default).
  --no-color       Force monochrome regardless of tty / NO_COLOR.
  --config PATH    Override the path to linear-config.yml
                   (default: .specify/extensions/linear/linear-config.yml).
  --help           Show this help.

Exit codes:
  0  Success (possibly with warnings).
  1  Partial failure: at least one Linear-side fetch failed.
  2  Workspace-level config error (halt without partial output).
  3  Transport failure: Linear unreachable; disk view still printed.
EOF
}

# -----------------------------------------------------------------------------
# status::log
#   Emit a per-step log line to stderr. The status command is short so we
#   never suppress these; the JSON envelope on stdout stays untouched.
# -----------------------------------------------------------------------------
status::log() {
    printf 'spec-kit-linear: status %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# status::promote_exit <code>
#   Monotonically promote STATUS_EXIT_CODE. Mirrors reconcile::promote_exit.
# -----------------------------------------------------------------------------
status::promote_exit() {
    local incoming="$1"
    if (( STATUS_EXIT_CODE == 2 )); then
        return 0
    fi
    case "$incoming" in
        2) STATUS_EXIT_CODE=2 ;;
        3) (( STATUS_EXIT_CODE < 3 )) && STATUS_EXIT_CODE=3 ;;
        1) (( STATUS_EXIT_CODE < 1 )) && STATUS_EXIT_CODE=1 ;;
        0) : ;;
        *) : ;;
    esac
}

# =============================================================================
# Step 1 — Argument parsing.
# =============================================================================
status::parse_args() {
    local config_path="${STATUS_CONFIG_PATH_DEFAULT}"
    while (( $# > 0 )); do
        case "$1" in
            --spec)
                if (( $# < 2 )); then
                    printf 'spec-kit-linear: --spec requires a feature number argument\n' >&2
                    status::usage
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
            --json)
                ARG_FORMAT="json"
                shift
                ;;
            --human)
                ARG_FORMAT="human"
                shift
                ;;
            --no-color|--no-colour)
                ARG_NO_COLOR=1
                shift
                ;;
            --config)
                if (( $# < 2 )); then
                    printf 'spec-kit-linear: --config requires a path argument\n' >&2
                    status::usage
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
                status::usage
                exit 0
                ;;
            *)
                printf 'spec-kit-linear: unknown argument: %s\n' "$1" >&2
                status::usage
                exit 2
                ;;
        esac
    done

    # Default to --all when neither --spec nor --all is given.
    if [[ -z "$ARG_SPEC" ]] && (( ARG_ALL == 0 )); then
        ARG_ALL=1
    fi

    # --spec and --all together is allowed but --spec wins — the operator
    # is asking for ONE spec by number; we honour that.

    # Honour the NO_COLOR convention upstream of summary::_supports_colour.
    if (( ARG_NO_COLOR == 1 )); then
        export NO_COLOR=1
    fi

    # Materialise the resolved config path for downstream readers.
    STATUS_CONFIG_PATH="$config_path"
    # Honour the same env override the integration helper uses for
    # other entry points (SPECKIT_LINEAR_CONFIG) so test sandboxes can
    # point this script at a non-default config without --config.
    if [[ -n "${SPECKIT_LINEAR_CONFIG:-}" ]]; then
        STATUS_CONFIG_PATH="${SPECKIT_LINEAR_CONFIG}"
    fi
}

# =============================================================================
# Step 2 — Config + spec-list resolution.
# =============================================================================

# status::resolve_spec_dirs
#   Echo one absolute path per `specs/NNN-feature/` to process, honouring
#   --spec / --all. Empty output (and exit 0) when no specs are present —
#   the caller reports "no specs found" rather than failing.
status::resolve_spec_dirs() {
    local specs_dir="${PWD}/${STATUS_SPEC_GLOB}"
    if [[ ! -d "$specs_dir" ]]; then
        return 0
    fi

    local dir base feature_number
    # Read deterministic order (numeric sort by NNN prefix) so the report
    # is stable across runs.
    while IFS= read -r dir; do
        base="$(basename "$dir")"
        if [[ ! "$base" =~ ^([0-9]{3,})-.+$ ]]; then
            continue
        fi
        feature_number="${BASH_REMATCH[1]}"
        # --spec filters to the requested feature number; numeric compare
        # so `--spec 2` matches `002-foo`.
        if [[ -n "$ARG_SPEC" ]]; then
            if [[ ! "$ARG_SPEC" =~ ^[0-9]+$ ]]; then
                continue
            fi
            if (( 10#$feature_number != 10#$ARG_SPEC )); then
                continue
            fi
        fi
        printf '%s\n' "$dir"
    done < <(find "$specs_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sort)
}

# =============================================================================
# Step 3 — Linear-side queries.
#
# Each function below echoes a JSON object summarising the Linear-side
# facts the report cares about, or the literal `null` when the entity
# doesn't exist / the query failed. Failures DO NOT abort — they promote
# STATUS_EXIT_CODE to 1 and continue, so partial reports surface rather
# than vanish behind a single transient API blip.
# =============================================================================

# status::query_spec_issue <speckit_label> <project_uuid>
#   Locate the spec Issue by `speckit-spec:NNN` label scoped to the
#   repo's Project (FR-004b). Echoes the most-recently-updated match's
#   summary JSON `{id, identifier, title, updatedAt, state, labels,
#   description, children}`, or `null` if no match.
status::query_spec_issue() {
    local spec_label="$1"
    local project_uuid="$2"

    local query='query SpecIssueForStatus($label: String!, $project: ID!) {
        issues(
            filter: {
                labels:  { name: { eq: $label } }
                project: { id:   { eq: $project } }
            }
        ) {
            nodes {
                id
                identifier
                title
                updatedAt
                description
                state { id name type }
                labels { nodes { name } }
                children {
                    nodes {
                        id
                        identifier
                        title
                        state { id name type }
                    }
                }
            }
        }
    }'
    local vars response
    vars="$(jq -nc \
        --arg label "$spec_label" \
        --arg project "$project_uuid" \
        '{label: $label, project: $project}')"

    if ! response="$(graphql::query "$query" "$vars" 2>/dev/null)"; then
        return 1
    fi

    printf '%s' "$response" | jq -c '
        .data.issues.nodes
        | sort_by(.updatedAt)
        | reverse
        | (first // null)
    '
}

# =============================================================================
# Step 4 — Per-spec processing.
# =============================================================================

# status::extract_memory_branch <description_text>
#   Echo the branch name recorded inside the spec Issue's memory block,
#   or empty if the block / branch row is missing. Used to detect
#   "Linear knows about a different branch than the worktree the
#   operator is on right now".
status::extract_memory_branch() {
    local description="$1"
    if [[ -z "$description" ]]; then
        return 0
    fi
    # Memory block uses a markdown table — grep for the "| **Branch** | ... |"
    # row inside the fences. Awk handles the fenced range cleanly.
    awk -v begin="$STATUS_MEMORY_BEGIN" -v end="$STATUS_MEMORY_END" '
        index($0, begin) { in_block = 1; next }
        index($0, end)   { in_block = 0; next }
        in_block && /\| \*\*Branch\*\* \|/ {
            line = $0
            # Extract the cell between the second and third pipes.
            n = split(line, cells, "|")
            if (n >= 4) {
                value = cells[3]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                # Strip surrounding backticks if present.
                gsub(/^`|`$/, "", value)
                print value
            }
            exit
        }
    ' <<<"$description"
}

# status::compute_completion <children_json>
#   Echo `<done>/<total>` for the spec's sub-issue completion ratio.
#   <children_json> is the `.children.nodes` array from the spec Issue
#   query. Echoes `0/0` when there are no sub-issues (Linear has the
#   spec Issue but no task-phase children yet).
status::compute_completion() {
    local children_json="$1"
    if [[ -z "$children_json" || "$children_json" == "null" ]]; then
        printf '0/0\n'
        return 0
    fi
    local total done_count
    total="$(printf '%s' "$children_json" | jq 'length')"
    done_count="$(printf '%s' "$children_json" \
        | jq '[.[] | select(.state.type == "completed")] | length')"
    printf '%s/%s\n' "$done_count" "$total"
}

# status::compute_drift <disk_phase> <linear_phase> <disk_branch>
#                      <memory_branch> <disk_completion> <linear_completion>
#                      <disk_touched_epoch> <linear_updated_at>
#   Echo a JSON array of drift signal strings. Empty array when the disk
#   and Linear views agree on every comparable axis. Each signal is a
#   short human-readable string.
status::compute_drift() {
    local disk_phase="$1"
    local linear_phase="$2"
    local disk_branch="$3"
    local memory_branch="$4"
    local disk_completion="$5"
    local linear_completion="$6"
    local disk_touched_epoch="$7"
    local linear_updated_at="$8"

    local -a signals=()

    # Lifecycle-phase mismatch — only flag when BOTH sides know a phase.
    # `linear_phase=` (empty) means we couldn't infer the Linear phase
    # from labels/state, which is a "no Issue / no labels" condition
    # already surfaced elsewhere.
    if [[ -n "$linear_phase" && -n "$disk_phase" && "$disk_phase" != "$linear_phase" ]]; then
        signals+=("lifecycle phase: disk=${disk_phase} linear=${linear_phase}")
    fi

    # Branch pointer mismatch — memory block recorded a different branch
    # than the worktree's current branch.
    if [[ -n "$memory_branch" && -n "$disk_branch" && "$memory_branch" != "$disk_branch" ]]; then
        signals+=("branch: disk=${disk_branch} memory-block=${memory_branch}")
    fi

    # Task checklist count drift — sub-issue ratio differs between sides.
    if [[ -n "$linear_completion" && -n "$disk_completion" && "$disk_completion" != "$linear_completion" ]]; then
        signals+=("task-phase completion: disk=${disk_completion} linear=${linear_completion}")
    fi

    # "Linear knows something disk doesn't" — Linear's updatedAt is more
    # recent than the spec dir's last-touched mtime. The reverse case
    # (disk newer than Linear) is the normal "ran /speckit-* but
    # haven't pushed yet" condition and not surfaced as drift.
    if [[ -n "$disk_touched_epoch" && -n "$linear_updated_at" ]]; then
        # ISO 8601 -> epoch via date (cross-platform).
        local linear_epoch=""
        if linear_epoch="$(date -u -d "$linear_updated_at" +%s 2>/dev/null)"; then
            :
        elif linear_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${linear_updated_at%Z}" +%s 2>/dev/null)"; then
            :
        elif linear_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S.000Z' "${linear_updated_at}" +%s 2>/dev/null)"; then
            :
        fi
        if [[ -n "$linear_epoch" && "$linear_epoch" =~ ^[0-9]+$ ]]; then
            if (( linear_epoch > disk_touched_epoch )); then
                signals+=("linear last-activity (${linear_updated_at}) is newer than disk last-touched")
            fi
        fi
    fi

    if (( ${#signals[@]} == 0 )); then
        printf '[]\n'
        return 0
    fi
    # Emit as a compact JSON array.
    printf '%s\n' "${signals[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# status::process_spec <spec_dir>
#   Compute the disk + Linear + drift summary for one spec and append a
#   row into STATUS_JSON_ROWS and STATUS_HUMAN_ROWS. Never throws — any
#   error path produces a row with partial information + a warning event.
status::process_spec() {
    local spec_dir="$1"

    # ---- disk-side facts ----
    local feature_number short_name
    if ! feature_number="$(parser::feature_number "$spec_dir")"; then
        summary::add warned "spec ${spec_dir}: cannot derive feature number; skipping"
        return 0
    fi
    short_name="$(parser::short_name "$spec_dir" || printf '')"

    local disk_phase=""
    disk_phase="$(parser::lifecycle_phase "$spec_dir" 2>/dev/null || printf '')"
    if [[ -z "$disk_phase" ]]; then
        disk_phase="unknown"
        summary::add warned "spec ${feature_number}: spec.md missing or empty; phase unknown"
    fi

    local current_branch
    current_branch="$(git_helpers::current_branch || printf '')"

    # Worktree(s) hosting the spec's feature branch. There may be zero
    # (branch not checked out), one (the common case), or many (rare —
    # the operator deliberately has multiple worktrees for the same
    # branch, which git actually refuses but they could have stale
    # entries). We surface a count and the first path.
    local worktree_path=""
    local feature_branch_pattern="^${feature_number}-"
    local wt_path wt_branch
    local -a worktree_paths=()
    while IFS=$'\t' read -r wt_path wt_branch; do
        if [[ -n "$wt_branch" && "$wt_branch" =~ $feature_branch_pattern ]]; then
            worktree_paths+=("$wt_path")
        fi
    done < <(git_helpers::list_worktrees)
    if (( ${#worktree_paths[@]} > 0 )); then
        worktree_path="${worktree_paths[0]}"
    fi

    local last_touched_iso last_touched_epoch=""
    last_touched_iso="$(git_helpers::last_touched "$spec_dir" || printf '')"
    if [[ -n "$last_touched_iso" ]]; then
        # Best-effort epoch for the drift comparator. Cross-platform try-both.
        if last_touched_epoch="$(date -u -d "$last_touched_iso" +%s 2>/dev/null)"; then
            :
        elif last_touched_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_touched_iso" +%s 2>/dev/null)"; then
            :
        else
            last_touched_epoch=""
        fi
    fi

    # Authority hint (spec 003 / FR-060): a NON-GATING display heuristic.
    # The FR-025 write-gate is removed (reconcile writes from any worktree
    # — FR-051); this row is purely informational so `status` can still
    # answer "is this the canonical feature-branch worktree?" without
    # affecting any write. Yes if current branch matches the spec's
    # feature-branch pattern; No otherwise.
    local authority="No"
    if git_helpers::is_authoritative_for_spec "$feature_number"; then
        authority="Yes"
    fi

    # ---- Linear-side query ----
    # The spec-Issue lookup is the load-bearing call; failure → record
    # the spec with empty Linear-side fields and a warning.
    local project_uuid spec_label spec_issue_json
    project_uuid="$(config::get_project_id 2>/dev/null || printf '')"
    spec_label="spec-kit-spec:${feature_number}"
    # Match reconcile.sh's label-name convention exactly so the lookup
    # finds the same Issue the reconciler created. reconcile.sh uses
    # `speckit-spec:NNN` (no hyphen in the family name); we mirror that.
    spec_label="speckit-spec:${feature_number}"

    spec_issue_json="null"
    local linear_fetch_failed=0
    if [[ -n "$project_uuid" ]]; then
        if ! spec_issue_json="$(status::query_spec_issue "$spec_label" "$project_uuid")"; then
            linear_fetch_failed=1
            spec_issue_json="null"
            summary::add warned "spec ${feature_number}: Linear query failed; surfacing disk-side facts only"
            status::promote_exit 1
        fi
    else
        # No project UUID means config validation will already have failed
        # upstream; we won't reach here in practice. Defensive: skip Linear.
        spec_issue_json="null"
    fi

    # ---- derive Linear-side summary fields ----
    local linear_identifier="" linear_title="" linear_updated_at=""
    local linear_state_name="" linear_state_type="" linear_phase=""
    local linear_completion="" children_json="[]" linear_description=""
    if [[ "$spec_issue_json" != "null" ]]; then
        linear_identifier="$(printf '%s' "$spec_issue_json" | jq -r '.identifier // ""')"
        linear_title="$(printf '%s' "$spec_issue_json" | jq -r '.title // ""')"
        linear_updated_at="$(printf '%s' "$spec_issue_json" | jq -r '.updatedAt // ""')"
        linear_state_name="$(printf '%s' "$spec_issue_json" | jq -r '.state.name // ""')"
        linear_state_type="$(printf '%s' "$spec_issue_json" | jq -r '.state.type // ""')"
        # phase:* label → linear-side lifecycle phase.
        linear_phase="$(printf '%s' "$spec_issue_json" \
            | jq -r '[.labels.nodes[].name | select(startswith("phase:"))] | (first // "") | sub("^phase:"; "")')"
        children_json="$(printf '%s' "$spec_issue_json" | jq -c '.children.nodes // []')"
        linear_completion="$(status::compute_completion "$children_json")"
        linear_description="$(printf '%s' "$spec_issue_json" | jq -r '.description // ""')"
    fi

    # ---- disk-side completion (count `## Phase N:` headers + check ratio) ----
    local tasks_md="${spec_dir%/}/tasks.md"
    local disk_total disk_done=0
    disk_total=0
    if [[ -f "$tasks_md" ]]; then
        local phase_idx phase_name task_id task_state task_desc task_est
        local -a phase_indexes=()
        while IFS=$'\t' read -r phase_idx phase_name; do
            : "${phase_name:-}"
            phase_indexes+=("$phase_idx")
        done < <(parser::task_phases "$tasks_md")
        disk_total="${#phase_indexes[@]}"
        # A task phase counts as "done" when every checklist item in it is checked.
        for phase_idx in "${phase_indexes[@]}"; do
            local any_unchecked=0 had_any=0
            while IFS=$'\t' read -r task_id task_state task_desc task_est; do
                : "${task_id:-}${task_desc:-}${task_est:-}"
                had_any=1
                if [[ "$task_state" != "checked" ]]; then
                    any_unchecked=1
                    break
                fi
            done < <(parser::tasks_in_phase "$tasks_md" "$phase_idx")
            if (( had_any == 1 && any_unchecked == 0 )); then
                disk_done=$(( disk_done + 1 ))
            fi
        done
    fi
    local disk_completion
    disk_completion="${disk_done}/${disk_total}"

    # ---- drift signals ----
    local memory_branch
    memory_branch="$(status::extract_memory_branch "$linear_description")"
    local drift_json
    drift_json="$(status::compute_drift \
        "$disk_phase" "$linear_phase" \
        "$current_branch" "$memory_branch" \
        "$disk_completion" "$linear_completion" \
        "$last_touched_epoch" "$linear_updated_at")"

    # ---- JSON row ----
    local row_json
    row_json="$(jq -nc \
        --arg feature_number "$feature_number" \
        --arg short_name "$short_name" \
        --arg disk_phase "$disk_phase" \
        --arg disk_branch "$current_branch" \
        --arg disk_worktree "$worktree_path" \
        --argjson disk_worktree_count "${#worktree_paths[@]}" \
        --arg disk_last_touched "$last_touched_iso" \
        --arg disk_completion "$disk_completion" \
        --arg authority "$authority" \
        --arg linear_identifier "$linear_identifier" \
        --arg linear_title "$linear_title" \
        --arg linear_state_name "$linear_state_name" \
        --arg linear_state_type "$linear_state_type" \
        --arg linear_phase "$linear_phase" \
        --arg linear_completion "$linear_completion" \
        --arg linear_updated_at "$linear_updated_at" \
        --argjson linear_present "$( [[ "$spec_issue_json" == "null" ]] && printf 'false' || printf 'true' )" \
        --argjson linear_fetch_failed "$linear_fetch_failed" \
        --argjson drift "$drift_json" \
        '{
            feature_number: $feature_number,
            short_name: $short_name,
            disk: {
                lifecycle_phase: $disk_phase,
                current_branch: $disk_branch,
                worktree: $disk_worktree,
                worktree_count: $disk_worktree_count,
                last_touched: $disk_last_touched,
                task_phase_completion: $disk_completion
            },
            authority: $authority,
            linear: {
                present: $linear_present,
                fetch_failed: ($linear_fetch_failed == 1),
                identifier: $linear_identifier,
                title: $linear_title,
                state_name: $linear_state_name,
                state_type: $linear_state_type,
                phase_label: $linear_phase,
                sub_issue_completion: $linear_completion,
                last_activity: $linear_updated_at
            },
            drift: $drift
        }')"

    if [[ -z "$STATUS_JSON_ROWS" ]]; then
        STATUS_JSON_ROWS="$row_json"
    else
        STATUS_JSON_ROWS="${STATUS_JSON_ROWS}"$'\n'"${row_json}"
    fi

    # ---- human row ----
    # Tab-delimited so we can format with `column -t -s$'\t'` at the end.
    # Drift cell collapses to "—" when no signals; otherwise shows the
    # count and the first signal.
    local drift_cell
    local drift_count
    drift_count="$(printf '%s' "$drift_json" | jq 'length')"
    if (( drift_count == 0 )); then
        drift_cell="—"
    else
        local first_signal
        first_signal="$(printf '%s' "$drift_json" | jq -r '.[0]')"
        if (( drift_count == 1 )); then
            drift_cell="${first_signal}"
        else
            drift_cell="${drift_count} signals: ${first_signal}…"
        fi
    fi
    local linear_state_cell
    if [[ "$spec_issue_json" == "null" ]]; then
        if (( linear_fetch_failed == 1 )); then
            linear_state_cell="<query failed>"
        else
            linear_state_cell="<not in linear>"
        fi
    else
        linear_state_cell="${linear_state_name:-?} (${linear_phase:-no phase label})"
    fi
    local human_row
    printf -v human_row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$feature_number" \
        "${short_name:-?}" \
        "$disk_phase" \
        "$disk_completion" \
        "$authority" \
        "${linear_identifier:-—}" \
        "$linear_state_cell" \
        "$drift_cell"

    if [[ -z "$STATUS_HUMAN_ROWS" ]]; then
        STATUS_HUMAN_ROWS="$human_row"
    else
        STATUS_HUMAN_ROWS="${STATUS_HUMAN_ROWS}"$'\n'"${human_row}"
    fi
}

# =============================================================================
# Step 5 — Output rendering.
# =============================================================================

# status::emit_json
#   Render every captured row into a single JSON array on stdout.
status::emit_json() {
    if [[ -z "$STATUS_JSON_ROWS" ]]; then
        printf '[]\n'
        return 0
    fi
    printf '%s\n' "$STATUS_JSON_ROWS" | jq -sc '.'
}

# status::_supports_color
#   Same convention as summary::_supports_colour but for stdout (the
#   human table writes to stdout, not stderr).
status::_supports_color() {
    if (( ARG_NO_COLOR == 1 )); then
        return 1
    fi
    if [[ -n "${NO_COLOR:-}" ]]; then
        return 1
    fi
    if [[ -t 1 ]]; then
        return 0
    fi
    return 1
}

# status::_colour <ansi-code> <text>
status::_colour() {
    local code="$1"
    local text="$2"
    if status::_supports_color; then
        printf '\033[%sm%s\033[0m' "$code" "$text"
    else
        printf '%s' "$text"
    fi
}

# status::emit_human
#   Render the captured rows as a scannable table on stdout, with
#   per-column colouring of the authority + drift cells.
status::emit_human() {
    local header
    printf -v header 'NNN\tNAME\tDISK PHASE\tDISK TASKS\tAUTH\tLINEAR ID\tLINEAR STATE\tDRIFT'

    if [[ -z "$STATUS_HUMAN_ROWS" ]]; then
        printf 'speckit.linear.status: no specs found under specs/\n'
        return 0
    fi

    # Colourise: AUTH cell green for Yes / yellow for No; DRIFT cell red
    # when non-empty (anything other than "—") / green when "—".
    local row coloured_rows=""
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        IFS=$'\t' read -r col_nnn col_name col_phase col_tasks col_auth col_lid col_lstate col_drift <<<"$row"
        local auth_coloured drift_coloured
        if [[ "$col_auth" == "Yes" ]]; then
            auth_coloured="$(status::_colour 32 "$col_auth")"
        else
            auth_coloured="$(status::_colour 33 "$col_auth")"
        fi
        if [[ "$col_drift" == "—" ]]; then
            drift_coloured="$(status::_colour 32 "$col_drift")"
        else
            drift_coloured="$(status::_colour 31 "$col_drift")"
        fi
        local cr
        printf -v cr '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "$col_nnn" "$col_name" "$col_phase" "$col_tasks" \
            "$auth_coloured" "$col_lid" "$col_lstate" "$drift_coloured"
        if [[ -z "$coloured_rows" ]]; then
            coloured_rows="$cr"
        else
            coloured_rows="${coloured_rows}"$'\n'"${cr}"
        fi
    done <<<"$STATUS_HUMAN_ROWS"

    # `column -t -s$'\t'` aligns columns when present (most macOS / Linux
    # ship it). Fall back to plain tab output if it's absent.
    {
        printf '%s\n' "$header"
        printf '%s\n' "$coloured_rows"
    } | (column -t -s $'\t' 2>/dev/null || cat)
}

# =============================================================================
# Step 6 — Entry point.
# =============================================================================
main() {
    status::parse_args "$@"

    summary::start "speckit.linear status"

    # Config load + validate. Halts (exit 2) on missing / malformed
    # config per FR-022.
    if ! config::load "$STATUS_CONFIG_PATH" 2>/dev/null; then
        printf 'spec-kit-linear: status: cannot load config at %s\n' "$STATUS_CONFIG_PATH" >&2
        printf 'hint: copy config-template.yml to %s and run /spec-kit-linear-install\n' \
            "$STATUS_CONFIG_PATH" >&2
        summary::add error "config load failed: ${STATUS_CONFIG_PATH}"
        summary::emit
        exit 2
    fi
    if ! config::validate 2>/dev/null; then
        # validate() exits 2 itself; re-running here would double-fire.
        # Instead surface a warning and re-invoke without trapping.
        printf 'spec-kit-linear: status: config validation failed at %s\n' "$STATUS_CONFIG_PATH" >&2
        summary::add error "config validation failed"
        summary::emit
        exit 2
    fi

    local -a spec_dirs=()
    local dir
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        spec_dirs+=("$dir")
    done < <(status::resolve_spec_dirs)

    if (( ${#spec_dirs[@]} == 0 )); then
        if [[ -n "$ARG_SPEC" ]]; then
            summary::add warned "no spec directory matched --spec ${ARG_SPEC}"
        else
            summary::add warned "no specs/NNN-*/ directories found"
        fi
    fi

    for dir in "${spec_dirs[@]}"; do
        status::process_spec "$dir"
    done

    # Emit the report to stdout (JSON or human). The structured summary
    # goes to stderr per Principle VIII.
    case "$ARG_FORMAT" in
        json)  status::emit_json ;;
        human) status::emit_human ;;
    esac

    summary::emit
    if summary::has_errors; then
        status::promote_exit 1
    fi
    exit "$STATUS_EXIT_CODE"
}

# Allow sourcing under bats / unit tests without invoking main().
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
