#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1-idempotent-rerun.bats — T021
#
# User Story 1 (P1, MVP) acceptance scenario #3 (spec.md §User Story 1):
#
#   GIVEN a previously-synced spec (fixture 002, all Issues + sub-issues
#         + relations already present in Linear and matching the
#         filesystem state),
#   WHEN  `src/reconcile.sh --spec 002` runs twice in a row,
#   THEN  the second invocation issues ZERO Linear mutations (only
#         lookup queries fire), and the summary reports
#         `Created: 0` + `Updated: 0`. Exit code 0.
#
# Maps to FR-001 ("Reconciliation MUST be idempotent: running it
# repeatedly against unchanged filesystem state MUST produce no
# observable changes in Linear") + SC-002 + Principle II.
#
# Mock strategy: every lookup query returns canned "already-present"
# nodes whose `id` / `description` / `labels` match exactly what
# reconcile would compute from the filesystem fixture. The reconciler's
# idempotency probe (T031) MUST short-circuit before each save_issue,
# so we assert mutation_count == 0 on the second run.
# =============================================================================

load '../helpers/integration-helpers'

# Deterministic UUIDs the canned "already present" responses use. The
# reconciler's UUIDv5 derivation (contracts §7.3) maps these to the
# fixture's stable filesystem keys; the tests don't recompute the
# UUIDs, they just trust the mocked Linear side to assert "these are
# what already exist" and let the reconciler's diff logic prove it
# matches.
SPEC_ISSUE_ID="ee000000-0000-4000-0000-000000000002"
PHASE1_SUB_ID="ee000000-0001-4000-0000-000000000002"
PHASE2_SUB_ID="ee000000-0002-4000-0000-000000000002"
PHASE3_SUB_ID="ee000000-0003-4000-0000-000000000002"

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # ---- canned responses representing a fully-synced Linear state ----
    #
    # The spec-issue locate query returns ONE node — the existing spec
    # Issue. The reconciler interprets this as "go down the update
    # path", then must diff against the desired state and skip the
    # write because everything matches.
    integration::stage_response 'query-LocateSpecIssue' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]}}}"

    # Task-phase locate query: returns the matching sub-issue.
    # Since the mock can't tell phase 1 from phase 2 from phase 3 (the
    # request body differs only by which `task-phase:N` label it filters
    # on, which our shim doesn't parse), we serve a list of all three
    # and let the reconciler match by label content.
    integration::stage_response 'query-LocateTaskPhase' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${PHASE1_SUB_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"},{\"id\":\"${PHASE2_SUB_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"},{\"id\":\"${PHASE3_SUB_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]}}}"

    # get_issue for the diff probe: each sub-issue already has the
    # expected blocks relation. We return the union of all three
    # blocking edges so whichever sub-issue is queried, the reconciler
    # sees its expected blocks state and decides "no delta".
    integration::stage_response 'query-GetIssueBlocks' \
        "{\"data\":{\"issue\":{\"blocks\":{\"nodes\":[{\"id\":\"${PHASE2_SUB_ID}\"},{\"id\":\"${PHASE3_SUB_ID}\"}]}}}}"

    # Comment locate query: every clarify-session marker is "already
    # present" (fixture 002 has no Clarifications section anyway, so
    # this is defensive). We serve a non-empty nodes array so any
    # comment dedup logic short-circuits.
    integration::stage_response 'query-LocateComment' \
        '{"data":{"comments":{"nodes":[{"id":"ff000000-0000-4000-0000-000000000001"}]}}}'

    # Generic query fallback: defaults to "nodes present" so any other
    # locate query the reconciler issues finds something. The
    # idempotency probe MUST still skip mutating because the body
    # match also has to pass — but if the test ever sees a save_issue
    # call here, the mutation_count assertion below will catch it.
    integration::stage_response 'query' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\",\"description\":\"<unchanged>\"}]},\"issue\":{\"blocks\":{\"nodes\":[]}},\"comments\":{\"nodes\":[{\"id\":\"ff000000-0000-4000-0000-000000000001\"}]}}}"

    # If any mutation DOES fire (test failure mode), we still want it
    # to return a parseable payload so the reconciler doesn't error
    # out before the assertion runs.
    integration::stage_response 'mutation' \
        "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"${SPEC_ISSUE_ID}\",\"identifier\":\"ACM-2\",\"title\":\"002-multi-phase\"}}}}"

    integration::stage_response 'default' '{"data":{}}'
}

@test "T021: second reconcile against synced state issues zero mutations" {
    # ---- first invocation: priming run (may or may not mutate; we
    # don't care — we only assert on the SECOND run) ----
    run integration::run_reconcile --spec 002
    [ "$status" -eq 0 ]

    # Reset the call counters so the second run is measured in isolation.
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # ---- second invocation ----
    run integration::run_reconcile --spec 002
    [ "$status" -eq 0 ]

    # ---- ZERO mutations ----
    local mutations
    mutations="$(integration::mutation_count)"
    [ "$mutations" -eq 0 ]

    # ---- queries are allowed (locate + diff probes) ----
    # We don't assert a precise count — different implementations may
    # batch differently — only that the reconciler actually consulted
    # Linear (i.e. didn't bypass the probe entirely).
    local queries
    queries="$(integration::query_count)"
    [ "$queries" -ge 1 ]

    # ---- summary reports Created: 0 + Updated: 0 ----
    # Format locked by src/summary.sh (`Created: <n>   Updated: <n>   ...`).
    [[ "$output" == *"speckit.linear summary"* ]]
    [[ "$output" == *"Created: 0"* ]]
    [[ "$output" == *"Updated: 0"* ]]
}
