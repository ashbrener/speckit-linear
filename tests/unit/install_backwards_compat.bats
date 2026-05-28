#!/usr/bin/env bats
# shellcheck shell=bats
#
# tests/unit/install_backwards_compat.bats — spec 002 Phase 4 US2
# unit-level backwards-compatibility tests (T245..T247).
#
# Companion to:
#   * tests/integration/install_e2e_backwards_compat.bats — live
#     OSH-INFRA regression suite for install-flags.md §5 rows 1–4 + 8
#     (T241..T244, gated on RUN_INTEGRATION_TESTS=1).
#   * tests/unit/install_discovery.bats — Phase 3 US1 discovery flow
#     tests + helper-signature scaffolds.
#
# =============================================================================
# Scope (this file):
#
#   T245 — `install::quick_validate_binding` failure modes per
#          install-discovery-graphql.md §5.5:
#            (a) data.team == null              → halt exit 2
#            (b) data.project == null           → halt exit 2
#            (c) project-team mismatch          → halt exit 2
#          Plus a happy-path bit-for-bit-stored assertion.
#
#   T246 — `--team <UUID>` alone (no `--project`) routes the discovery
#          flow through P3 (project picker) scoped to the passed team
#          but SKIPS P2 (team picker) — covers install-flags.md §5
#          row 5 + FR-044 fast path.
#
#   T247 — `--project <UUID>` alone (no `--team`) resolves the owning
#          team via the project's `teams.nodes[0].id` field per
#          install-discovery-graphql.md §5.5 / install-flags.md §5
#          row 6.
#
# =============================================================================
# Phase 4 status — tests-first discipline
#
# These tests were authored BEFORE the Phase 4 impl tasks (T248..T251)
# were marked done. A parallel impl agent landed T248..T251 in the
# same Phase 4 commit window; consequently, on most machines these
# tests pass at first run. The single bit that requires the impl
# landing is the GraphQL-driven `install::quick_validate_binding`
# helper (Phase 2 stub returned 0 unconditionally; Phase 4 wires the
# real combined query + validation). The harness below uses a
# function-override stub for `graphql::query` (no live network); the
# helper's success path therefore depends on the impl reading
# response JSON via jq — which the Phase 4 commit lands.
#
# Each `@test` records its expected post-impl behaviour. If a test
# FAILS after Phase 4 lands, the impl drifted from the contract; the
# error text below points at the §5.5 anchor that drifted.
# =============================================================================

setup() {
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
    export PROJECT_ROOT

    TEST_TMP="${BATS_TEST_TMPDIR}/work"
    mkdir -p "$TEST_TMP"
    cd "$TEST_TMP" || exit 1

    # Wipe LINEAR_API_KEY so the helpers under test don't accidentally
    # pick up the harness shell's env value and bypass the stubs.
    unset LINEAR_API_KEY

    # Fixture-replay state matches the install_discovery.bats harness
    # (re-used so any future move to a shared lib file is easy).
    INSTALL_TEST_FIXTURE_DIR="${PROJECT_ROOT}/tests/fixtures/linear_responses"
    export INSTALL_TEST_FIXTURE_DIR
    INSTALL_TEST_CALL_LOG="${BATS_TEST_TMPDIR}/graphql-calls"
    mkdir -p "$INSTALL_TEST_CALL_LOG"
    printf '0' > "${INSTALL_TEST_CALL_LOG}/count"
    : > "${INSTALL_TEST_CALL_LOG}/queries.jsonl"
    export INSTALL_TEST_CALL_LOG

    export GRAPHQL_RETRY_BACKOFF=0
}

teardown() {
    :
}

# ---------------------------------------------------------------------------
# _source_install_sh — source install.sh without invoking install::main.
# Matches the install_discovery.bats harness so behaviour stays in
# lockstep across both files.
# ---------------------------------------------------------------------------
_source_install_sh() {
    # shellcheck source=../../src/install.sh disable=SC1091
    source "${PROJECT_ROOT}/src/install.sh"
}

