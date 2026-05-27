#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1-task-added.bats — T022
#
# User Story 1 (P1, MVP) acceptance scenario #4 (spec.md §User Story 1)
# + SC-006:
#
#   GIVEN a previously-synced spec (fixture 002 fully present in Linear)
#         whose `tasks.md` has been mutated to add one new task line
#         under `## Phase 2:`,
#   WHEN  `src/reconcile.sh --spec 002` runs,
#   THEN  the only Linear mutation issued is ONE save_issue UPDATE on
#         the Phase 2 sub-issue, carrying the regenerated checklist
#         that contains the new task. No new Issues are created. No
#         other sub-issues are touched. No comments are posted. Exit 0.
#         Summary reports `Updated: 1`.
#
# Maps to FR-006 + FR-024 + SC-006 ("Adding or removing a single task
# from `tasks.md` and re-running reconcile changes exactly one line in
# exactly one task-phase sub-issue's checklist in Linear, with no churn
# on any other Issue, sub-issue, comment, or label").
#
# Mock strategy: identical canned state to us1-idempotent-rerun.bats
# (everything "already exists"), except the Phase 2 sub-issue's stored
# description deliberately diverges from what reconcile will compute
# after we append the new task to tasks.md. Reconcile's idempotency
# probe MUST detect the diff and emit exactly one save_issue UPDATE
# against the Phase 2 sub-issue.
# =============================================================================

load '../helpers/integration-helpers'

SPEC_ISSUE_ID="ee000000-0000-4000-0000-000000000002"
PHASE1_SUB_ID="ee000000-0001-4000-0000-000000000002"
PHASE2_SUB_ID="ee000000-0002-4000-0000-000000000002"
PHASE3_SUB_ID="ee000000-0003-4000-0000-000000000002"

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # ---- mutate the fixture's tasks.md in the sandbox: add one task
    # to ## Phase 2: Foundational. The line is appended below the
    # existing Phase 2 task lines but ABOVE the next `## Phase 3:`
    # header so the parser counts it under Phase 2. ----
    local tasks_md="${SANDBOX_REPO}/specs/002-multi-phase/tasks.md"
    # Re-write tasks.md inline (avoids brittle sed insertion).
    cat > "$tasks_md" <<'TASKS'
# Tasks: Multi-Phase Tasks Fixture

**Branch**: `002-multi-phase`

## Phase 1: Setup

- [ ] T002-001 Create skeleton directories
- [ ] T002-002 [P] Configure tooling

## Phase 2: Foundational

Phase 2 depends on Phase 1 (setup must land before foundational work).

- [ ] T002-003 Implement core module A
- [ ] T002-004 [P] Implement core module B (depends on T002-001)
- [ ] T002-007 NEW TASK ADDED IN TEST (Phase 2 only)

## Phase 3: Polish

Phase 3 depends on Phase 2.

