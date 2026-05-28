#!/usr/bin/env bats
# shellcheck shell=bats
#
# tests/unit/install_discovery.bats — unit tests for the spec 002
# install-ergonomics discovery flow (T220 + Phase 3..5 test tasks).
#
# =============================================================================
# Mock strategy
# =============================================================================
# We DO NOT make live Linear API calls. The harness here overrides the
# `graphql::query` function (sourced from `src/graphql.sh`) with a
# fixture-replay stub:
#
#   * The stub reads `INSTALL_TEST_FIXTURE_PATH` (single fixture per
#     call) OR `INSTALL_TEST_FIXTURE_SEQ_<N>` (sequenced fixtures for
#     multi-step flows like teams → projects → projectCreate).
#   * It echoes the fixture's contents verbatim on stdout — exactly
#     what the real `graphql::query` returns after a successful
#     network round trip.
#   * It increments a call-counter file at
#     `${INSTALL_TEST_CALL_LOG}/count` so the FR-048 single-fire
#     invariant test (T224) can assert exact call counts.
#   * It appends each invocation's query body to
#     `${INSTALL_TEST_CALL_LOG}/queries.jsonl` (one JSON line per
#     call) so tests can introspect operation order.
#
# All Phase 3..5 tests use the helpers' module-global side effects
# (`INSTALL_SESSION_*`) rather than stdout to verify behaviour — this
# matches SC-010's "zero UUIDs surfaced" invariant: stdout / stderr
# carry operator-facing prompts only, never internal UUIDs.
#
# Phase 2 scope (this commit): the harness itself + signature
# assertions for the helpers T203–T210. Phase 3..5 tasks (T221+) layer
# the full per-FR behaviour tests on top of this scaffold.
# =============================================================================

setup() {
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
    export PROJECT_ROOT

    # Each test gets its own ephemeral cwd. bats-core auto-cleans
    # BATS_TEST_TMPDIR; we just chdir into a subdir to scope any .env
    # the helpers might write.
    TEST_TMP="${BATS_TEST_TMPDIR}/work"
    mkdir -p "$TEST_TMP"
    cd "$TEST_TMP"

    # Wipe LINEAR_API_KEY from the inherited env so tests opt-in
    # explicitly (env-var path vs. .env path vs. interactive prompt).
    unset LINEAR_API_KEY

    # Fixture-replay state lives alongside the test work dir.
    INSTALL_TEST_FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/linear_responses"
    export INSTALL_TEST_FIXTURE_DIR
    INSTALL_TEST_CALL_LOG="${BATS_TEST_TMPDIR}/graphql-calls"
    mkdir -p "$INSTALL_TEST_CALL_LOG"
    printf '0' > "${INSTALL_TEST_CALL_LOG}/count"
    : > "${INSTALL_TEST_CALL_LOG}/queries.jsonl"
    export INSTALL_TEST_CALL_LOG

    # Speed up retries in any downstream graphql call (defensive — the
    # stub below short-circuits the network path entirely).
    export GRAPHQL_RETRY_BACKOFF=0
}

teardown() {
    # bats-core auto-cleans BATS_TEST_TMPDIR; nothing else to unwind.
    :
}

# ---------------------------------------------------------------------------
# _source_install_sh
#
# Source src/install.sh in a controlled way: we want the function
# definitions (and module-level state declarations) but NOT the
# top-level `install::main` invocation. install.sh already guards the
# entry point with `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` so a
# `source` from bats is safe.
# ---------------------------------------------------------------------------
_source_install_sh() {
    # shellcheck source=../../src/install.sh disable=SC1091
    source "${PROJECT_ROOT}/src/install.sh"
}

