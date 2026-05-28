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
    # Phase 3: empty-list picker prompts for choice 1 (the lone
    # "Create new project" option) — feed stdin via process
    # substitution so the helper's $INSTALL_SESSION_PROJECT_CHOICE
    # propagates to the test scope.
    _source_install_sh
    INSTALL_SESSION_PROJECTS_IDS=()
    INSTALL_SESSION_PROJECTS_NAMES=()
    install::pick_project_interactively < <(printf '1\n')
    [ "$INSTALL_SESSION_PROJECT_CHOICE" = "create" ]
}

@test "T208 stub: install::prompt_new_project_name exists as a function" {
    _source_install_sh
    run type -t install::prompt_new_project_name
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

@test "T208 stub: install::prompt_new_project_name defaults to repo basename" {
    # Phase 3: prompt_new_project_name now reads stdin. Feed empty input
    # to accept the default (repo basename or pwd basename).
    _source_install_sh
    local name
    name="$(install::prompt_new_project_name < <(printf '\n'))"
    [ -n "$name" ]
}

@test "T209 stub: install::quick_validate_binding exists as a function" {
    _source_install_sh
    run type -t install::quick_validate_binding
    [ "$status" -eq 0 ]
    [ "$output" = "function" ]
}

# NOTE: the Phase 2 stub test "stores both UUIDs on session" was removed
# when Phase 4 (T248) replaced the stub with a full GraphQL-driven
# validator. The stub stored its two args verbatim; the real helper now
# issues a `quick-validate` query and only populates the session block
# on a successful round trip. Calling it with bare UUIDs and no mocked
# graphql::query no longer stores anything (the validation query fails
# first). The real behaviour — UUIDs stored on a successful validate,
# plus the three failure modes (team-null, project-null, mismatch) — is
# covered by T245 in tests/unit/install_backwards_compat.bats with a
# properly mocked graphql::query. See Assumption A16 in tasks.md.

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

# Phase 3 tests appended below.


# =============================================================================
# Phase 3 — User Story 1 tests (T221..T231).
#
# These exercise the full FR-037..FR-043 behaviour through the helpers
# implemented in Phase 3 tasks T232..T240. The Phase 2 stubs returned
# early without prompting; these assert the post-Phase-3 behaviour:
# full read-loop, picker rendering, write-order guard, and SC-010
# zero-UUID surface.
# =============================================================================

# ---------------------------------------------------------------------------
# T221 — FR-037 API key resolution (precedence order).
# ---------------------------------------------------------------------------

@test "T221: install::prompt_for_api_key honours LINEAR_API_KEY env var (precedence 1)" {
    _source_install_sh
    export LINEAR_API_KEY="lin_api_env_winner"
    printf 'LINEAR_API_KEY=lin_api_dotenv_loser\n' > .env
    install::prompt_for_api_key
    [ "$INSTALL_SESSION_API_KEY" = "lin_api_env_winner" ]
    [ "$INSTALL_SESSION_API_KEY_SOURCE" = "env" ]
}

@test "T221: install::prompt_for_api_key reads .env when env var absent (precedence 2)" {
    _source_install_sh
    unset LINEAR_API_KEY
    printf 'LINEAR_API_KEY=lin_api_dotenv_value\n' > .env
    install::prompt_for_api_key
    [ "$INSTALL_SESSION_API_KEY" = "lin_api_dotenv_value" ]
    [ "$INSTALL_SESSION_API_KEY_SOURCE" = "dotenv" ]
}

@test "T221: install::prompt_for_api_key reads stdin when env+dotenv absent (precedence 3)" {
    unset LINEAR_API_KEY
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_FLAG_NON_INTERACTIVE=0
        install::prompt_for_api_key < <(printf 'lin_api_prompt_value\nn\n')
        printf 'KEY=%s SRC=%s\n' \"\$INSTALL_SESSION_API_KEY\" \"\$INSTALL_SESSION_API_KEY_SOURCE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEY=lin_api_prompt_value SRC=prompt"* ]]
}

