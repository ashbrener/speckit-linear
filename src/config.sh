#!/usr/bin/env bash
# shellcheck shell=bash
#
# src/config.sh — loader + validator for
# `.specify/extensions/linear/linear-config.yml`.
#
# Sourced by other bridge scripts. Never executed directly. Public API
# uses the `config::*` namespace per the project convention.
#
# Per Principle V (UUID-based binding) every Linear identifier the
# bridge consumes is a UUID stored in the per-repo config. This module
# enforces that contract on every invocation BEFORE any downstream
# code is allowed to talk to Linear (FR-022, Principle VIII Rule 1).
#
# Behaviour summary:
#   config::load <path>                      — parse + populate state
#   config::get_team_id                      — echo team UUID
#   config::get_project_id                   — echo project UUID
#   config::get_workflow_state_uuid <phase>  — echo UUID for one of the
#       nine lifecycle phases (specifying|clarifying|planning|tasking|
#       red_team|implementing|analyzing|ready_to_merge|merged)
#   config::get_default_state_uuid <key>     — echo UUID for a stock
#       team state used by task-phase sub-issues (todo|in_progress|done).
#       The `default_state_uuids` block is added during the post-analyze
#       remediation; absence is surfaced as an actionable error.
#   config::validate                         — confirm every required
#       UUID is present + well-formed; exit 2 with operator-actionable
#       diagnostics on failure (Principle VIII).
#
# YAML parsing strategy: the config file is shallow (one nesting level
# beneath top-level keys, plus the flat `workflow_state_uuids` and
# `default_state_uuids` maps), so we parse it with awk + sed rather than
# pulling in yq. yq is intentionally NOT a required dependency per
# `plan.md` §Technical Context — keeping the dep surface to bash + curl
# + jq + git lets the bridge install cleanly on a stock macOS / Ubuntu
# operator workstation.

set -euo pipefail

# ---------------------------------------------------------------------------
# Module-level state. All keys are flattened "dotted" paths (e.g.
# `linear.team.id`, `linear.workflow_state_uuids.specifying`). One
# associative array keeps the parser's output discoverable to every
# getter without re-reading the file.
# ---------------------------------------------------------------------------

declare -gA CONFIG_VALUES=()
declare -g CONFIG_LOADED_PATH=""

# UUID regex per RFC 4122 (lowercase hex). Validation accepts upper or
# lower case but the canonical form the seed step emits is lowercase.
readonly CONFIG_UUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# The nine lifecycle phases the seed step captures (FR-021, FR-032).
# Order matches `contracts/config-schema.json` and the data-model doc.
readonly -a CONFIG_WORKFLOW_PHASES=(
    "specifying"
    "clarifying"
    "planning"
    "tasking"
    "red_team"
    "implementing"
    "analyzing"
    "ready_to_merge"
    "merged"
)

# The three stock team states task-phase sub-issues use (FR-005, data
# model § 3.5). Distinct from the nine spec-lifecycle phases above.
readonly -a CONFIG_DEFAULT_STATE_KEYS=(
    "todo"
    "in_progress"
    "done"
)

# ---------------------------------------------------------------------------
# Internal helpers.
# ---------------------------------------------------------------------------

# config::_die <message...>
# Print a structured, operator-actionable error to stderr and exit 2
# (the FR-022 / Principle VIII halt code). All public-API error paths
# funnel through here.
config::_die() {
    local message="$*"
    printf 'spec-kit-linear: config: %s\n' "${message}" >&2
    exit 2
}

# config::_warn <message...>
# Non-fatal companion to `_die` — for cases where the caller wants the
# diagnostic but is responsible for the exit decision (e.g.
# `config::validate` accumulates several issues before exiting).
config::_warn() {
    local message="$*"
    printf 'spec-kit-linear: config: %s\n' "${message}" >&2
}

