#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
# ^^^ Every GraphQL query/mutation string in this file uses single quotes so
#     `$variable` tokens remain literal — those are GraphQL variable references
#     resolved server-side, NOT bash expansions. Suppressing SC2016 file-wide
#     mirrors the convention in src/reconcile.sh and keeps the contract
#     readable.
# =============================================================================
# src/seed.sh — one-shot Linear workspace seeder (Layer D, install-time helper).
#
# Implements User Story 4 (P2 — "One-shot install and workspace seed") and the
# seed-time portion of `contracts/linear-graphql-mutations.md` §2. Materialises
# every Linear primitive the bridge needs at runtime that does NOT mint itself
# lazily during reconcile:
#
#   * Nine custom workflow states on the consumer team (FR-021, FR-032),
#     created via the `workflowStateCreate` GraphQL mutation because the live
#     MCP catalogue has no equivalent tool (Capability 8 in the runtime probe).
#   * Eighteen workspace-scoped issue labels — `phase:*` and `task-phase:*` —
#     created via `issueLabelCreate` GraphQL because hooks / non-AI paths have
#     no MCP session (Principle VI: keys-at-the-edges).
#
# After the writes settle, the script captures every returned UUID and writes
# the resolved IDs back into the consumer repo's
# `.specify/extensions/linear/linear-config.yml`. The two captured maps are:
#
#   * `linear.workflow_state_uuids` — 9 keys, matching the lifecycle phases
#     (specifying, clarifying, planning, tasking, red_team, implementing,
#     analyzing, ready_to_merge, merged). Driven by FR-032.
#   * `linear.default_state_uuids` — 3 keys (todo, in_progress, done), captured
#     from the team's stock workflow states so task-phase sub-issues per FR-005
#     can carry a Todo / In Progress / Done state without re-creating that
#     palette.
#
# The seed itself is idempotent (per Principle II and FR-021 — "safe to
# re-run"): every create is preceded by an existence query, and a re-run
# against an already-seeded workspace observably emits zero `created` events
# and produces the same `linear-config.yml` byte-for-byte.
#
# -----------------------------------------------------------------------------
# Constitutional alignment
# -----------------------------------------------------------------------------
# Principle V (UUID-based binding) — every Linear identifier we capture is
#   stored as a UUID in the per-repo config file. Lookups are never by name.
# Principle VI (OAuth-first, keys-at-the-edges) — this is one of the two paths
#   that legitimately uses LINEAR_API_KEY (the other is the GitHub Action). The
#   key never leaves graphql.sh's process; this script just calls into it.
# Principle VIII (observable failure) — every create/skip/error is funnelled
#   through `summary::*` and rendered in the final structured block. The
#   script never appears to succeed when it has silently dropped work.
#
# -----------------------------------------------------------------------------
# CLI surface (per contracts/command-shapes.md §4)
# -----------------------------------------------------------------------------
#   src/seed.sh [--team UUID] [--dry-run] [--workspace-only] [--help]
#
# Exit codes (matching the rest of the bridge):
#   0  success (possibly with warnings)
#   1  transient failure (5xx after retry, rate-limit exhaustion). Re-run.
#   2  workspace-level config error (FR-022) — missing config, malformed UUIDs,
#      no team resolvable from config + CLI override.
#   3  transport failure across the board (Linear unreachable; nothing written).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Module sourcing. Order matches src/reconcile.sh so a single shellcheck pass
# behaves identically across both entrypoints. graphql.sh + summary.sh are
# load-bearing; config.sh's getters are only used when we have an already-
# parsed config to extract `linear.team.id` from (the seed step's main input
# besides the API key).
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./config.sh disable=SC1091
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=./graphql.sh disable=SC1091
source "${SCRIPT_DIR}/graphql.sh"
# shellcheck source=./summary.sh disable=SC1091
source "${SCRIPT_DIR}/summary.sh"

# -----------------------------------------------------------------------------
# Module constants.
# -----------------------------------------------------------------------------

# Default config path. Resolved relative to PWD (the consumer repo's root) so
# the same script binary serves every consumer repo's invocation. Matches the
# convention in reconcile.sh.
readonly SEED_CONFIG_PATH_DEFAULT=".specify/extensions/linear/linear-config.yml"

# Path of the template the seed copies from when the consumer repo has not yet
# materialised its `linear-config.yml`. The template is checked into the
# extension itself (committed as `config-template.yml` at the repo root, and
# also under `.specify/extensions/linear/` after `specify extension add
# linear`). The fallback search order below covers both.
readonly SEED_TEMPLATE_BASENAME="config-template.yml"