# ---------------------------------------------------------------------------
# T222 — FR-037 "Save to .env?" flow + .gitignore guard.
# ---------------------------------------------------------------------------

@test "T222: save-to-.env Y writes LINEAR_API_KEY to .env" {
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_FLAG_NON_INTERACTIVE=0
        install::prompt_for_api_key < <(printf 'lin_api_saved\nY\n')
    "
    [ "$status" -eq 0 ]
    [ -f "${TEST_TMP}/.env" ]
    grep -q '^LINEAR_API_KEY=lin_api_saved$' "${TEST_TMP}/.env"
}

@test "T222: save-to-.env flow ensures .env is in .gitignore" {
    : > "${TEST_TMP}/.gitignore"
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_FLAG_NON_INTERACTIVE=0
        install::prompt_for_api_key < <(printf 'lin_api_saved\nY\n')
    "
    [ "$status" -eq 0 ]
    grep -qE '^\.env$' "${TEST_TMP}/.gitignore"
}

@test "T222: save-to-.env N skips .env write" {
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_FLAG_NON_INTERACTIVE=0
        install::prompt_for_api_key < <(printf 'lin_api_not_saved\nN\n')
    "
    [ "$status" -eq 0 ]
    [ ! -f "${TEST_TMP}/.env" ]
}

# ---------------------------------------------------------------------------
# T223 — FR-037 .env conflict triage (overwrite/keep/abort).
# ---------------------------------------------------------------------------

@test "T223: .env conflict 'overwrite' rewrites existing LINEAR_API_KEY line" {
    printf 'OTHER_VAR=keep_me\nLINEAR_API_KEY=lin_api_old\n' > "${TEST_TMP}/.env"
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_SESSION_API_KEY='lin_api_new'
        INSTALL_SESSION_API_KEY_SOURCE='prompt'
        install::_resolve_dotenv_conflict < <(printf 'overwrite\n')
    "
    [ "$status" -eq 0 ]
    grep -q '^LINEAR_API_KEY=lin_api_new$' "${TEST_TMP}/.env"
    grep -q '^OTHER_VAR=keep_me$' "${TEST_TMP}/.env"
}

@test "T223: .env conflict 'keep' discards new key, re-resolves from .env" {
    printf 'LINEAR_API_KEY=lin_api_existing\n' > "${TEST_TMP}/.env"
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_SESSION_API_KEY='lin_api_replacement'
        INSTALL_SESSION_API_KEY_SOURCE='prompt'
        install::_resolve_dotenv_conflict < <(printf 'keep\n')
        printf 'KEY=%s\n' \"\$INSTALL_SESSION_API_KEY\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEY=lin_api_existing"* ]]
}

@test "T223: .env conflict 'abort' exits 0 without writing" {
    printf 'LINEAR_API_KEY=lin_api_existing\n' > "${TEST_TMP}/.env"
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_SESSION_API_KEY='lin_api_replacement'
        INSTALL_SESSION_API_KEY_SOURCE='prompt'
        install::_resolve_dotenv_conflict < <(printf 'abort\n')
    "
    [ "$status" -eq 0 ]
    grep -q '^LINEAR_API_KEY=lin_api_existing$' "${TEST_TMP}/.env"
}

# ---------------------------------------------------------------------------
# T224 — FR-048 viewer query single-fire invariant + organization fields.
# ---------------------------------------------------------------------------

@test "T224: install::resolve_operator issues exactly one viewer query (FR-048)" {
    _source_install_sh
    _install_graphql_stub
    INSTALL_TEST_FIXTURE_PATH="${INSTALL_TEST_FIXTURE_DIR}/viewer.json"
    export LINEAR_API_KEY="lin_api_test"
    install::resolve_operator
    [ "$(_graphql_call_count)" = "1" ]
    [ "$INSTALL_SESSION_VIEWER_ID" = "11111111-2222-3333-4444-555555555555" ]
    [ "$INSTALL_SESSION_VIEWER_ORG_NAME" = "OSH Infra" ]
    [ "$INSTALL_SESSION_VIEWER_ORG_URL_KEY" = "osh-infra" ]
    [ "$INSTALL_OPERATOR_USER_ID" = "11111111-2222-3333-4444-555555555555" ]
}

