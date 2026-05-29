#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us3-pull-cross-repo.bats — T052
#
# User Story 3 (P2) — `speckit.linear.pull` is the cross-repo unified
# spec view that NEVER writes to Linear (spec.md FR-026 read-only
# display semantics, FR-004b workspace label lookup, SC-009).
#
# Four scenarios cover the load-bearing contract:
#
#   1. REPO SCOPE — default `--repo` flag returns every spec Issue
#      whose Project matches the bound Project UUID. Output mentions
#      the staged identifiers. ZERO mutations.
#
#   2. WORKSPACE-WIDE — `--workspace-wide` filters by team UUID
#      instead of project UUID. Output groups by Project header in
#      the human view and surfaces every staged identifier.
#
#   3. PHASE FILTER — `--phase implementing` restricts to Issues
#      whose `phase:implementing` label is present. ZERO mutations.
#
#   4. JSON SHAPE — `--json` emits a parseable array carrying the
#      per-Issue fields the contract documents (identifier,
#      feature_number, project_name, phase_label, estimate, url).
#
# Mock strategy: reuses the curl-shim from integration-helpers.bash.
# All scenarios stage a `query-PullSpecIssues` canned response; the
# pull command never reaches a mutation code path so the catch-all
# mutation response is defensive only.
# =============================================================================

load '../helpers/integration-helpers'

# -----------------------------------------------------------------------------
# Test-local helpers — mirror the find_status_sh / run_status pattern
# from us3-status-staleness.bats so this file stays self-contained.
# -----------------------------------------------------------------------------
find_pull_sh() {
    printf '%s' "${PROJECT_ROOT}/src/pull.sh"
}

run_pull_in_sandbox() {
    local pull_sh
    pull_sh="$(find_pull_sh)"
    (
        cd "$SANDBOX_REPO"
        export SPECKIT_LINEAR_CONFIG="$LINEAR_CONFIG_PATH"
        bash "$pull_sh" "$@" 2>&1
    )
}

# stage_pull_response <inline_nodes_json>
#   Stage the `query-PullSpecIssues` canned response with the given
#   `issues.nodes` array body. Callers compose multi-Issue arrays via
#   here-doc strings.
stage_pull_response() {
    local nodes_json="$1"
    local payload
    payload=$(cat <<EOF
{"data":{"issues":{"nodes":${nodes_json}}}}
EOF
)
    integration::stage_response 'query-PullSpecIssues' "$payload"
}

# Deterministic Issue UUIDs — the bridge's process_issue path is
# purely a projection of these fields onto the rendered row.
SPEC_UUID_5="ee000000-0000-4000-0000-000000000005"
SPEC_UUID_12="ee000000-0000-4000-0000-000000000012"
SPEC_UUID_13="ee000000-0000-4000-0000-000000000013"

# =============================================================================
# Scenario 1 — REPO SCOPE.
# =============================================================================