# -----------------------------------------------------------------------------
# CLI-flag globals — populated by seed::parse_args.
# -----------------------------------------------------------------------------
declare -g ARG_TEAM_OVERRIDE=""        # UUID or empty
declare -g ARG_DRY_RUN=0               # 0|1
declare -g ARG_WORKSPACE_ONLY=0        # 0|1 — skip the config.yml write
declare -g SEED_CONFIG_PATH=""         # populated after parse_args

# Aggregate exit-code tracker — monotonic promotion to higher severities.
declare -g SEED_EXIT_CODE=0

# -----------------------------------------------------------------------------
# Workflow-state catalogue (T058).
#
# Tab-separated rows: <lifecycle_key>\t<name>\t<type>\t<color>\t<position>.
# Order matches the position column so the array index is the de facto seed
# order. Names + colors + positions are locked by the task brief — changing
# any value here changes the operator-visible Linear UI without a constitution
# amendment, so don't.
# -----------------------------------------------------------------------------
readonly -a SEED_WORKFLOW_STATES=(
    $'specifying\tSpecifying\tunstarted\t#6B7280\t1'
    $'clarifying\tClarifying\tstarted\t#F59E0B\t2'
    $'planning\tPlanning\tstarted\t#3B82F6\t3'
    $'tasking\tTasking\tstarted\t#8B5CF6\t4'
    $'red_team\tRed-team\tstarted\t#EF4444\t5'
    $'implementing\tImplementing\tstarted\t#10B981\t6'
    $'analyzing\tAnalyzing\tstarted\t#06B6D4\t7'
    $'ready_to_merge\tReady-to-merge\tstarted\t#84CC16\t8'
    $'merged\tMerged\tcompleted\t#22C55E\t9'
)

# -----------------------------------------------------------------------------
# Label catalogue (T059).
#
# Two families — `phase:*` (one per lifecycle phase) and `task-phase:N`
# (covering up to 9 task phases per spec, per the task brief). All are
# workspace-scoped (the workspace-scope flag is set by passing teamId=null to
# the create mutation). The `speckit-spec:NNN` family is deliberately NOT in
# this list — those are minted lazily by reconcile.sh per spec, not seeded.
# -----------------------------------------------------------------------------
readonly -a SEED_PHASE_LABELS=(
    "phase:specifying"
    "phase:clarifying"
    "phase:planning"
    "phase:tasking"
    "phase:red_team"
    "phase:implementing"
    "phase:analyzing"
    "phase:ready_to_merge"
    "phase:merged"
)
readonly -a SEED_TASK_PHASE_LABELS=(
    "task-phase:1"
    "task-phase:2"
    "task-phase:3"
    "task-phase:4"
    "task-phase:5"
    "task-phase:6"
    "task-phase:7"
    "task-phase:8"
    "task-phase:9"
)

# Default-state hunt table (FR-005, contracts §4.3). Tab-separated rows:
# <key>\t<expected_name>\t<expected_type>. We probe by name first (the common
# stock-Linear-team case where the names match exactly) and fall back to the
# first state whose type matches when the name doesn't line up — operators
# sometimes rename "Todo" → "Backlog" without changing the type.
readonly -a SEED_DEFAULT_STATE_LOOKUPS=(
    $'todo\tTodo\tunstarted'
    $'in_progress\tIn Progress\tstarted'
    $'done\tDone\tcompleted'
)

# Module-level capture buffers — populated by the create / discover paths and
# consumed by the config-write step. Bash 4+ associative arrays (Principle: we
# already require bash 4 elsewhere; macOS 3.2 is explicitly out of scope per
# plan.md Technical Context).
declare -gA SEED_WORKFLOW_UUIDS=()         # lifecycle_key → UUID
declare -gA SEED_DEFAULT_STATE_UUIDS=()    # todo|in_progress|done → UUID
# SEED_LABEL_UUIDS is populated for diagnostics / future use (label UUIDs are
# not written to linear-config.yml because reconcile.sh looks labels up by
# name). The shellcheck SC2034 disable below is intentional — the array
# exists to surface "what labels does the workspace now hold" to anyone who
# wants to source seed.sh as a library, even though main() itself never
# reads it back out.
# shellcheck disable=SC2034
declare -gA SEED_LABEL_UUIDS=()            # label_name → UUID (diagnostics)