@test "T224: viewer query body selects organization fields per FR-048" {
    _source_install_sh
    _install_graphql_stub
    INSTALL_TEST_FIXTURE_PATH="${INSTALL_TEST_FIXTURE_DIR}/viewer.json"
    export LINEAR_API_KEY="lin_api_test"
    install::resolve_operator
    local logged
    logged="$(jq -r '.query' "${INSTALL_TEST_CALL_LOG}/queries.jsonl")"
    [[ "$logged" == *"organization"* ]]
    [[ "$logged" == *"urlKey"* ]]
}

# ---------------------------------------------------------------------------
# T225 — FR-039 team picker branches.
# ---------------------------------------------------------------------------

@test "T225: team discovery auto-picks the only team in the workspace" {
    _source_install_sh
    _install_graphql_stub
    INSTALL_TEST_FIXTURE_PATH="${INSTALL_TEST_FIXTURE_DIR}/teams_single.json"
    install::discover_teams
    install::pick_team_interactively
    [ "$INSTALL_SESSION_SELECTED_TEAM_KEY" = "OSH" ]
    [ -n "$INSTALL_SESSION_SELECTED_TEAM_ID" ]
}

@test "T225: team discovery — multi-pick honours operator pick '2'" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/teams_multi.json'; }
        install::discover_teams
        install::pick_team_interactively < <(printf '2\n')
        printf 'KEY=%s NAME=%s\n' \"\$INSTALL_SESSION_SELECTED_TEAM_KEY\" \"\$INSTALL_SESSION_SELECTED_TEAM_NAME\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"KEY=ENG NAME=Engineering"* ]]
}

@test "T225: team discovery — zero teams halts exit 2" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/teams_zero.json'; }
        install::discover_teams
        install::pick_team_interactively
    "
    [ "$status" -eq 2 ]
}

@test "T225: team discovery — overflow surfaces warning + --team pointer" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/teams_overflow.json'; }
        install::discover_teams
        install::pick_team_interactively < <(printf '1\n') 2>&1
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"more not shown"* ]]
    [[ "$output" == *"--team"* ]]
}
# ---------------------------------------------------------------------------
# T226 — FR-040 project picker branches.
# ---------------------------------------------------------------------------

@test "T226: project discovery — empty list forces 'create' (only option)" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/projects_empty.json'; }
        INSTALL_SESSION_SELECTED_TEAM_ID='6ab43461-6d22-4f02-bb1e-0be9859c7997'
        INSTALL_SESSION_SELECTED_TEAM_KEY='OSH'
        INSTALL_SESSION_SELECTED_TEAM_NAME='OSH'
        install::discover_projects
        install::pick_project_interactively < <(printf '1\n')
        printf 'CHOICE=%s\n' \"\$INSTALL_SESSION_PROJECT_CHOICE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHOICE=create"* ]]
}

@test "T226: project discovery — multi-pick attaches to operator's choice" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/projects_multi.json'; }
        INSTALL_SESSION_SELECTED_TEAM_ID='6ab43461-6d22-4f02-bb1e-0be9859c7997'
        INSTALL_SESSION_SELECTED_TEAM_KEY='OSH'
        INSTALL_SESSION_SELECTED_TEAM_NAME='OSH'
        install::discover_projects
        install::pick_project_interactively < <(printf '2\n')
        printf 'CHOICE=%s NAME=%s\n' \"\$INSTALL_SESSION_PROJECT_CHOICE\" \"\$INSTALL_SESSION_SELECTED_PROJECT_NAME\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHOICE=attach NAME=acme-backend"* ]]
}