- [ ] T002-005 Add documentation
- [ ] T002-006 [P] Run final lint pass
TASKS
    git -C "$SANDBOX_REPO" add "specs/002-multi-phase/tasks.md"
    git -C "$SANDBOX_REPO" commit --quiet -m 'add T002-007 to Phase 2'

    # ---- canned "fully synced" Linear state ----
    integration::stage_response 'query-LocateSpecIssue' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]}}}"

    integration::stage_response 'query-LocateTaskPhase' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${PHASE1_SUB_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"},{\"id\":\"${PHASE2_SUB_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"},{\"id\":\"${PHASE3_SUB_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]}}}"

    # Crucially: the Phase 2 sub-issue's stored description does NOT
    # contain T002-007 (since the test just added it). All other
    # sub-issues' descriptions DO match what reconcile will compute,
    # so they should NOT be updated.
    #
    # The reconciler's `get_issue` probe will fetch the current state
    # of the sub-issue and diff against the desired body. We return a
    # description string that lists T002-003 + T002-004 but omits the
    # newly-added T002-007 — the diff will flag this as "needs update".
    integration::stage_response 'query-GetIssue' \
        "{\"data\":{\"issue\":{\"id\":\"${PHASE2_SUB_ID}\",\"description\":\"- [ ] T002-003 Implement core module A\\n- [ ] T002-004 [P] Implement core module B (depends on T002-001)\\n\",\"blocks\":{\"nodes\":[{\"id\":\"${PHASE3_SUB_ID}\"}]}}}}"

    integration::stage_response 'query-GetIssueBlocks' \
        "{\"data\":{\"issue\":{\"blocks\":{\"nodes\":[{\"id\":\"${PHASE2_SUB_ID}\"},{\"id\":\"${PHASE3_SUB_ID}\"}]}}}}"

    integration::stage_response 'query-LocateComment' \
        '{"data":{"comments":{"nodes":[{"id":"ff000000-0000-4000-0000-000000000001"}]}}}'

    integration::stage_response 'query' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]},\"issue\":{\"blocks\":{\"nodes\":[]},\"description\":\"<unchanged>\"},\"comments\":{\"nodes\":[{\"id\":\"ff000000-0000-4000-0000-000000000001\"}]}}}"

    # The single expected mutation: a save_issue UPDATE on the Phase 2
    # sub-issue. We echo the same UUID back so the reconciler keeps
    # tracking it.
    integration::stage_response 'mutation' \
        "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"${PHASE2_SUB_ID}\",\"identifier\":\"OSH-4\",\"title\":\"Phase 2 — Foundational\"}}}}"

    integration::stage_response 'default' '{"data":{}}'
}

@test "T022: adding one task to Phase 2 produces exactly one Phase-2-sub-issue UPDATE" {
    # Prime so the "already synced" state is acknowledged. (The prime
    # itself may also issue the one expected update — that's fine; we
    # measure the second run.) On the prime, the canned state matches
    # everything EXCEPT the Phase 2 description; reconcile will issue
    # the update, the mock acks it, but the canned state still claims
    # the old description on subsequent reads. We compensate by only
    # asserting on a fresh, isolated invocation: priming, resetting
    # the call log, and then running once.
    run integration::run_reconcile --spec 002
    [ "$status" -eq 0 ]

    # Reset for the assertion run.
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # ---- assertion run ----
    run integration::run_reconcile --spec 002
    [ "$status" -eq 0 ]

    # ---- exactly one mutation ----
    # The reconciler MUST issue precisely one save_issue UPDATE — the
    # Phase 2 sub-issue. No new creates, no other updates.
    local mutations
    mutations="$(integration::mutation_count)"
    [ "$mutations" -eq 1 ]

    # ---- that mutation targets the Phase 2 sub-issue ----
    # The Phase 2 sub-issue's UUID must appear in the single mutation
    # body (either as the `id` field for an issueUpdate, or as the
    # path of a save_issue with id set).
    local phase2_targeted
    phase2_targeted="$(integration::calls_containing "$PHASE2_SUB_ID")"
    [ "$phase2_targeted" -ge 1 ]

    # ---- the new task code is present in the mutation body ----
    # FR-006: the checklist mirrors `tasks.md`. The new task line
    # `T002-007` must land in the issueUpdate's `description`.
    local new_task_in_body
    new_task_in_body="$(integration::calls_containing 'T002-007')"
    [ "$new_task_in_body" -ge 1 ]

    # ---- no comment posts ----
    # save_comment is its own GraphQL operation
    # (`commentCreate` / `commentUpdate` per
    # contracts/linear-graphql-mutations.md §4.5). The fixture has no
    # Clarifications section, and we did not add one — so zero
    # comment-shaped mutations are expected.
    local comment_creates
    comment_creates="$(integration::count_op 'mutation:CommentCreate')"
    local comment_updates
    comment_updates="$(integration::count_op 'mutation:CommentUpdate')"
    local comment_mcps
    comment_mcps="$(integration::count_op 'mutation:SaveComment')"
    [ "$(( comment_creates + comment_updates + comment_mcps ))" -eq 0 ]

    # ---- summary reports exactly one update ----
    [[ "$output" == *"Updated: 1"* ]]
    [[ "$output" == *"Created: 0"* ]]
}