# -----------------------------------------------------------------------------
# seed::usage
#   Print operator-facing usage to stderr.
# -----------------------------------------------------------------------------
seed::usage() {
    cat >&2 <<'EOF'
Usage: seed.sh [--team UUID] [--dry-run] [--workspace-only] [--help]

One-shot Linear workspace seed. Creates the 9 custom lifecycle workflow
states + 18 workspace labels the bridge relies on, captures every UUID,
and writes them back into .specify/extensions/linear/linear-config.yml.

Options:
  --team UUID       Override the team UUID. Default: read from
                    linear-config.yml's linear.team.id.
  --dry-run         Log every mutation that WOULD fire; issue none. No
                    config.yml write.
  --workspace-only  Run the workspace mutations only — do NOT write the
                    captured UUIDs back to linear-config.yml. Useful when
                    verifying workspace state from a non-bridge-installed
                    context (e.g. dogfood from a sibling repo).
  --help            Show this help.

Exit codes:
  0  Success (possibly with warnings).
  1  Transient failure (5xx after retry, rate-limit exhaustion). Re-run.
  2  Workspace-level config error (missing config, malformed UUIDs, no
     team resolvable).
  3  Transport failure: Linear unreachable; nothing written.

See contracts/command-shapes.md §4 for the full contract.
EOF
}

# -----------------------------------------------------------------------------
# seed::log
#   Emit a per-mutation log line to stderr. Always on (the seed command is
#   short enough that --quiet is not worth a flag).
# -----------------------------------------------------------------------------
seed::log() {
    printf 'speckit-linear: seed %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# seed::promote_exit <code>
#   Monotonically promote SEED_EXIT_CODE. Mirrors reconcile::promote_exit so
#   the operator-facing exit semantics are identical between the two entry
#   points. 2 is terminal (workspace-level halt) — never demote.
# -----------------------------------------------------------------------------
seed::promote_exit() {
    local incoming="$1"
    if (( SEED_EXIT_CODE == 2 )); then
        return 0
    fi
    case "$incoming" in
        2) SEED_EXIT_CODE=2 ;;
        3) (( SEED_EXIT_CODE < 3 )) && SEED_EXIT_CODE=3 ;;
        1) (( SEED_EXIT_CODE < 1 )) && SEED_EXIT_CODE=1 ;;
        0) : ;;
        *) : ;;
    esac
}

# =============================================================================
# Step 1 — Argument parsing.
# =============================================================================
seed::parse_args() {
    local config_path="${SEED_CONFIG_PATH_DEFAULT}"
    while (( $# > 0 )); do
        case "$1" in
            --team)
                if (( $# < 2 )); then
                    printf 'speckit-linear: --team requires a UUID argument\n' >&2
                    seed::usage
                    exit 2
                fi
                ARG_TEAM_OVERRIDE="$2"
                shift 2
                ;;
            --team=*)
                ARG_TEAM_OVERRIDE="${1#--team=}"
                shift
                ;;
            --dry-run)
                ARG_DRY_RUN=1
                shift
                ;;
            --workspace-only)
                ARG_WORKSPACE_ONLY=1
                shift
                ;;
            --config)
                if (( $# < 2 )); then
                    printf 'speckit-linear: --config requires a path argument\n' >&2
                    seed::usage
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
                seed::usage
                exit 0
                ;;
            *)
                printf 'speckit-linear: unknown argument: %s\n' "$1" >&2
                seed::usage
                exit 2
                ;;
        esac
    done

    SEED_CONFIG_PATH="$config_path"
}

# =============================================================================
# Step 2 — Team UUID resolution.
#
# Order of precedence:
#   1. --team UUID on the CLI (operator override or non-interactive install).
#   2. linear.team.id parsed from .specify/extensions/linear/linear-config.yml.
#   3. Hard failure — without a team we cannot create team-scoped workflow
#      states. Exit 2 with an operator-actionable hint.
# =============================================================================
seed::resolve_team_uuid() {
    if [[ -n "$ARG_TEAM_OVERRIDE" ]]; then
        printf '%s\n' "$ARG_TEAM_OVERRIDE"
        return 0
    fi

    if [[ ! -e "$SEED_CONFIG_PATH" ]]; then
        summary::add error "no --team UUID supplied and ${SEED_CONFIG_PATH} not found"
        seed::promote_exit 2
        return 2
    fi

    # config::load + config::get_team_id will exit 2 if team.id is missing or
    # malformed. That matches the desired semantics (Principle VIII — surface,
    # don't enforce) so we let the propagation happen naturally.
    config::load "$SEED_CONFIG_PATH"
    config::get_team_id
}

# =============================================================================
# Step 3 — Workflow-state idempotency probe + create (T058 + T060).
#
# Per contracts §2.1: before each workflowStateCreate, query
# `workflowStates(filter: { team: { id: { eq: $teamId } }, name: { eq: $name } })`.
# If exactly one match exists, capture its `id` and skip the mutation. If zero
# matches, call workflowStateCreate. >=2 matches surfaces a warning and skips
# (per the contract, "never auto-pick" on ambiguity).
# =============================================================================