@test "T226: project discovery — choosing N+1 tail sets choice=create" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/projects_multi.json'; }
        INSTALL_SESSION_SELECTED_TEAM_ID='6ab43461-6d22-4f02-bb1e-0be9859c7997'
        INSTALL_SESSION_SELECTED_TEAM_KEY='OSH'
        INSTALL_SESSION_SELECTED_TEAM_NAME='OSH'
        install::discover_projects
        install::pick_project_interactively < <(printf '4\n')
        printf 'CHOICE=%s\n' \"\$INSTALL_SESSION_PROJECT_CHOICE\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHOICE=create"* ]]
}

# ---------------------------------------------------------------------------
# T227 — FR-041 projectCreate happy path + duplicate-name triage.
# ---------------------------------------------------------------------------

@test "T227: install::create_linear_project happy path captures name/url" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::mutate() { cat '${INSTALL_TEST_FIXTURE_DIR}/projectCreate_ok.json'; }
        install::create_linear_project '6ab43461-6d22-4f02-bb1e-0be9859c7997' 'spec-kit-linear'
        printf 'NAME=%s URL=%s\n' \"\$INSTALL_SESSION_SELECTED_PROJECT_NAME\" \"\$INSTALL_SESSION_SELECTED_PROJECT_URL\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"NAME=spec-kit-linear"* ]]
    [[ "$output" == *"URL=https://linear.app/osh-infra/project/"* ]]
}

@test "T227: duplicate-name triage 'pick-existing' attaches to existing match" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() {
            printf '%s' '{\"data\":{\"projects\":{\"nodes\":[{\"id\":\"97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080\",\"name\":\"spec-kit-linear\",\"url\":\"https://linear.app/osh-infra/project/spec-kit-linear-97bca3d5ede3\"}]}}}'
        }
        install::_handle_duplicate_name '6ab43461-6d22-4f02-bb1e-0be9859c7997' 'spec-kit-linear' < <(printf 'pick-existing\n')
        printf 'CHOICE=%s NAME=%s\n' \"\$INSTALL_SESSION_PROJECT_CHOICE\" \"\$INSTALL_SESSION_SELECTED_PROJECT_NAME\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHOICE=attach NAME=spec-kit-linear"* ]]
}

# ---------------------------------------------------------------------------
# T228 — FR-041 projectCreate failure surface.
# ---------------------------------------------------------------------------

@test "T228: install::create_linear_project surfaces Linear error on success=false" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::mutate() { cat '${INSTALL_TEST_FIXTURE_DIR}/projectCreate_fail.json'; }
        install::create_linear_project '6ab43461-6d22-4f02-bb1e-0be9859c7997' 'spec-kit-linear'
    "
    [ "$status" -eq 1 ]
    [[ "$output" == *"permission"* ]]
}

# ---------------------------------------------------------------------------
# T229 — FR-042 / FR-043 write-order invariant.
# ---------------------------------------------------------------------------

@test "T229: linear-config.yml is written before any hook registration call" {
    _source_install_sh
    local order_log="${BATS_TEST_TMPDIR}/order.log"
    : > "$order_log"
    install::write_config() { printf 'write_config\n' >> "$order_log"; }
    install::register_after_hooks() { printf 'register_after_hooks\n' >> "$order_log"; }
    install::install_git_hooks() { printf 'install_git_hooks\n' >> "$order_log"; }
    install::install_github_action() { printf 'install_github_action\n' >> "$order_log"; return 0; }

    install::write_config "stub-team" "stub-project"
    install::register_after_hooks
    install::install_git_hooks
    install::install_github_action

    [ "$(head -n1 "$order_log")" = "write_config" ]
    grep -qx 'register_after_hooks' "$order_log"
    grep -qx 'install_git_hooks' "$order_log"
}

# ---------------------------------------------------------------------------
# T230 — SC-010 zero-UUID surface assertion across the full discovery flow.
# ---------------------------------------------------------------------------

