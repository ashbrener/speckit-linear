#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1-fresh-reconcile.bats — T020
#
# User Story 1 (P1, MVP) acceptance scenario #1 + #2 (spec.md §User Story 1):
#
#   GIVEN a `specs/002-multi-phase/` directory (spec.md + plan.md +
#         tasks.md with three `## Phase N:` blocks and inter-phase deps),
#         and a clean Linear state (no Issues match `speckit-spec:002`),
#   WHEN  `src/reconcile.sh --spec 002` runs from the spec's feature branch
#         (so the FR-025 write-authority gate permits writes),
#   THEN  the reconciler issues:
#           * exactly one save_issue CREATE for the spec Issue
#             (title `002-multi-phase`, label `phase:tasking`, memory block
#             containing branch + worktree + last-touched fields)
#           * three save_issue CREATEs for the task-phase sub-issues
#             (titles `Phase 1 — Setup`, `Phase 2 — Foundational`,
#             `Phase 3 — Polish`, each parented to the spec Issue)
#           * two save_issue mutations setting `blocks` / `blockedBy`
#             between the sub-issues per the fixture's deps (Phase 1
#             blocks Phase 2; Phase 2 blocks Phase 3)
#           * exits 0 and emits a summary mentioning `Created:` with a
#             count of at least 4 (1 spec + 3 sub-issues)
#
# Maps to FR-001, FR-003, FR-004, FR-004b, FR-005, FR-006, FR-007.
#
# Mock strategy: the curl shim under tests/helpers/integration-helpers.bash
# returns "no nodes" for every locate query and a fresh fake-UUID payload
# for every save_issue mutation. We assert on the call log to count
# mutations by kind, not on a live Linear state.
# =============================================================================

load '../helpers/integration-helpers'

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # ---- canned responses ----
    # Spec-issue locate query → zero nodes. Forces CREATE path.
    integration::stage_response 'query-LocateSpecIssue' \
        '{"data":{"issues":{"nodes":[]}}}'

    # Task-phase locate query (issues filter by parent + task-phase label)
    # → zero nodes for every phase. Forces CREATE path for each sub-issue.
    integration::stage_response 'query-LocateTaskPhase' \
        '{"data":{"issues":{"nodes":[]}}}'

    # Generic query fallback — anything else (e.g. get_issue blocks
    # diff) returns empty so reconcile sees "no existing relations".
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":{"blocks":{"nodes":[]}}}}'

    # save_issue mutations always succeed and echo a stable fake UUID.
    # Reconcile may issue these under the operation names IssueCreate,
    # IssueUpdate, IssueUpsert, or the MCP-style save_issue — we serve
    # the same payload for any of them via the kind-level fallback.
    integration::stage_response 'mutation' \
        '{"data":{"issueCreate":{"success":true,"issue":{"id":"11111111-1111-4111-1111-111111111111","identifier":"OSH-1","title":"created"}},"issueUpdate":{"success":true,"issue":{"id":"22222222-2222-4222-2222-222222222222","identifier":"OSH-2","title":"updated","state":{"id":"cccccccc-0004-4ccc-cccc-cccccccccccc"}}}}}'

    # Default catch-all so an unexpected request still produces valid
    # JSON rather than tripping graphql.sh's parser.
    integration::stage_response 'default' '{"data":{}}'
}

@test "T020: fresh reconcile creates spec Issue + 3 sub-issues + 2 blocking relations" {
    run integration::run_reconcile --spec 002

    # ---- exit code ----
    [ "$status" -eq 0 ]

    # ---- mutation accounting ----
    # The reconciler must have issued at least 4 save_issue mutations:
    # one for the spec Issue + three for the task-phase sub-issues.
    # The two blocking-relation calls (Phase 1→2, Phase 2→3) push the
    # observed mutation count to >= 6 in total. We assert lower bounds
    # so a reconciler that batches relations into a single multi-blocks
    # call still passes (the contract — `contracts/linear-graphql-mutations.md`
    # §4.4 — allows either shape).
    local mutations
    mutations="$(integration::mutation_count)"
    [ "$mutations" -ge 4 ]

    # At least one mutation body must reference the spec's identity label
    # `speckit-spec:002` (FR-004b — stamped on creation).
    local spec_label_calls
    spec_label_calls="$(integration::calls_containing 'speckit-spec:002')"
    [ "$spec_label_calls" -ge 1 ]

    # At least one mutation body must contain the `phase:tasking` label
    # (FR-003 — phase label mirrors current lifecycle phase; fixture
    # 002 has spec.md + plan.md + tasks.md, so lifecycle_phase = tasking).
    local phase_label_calls
    phase_label_calls="$(integration::calls_containing 'phase:tasking')"
    [ "$phase_label_calls" -ge 1 ]

    # ---- memory block content (FR-004) ----
    # The spec Issue's description MUST include branch / worktree / a
    # last-touched timestamp. We grep for distinctive substrings rather
    # than a precise template so cosmetic format tweaks don't break the
    # test. Branch name = fixture name (= the checked-out branch in
    # setup_sandbox).
    local branch_calls
    branch_calls="$(integration::calls_containing '002-multi-phase')"
    [ "$branch_calls" -ge 1 ]

    # Worktree path appears in the memory block. Sandbox repo path is
    # always under BATS_TEST_TMPDIR — grep for the leading "/repo" segment.
    local worktree_calls
    worktree_calls="$(integration::calls_containing 'repo')"
    [ "$worktree_calls" -ge 1 ]

    # ---- sub-issue creation ----
    # Each task-phase header (`Phase 1 — Setup` etc.) must appear in at
    # least one mutation body. The em-dash separator is locked by the
    # contract (linear-graphql-mutations.md §4.3 "Title format").
    local phase1_calls
    phase1_calls="$(integration::calls_containing 'Phase 1 — Setup')"
    [ "$phase1_calls" -ge 1 ]

    local phase2_calls
    phase2_calls="$(integration::calls_containing 'Phase 2 — Foundational')"
    [ "$phase2_calls" -ge 1 ]

    local phase3_calls
    phase3_calls="$(integration::calls_containing 'Phase 3 — Polish')"
    [ "$phase3_calls" -ge 1 ]

    # ---- blocking relations (FR-007) ----
    # Fixture 002 declares "Phase 2 depends on Phase 1" and "Phase 3
    # depends on Phase 2". At least one mutation body must reference
    # `blocks` (or `blockedBy`) for the relations to land. We check
    # the keyword presence; the precise call shape is per
    # contracts/linear-graphql-mutations.md §4.4.
    local blocks_calls
    blocks_calls="$(integration::calls_containing 'blocks')"
    [ "$blocks_calls" -ge 1 ]

    # ---- summary contract (FR-023) ----
    # The reconciler's structured summary is printed to stderr (per
    # src/summary.sh), but `integration::run_reconcile` captures both
    # streams into `$output` so `[[ "$output" == *"Created:"* ]]` matches.
    [[ "$output" == *"speckit.linear summary"* ]]
    [[ "$output" == *"Created:"* ]]
}