# seed::query_workflow_state <team_uuid> <name>
#   Echo the matching workflowState UUID, or empty string on no match. Halts
#   the script (via graphql.sh) on auth / transport failure. Multi-match
#   surfaces a warning and echoes empty so the caller skips the create —
#   silent auto-pick is forbidden per the contract.
seed::query_workflow_state() {
    local team_uuid="$1"
    local name="$2"

    local query='query SeedFindWorkflowState($team: ID!, $name: String!) {
        workflowStates(
            filter: {
                team: { id:   { eq: $team } }
                name: { eq:   $name }
            }
        ) {
            nodes { id name type }
        }
    }'
    local vars
    vars="$(jq -nc \
        --arg team "$team_uuid" \
        --arg name "$name" \
        '{team: $team, name: $name}')"

    local response
    response="$(graphql::query "$query" "$vars")"

    local count
    count="$(printf '%s' "$response" | jq '.data.workflowStates.nodes | length')"
    case "$count" in
        0) printf '' ;;
        1) printf '%s' "$response" | jq -r '.data.workflowStates.nodes[0].id' ;;
        *)
            summary::add warned \
                "workflowStates query returned ${count} matches for name='${name}' on team ${team_uuid}; skipping create — operator must disambiguate manually"
            printf ''
            ;;
    esac
}

# seed::create_workflow_state <team_uuid> <name> <type> <color> <position>
#   Issue a workflowStateCreate mutation and echo the resulting UUID. On
#   --dry-run, log + return a synthetic placeholder ID so the caller's flow
#   continues end-to-end (mirrors the reconcile.sh dry-run convention).
seed::create_workflow_state() {
    local team_uuid="$1"
    local name="$2"
    local type="$3"
    local color="$4"
    local position="$5"

    if (( ARG_DRY_RUN == 1 )); then
        seed::log "DRY-RUN workflowStateCreate name='${name}' type=${type} color=${color} position=${position}"
        summary::add created "workflowStateCreate ${name} (dry-run)"
        # Synthesize a UUIDv4-shaped placeholder so the config-write path can
        # round-trip a dry-run end-to-end without choking on the regex check.
        printf '00000000-0000-0000-0000-dryrun%6s' "${name:0:6}" \
            | tr -c '0-9a-f-' '0' \
            | head -c 36
        printf '\n'
        return 0
    fi

    local mutation='mutation SeedWorkflowStateCreate($input: WorkflowStateCreateInput!) {
        workflowStateCreate(input: $input) {
            success
            workflowState { id name type }
        }
    }'
    local input_json vars
    input_json="$(jq -nc \
        --arg name "$name" \
        --arg type "$type" \
        --arg color "$color" \
        --arg team "$team_uuid" \
        --argjson position "$position" \
        '{
            name:     $name,
            type:     $type,
            color:    $color,
            teamId:   $team,
            position: $position
        }')"
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "workflowStateCreate ${name} failed (transport)"
        seed::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.workflowStateCreate.success == true' >/dev/null 2>&1; then
        summary::add error "workflowStateCreate ${name} did not return success=true"
        seed::promote_exit 1
        return 1
    fi
    summary::add created "workflowStateCreate ${name}"
    printf '%s\n' "$(printf '%s' "$response" | jq -r '.data.workflowStateCreate.workflowState.id')"
}

# seed::reconcile_workflow_states <team_uuid>
#   Drive T058 + T060: for each row in SEED_WORKFLOW_STATES, query → create
#   if absent → capture UUID into SEED_WORKFLOW_UUIDS keyed by lifecycle_key.
seed::reconcile_workflow_states() {
    local team_uuid="$1"
    local row key name type color position uuid
    for row in "${SEED_WORKFLOW_STATES[@]}"; do
        # Tab-separated parse — IFS scoped to the read so the surrounding
        # shell environment stays untouched.
        IFS=$'\t' read -r key name type color position <<<"$row"

        uuid="$(seed::query_workflow_state "$team_uuid" "$name")"
        if [[ -n "$uuid" ]]; then
            seed::log "workflow state '${name}' already exists (${uuid}); skipping create"
            summary::add skipped "workflow state '${name}' already present"
            SEED_WORKFLOW_UUIDS[$key]="$uuid"
            continue
        fi

        if ! uuid="$(seed::create_workflow_state "$team_uuid" "$name" "$type" "$color" "$position")"; then
            # create_workflow_state already aggregated the error; just move on.
            continue
        fi
        seed::log "created workflow state '${name}' → ${uuid}"
        SEED_WORKFLOW_UUIDS[$key]="$uuid"
    done
}