@test "T230: full discovery flow never surfaces a UUID on stderr/stdout (SC-010)" {
    local uuid_regex='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    local combined
    combined="$(bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() {
            case \"\$1\" in
                *viewer*) cat '${INSTALL_TEST_FIXTURE_DIR}/viewer.json' ;;
                *Teams*|*teams*) cat '${INSTALL_TEST_FIXTURE_DIR}/teams_multi.json' ;;
                *projects*) cat '${INSTALL_TEST_FIXTURE_DIR}/projects_multi.json' ;;
            esac
        }
        export LINEAR_API_KEY='lin_api_test'
        install::resolve_operator
        install::discover_teams
        install::pick_team_interactively < <(printf '1\n')
        install::discover_projects
        install::pick_project_interactively < <(printf '1\n')
    " 2>&1 || true)"
    if printf '%s' "$combined" | grep -qE "$uuid_regex"; then
        printf 'SC-010 violation: UUID surfaced in output\n%s\n' "$combined" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T231 — integration harness pointer (lives under tests/integration/).
# ---------------------------------------------------------------------------

@test "T231: integration harness install_e2e_discovery.bats exists" {
    [ -f "${PROJECT_ROOT}/tests/integration/install_e2e_discovery.bats" ]
}

# =============================================================================
# US1 acceptance scenarios (spec.md US1 scenarios 1..4).
# =============================================================================

@test "US1-scenario-1: fresh repo (no .env, no config) — discovery completes" {
    [ ! -f "${TEST_TMP}/.env" ]
    [ ! -f "${TEST_TMP}/.specify/extensions/linear/linear-config.yml" ]
    run bash -c "
        cd '${TEST_TMP}'
        unset LINEAR_API_KEY
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() {
            case \"\$1\" in
                *viewer*) cat '${INSTALL_TEST_FIXTURE_DIR}/viewer.json' ;;
                *Teams*|*teams*) cat '${INSTALL_TEST_FIXTURE_DIR}/teams_multi.json' ;;
                *projects*) cat '${INSTALL_TEST_FIXTURE_DIR}/projects_multi.json' ;;
            esac
        }
        INSTALL_FLAG_NON_INTERACTIVE=0
        {
            install::prompt_for_api_key
            install::resolve_operator
            install::discover_teams
            install::pick_team_interactively
            install::discover_projects
            install::pick_project_interactively
        } < <(printf 'lin_api_test\nN\n1\n1\n')
        printf 'TEAM=%s PROJ=%s\n' \"\$INSTALL_SESSION_SELECTED_TEAM_KEY\" \"\$INSTALL_SESSION_SELECTED_PROJECT_NAME\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEAM=OSH PROJ=spec-kit-linear"* ]]
}

@test "US1-scenario-2: single-team workspace — team picker silent (auto-pick)" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/teams_single.json'; }
        install::discover_teams
        install::pick_team_interactively 2>&1
    "
    [ "$status" -eq 0 ]
    [[ ! "$output" == *"Pick a team"* ]]
    [[ "$output" == *"auto-picked"* ]]
}

@test "US1-scenario-3: 'Create new' branch fires projectCreate and surfaces URL" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { printf '%s' '{\"data\":{\"projects\":{\"nodes\":[]}}}'; }
        graphql::mutate() { cat '${INSTALL_TEST_FIXTURE_DIR}/projectCreate_ok.json'; }
        INSTALL_SESSION_SELECTED_TEAM_ID='6ab43461-6d22-4f02-bb1e-0be9859c7997'
        INSTALL_SESSION_SELECTED_TEAM_KEY='OSH'
        INSTALL_SESSION_SELECTED_TEAM_NAME='OSH'
        install::run_create_project_branch < <(printf 'spec-kit-linear\nY\n')
        printf 'URL=%s\n' \"\$INSTALL_SESSION_SELECTED_PROJECT_URL\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"URL=https://linear.app/"* ]]
}

@test "US1-scenario-4: invalid API key — viewer null halts before any picker" {
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() { printf '%s' '{\"data\":{\"viewer\":null}}'; }
        export LINEAR_API_KEY='lin_api_bogus'
        install::resolve_operator
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *"viewer"* || "$output" == *"API key"* || "$output" == *"FR-034"* ]]
}