@test "T052-repo: pull --repo returns spec Issues in the bound Project" {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # Stage two spec Issues in the same Project.
    stage_pull_response '[
      {
        "id":"'"${SPEC_UUID_5}"'",
        "identifier":"ACM-5",
        "title":"001-spec-kit-linear-bridge",
        "updatedAt":"2026-05-25T16:00:00.000Z",
        "description":"<!-- spec-kit-linear:memory:begin -->\n| **Branch** | `001-spec-kit-linear-bridge` |\n<!-- spec-kit-linear:memory:end -->",
        "estimate":40,
        "state":{"id":"cccccccc-0009-4ccc-cccc-cccccccccccc","name":"Done","type":"completed"},
        "labels":{"nodes":[{"name":"speckit-spec:001"},{"name":"phase:merged"}]},
        "project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"spec-kit-linear"},
        "assignee":{"id":"33333333-3333-4333-8333-333333333333","name":"ash","displayName":"ash"},
        "team":{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","organization":{"urlKey":"acme"}}
      },
      {
        "id":"'"${SPEC_UUID_12}"'",
        "identifier":"ACM-12",
        "title":"002-multi-phase",
        "updatedAt":"2026-05-27T09:21:00.000Z",
        "description":"",
        "estimate":6,
        "state":{"id":"cccccccc-0004-4ccc-cccc-cccccccccccc","name":"Tasking","type":"started"},
        "labels":{"nodes":[{"name":"speckit-spec:002"},{"name":"phase:tasking"}]},
        "project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"spec-kit-linear"},
        "assignee":{"id":"33333333-3333-4333-8333-333333333333","name":"ash","displayName":"ash"},
        "team":{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","organization":{"urlKey":"acme"}}
      }
    ]'
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'mutation' '{"data":{}}'
    integration::stage_response 'default' '{"data":{}}'

    run run_pull_in_sandbox --repo --no-color
    [ "$status" -eq 0 ]

    # ---- ZERO mutations (SC-009 + FR-026) ----
    local mutation_lines
    mutation_lines="$(grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null | head -n1)"
    [[ -z "$mutation_lines" || "$mutation_lines" == "0" ]]

    # ---- output surfaces both identifiers ----
    [[ "$output" == *"ACM-5"* ]]
    [[ "$output" == *"ACM-12"* ]]
    # ---- summary block fired ----
    [[ "$output" == *"speckit.linear summary"* ]]
}

# =============================================================================
# Scenario 2 — WORKSPACE-WIDE: cross-Project inventory.
# =============================================================================

@test "T052-workspace-wide: pull --workspace-wide groups by Project" {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # Stage two Issues in two distinct Projects so the human view's
    # Project grouping has something to render.
    stage_pull_response '[
      {
        "id":"'"${SPEC_UUID_12}"'",
        "identifier":"ACM-12",
        "title":"002-multi-phase",
        "updatedAt":"2026-05-27T09:21:00.000Z",
        "description":"",
        "estimate":6,
        "state":{"id":"cccccccc-0004-4ccc-cccc-cccccccccccc","name":"Tasking","type":"started"},
        "labels":{"nodes":[{"name":"speckit-spec:002"},{"name":"phase:tasking"}]},
        "project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"spec-kit-linear"},
        "assignee":{"id":"33333333-3333-4333-8333-333333333333","name":"ash","displayName":"ash"},
        "team":{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","organization":{"urlKey":"acme"}}
      },
      {
        "id":"'"${SPEC_UUID_13}"'",
        "identifier":"ACM-22",
        "title":"003-feature-x",
        "updatedAt":"2026-05-28T08:00:00.000Z",
        "description":"",
        "estimate":8,
        "state":{"id":"cccccccc-0003-4ccc-cccc-cccccccccccc","name":"Planning","type":"unstarted"},
        "labels":{"nodes":[{"name":"speckit-spec:003"},{"name":"phase:planning"}]},
        "project":{"id":"bbbbbbbb-2222-4bbb-bbbb-bbbbbbbbbbbb","name":"another-repo"},
        "assignee":{"id":"33333333-3333-4333-8333-333333333333","name":"ash","displayName":"ash"},
        "team":{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","organization":{"urlKey":"acme"}}
      }
    ]'
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'mutation' '{"data":{}}'
    integration::stage_response 'default' '{"data":{}}'

    run run_pull_in_sandbox --workspace-wide --no-color
    [ "$status" -eq 0 ]

    # ---- ZERO mutations ----
    local mutation_lines
    mutation_lines="$(grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null | head -n1)"
    [[ -z "$mutation_lines" || "$mutation_lines" == "0" ]]

    # ---- output groups by both Projects ----
    [[ "$output" == *"spec-kit-linear"* ]]
    [[ "$output" == *"another-repo"* ]]
    # ---- both identifiers surface ----
    [[ "$output" == *"ACM-12"* ]]
    [[ "$output" == *"ACM-22"* ]]
}

# =============================================================================
# Scenario 3 — PHASE FILTER.
# =============================================================================

@test "T052-phase: pull --phase implementing carries the phase label into the filter" {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # Stage a single Issue at phase:implementing — the mock returns it
    # regardless of the filter, but we verify the request body the
    # bridge sent carried the `phase:implementing` constraint.
    stage_pull_response '[
      {
        "id":"'"${SPEC_UUID_13}"'",
        "identifier":"ACM-13",
        "title":"005-implementing-feature",
        "updatedAt":"2026-05-28T11:50:00.000Z",
        "description":"",
        "estimate":46,
        "state":{"id":"cccccccc-0006-4ccc-cccc-cccccccccccc","name":"Implementing","type":"started"},
        "labels":{"nodes":[{"name":"speckit-spec:005"},{"name":"phase:implementing"}]},
        "project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"spec-kit-linear"},
        "assignee":{"id":"33333333-3333-4333-8333-333333333333","name":"ash","displayName":"ash"},
        "team":{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","organization":{"urlKey":"acme"}}
      }
    ]'
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'mutation' '{"data":{}}'
    integration::stage_response 'default' '{"data":{}}'

    run run_pull_in_sandbox --repo --phase implementing --no-color
    [ "$status" -eq 0 ]

    # ---- ZERO mutations ----
    local mutation_lines
    mutation_lines="$(grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null | head -n1)"
    [[ -z "$mutation_lines" || "$mutation_lines" == "0" ]]

    # ---- request body contained the phase:implementing constraint ----
    local phase_matches
    phase_matches="$(integration::calls_containing 'phase:implementing')"
    [[ "$phase_matches" -ge 1 ]]

    # ---- output surfaces the ACM-13 identifier ----
    [[ "$output" == *"ACM-13"* ]]
}

# =============================================================================
# Scenario 4 — JSON shape.
# =============================================================================

@test "T052-json: pull --json emits an array carrying contract fields" {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    stage_pull_response '[
      {
        "id":"'"${SPEC_UUID_13}"'",
        "identifier":"ACM-13",
        "title":"005-implementing-feature",
        "updatedAt":"2026-05-28T11:50:00.000Z",
        "description":"",
        "estimate":46,
        "state":{"id":"cccccccc-0006-4ccc-cccc-cccccccccccc","name":"Implementing","type":"started"},
        "labels":{"nodes":[{"name":"speckit-spec:005"},{"name":"phase:implementing"}]},
        "project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"spec-kit-linear"},
        "assignee":{"id":"33333333-3333-4333-8333-333333333333","name":"ash","displayName":"ash"},
        "team":{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","organization":{"urlKey":"acme"}}
      }
    ]'
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'mutation' '{"data":{}}'
    integration::stage_response 'default' '{"data":{}}'

    run run_pull_in_sandbox --repo --json --no-color
    [ "$status" -eq 0 ]

    # ---- ZERO mutations ----
    local mutation_lines
    mutation_lines="$(grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null | head -n1)"
    [[ -z "$mutation_lines" || "$mutation_lines" == "0" ]]

    # ---- every contract field surfaces in the stdout JSON ----
    [[ "$output" == *'"identifier":"ACM-13"'* ]]
    [[ "$output" == *'"feature_number":"005"'* ]]
    [[ "$output" == *'"project_name":"spec-kit-linear"'* ]]
    [[ "$output" == *'"phase_label":"implementing"'* ]]
    [[ "$output" == *'"estimate":46'* ]]
    [[ "$output" == *'"url":"https://linear.app/acme/issue/ACM-13"'* ]]
}