# =============================================================================
# Step 4 — Default-state capture (T059 secondary requirement).
#
# The team's stock workflow states (Todo / In Progress / Done) are queried via
# the same `workflowStates(filter: { team })` query, this time enumerating
# every state on the team and matching by (name, type) tuple. The bridge does
# NOT create these — Linear ships them on every team by default; if the
# operator has renamed or deleted them we surface a warning and skip the
# affected key rather than auto-recreating, because reconcile.sh treats
# default_state_uuids as optional-but-validated.
# =============================================================================

# seed::query_team_states <team_uuid>
#   Echo every workflow state on the team as JSON `[{id, name, type}, ...]`.
seed::query_team_states() {
    local team_uuid="$1"
    local query='query SeedListTeamStates($team: String!) {
        team(id: $team) {
            states { nodes { id name type } }
        }
    }'
    local vars
    vars="$(jq -nc --arg team "$team_uuid" '{team: $team}')"

    local response
    response="$(graphql::query "$query" "$vars")"
    printf '%s' "$response" | jq -c '.data.team.states.nodes'
}

# seed::capture_default_states <team_uuid>
#   Populate SEED_DEFAULT_STATE_UUIDS from the team's stock workflow states.
#   For each (key, expected_name, expected_type) row: prefer an exact name +
#   type match; fall back to the first state whose type matches alone.
seed::capture_default_states() {
    local team_uuid="$1"
    local team_states
    team_states="$(seed::query_team_states "$team_uuid")"

    local row key expected_name expected_type uuid
    for row in "${SEED_DEFAULT_STATE_LOOKUPS[@]}"; do
        IFS=$'\t' read -r key expected_name expected_type <<<"$row"

        # Exact (name, type) match first.
        uuid="$(printf '%s' "$team_states" | jq -r \
            --arg name "$expected_name" \
            --arg type "$expected_type" \
            '
            map(select(.name == $name and .type == $type))
            | (.[0].id // "")
            ')"

        # Fallback: first state with the expected type, regardless of name.
        if [[ -z "$uuid" ]]; then
            uuid="$(printf '%s' "$team_states" | jq -r \
                --arg type "$expected_type" \
                '
                map(select(.type == $type))
                | (.[0].id // "")
                ')"
            if [[ -n "$uuid" ]]; then
                # Operator has likely renamed Todo → Backlog or similar; the
                # bridge still works but we want the audit trail.
                local matched_name
                matched_name="$(printf '%s' "$team_states" | jq -r \
                    --arg id "$uuid" \
                    'map(select(.id == $id)) | (.[0].name // "")')"
                summary::add warned \
                    "default state '${key}': expected name='${expected_name}' type=${expected_type}; matched '${matched_name}' by type only"
            fi
        fi

        if [[ -z "$uuid" ]]; then
            summary::add warned \
                "default state '${key}' (expected '${expected_name}', type ${expected_type}) not found on team ${team_uuid}; task-phase sub-issues will fail until this state exists"
            continue
        fi

        seed::log "default state '${key}' → ${uuid}"
        SEED_DEFAULT_STATE_UUIDS[$key]="$uuid"
    done
}

# =============================================================================
# Step 5 — Label idempotency probe + create (T059 + T060).
#
# Per contracts §2.2: pre-query each label by name; skip on hit. Labels are
# created as workspace-scoped (teamId omitted) so any team in the workspace
# can attach them — `phase:*` and `task-phase:*` are bridge-vocabulary that
# belongs to every consumer repo, not to a single team.
# =============================================================================

# seed::query_label <name>
#   Echo the matching label UUID or empty. Workspace-scoped labels live in
#   the same `issueLabels` collection as team-scoped ones; we filter by name
#   alone since the bridge owns the name family (`phase:*`, `task-phase:*`).
seed::query_label() {
    local name="$1"
    local query='query SeedFindLabel($name: String!) {
        issueLabels(filter: { name: { eq: $name } }) {
            nodes { id name }
        }
    }'
    local vars
    vars="$(jq -nc --arg name "$name" '{name: $name}')"

    local response
    response="$(graphql::query "$query" "$vars")"

    local count
    count="$(printf '%s' "$response" | jq '.data.issueLabels.nodes | length')"
    case "$count" in
        0) printf '' ;;
        1) printf '%s' "$response" | jq -r '.data.issueLabels.nodes[0].id' ;;
        *)
            summary::add warned \
                "issueLabels query returned ${count} matches for name='${name}'; skipping create — operator must disambiguate manually"
            printf ''
            ;;
    esac
}