# =============================================================================
# Phase 5 — User Story 3 (docs + safety guards) unit tests.
#
# T255 covers `install::detect_self_install` (FR-046 self-install guard)
# via three @test blocks: source != target → exit 0, source == target →
# exit 2, source == target via differing path representations (one
# absolute, one with trailing slash) — verifies `pwd -P`
# canonicalisation per plan.md A7.
#
# T256 covers `install::detect_vendored_git` (FR-049 vendored .git/
# warning) via two @test blocks: no `.git/` present → no warning
# emitted, `.git/` present → exactly one `summary::add warned` call
# with the FR-049 remediation string.
# =============================================================================

@test "T255: install::detect_self_install returns 0 when source != target" {
    _source_install_sh
    local src_dir="${BATS_TEST_TMPDIR}/src-distinct"
    local target_dir="${BATS_TEST_TMPDIR}/target-distinct"
    mkdir -p "$src_dir" "$target_dir"
    run install::detect_self_install "$src_dir" "$target_dir"
    [ "$status" -eq 0 ]
}

@test "T255: install::detect_self_install exits 2 when source == target (identical paths)" {
    _source_install_sh
    local shared_dir="${BATS_TEST_TMPDIR}/shared-checkout"
    mkdir -p "$shared_dir"
    run install::detect_self_install "$shared_dir" "$shared_dir"
    [ "$status" -eq 2 ]
    # Verbatim FR-046 message from install-flags.md §4.
    [[ "$output" == *"source path equals target path"* ]]
    [[ "$output" == *"FR-046"* ]]
}

@test "T255: install::detect_self_install canonicalises via pwd -P (trailing slash + absolute variants)" {
    # Plan.md A7: the guard uses `cd && pwd -P` rather than `realpath`.
    # Two path representations of the SAME canonical directory MUST
    # collide: one with a trailing slash, one without.
    _source_install_sh
    local shared_dir="${BATS_TEST_TMPDIR}/shared-canon"
    mkdir -p "$shared_dir"
    run install::detect_self_install "${shared_dir}/" "${shared_dir}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"FR-046"* ]]
}

@test "T256: install::detect_vendored_git is silent when no .git/ is present" {
    _source_install_sh
    summary::start "phase-5 test"
    local source_dir="${BATS_TEST_TMPDIR}/source-clean"
    mkdir -p "${source_dir}/.specify/extensions/linear"
    run install::detect_vendored_git "$source_dir"
    [ "$status" -eq 0 ]
    # No FR-049 warning row should have surfaced on stderr/stdout.
    [[ ! "$output" == *"FR-049"* ]]
    # And the summary's warned counter must still be zero.
    [ "$(summary::count warned)" = "0" ]
}

@test "T256: install::detect_vendored_git emits exactly one warned row with remediation when .git/ present" {
    _source_install_sh
    summary::start "phase-5 test"
    local source_dir="${BATS_TEST_TMPDIR}/source-vendored"
    mkdir -p "${source_dir}/.specify/extensions/linear/.git"
    run install::detect_vendored_git "$source_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FR-049"* ]]
    [[ "$output" == *"rm -rf"* ]]
    [[ "$output" == *".specify/extensions/linear/.git"* ]]

    # Direct (non-`run`) re-call so the side-effect counter survives
    # into the test scope — `run` forks a subshell and the summary
    # state would otherwise be lost.
    summary::start "phase-5 test"
    install::detect_vendored_git "$source_dir" 2>/dev/null
    [ "$(summary::count warned)" = "1" ]
}

# ---------------------------------------------------------------------------
# FR-033 worktree-safe git hooks path.
#
# Regression coverage for the v0.1.1 dogfood bug: install.sh hardcoded the
# local-hook target as `.git/hooks`, which is WRONG in a linked git worktree
# where `.git` is a FILE and hooks live in the common dir (resolved via
# `git rev-parse --git-path hooks`, honouring core.hooksPath). These tests
# build a real temp repo, add a worktree, and assert the resolved target —
# they are hermetic (no network, only local git) so we gate on git presence.
# ---------------------------------------------------------------------------

