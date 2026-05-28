#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us4-seed-idempotent.bats — T055
#
# User Story 4 (P2) — seed idempotency (spec.md FR-021):
#
#   GIVEN a sandbox Linear workspace that ALREADY contains the nine
#         canonical workflow states and the `phase:*` + `task-phase:*`
#         label families,
#   WHEN  `src/seed.sh` runs TWICE in a row,
#   THEN  the SECOND invocation issues ZERO `workflowStateCreate` and
#         ZERO `issueLabelCreate` mutations (per-§2.1/§2.2 idempotency:
#         pre-query → exact-match found → capture id → skip create),
#         AND `.specify/extensions/linear/linear-config.yml` contents
#         are byte-identical between the two runs (no field churn).
#         Exit 0. Summary emits an "already seeded" / zero-mutation
#         line.
#
# Maps to FR-021 ("This operation MUST be safe to re-run") + Principle
# II (reconcile, never event-push) + SC-002 (zero churn on no-op).
#
# Mock strategy: reuses the curl-shim. Every workflowStates / issueLabels
# locate query returns a non-empty `nodes` array carrying the exact
# names the seed step queries by. The seed step's idempotency probe
# MUST match on each, capture the existing UUID, and skip the create.
# =============================================================================

load '../helpers/integration-helpers'

# Stable existing-state UUIDs. The seed step is expected to capture
# these and persist them under the matching `workflow_state_uuids`
# key (whether on the first or the second run is implementation-
# defined; the test asserts the SECOND run produces the same on-disk
# config as the first).
EXISTING_SPECIFYING_ID="cccccccc-0001-4ccc-cccc-cccccccccccc"
EXISTING_CLARIFYING_ID="cccccccc-0002-4ccc-cccc-cccccccccccc"
EXISTING_PLANNING_ID="cccccccc-0003-4ccc-cccc-cccccccccccc"
EXISTING_TASKING_ID="cccccccc-0004-4ccc-cccc-cccccccccccc"
EXISTING_RED_TEAM_ID="cccccccc-0005-4ccc-cccc-cccccccccccc"
EXISTING_IMPLEMENTING_ID="cccccccc-0006-4ccc-cccc-cccccccccccc"
EXISTING_ANALYZING_ID="cccccccc-0007-4ccc-cccc-cccccccccccc"
EXISTING_RTM_ID="cccccccc-0008-4ccc-cccc-cccccccccccc"
EXISTING_MERGED_ID="cccccccc-0009-4ccc-cccc-cccccccccccc"

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '001-minimal'
    integration::install_gh_shim_no_pr

    # ---- canned: every workflowStates locate returns the matching node ----
    # The mock can't easily branch on input body, so we return a UNION
    # of all nine known nodes for every query. The seed step's filter
    # logic — "if exactly one match by name exists, capture its id" —
    # must still match each lifecycle key correctly. If the
    # implementation pre-queries with `name: { eq: <key> }`, returning
    # all nine is over-generous but harmless: the seed step picks the
    # one whose `name` matches the requested key.
    local nodes
    nodes=$(printf '%s' "[\
{\"id\":\"${EXISTING_SPECIFYING_ID}\",\"name\":\"Specifying\",\"type\":\"unstarted\"},\
{\"id\":\"${EXISTING_CLARIFYING_ID}\",\"name\":\"Clarifying\",\"type\":\"unstarted\"},\
{\"id\":\"${EXISTING_PLANNING_ID}\",\"name\":\"Planning\",\"type\":\"unstarted\"},\
{\"id\":\"${EXISTING_TASKING_ID}\",\"name\":\"Tasking\",\"type\":\"unstarted\"},\
{\"id\":\"${EXISTING_RED_TEAM_ID}\",\"name\":\"Red-team\",\"type\":\"unstarted\"},\
{\"id\":\"${EXISTING_IMPLEMENTING_ID}\",\"name\":\"Implementing\",\"type\":\"started\"},\
{\"id\":\"${EXISTING_ANALYZING_ID}\",\"name\":\"Analyzing\",\"type\":\"started\"},\
{\"id\":\"${EXISTING_RTM_ID}\",\"name\":\"Ready-to-merge\",\"type\":\"started\"},\
{\"id\":\"${EXISTING_MERGED_ID}\",\"name\":\"Merged\",\"type\":\"completed\"}\
]")

    integration::stage_response 'query-WorkflowStatesByName' \
        "{\"data\":{\"workflowStates\":{\"nodes\":${nodes}}}}"
    integration::stage_response 'query-SeedWorkflowStates' \
        "{\"data\":{\"workflowStates\":{\"nodes\":${nodes}}}}"

    # ---- canned: every issueLabels locate returns the matching node ----
    local label_nodes
    label_nodes=$(printf '%s' "[\
{\"id\":\"bbbb0001-1111-4111-1111-111111110001\",\"name\":\"phase:specifying\"},\
{\"id\":\"bbbb0002-1111-4111-1111-111111110002\",\"name\":\"phase:clarifying\"},\
{\"id\":\"bbbb0003-1111-4111-1111-111111110003\",\"name\":\"phase:planning\"},\
{\"id\":\"bbbb0004-1111-4111-1111-111111110004\",\"name\":\"phase:tasking\"},\
{\"id\":\"bbbb0005-1111-4111-1111-111111110005\",\"name\":\"phase:red_team\"},\
{\"id\":\"bbbb0006-1111-4111-1111-111111110006\",\"name\":\"phase:implementing\"},\
{\"id\":\"bbbb0007-1111-4111-1111-111111110007\",\"name\":\"phase:analyzing\"},\
{\"id\":\"bbbb0008-1111-4111-1111-111111110008\",\"name\":\"phase:ready_to_merge\"},\
{\"id\":\"bbbb0011-1111-4111-1111-111111110011\",\"name\":\"task-phase:1\"},\
{\"id\":\"bbbb0012-1111-4111-1111-111111110012\",\"name\":\"task-phase:2\"},\
{\"id\":\"bbbb0013-1111-4111-1111-111111110013\",\"name\":\"task-phase:3\"},\
{\"id\":\"bbbb0014-1111-4111-1111-111111110014\",\"name\":\"task-phase:4\"},\
{\"id\":\"bbbb0015-1111-4111-1111-111111110015\",\"name\":\"task-phase:5\"},\
{\"id\":\"bbbb0016-1111-4111-1111-111111110016\",\"name\":\"task-phase:6\"},\
{\"id\":\"bbbb0017-1111-4111-1111-111111110017\",\"name\":\"task-phase:7\"},\
{\"id\":\"bbbb0018-1111-4111-1111-111111110018\",\"name\":\"task-phase:8\"},\
{\"id\":\"bbbb0019-1111-4111-1111-111111110019\",\"name\":\"task-phase:9\"}\
]")

    integration::stage_response 'query-IssueLabelsByName' \
        "{\"data\":{\"issueLabels\":{\"nodes\":${label_nodes}}}}"
    integration::stage_response 'query-SeedLabels' \
        "{\"data\":{\"issueLabels\":{\"nodes\":${label_nodes}}}}"

    # Generic fallback so any seed-side locate finds the union.
    integration::stage_response 'query' \
        "{\"data\":{\"workflowStates\":{\"nodes\":${nodes}},\"issueLabels\":{\"nodes\":${label_nodes}}}}"

    # If a create DOES fire (test failure mode), it lands a parseable
    # response so the seed step doesn't crash before the assertion.
    integration::stage_response 'mutation' \
        '{"data":{"workflowStateCreate":{"success":true,"workflowState":{"id":"00000000-0000-4000-0000-000000000000","name":"Unexpected","type":"unstarted"}},"issueLabelCreate":{"success":true,"issueLabel":{"id":"00000000-0000-4000-0000-000000000000","name":"unexpected"}}}}'

    integration::stage_response 'default' '{"data":{}}'
}