# seed::create_label <name>
#   Issue an `issueLabelCreate` GraphQL mutation. Workspace-scoped (no team).
#   No color is forced — Linear assigns a sensible default and the operator
#   may recolour the labels in the UI without breaking lookups (Principle V).
seed::create_label() {
    local name="$1"

    if (( ARG_DRY_RUN == 1 )); then
        seed::log "DRY-RUN issueLabelCreate name='${name}' (workspace-scoped)"
        summary::add created "issueLabelCreate ${name} (dry-run)"
        printf '00000000-0000-0000-0000-000000000000\n'
        return 0
    fi

    local mutation='mutation SeedLabelCreate($input: IssueLabelCreateInput!) {
        issueLabelCreate(input: $input) {
            success
            issueLabel { id name }
        }
    }'
    local input_json vars
    # No teamId → workspace-scoped per Linear's IssueLabelCreateInput contract.
    input_json="$(jq -nc --arg name "$name" '{name: $name}')"
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "issueLabelCreate ${name} failed (transport)"
        seed::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.issueLabelCreate.success == true' >/dev/null 2>&1; then
        summary::add error "issueLabelCreate ${name} did not return success=true"
        seed::promote_exit 1
        return 1
    fi
    summary::add created "issueLabelCreate ${name}"
    printf '%s\n' "$(printf '%s' "$response" | jq -r '.data.issueLabelCreate.issueLabel.id')"
}

# seed::reconcile_labels
#   Walk both label families (phase:* and task-phase:N) and find-or-create
#   each. Captured UUIDs go into SEED_LABEL_UUIDS for diagnostics. Unlike the
#   workflow-state UUIDs these are NOT written to linear-config.yml — label
#   lookups inside reconcile.sh are by name (workspace-scoped, stable).
seed::reconcile_labels() {
    local name uuid
    local -a all_labels=()
    all_labels+=("${SEED_PHASE_LABELS[@]}")
    all_labels+=("${SEED_TASK_PHASE_LABELS[@]}")

    for name in "${all_labels[@]}"; do
        uuid="$(seed::query_label "$name")"
        if [[ -n "$uuid" ]]; then
            seed::log "label '${name}' already exists (${uuid}); skipping create"
            summary::add skipped "label '${name}' already present"
            # shellcheck disable=SC2034  # diagnostics-only buffer
            SEED_LABEL_UUIDS[$name]="$uuid"
            continue
        fi

        if ! uuid="$(seed::create_label "$name")"; then
            continue
        fi
        seed::log "created label '${name}' → ${uuid}"
        # shellcheck disable=SC2034  # diagnostics-only buffer
        SEED_LABEL_UUIDS[$name]="$uuid"
    done
}

# =============================================================================
# Step 6 — Config write-back (T060 second half).
#
# Update `.specify/extensions/linear/linear-config.yml` in place. Two cases:
#   * File exists: edit in place, preserving every field we did NOT touch.
#     The strategy is a per-line awk script that rewrites the
#     `linear.workflow_state_uuids` and `linear.default_state_uuids` blocks
#     wholesale (so the per-key indentation and ordering stay stable across
#     re-runs) and emits every other line verbatim.
#   * File missing: copy `config-template.yml` into place first, then apply
#     the same edit. This is the "fresh consumer repo, never installed"
#     bootstrap path; downstream `speckit.linear.install` still fills in
#     team/project UUIDs separately.
#
# We deliberately do NOT use `yq` — keeping the dependency surface at
# {bash, curl, jq, git} is a load-bearing decision in plan.md §Technical
# Context.
# =============================================================================