# _make_worktree_consumer
#
# Create a temp git repo with one commit, add a linked worktree, and seed
# the worktree with the `.specify/` layout install::check_repo_layout needs.
# Echoes the worktree path. Leaves cwd unchanged.
_make_worktree_consumer() {
    local base="${BATS_TEST_TMPDIR}/wt-repo"
    local wt="${BATS_TEST_TMPDIR}/wt-linked"
    git init -q "$base"
    git -C "$base" config user.email "test@example.com"
    git -C "$base" config user.name "Test"
    git -C "$base" commit -q --allow-empty -m "root"
    git -C "$base" worktree add -q -b feat/wt "$wt" >/dev/null 2>&1
    mkdir -p "${wt}/.specify/extensions/linear"
    printf '%s\n' "$wt"
}

@test "FR-033: install::check_repo_layout resolves hooks dir via rev-parse in a worktree (not literal .git/hooks)" {
    command -v git >/dev/null 2>&1 || skip "git not available"
    _source_install_sh
    summary::start "fr-033 worktree test"

    local wt
    wt="$(_make_worktree_consumer)"
    cd "$wt"

    # In a linked worktree `.git` is a FILE, never a hooks directory.
    [ -f "${wt}/.git" ]
    [ ! -d "${wt}/.git/hooks" ]

    install::check_repo_layout >/dev/null 2>&1 || true

    # The canonical worktree-safe answer.
    local expected
    expected="$(git rev-parse --git-path hooks)"
    [ -n "$expected" ]
    # Resolution must NOT be the literal worktree-relative `.git/hooks`.
    [ "$INSTALL_GIT_HOOKS_DIR" != ".git/hooks" ]
    [ "$INSTALL_GIT_HOOKS_DIR" = "$expected" ]
    # And the resolved dir must now exist (mkdir -p ran).
    [ -d "$INSTALL_GIT_HOOKS_DIR" ]
}

@test "FR-033: install::install_git_hooks lands hooks in the rev-parse-resolved dir inside a worktree" {
    command -v git >/dev/null 2>&1 || skip "git not available"
    _source_install_sh
    summary::start "fr-033 worktree test"

    local wt
    wt="$(_make_worktree_consumer)"
    cd "$wt"

    install::check_repo_layout >/dev/null 2>&1 || true
    local hooks_dir
    hooks_dir="$(git rev-parse --git-path hooks)"

    install::install_git_hooks >/dev/null 2>&1 || true

    # At least one shipped template must have landed in the resolved dir.
    local landed=0 name
    for name in post-checkout post-commit post-merge; do
        if [ -f "${hooks_dir}/${name}" ]; then
            landed=1
        fi
        # Nothing should have been written to the bogus worktree .git/hooks.
        [ ! -f "${wt}/.git/hooks/${name}" ]
    done
    [ "$landed" -eq 1 ]
}

@test "FR-033: install::check_repo_layout honours core.hooksPath" {
    command -v git >/dev/null 2>&1 || skip "git not available"
    _source_install_sh
    summary::start "fr-033 hookspath test"

    local base="${BATS_TEST_TMPDIR}/hp-repo"
    git init -q "$base"
    git -C "$base" config user.email "test@example.com"
    git -C "$base" config user.name "Test"
    git -C "$base" config core.hooksPath ".husky"
    mkdir -p "${base}/.specify/extensions/linear"
    cd "$base"

    install::check_repo_layout >/dev/null 2>&1 || true

    local expected
    expected="$(git rev-parse --git-path hooks)"
    [ "$INSTALL_GIT_HOOKS_DIR" = "$expected" ]
    [[ "$INSTALL_GIT_HOOKS_DIR" == *".husky"* ]]
}