# config::_strip <raw>
# Trim leading + trailing whitespace and unwrap surrounding single or
# double quotes from a YAML scalar. Comments after `#` are stripped
# upstream in `_parse_file` before this is called.
config::_strip() {
    local value="${1-}"
    # leading whitespace
    value="${value#"${value%%[![:space:]]*}"}"
    # trailing whitespace
    value="${value%"${value##*[![:space:]]}"}"
    # surrounding double quotes
    if [[ "${value}" == \"*\" ]]; then
        value="${value#\"}"
        value="${value%\"}"
    # surrounding single quotes
    elif [[ "${value}" == \'*\' ]]; then
        value="${value#\'}"
        value="${value%\'}"
    fi
    printf '%s' "${value}"
}

# config::_parse_file <path>
# Populate CONFIG_VALUES from a shallow YAML file. The grammar we
# accept matches `config-template.yml`:
#
#   key: value                      # scalar at the current indent level
#   key:                            # nested-block opener
#     child: value                  # child of the most recent opener
#   - item                          # list item under the most recent opener
#
# Two indentation levels are supported (top-level keys plus one nested
# block, with `workflow_state_uuids` / `default_state_uuids` being
# flat maps that live one level deeper than their parent). That is the
# entire shape `config-template.yml` ever produces, so we don't try to
# be a general-purpose YAML parser.
config::_parse_file() {
    local path="$1"
    local line raw_key raw_value
    local indent
    # Parallel arrays simulating a stack: stack[i] is the YAML key at
    # depth i; indents[i] is the column at which that key's CHILDREN
    # must sit. depth is the count of currently-open blocks.
    local -a stack=()
    local -a indents=()
    local depth=0
    local current_prefix=""
    local list_counter=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip trailing CR (Windows-friendly).
        line="${line%$'\r'}"

        # Drop trailing comments. We're permissive: any `#` not inside
        # a balanced-quote run is treated as a comment. The config
        # template never embeds `#` inside scalar values, so the simple
        # split below is safe.
        if [[ "${line}" == *'#'* ]]; then
            local before_hash="${line%%#*}"
            local dq="${before_hash//[^\"]/}"
            local sq="${before_hash//[^\']/}"
            if (( ${#dq} % 2 == 0 )) && (( ${#sq} % 2 == 0 )); then
                line="${before_hash}"
            fi
        fi

        # Skip blank lines.
        if [[ -z "${line//[[:space:]]/}" ]]; then
            continue
        fi

        # Compute leading indent (spaces only; tabs are rejected to
        # keep the operator-edit path predictable).
        if [[ "${line}" == *$'\t'* ]]; then
            config::_die "${path}: tab character in indentation; use spaces only"
        fi
        local lstripped="${line#"${line%%[![:space:]]*}"}"
        indent=$(( ${#line} - ${#lstripped} ))

        # Pop the indent stack until the top frame's child-indent is
        # strictly less than the current line's indent (i.e. the
        # current line is a child of the surviving top frame, or a
        # sibling of the popped one).
        while (( depth > 0 )) && (( indents[depth-1] >= indent )); do
            depth=$(( depth - 1 ))
            unset 'stack[depth]'
            unset 'indents[depth]'
        done

        # Rebuild current_prefix from the surviving stack.
        current_prefix=""
        local d
        for (( d = 0; d < depth; d++ )); do
            if [[ -z "${current_prefix}" ]]; then
                current_prefix="${stack[d]}"
            else
                current_prefix="${current_prefix}.${stack[d]}"
            fi
        done

        # List item under the most-recently-opened block.
        if [[ "${lstripped}" == -* ]]; then
            if [[ -z "${current_prefix}" ]]; then
                config::_die "${path}: list item outside any block: ${lstripped}"
            fi
            local item="${lstripped#-}"
            item="$(config::_strip "${item}")"
            CONFIG_VALUES["${current_prefix}.${list_counter}"]="${item}"
            list_counter=$(( list_counter + 1 ))
            continue
        fi

        # key:value or key:  (block opener)
        if [[ "${lstripped}" != *:* ]]; then
            config::_die "${path}: malformed line (no key:value separator): ${lstripped}"
        fi

        raw_key="${lstripped%%:*}"
        raw_value="${lstripped#*:}"
        raw_key="$(config::_strip "${raw_key}")"
        raw_value="$(config::_strip "${raw_value}")"

        local full_key
        if [[ -z "${current_prefix}" ]]; then
            full_key="${raw_key}"
        else
            full_key="${current_prefix}.${raw_key}"
        fi

        if [[ -z "${raw_value}" ]]; then
            # Block opener — push onto the stack and reset the list
            # counter in case the next non-blank line is a list item.
            stack[depth]="${raw_key}"
            indents[depth]="${indent}"
            depth=$(( depth + 1 ))
            current_prefix="${full_key}"
            list_counter=0
        else
            CONFIG_VALUES["${full_key}"]="${raw_value}"
        fi
    done < "${path}"
}

# ---------------------------------------------------------------------------
# Public API.
# ---------------------------------------------------------------------------

# config::load <path>
# Parse the YAML at <path> and populate module state. Halts with exit
# 2 if the file is missing or unreadable. Other parse failures funnel
# through `config::_die`.
config::load() {
    if (( $# != 1 )); then
        config::_die "config::load requires exactly one argument (path to linear-config.yml)"
    fi

    local path="$1"

    if [[ ! -e "${path}" ]]; then
        config::_die "file not found: ${path}
hint: copy config-template.yml to ${path} and run \`/spec-kit-linear-install\` to populate UUIDs"
    fi

    if [[ ! -r "${path}" ]]; then
        config::_die "file not readable: ${path}"
    fi

    # Reset state so consecutive loads in the same process don't leak.
    CONFIG_VALUES=()
    CONFIG_LOADED_PATH="${path}"

    config::_parse_file "${path}"
}

# config::_require_loaded
# Internal guard for every getter. Refuses to operate on empty state.
config::_require_loaded() {
    if [[ -z "${CONFIG_LOADED_PATH}" ]]; then
        config::_die "no config loaded; call \`config::load <path>\` first"
    fi
}

# config::get_team_id
# Echo the Linear team UUID. Halts if the field is absent.
config::get_team_id() {
    config::_require_loaded
    local value="${CONFIG_VALUES[linear.team.id]:-}"
    if [[ -z "${value}" ]]; then
        config::_die "${CONFIG_LOADED_PATH}: linear.team.id is missing"
    fi
    printf '%s\n' "${value}"
}

# config::get_project_id
# Echo the Linear project UUID. Halts if the field is absent.
config::get_project_id() {
    config::_require_loaded
    local value="${CONFIG_VALUES[linear.project.id]:-}"
    if [[ -z "${value}" ]]; then
        config::_die "${CONFIG_LOADED_PATH}: linear.project.id is missing"
    fi
    printf '%s\n' "${value}"
}

# config::get_operator_user_id
# Echo the Linear operator user UUID captured at install time via the
# `viewer` query (FR-034). Empty (no halt) if absent — the reconciler
# treats absence as a warning and creates Issues unassigned per the
# graceful-degradation clause of FR-034. NOT added to config::validate's
# required-fields list for the same reason.
config::get_operator_user_id() {
    config::_require_loaded
    printf '%s\n' "${CONFIG_VALUES[linear.operator.user_id]:-}"
}

# config::get_operator_name
# Echo the Linear operator's display name (informational; populated by
# the install step's `viewer { name }` capture per FR-034). Empty if
# absent.
config::get_operator_name() {
    config::_require_loaded
    printf '%s\n' "${CONFIG_VALUES[linear.operator.name]:-}"
}

# config::get_operator_email
# Echo the Linear operator's email (informational; populated by the
# install step's `viewer { email }` capture per FR-034). Empty if
# absent.
config::get_operator_email() {
    config::_require_loaded
    printf '%s\n' "${CONFIG_VALUES[linear.operator.email]:-}"
}

# config::get_workflow_state_uuid <lifecycle_phase>
# Echo the workflow-state UUID for one of the nine lifecycle phases
# (specifying|clarifying|planning|tasking|red_team|implementing|
# analyzing|ready_to_merge|merged). Halts on unknown phase or missing
# UUID with a remediation pointer to `speckit.linear.seed`.
config::get_workflow_state_uuid() {
    config::_require_loaded
    if (( $# != 1 )); then
        config::_die "config::get_workflow_state_uuid requires exactly one argument (lifecycle phase)"
    fi

    local phase="$1"
    local known=0
    local candidate
    for candidate in "${CONFIG_WORKFLOW_PHASES[@]}"; do
        if [[ "${candidate}" == "${phase}" ]]; then
            known=1
            break
        fi
    done

    if (( known == 0 )); then
        config::_die "unknown lifecycle phase: ${phase}
hint: valid phases are ${CONFIG_WORKFLOW_PHASES[*]}"
    fi

    local value="${CONFIG_VALUES[linear.workflow_state_uuids.${phase}]:-}"
    if [[ -z "${value}" ]]; then
        config::_die "${CONFIG_LOADED_PATH}: linear.workflow_state_uuids.${phase} is missing
hint: run \`/spec-kit-linear-seed\` to re-capture workflow-state UUIDs"
    fi
    printf '%s\n' "${value}"
}

# config::get_default_state_uuid <todo|in_progress|done>
# Echo the UUID for one of the three stock team states task-phase
# sub-issues use (FR-005). The `default_state_uuids` block is added
# during the post-analyze remediation; if absent, surface the gap.
config::get_default_state_uuid() {
    config::_require_loaded
    if (( $# != 1 )); then
        config::_die "config::get_default_state_uuid requires exactly one argument (todo|in_progress|done)"
    fi

    local key="$1"
    local known=0
    local candidate
    for candidate in "${CONFIG_DEFAULT_STATE_KEYS[@]}"; do
        if [[ "${candidate}" == "${key}" ]]; then
            known=1
            break
        fi
    done

    if (( known == 0 )); then
        config::_die "unknown default-state key: ${key}
hint: valid keys are ${CONFIG_DEFAULT_STATE_KEYS[*]}"
    fi

    local value="${CONFIG_VALUES[linear.default_state_uuids.${key}]:-}"
    if [[ -z "${value}" ]]; then
        config::_die "${CONFIG_LOADED_PATH}: linear.default_state_uuids.${key} is missing
hint: run \`/spec-kit-linear-seed\` to capture stock team-state UUIDs (todo/in_progress/done)"
    fi
    printf '%s\n' "${value}"
}

# config::validate
# Confirm every required UUID is present and well-formed. Returns 0 on
# success; on failure, prints a list of missing/malformed fields to
# stderr (each prefixed with the source file path so the operator can
# jump straight to the offending line) and exits 2.
#
# Required fields:
#   schema_version                                 (must equal 1)
#   linear.team.id                                 (UUID)
#   linear.project.id                              (UUID)
#   linear.workflow_state_uuids.<each of 9>        (UUID)
#   linear.default_state_uuids.<each of 3>         (UUID; only checked if the block is present)
#
# `default_state_uuids` is treated as optional-but-validated: missing
# block → soft warning so old configs still load; partial block →
# hard failure so half-finished seeds can't ship.
config::validate() {
    config::_require_loaded

    local -a problems=()
    local path="${CONFIG_LOADED_PATH}"

    # schema_version sanity check (the JSON Schema pins it to 1).
    local schema_version="${CONFIG_VALUES[schema_version]:-}"
    if [[ -z "${schema_version}" ]]; then
        problems+=("${path}: schema_version: missing (expected 1)")
    elif [[ "${schema_version}" != "1" ]]; then
        problems+=("${path}: schema_version: got '${schema_version}', expected 1")
    fi

    # team + project UUIDs.
    local field
    for field in "linear.team.id" "linear.project.id"; do
        local value="${CONFIG_VALUES[${field}]:-}"
        if [[ -z "${value}" ]]; then
            problems+=("${path}: ${field}: missing")
        elif ! [[ "${value}" =~ ${CONFIG_UUID_REGEX} ]]; then
            problems+=("${path}: ${field}: malformed UUID ('${value}')")
        elif [[ "${value}" == "00000000-0000-0000-0000-000000000000" ]]; then
            problems+=("${path}: ${field}: still set to the zero placeholder UUID; run \`/spec-kit-linear-install\` to resolve it")
        fi
    done

    # workflow_state_uuids — all nine required.
    local phase
    for phase in "${CONFIG_WORKFLOW_PHASES[@]}"; do
        local key="linear.workflow_state_uuids.${phase}"
        local value="${CONFIG_VALUES[${key}]:-}"
        if [[ -z "${value}" ]]; then
            problems+=("${path}: ${key}: missing (run \`/spec-kit-linear-seed\`)")
        elif ! [[ "${value}" =~ ${CONFIG_UUID_REGEX} ]]; then
            problems+=("${path}: ${key}: malformed UUID ('${value}')")
        elif [[ "${value}" == "00000000-0000-0000-0000-000000000000" ]]; then
            problems+=("${path}: ${key}: still set to the zero placeholder UUID; run \`/spec-kit-linear-seed\`")
        fi
    done

    # default_state_uuids — optional block, but if any key is present
    # ALL three must be present + well-formed.
    local default_block_present=0
    local default_key
    for default_key in "${CONFIG_DEFAULT_STATE_KEYS[@]}"; do
        if [[ -n "${CONFIG_VALUES[linear.default_state_uuids.${default_key}]:-}" ]]; then
            default_block_present=1
            break
        fi
    done

    if (( default_block_present == 1 )); then
        for default_key in "${CONFIG_DEFAULT_STATE_KEYS[@]}"; do
            local dkey="linear.default_state_uuids.${default_key}"
            local dvalue="${CONFIG_VALUES[${dkey}]:-}"
            if [[ -z "${dvalue}" ]]; then
                problems+=("${path}: ${dkey}: missing (partial default_state_uuids block)")
            elif ! [[ "${dvalue}" =~ ${CONFIG_UUID_REGEX} ]]; then
                problems+=("${path}: ${dkey}: malformed UUID ('${dvalue}')")
            elif [[ "${dvalue}" == "00000000-0000-0000-0000-000000000000" ]]; then
                problems+=("${path}: ${dkey}: still set to the zero placeholder UUID; run \`/spec-kit-linear-seed\`")
            fi
        done
    fi

    if (( ${#problems[@]} > 0 )); then
        config::_warn "validation failed for ${path}:"
        local problem
        for problem in "${problems[@]}"; do
            printf '  - %s\n' "${problem}" >&2
        done
        exit 2
    fi

    return 0
}