# ---------------------------------------------------------------------------
# _install_graphql_stub
#
# Override the real `graphql::query` with a fixture-replay stub.
#
# Usage from a test body:
#
#     _install_graphql_stub
#     INSTALL_TEST_FIXTURE_PATH="${INSTALL_TEST_FIXTURE_DIR}/teams_multi.json"
#     # ... call the helper under test ...
#
# For multi-step flows (e.g. viewer → teams → projects), set
# `INSTALL_TEST_FIXTURE_SEQ` to a space-separated list of fixture
# basenames; the stub plays them back in order.
# ---------------------------------------------------------------------------
_install_graphql_stub() {
    # shellcheck disable=SC2317
    graphql::query() {
        local query="${1:-}"
        local vars="${2:-}"

        # Track call count for FR-048 single-fire invariant assertions.
        local current_count
        current_count="$(cat "${INSTALL_TEST_CALL_LOG}/count")"
        printf '%d' "$(( current_count + 1 ))" > "${INSTALL_TEST_CALL_LOG}/count"

        # Append the call to the JSONL log so tests can introspect the
        # query body and variables. We use jq to keep the line well-formed.
        jq -nc \
            --arg query "$query" \
            --arg vars "$vars" \
            --arg call_n "$(( current_count + 1 ))" \
            '{call_n: ($call_n | tonumber), query: $query, vars: $vars}' \
            >> "${INSTALL_TEST_CALL_LOG}/queries.jsonl"

        # Fixture resolution:
        #   1. INSTALL_TEST_FIXTURE_SEQ — space-separated list,
        #      consumed in order (one fixture per call).
        #   2. INSTALL_TEST_FIXTURE_PATH — single fixture replayed
        #      for every call.
        if [[ -n "${INSTALL_TEST_FIXTURE_SEQ:-}" ]]; then
            local -a seq
            # shellcheck disable=SC2206
            seq=( $INSTALL_TEST_FIXTURE_SEQ )
            local idx=$(( current_count ))
            if (( idx >= ${#seq[@]} )); then
                printf 'install_discovery.bats: fixture sequence exhausted at call %d\n' "$(( current_count + 1 ))" >&2
                return 1
            fi
            cat "${INSTALL_TEST_FIXTURE_DIR}/${seq[$idx]}"
            return 0
        fi

        if [[ -n "${INSTALL_TEST_FIXTURE_PATH:-}" ]]; then
            cat "$INSTALL_TEST_FIXTURE_PATH"
            return 0
        fi

        printf 'install_discovery.bats: no fixture configured for graphql::query call\n' >&2
        return 1
    }
    export -f graphql::query
}

# ---------------------------------------------------------------------------
# _graphql_call_count
#
# Echo the number of times the stubbed `graphql::query` has been
# invoked so far in the current test. Used by FR-048 single-fire
# invariant assertions.
# ---------------------------------------------------------------------------
_graphql_call_count() {
    cat "${INSTALL_TEST_CALL_LOG}/count"
}

# =============================================================================
# Signature assertions for the spec 002 helper stubs (T203–T210).
#
# These tests do NOT exercise the full per-FR behaviour — that lands
# in Phase 3 (T221..T231), Phase 4 (T245..T247), and Phase 5
# (T255..T256). They just verify each helper is defined with the
# expected name + argument-handling contract so the harness is wired
# correctly before the behavioural tests land.
# =============================================================================

@test "T203 stub: install::detect_self_install exists as a function" {
    _source_install_sh
    run type -t install::detect_self_install
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T203 stub: install::detect_self_install returns 0 when src != target" {
    _source_install_sh
    local src_dir="${BATS_TEST_TMPDIR}/src"
    local target_dir="${BATS_TEST_TMPDIR}/target"
    mkdir -p "$src_dir" "$target_dir"
    run install::detect_self_install "$src_dir" "$target_dir"
    [ "$status" -eq 0 ]
}

@test "T203 stub: install::detect_self_install exits 2 when src == target (canonical)" {
    _source_install_sh
    local shared_dir="${BATS_TEST_TMPDIR}/shared"
    mkdir -p "$shared_dir"
    # Pass the same path twice — pwd -P canonicalisation should match.
    run install::detect_self_install "$shared_dir" "$shared_dir"
    [ "$status" -eq 2 ]
}

@test "T204 stub: install::detect_vendored_git exists as a function" {
    _source_install_sh
    run type -t install::detect_vendored_git
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T204 stub: install::detect_vendored_git is silent when no .git/ present" {
    _source_install_sh
    summary::start "test"
    local source_dir="${BATS_TEST_TMPDIR}/clean-source"
    mkdir -p "$source_dir"
    run install::detect_vendored_git "$source_dir"
    [ "$status" -eq 0 ]
}

@test "T204 stub: install::detect_vendored_git warns when .git/ present" {
    _source_install_sh
    summary::start "test"
    local source_dir="${BATS_TEST_TMPDIR}/dirty-source"
    mkdir -p "${source_dir}/.specify/extensions/linear/.git"
    run install::detect_vendored_git "$source_dir"
    [ "$status" -eq 0 ]
    # The warning is emitted via summary::add + install::_log_warn; the
    # combined stderr should mention FR-049.
    [[ "$output" =~ FR-049 ]]
}

@test "T205 stub: install::prompt_for_api_key exists as a function" {
    _source_install_sh
    run type -t install::prompt_for_api_key
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T205 stub: install::prompt_for_api_key honours LINEAR_API_KEY env var" {
    _source_install_sh
    export LINEAR_API_KEY="lin_api_test_env_key"
    install::prompt_for_api_key
    [ "$INSTALL_SESSION_API_KEY" = "lin_api_test_env_key" ]
    [ "$INSTALL_SESSION_API_KEY_SOURCE" = "env" ]
}

@test "T205 stub: install::prompt_for_api_key reads .env when env var absent" {
    _source_install_sh
    unset LINEAR_API_KEY
    printf 'LINEAR_API_KEY=lin_api_test_dotenv_key\n' > .env
    install::prompt_for_api_key
    [ "$INSTALL_SESSION_API_KEY" = "lin_api_test_dotenv_key" ]
    [ "$INSTALL_SESSION_API_KEY_SOURCE" = "dotenv" ]
}

@test "T205 stub: install::prompt_for_api_key halts under --non-interactive without key" {
    _source_install_sh
    unset LINEAR_API_KEY
    INSTALL_FLAG_NON_INTERACTIVE=1
    run install::prompt_for_api_key
    [ "$status" -eq 2 ]
}

@test "T206 stub: install::pick_team_interactively exists as a function" {
    _source_install_sh
    run type -t install::pick_team_interactively
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T206 stub: install::pick_team_interactively auto-picks single team" {
    _source_install_sh
    INSTALL_SESSION_TEAMS_IDS=("6ab43461-6d22-4f02-bb1e-0be9859c7997")
    INSTALL_SESSION_TEAMS_KEYS=("OSH")
    INSTALL_SESSION_TEAMS_NAMES=("OSH Infra")
    install::pick_team_interactively
    [ "$INSTALL_SESSION_SELECTED_TEAM_ID" = "6ab43461-6d22-4f02-bb1e-0be9859c7997" ]
    [ "$INSTALL_SESSION_SELECTED_TEAM_KEY" = "OSH" ]
    [ "$INSTALL_SESSION_SELECTED_TEAM_NAME" = "OSH Infra" ]
}

@test "T206 stub: install::pick_team_interactively halts on zero teams" {
    _source_install_sh
    INSTALL_SESSION_TEAMS_IDS=()
    INSTALL_SESSION_TEAMS_KEYS=()
    INSTALL_SESSION_TEAMS_NAMES=()
    run install::pick_team_interactively
    [ "$status" -eq 2 ]
}

@test "T207 stub: install::pick_project_interactively exists as a function" {
    _source_install_sh
    run type -t install::pick_project_interactively
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T207 stub: install::pick_project_interactively forces 'create' on empty list" {
    _source_install_sh
    INSTALL_SESSION_PROJECTS_IDS=()
    INSTALL_SESSION_PROJECTS_NAMES=()
    install::pick_project_interactively
    [ "$INSTALL_SESSION_PROJECT_CHOICE" = "create" ]
}

@test "T208 stub: install::prompt_new_project_name exists as a function" {
    _source_install_sh
    run type -t install::prompt_new_project_name
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T208 stub: install::prompt_new_project_name defaults to repo basename" {
    _source_install_sh
    # The Phase 2 stub returns `basename "$(git rev-parse --show-toplevel)"`
    # or `basename "$(pwd)"` when git is unavailable. Either way the output
    # MUST be non-empty.
    local name
    name="$(install::prompt_new_project_name)"
    [ -n "$name" ]
}

@test "T209 stub: install::quick_validate_binding exists as a function" {
    _source_install_sh
    run type -t install::quick_validate_binding
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T209 stub: install::quick_validate_binding stores both UUIDs on session" {
    _source_install_sh
    install::quick_validate_binding \
        "6ab43461-6d22-4f02-bb1e-0be9859c7997" \
        "97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080"
    [ "$INSTALL_SESSION_SELECTED_TEAM_ID" = "6ab43461-6d22-4f02-bb1e-0be9859c7997" ]
    [ "$INSTALL_SESSION_SELECTED_PROJECT_ID" = "97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080" ]
}

@test "T210: install::usage documents the interactive default flow" {
    _source_install_sh
    run install::usage
    [ "$status" -eq 0 ]
    [[ "$output" =~ "INTERACTIVE DEFAULT FLOW" ]]
    [[ "$output" =~ "FR-046" ]]
    [[ "$output" =~ "FR-047" ]]
}

@test "T210: install::parse_args logs soft-deprecation when --auto-create used interactively" {
    _source_install_sh
    INSTALL_FLAG_AUTO_CREATE=0
    INSTALL_FLAG_NON_INTERACTIVE=0
    INSTALL_FLAG_TEAM=""
    INSTALL_FLAG_PROJECT=""
    INSTALL_FLAG_HELP=0
    run install::parse_args --team 6ab43461-6d22-4f02-bb1e-0be9859c7997 --auto-create
    [ "$status" -eq 0 ]
    [[ "$output" =~ "--auto-create is deprecated" ]]
}

@test "T210: install::parse_args does NOT log deprecation under --non-interactive" {
    _source_install_sh
    INSTALL_FLAG_AUTO_CREATE=0
    INSTALL_FLAG_NON_INTERACTIVE=0
    INSTALL_FLAG_TEAM=""
    INSTALL_FLAG_PROJECT=""
    INSTALL_FLAG_HELP=0
    run install::parse_args --team 6ab43461-6d22-4f02-bb1e-0be9859c7997 --auto-create --non-interactive
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "--auto-create is deprecated" ]]
}

# =============================================================================
# Fixture round-trip + graphql::query stub harness (T220).
#
# These tests verify the bats harness itself: the JSON fixtures are
# byte-identical to install-discovery-graphql.md §1–§4 (plan.md A10),
# and the graphql::query stub correctly replays them.
# =============================================================================

@test "T211–T219 fixtures: all expected fixture files exist" {
    local expected=(
        viewer.json
        teams_single.json
        teams_multi.json
        teams_overflow.json
        teams_zero.json
        projects_empty.json
        projects_multi.json
        projectCreate_ok.json
        projectCreate_fail.json
    )
    for f in "${expected[@]}"; do
        [ -f "${INSTALL_TEST_FIXTURE_DIR}/${f}" ] || \
            { echo "missing fixture: ${f}" >&2; return 1; }
    done
}

@test "T214 fixture: teams_overflow.json carries exactly 21 team nodes" {
    local count
    count="$(jq '.data.teams.nodes | length' "${INSTALL_TEST_FIXTURE_DIR}/teams_overflow.json")"
    [ "$count" = "21" ]
}

@test "T215 fixture: teams_zero.json carries zero team nodes" {
    local count
    count="$(jq '.data.teams.nodes | length' "${INSTALL_TEST_FIXTURE_DIR}/teams_zero.json")"
    [ "$count" = "0" ]
}

@test "T216 fixture: projects_empty.json carries zero project nodes" {
    local count
    count="$(jq '.data.team.projects.nodes | length' "${INSTALL_TEST_FIXTURE_DIR}/projects_empty.json")"
    [ "$count" = "0" ]
}

@test "T218 fixture: projectCreate_ok.json reports success=true with project.url" {
    local success url
    success="$(jq '.data.projectCreate.success' "${INSTALL_TEST_FIXTURE_DIR}/projectCreate_ok.json")"
    url="$(jq -r '.data.projectCreate.project.url' "${INSTALL_TEST_FIXTURE_DIR}/projectCreate_ok.json")"
    [ "$success" = "true" ]
    [[ "$url" =~ ^https://linear\.app/ ]]
}

@test "T219 fixture: projectCreate_fail.json reports success=false with errors[]" {
    local success errors_len
    success="$(jq '.data.projectCreate.success' "${INSTALL_TEST_FIXTURE_DIR}/projectCreate_fail.json")"
    errors_len="$(jq '.errors | length' "${INSTALL_TEST_FIXTURE_DIR}/projectCreate_fail.json")"
    [ "$success" = "false" ]
    [ "$errors_len" -ge 1 ]
}

@test "T220 stub: graphql::query replays a single fixture from INSTALL_TEST_FIXTURE_PATH" {
    _source_install_sh
    _install_graphql_stub
    INSTALL_TEST_FIXTURE_PATH="${INSTALL_TEST_FIXTURE_DIR}/viewer.json"
    local response
    response="$(graphql::query 'query Viewer { viewer { id } }' '{}')"
    local viewer_id
    viewer_id="$(printf '%s' "$response" | jq -r '.data.viewer.id')"
    [ "$viewer_id" = "11111111-2222-3333-4444-555555555555" ]
    [ "$(_graphql_call_count)" = "1" ]
}

@test "T220 stub: graphql::query plays fixture sequence in order" {
    _source_install_sh
    _install_graphql_stub
    INSTALL_TEST_FIXTURE_SEQ="viewer.json teams_multi.json projects_multi.json"
    local r1 r2 r3
    r1="$(graphql::query 'q1' '{}')"
    r2="$(graphql::query 'q2' '{}')"
    r3="$(graphql::query 'q3' '{}')"
    [ "$(printf '%s' "$r1" | jq -r '.data.viewer.email')" = "ash@example.com" ]
    [ "$(printf '%s' "$r2" | jq -r '.data.teams.nodes | length')" = "3" ]
    [ "$(printf '%s' "$r3" | jq -r '.data.team.projects.nodes | length')" = "3" ]
    [ "$(_graphql_call_count)" = "3" ]
}

@test "T220 stub: graphql::query call log records query bodies" {
    _source_install_sh
    _install_graphql_stub
    INSTALL_TEST_FIXTURE_PATH="${INSTALL_TEST_FIXTURE_DIR}/teams_single.json"
    graphql::query 'query Teams { teams { nodes { id } } }' '{}' >/dev/null
    local logged
    logged="$(jq -r '.query' "${INSTALL_TEST_CALL_LOG}/queries.jsonl")"
    [[ "$logged" =~ "Teams" ]]
}