# seed::find_template
#   Locate the config template. Search order:
#     1. .specify/extensions/linear/config-template.yml — the post-install
#        location (where `specify extension add linear` drops it).
#     2. config-template.yml at the repo root — the dogfood location (this
#        repo's own committed template).
#     3. <SCRIPT_DIR>/../config-template.yml — relative to seed.sh, useful
#        when the bridge has been vendored into another tool.
#   Echo the first hit, or empty on no match.
seed::find_template() {
    local candidates=(
        ".specify/extensions/linear/${SEED_TEMPLATE_BASENAME}"
        "${SEED_TEMPLATE_BASENAME}"
        "${SCRIPT_DIR}/../${SEED_TEMPLATE_BASENAME}"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf ''
}

# seed::ensure_config
#   Make sure linear-config.yml exists at SEED_CONFIG_PATH. If absent, copy
#   from the template and surface a warning so the operator knows they need
#   to run /speckit-linear-install next to fill in team + project UUIDs.
seed::ensure_config() {
    if [[ -f "$SEED_CONFIG_PATH" ]]; then
        return 0
    fi

    local template
    template="$(seed::find_template)"
    if [[ -z "$template" ]]; then
        summary::add error "linear-config.yml not found at ${SEED_CONFIG_PATH} and no config-template.yml available; cannot write captured UUIDs"
        seed::promote_exit 2
        return 2
    fi

    # Ensure the parent directory exists before the copy.
    local parent_dir
    parent_dir="$(dirname "$SEED_CONFIG_PATH")"
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir"
    fi

    cp "$template" "$SEED_CONFIG_PATH"
    summary::add warned \
        "${SEED_CONFIG_PATH} was missing; copied from ${template}. Run /speckit-linear-install to fill in linear.team.id and linear.project.id."
}

# seed::render_workflow_uuid_block <indent>
#   Echo the YAML lines for the `workflow_state_uuids:` block, including the
#   block opener itself, with <indent> spaces of leading indent on the opener
#   (children indent two spaces deeper).
seed::render_workflow_uuid_block() {
    local indent="$1"
    local child_indent
    child_indent="${indent}  "

    printf '%sworkflow_state_uuids:\n' "$indent"

    # Render keys in the canonical order from CONFIG_WORKFLOW_PHASES so the
    # diff between re-runs is stable.
    local key value
    for key in specifying clarifying planning tasking red_team implementing analyzing ready_to_merge merged; do
        value="${SEED_WORKFLOW_UUIDS[$key]:-00000000-0000-0000-0000-000000000000}"
        printf '%s%s: "%s"\n' "$child_indent" "$key" "$value"
    done
}

# seed::render_default_state_uuid_block <indent>
#   Echo the YAML lines for the `default_state_uuids:` block.
seed::render_default_state_uuid_block() {
    local indent="$1"
    local child_indent
    child_indent="${indent}  "

    printf '%sdefault_state_uuids:\n' "$indent"

    local key value
    # "done" is quoted to keep shellcheck SC1010 from misreading the literal
    # iteration value as the loop-terminator keyword.
    for key in todo in_progress "done"; do
        value="${SEED_DEFAULT_STATE_UUIDS[$key]:-00000000-0000-0000-0000-000000000000}"
        printf '%s%s: "%s"\n' "$child_indent" "$key" "$value"
    done
}

# seed::write_config_uuids
#   Splice the captured UUIDs into linear-config.yml. Strategy: a pure-bash
#   line-by-line rewrite that emits every input line verbatim EXCEPT when it
#   encounters the `workflow_state_uuids:` or `default_state_uuids:` opener;
#   on those, it emits the freshly-rendered replacement block in place of the
#   opener and then discards every subsequent indented child line until the
#   block ends (next sibling or end-of-`linear:` block).
#
#   When a block is missing entirely from the file (e.g. an older config that
#   pre-dates `default_state_uuids`), the missing block is appended at the
#   end of the `linear:` section.
#
#   We deliberately avoid awk's `-v` here — BSD awk (the macOS default)
#   rejects newline-bearing values, which our multi-line UUID blocks would
#   need. Pure bash also keeps the splice trivially testable from bats.
seed::write_config_uuids() {
    if (( ARG_WORKSPACE_ONLY == 1 )); then
        seed::log "--workspace-only: skipping config write"
        return 0
    fi
    if (( ARG_DRY_RUN == 1 )); then
        seed::log "DRY-RUN: skipping config write (would update ${SEED_CONFIG_PATH})"
        return 0
    fi

    seed::ensure_config || return $?

    # Render the two replacement blocks at the canonical indent (2 spaces —
    # children of `linear:`, sibling of `team:` / `project:`).
    local wf_block default_block
    wf_block="$(seed::render_workflow_uuid_block "  ")"
    default_block="$(seed::render_default_state_uuid_block "  ")"

    local tmp_out
    tmp_out="$(mktemp -t speckit-linear-seed.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp_out}'" RETURN

    # Per-line state machine:
    #   state="normal"      — emit verbatim
    #   state="skip_wf"     — inside an old workflow_state_uuids block; drop
    #                         children, resume on first non-child line
    #   state="skip_default"— inside an old default_state_uuids block; ditto
    #
    # in_linear tracks whether we're inside the top-level `linear:` block so
    # we know to append missing replacement blocks before the next top-level
    # key (or at EOF).
    local state="normal"
    local in_linear=0
    local wf_seen=0
    local default_seen=0
    local line

    # IFS= + read -r + the `|| [[ -n "$line" ]]` tail preserves the final
    # line even when the file lacks a trailing newline.
    while IFS= read -r line || [[ -n "$line" ]]; do
        # End-of-`linear:` block — first top-level (no-leading-whitespace)
        # key after we entered it. Flush any missing replacement blocks
        # before the new top-level key.
        if (( in_linear == 1 )) && [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*: ]]; then
            if (( wf_seen == 0 )); then
                printf '%s\n' "$wf_block" >>"$tmp_out"
                wf_seen=1
            fi
            if (( default_seen == 0 )); then
                printf '%s\n' "$default_block" >>"$tmp_out"
                default_seen=1
            fi
            in_linear=0
            state="normal"
            printf '%s\n' "$line" >>"$tmp_out"
            continue
        fi

        # Top-level `linear:` opener — record + emit.
        if [[ "$line" =~ ^linear:[[:space:]]*$ ]]; then
            in_linear=1
            state="normal"
            printf '%s\n' "$line" >>"$tmp_out"
            continue
        fi

        # workflow_state_uuids opener — emit replacement, skip its children.
        if [[ "$state" == "normal" ]] \
            && [[ "$line" =~ ^[[:space:]]+workflow_state_uuids:[[:space:]]*$ ]]; then
            printf '%s\n' "$wf_block" >>"$tmp_out"
            wf_seen=1
            state="skip_wf"
            continue
        fi

        # default_state_uuids opener — same.
        if [[ "$state" == "normal" ]] \
            && [[ "$line" =~ ^[[:space:]]+default_state_uuids:[[:space:]]*$ ]]; then
            printf '%s\n' "$default_block" >>"$tmp_out"
            default_seen=1
            state="skip_default"
            continue
        fi

        # While skipping an old replacement block, drop deeply-indented
        # children (4+ spaces) and comments. Any line at 2-or-fewer spaces
        # of indent is a sibling key — exit skip mode and re-process this
        # line as normal by re-emitting through the default branch.
        if [[ "$state" == "skip_wf" ]] || [[ "$state" == "skip_default" ]]; then
            if [[ "$line" =~ ^\ \ \ \ [^[:space:]] ]] \
                || [[ "$line" =~ ^[[:space:]]+# ]]; then
                # Indented child / nested comment — drop it.
                continue
            fi
            # Sibling or blank — leave skip mode and fall through to emit.
            state="normal"
        fi

        # Default: emit verbatim.
        printf '%s\n' "$line" >>"$tmp_out"
    done <"$SEED_CONFIG_PATH"

    # File ended mid-`linear:` block — flush any missing replacement blocks
    # at the end so the resulting config is complete even when the operator
    # has truncated the file to bare essentials.
    if (( in_linear == 1 )); then
        if (( wf_seen == 0 )); then
            printf '%s\n' "$wf_block" >>"$tmp_out"
        fi
        if (( default_seen == 0 )); then
            printf '%s\n' "$default_block" >>"$tmp_out"
        fi
    fi

    # Atomic-ish replace. `mv` on the same filesystem is atomic; if the
    # operator is doing something exotic (NFS, etc.) the previous file
    # contents are still recoverable from the tempfile location until the
    # trap fires.
    mv "$tmp_out" "$SEED_CONFIG_PATH"
    seed::log "wrote ${SEED_CONFIG_PATH}"
}

# =============================================================================
# Step 7 — Main orchestration.
# =============================================================================
main() {
    seed::parse_args "$@"

    summary::start "speckit.linear seed"

    local team_uuid
    if ! team_uuid="$(seed::resolve_team_uuid)"; then
        # resolve_team_uuid already aggregated the error via summary::add.
        summary::emit
        exit "$SEED_EXIT_CODE"
    fi
    seed::log "team UUID: ${team_uuid}"
    if (( ARG_DRY_RUN == 1 )); then
        seed::log "DRY-RUN MODE: no Linear mutations will be issued; no config write"
    fi
    if (( ARG_WORKSPACE_ONLY == 1 )); then
        seed::log "--workspace-only: linear-config.yml will NOT be written"
    fi

    # T058: workflow states (9).
    seed::reconcile_workflow_states "$team_uuid"

    # Default-state capture (FR-005 / contracts §4.3) — Todo / In Progress /
    # Done UUIDs into SEED_DEFAULT_STATE_UUIDS.
    seed::capture_default_states "$team_uuid"

    # T059: labels (9 phase:* + 9 task-phase:N = 18 total).
    seed::reconcile_labels

    # T060 (write-back half): splice captured UUIDs into linear-config.yml.
    seed::write_config_uuids

    summary::emit

    # If any summary error fired, ensure exit code reflects that.
    if summary::has_errors; then
        seed::promote_exit 1
    fi

    exit "$SEED_EXIT_CODE"
}

# Allow sourcing under bats / unit tests without invoking main().
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