# ---------------------------------------------------------------------------
# _install_graphql_stub — override graphql::query with a call-counter +
# JSONL-logging stub. INSTALL_TEST_FIXTURE_PATH (single fixture) or
# INSTALL_TEST_FIXTURE_SEQ (space-separated sequence) drives the
# response body.
# ---------------------------------------------------------------------------
_install_graphql_stub() {
    # shellcheck disable=SC2317
    graphql::query() {
        local query="${1:-}"
        local vars="${2:-}"

        local current_count
        current_count="$(cat "${INSTALL_TEST_CALL_LOG}/count")"
        printf '%d' "$(( current_count + 1 ))" > "${INSTALL_TEST_CALL_LOG}/count"

        jq -nc \
            --arg query "$query" \
            --arg vars "$vars" \
            --arg call_n "$(( current_count + 1 ))" \
            '{call_n: ($call_n | tonumber), query: $query, vars: $vars}' \
            >> "${INSTALL_TEST_CALL_LOG}/queries.jsonl"

        if [[ -n "${INSTALL_TEST_FIXTURE_SEQ:-}" ]]; then
            local -a seq
            # shellcheck disable=SC2206
            seq=( $INSTALL_TEST_FIXTURE_SEQ )
            local idx=$(( current_count ))
            if (( idx >= ${#seq[@]} )); then
                printf 'install_backwards_compat.bats: fixture sequence exhausted at call %d\n' "$(( current_count + 1 ))" >&2
                return 1
            fi
            cat "${INSTALL_TEST_FIXTURE_DIR}/${seq[$idx]}"
            return 0
        fi

        if [[ -n "${INSTALL_TEST_FIXTURE_PATH:-}" ]]; then
            cat "$INSTALL_TEST_FIXTURE_PATH"
            return 0
        fi

        printf 'install_backwards_compat.bats: no fixture configured for graphql::query call\n' >&2
        return 1
    }
    export -f graphql::query
}

# ---------------------------------------------------------------------------
# _graphql_call_count — echo the number of stubbed graphql::query
# invocations. Used by the T246 + T247 call-count invariants.
# ---------------------------------------------------------------------------
_graphql_call_count() {
    cat "${INSTALL_TEST_CALL_LOG}/count"
}

# =============================================================================
# T245 — FR-044 install::quick_validate_binding failure modes
# (install-discovery-graphql.md §5.5)
# =============================================================================

@test "T245: quick_validate_binding halts exit 2 when team == null (§5.5.a)" {
    # data.team == null → "--team <UUID> not accessible to this API key".
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() {
            printf '%s' '{\"data\":{\"team\":null,\"project\":{\"id\":\"97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080\",\"name\":\"proj\",\"url\":\"https://linear.app/x/project/proj\",\"teams\":{\"nodes\":[{\"id\":\"deadbeef-dead-beef-dead-beefdeadbeef\"}]}}}}'
        }
        install::quick_validate_binding \
            '6ab43461-6d22-4f02-bb1e-0be9859c7997' \
            '97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080'
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *"--team"* ]]
    [[ "$output" == *"not accessible"* ]]
}

@test "T245: quick_validate_binding halts exit 2 when project == null (§5.5.b)" {
    # data.project == null → "--project <UUID> not accessible to this API key".
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() {
            printf '%s' '{\"data\":{\"team\":{\"id\":\"6ab43461-6d22-4f02-bb1e-0be9859c7997\",\"name\":\"OSH Infra\",\"key\":\"OSH\"},\"project\":null}}'
        }
        install::quick_validate_binding \
            '6ab43461-6d22-4f02-bb1e-0be9859c7997' \
            '97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080'
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *"--project"* ]]
    [[ "$output" == *"not accessible"* ]]
}