@test "T055: second seed run against pre-populated workspace issues zero create mutations" {
    # ---- first invocation: prime ----
    run integration::run_seed --team "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    [ "$status" -eq 0 ]

    # Snapshot the config the first run produced.
    local config_after_first
    config_after_first="$(cat "$LINEAR_CONFIG_PATH")"

    # Reset call counters so the second run is measured in isolation.
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # ---- second invocation ----
    run integration::run_seed --team "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    [ "$status" -eq 0 ]

    # ---- ZERO create mutations on the second run ----
    # Idempotency probe MUST have hit on every locate, capturing the
    # canned existing UUID and skipping the create. Sum across
    # operation-name spellings.
    local wfs_a wfs_b wfs_creates
    wfs_a="$(integration::count_op 'mutation:WorkflowStateCreate')"
    wfs_b="$(integration::count_op 'mutation:SeedWorkflowState')"
    wfs_creates=$(( wfs_a + wfs_b ))
    [ "$wfs_creates" -eq 0 ]

    local label_a label_b label_creates
    label_a="$(integration::count_op 'mutation:IssueLabelCreate')"
    label_b="$(integration::count_op 'mutation:CreateIssueLabel')"
    label_creates=$(( label_a + label_b ))
    [ "$label_creates" -eq 0 ]

    # Sanity: total mutation count is zero.
    local total_mutations
    total_mutations="$(integration::mutation_count)"
    [ "$total_mutations" -eq 0 ]

    # ---- queries ARE allowed (locate-by-name pre-queries fire) ----
    local queries
    queries="$(integration::query_count)"
    [ "$queries" -ge 1 ]

    # ---- config.yml byte-identical between runs ----
    # FR-021 + SC-002: no churn on no-op. The seed step's contract
    # (command-shapes.md §4.5) describes the config write as
    # "captured workflow-state UUIDs back into the config file"; if
    # the second run rewrote the file with the same UUIDs it captured
    # in run 1, the file MUST be byte-identical.
    local config_after_second
    config_after_second="$(cat "$LINEAR_CONFIG_PATH")"
    [ "$config_after_first" = "$config_after_second" ]

    # ---- summary signals "already seeded" / zero-create state ----
    # Command-shapes.md §4.5 sample shows "Workflow states existing: 9"
    # when nothing was created. Accept any phrasing that surfaces the
    # zero-create / already-seeded outcome.
    [[ "$output" == *"summary"* ]]
    [[ "$output" == *"existing"* ]] || \
        [[ "$output" == *"already"* ]] || \
        [[ "$output" == *"created:"*"0"* ]] || \
        [[ "$output" == *"Created: 0"* ]] || \
        [[ "$output" == *"Workflow states created:"*"0"* ]]
}