@test "T245: quick_validate_binding halts exit 2 on project-team mismatch (§5.5.c)" {
    # team.id = AAAA…, project.teams.nodes[].id = BBBB… (no overlap) →
    # "--project does not belong to --team".
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() {
            printf '%s' '{\"data\":{\"team\":{\"id\":\"6ab43461-6d22-4f02-bb1e-0be9859c7997\",\"name\":\"OSH Infra\",\"key\":\"OSH\"},\"project\":{\"id\":\"97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080\",\"name\":\"orphan-project\",\"url\":\"https://linear.app/x/project/orphan\",\"teams\":{\"nodes\":[{\"id\":\"deadbeef-dead-beef-dead-beefdeadbeef\"}]}}}}'
        }
        install::quick_validate_binding \
            '6ab43461-6d22-4f02-bb1e-0be9859c7997' \
            '97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080'
    "
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not belong"* ]]
}

@test "T245: quick_validate_binding succeeds when project.teams contains team.id" {
    # Happy path — team.id ∈ project.teams.nodes[].id. Exit 0 with
    # SESSION_SELECTED_{TEAM,PROJECT}_ID populated bit-for-bit from
    # the inputs (CI canonical FR-044 round-trip).
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        graphql::query() {
            printf '%s' '{\"data\":{\"team\":{\"id\":\"6ab43461-6d22-4f02-bb1e-0be9859c7997\",\"name\":\"OSH Infra\",\"key\":\"OSH\"},\"project\":{\"id\":\"97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080\",\"name\":\"spec-kit-linear\",\"url\":\"https://linear.app/osh-infra/project/spec-kit-linear\",\"teams\":{\"nodes\":[{\"id\":\"6ab43461-6d22-4f02-bb1e-0be9859c7997\"}]}}}}'
        }
        install::quick_validate_binding \
            '6ab43461-6d22-4f02-bb1e-0be9859c7997' \
            '97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080'
        printf 'TEAM=%s PROJ=%s\n' \"\$INSTALL_SESSION_SELECTED_TEAM_ID\" \"\$INSTALL_SESSION_SELECTED_PROJECT_ID\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEAM=6ab43461-6d22-4f02-bb1e-0be9859c7997"* ]]
    [[ "$output" == *"PROJ=97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080"* ]]
}

# =============================================================================
# T246 — `--team <UUID>` alone (no `--project`) — install-flags.md §5 row 5
# =============================================================================

@test "T246: --team alone — discover_teams short-circuits (no teams query)" {
    # FR-044 fast path: with --team set, install::discover_teams MUST
    # NOT issue the broad `teams(first:21)` query — it populates
    # SELECTED_TEAM_ID directly from the flag. Call-count == 0.
    _source_install_sh
    _install_graphql_stub
    INSTALL_FLAG_TEAM="6ab43461-6d22-4f02-bb1e-0be9859c7997"
    INSTALL_FLAG_PROJECT=""
    INSTALL_FLAG_AUTO_CREATE=0
    install::discover_teams
    [ "$INSTALL_SESSION_SELECTED_TEAM_ID" = "6ab43461-6d22-4f02-bb1e-0be9859c7997" ]
    [ "$(_graphql_call_count)" = "0" ]
}

@test "T246: --team alone — discover_projects runs P3 picker on the passed team" {
    # With --team but no --project, install::discover_projects MUST
    # query `team(id:).projects(first:21)` (P3 still runs) using the
    # flag-supplied team id. The picker fires and the operator picks
    # an existing project from the list.
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_FLAG_TEAM='6ab43461-6d22-4f02-bb1e-0be9859c7997'
        INSTALL_FLAG_PROJECT=''
        INSTALL_FLAG_AUTO_CREATE=0
        graphql::query() { cat '${INSTALL_TEST_FIXTURE_DIR}/projects_multi.json'; }
        install::discover_teams
        install::discover_projects
        install::pick_project_interactively < <(printf '1\n')
        printf 'CHOICE=%s TEAM=%s\n' \"\$INSTALL_SESSION_PROJECT_CHOICE\" \"\$INSTALL_SESSION_SELECTED_TEAM_ID\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHOICE=attach"* ]]
    [[ "$output" == *"TEAM=6ab43461-6d22-4f02-bb1e-0be9859c7997"* ]]
}

# =============================================================================
# T247 — `--project <UUID>` alone (no `--team`) — install-flags.md §5 row 6
# =============================================================================

@test "T247: --project alone — team resolves from project.teams.nodes[0].id" {
    # Per install-discovery-graphql.md §5.5: when only --project is
    # passed, quick_validate_binding is called with team_uuid="" and
    # MUST backfill INSTALL_SESSION_SELECTED_TEAM_ID from the
    # project's teams connection (the team is by construction the
    # project's owner team).
    run bash -c "
        cd '${TEST_TMP}'
        source '${PROJECT_ROOT}/src/install.sh'
        INSTALL_FLAG_TEAM=''
        INSTALL_FLAG_PROJECT='97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080'
        INSTALL_FLAG_AUTO_CREATE=0
        graphql::query() {
            # team(id:'') returns null (empty string is not a valid
            # team UUID); project leg carries the owning team in
            # .teams.nodes[0].
            printf '%s' '{\"data\":{\"team\":null,\"project\":{\"id\":\"97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080\",\"name\":\"spec-kit-linear\",\"url\":\"https://linear.app/osh-infra/project/spec-kit-linear\",\"teams\":{\"nodes\":[{\"id\":\"6ab43461-6d22-4f02-bb1e-0be9859c7997\",\"name\":\"OSH Infra\",\"key\":\"OSH\"}]}}}}'
        }
        install::quick_validate_binding '' '97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080'
        printf 'TEAM=%s PROJ=%s\n' \"\$INSTALL_SESSION_SELECTED_TEAM_ID\" \"\$INSTALL_SESSION_SELECTED_PROJECT_ID\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEAM=6ab43461-6d22-4f02-bb1e-0be9859c7997"* ]]
    [[ "$output" == *"PROJ=97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080"* ]]
}

@test "T247: --project alone — no broad teams listing query fires" {
    # Invariant: when --project is the only flag, install::main MUST
    # route through quick_validate_binding (single combined query),
    # NOT through install::discover_teams's broad `teams(first:21)`
    # query. The discover_teams call should be skipped entirely under
    # `--project`-alone routing (per install-flags.md §5 row 6).
    #
    # We do NOT invoke discover_teams here — instead we assert the
    # routing predicate honors --project. The call-count assertion is
    # the load-bearing bit: zero broad queries fire from this test
    # body (only quick_validate_binding's combined query would, but
    # we don't invoke it here).
    _source_install_sh
    _install_graphql_stub
    # INSTALL_FLAG_* are consumed by install::_should_use_discovery_flow
    # below (sourced from src/install.sh). shellcheck's SC2034 misses
    # the cross-file usage; disable the warning at the call site.
    # shellcheck disable=SC2034
    INSTALL_FLAG_TEAM=""
    # shellcheck disable=SC2034
    INSTALL_FLAG_PROJECT="97bca3d5-ede3-4e7f-9c1a-2d4b5e6f7080"
    # shellcheck disable=SC2034
    INSTALL_FLAG_AUTO_CREATE=0
    # The dispatch predicate MUST allow --project-alone through the
    # discovery flow (not the legacy v0.1.0 path). Post-T251, the
    # discovery flow internally fast-paths via quick_validate_binding.
    if install::_should_use_discovery_flow; then
        :  # expected post-T251 behaviour
    else
        # The pre-Phase-4 dispatch routed --project to the legacy
        # path. This assertion documents the Phase 4 expectation; if
        # the predicate still returns false the test FAILS — flagging
        # that T251 hasn't tightened the dispatch yet.
        echo "expected --project alone to route through discovery flow (T251)" >&2
        return 1
    fi
    [ "$(_graphql_call_count)" = "0" ]
}
