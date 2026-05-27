#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us1-clarify-mirror.bats — T023
#
# User Story 1 (P1, MVP) — clarify-session mirroring (spec.md FR-015):
#
#   GIVEN fixture 005-clarify-sessions (spec.md containing three
#         `### Session YYYY-MM-DD` blocks under `## Clarifications`,
#         each with two Q/A bullets), AND a clean Linear state
#         (no existing comments match the session markers, the spec
#         Issue itself was just created by the same reconcile pass),
#   WHEN  `src/reconcile.sh --spec 005` runs from the spec's feature
#         branch,
#   THEN  the reconciler issues exactly three save_comment mutations,
#         in chronological order matching the three session dates
#         (2026-05-01, 2026-05-15, 2026-05-28), each comment body
#         containing the corresponding session's Q/A bullets verbatim.
#         Exit 0. Summary reports a non-zero `Created:` count covering
#         the comments.
#
# Maps to FR-008 + FR-015 ("For every `### Session YYYY-MM-DD`
# subheading the bridge finds under the `## Clarifications` section of
# `spec.md`, it MUST post (exactly once, idempotently) a comment on
# the spec Issue containing that session's Q/A bullets").
#
# Mock strategy: the spec-issue locate query returns ONE existing
# Issue (so the reconciler skips creating a fresh spec Issue and uses
# the existing UUID as the comment parent). Every comment-locate
# query (`comments(filter: { body: { startsWith: ... } })`) returns
# zero nodes, forcing the bridge down the CREATE path for each of
# the three sessions. The classified.log file is then inspected to
# count CommentCreate / SaveComment-shaped operations.
# =============================================================================

load '../helpers/integration-helpers'

SPEC_ISSUE_ID="ee000000-0000-4000-0000-000000000005"

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '005-clarify-sessions'
    integration::install_gh_shim_no_pr

    # ---- canned spec-issue: already exists ----
    # Returning ONE node means the reconciler resolves the spec Issue
    # to $SPEC_ISSUE_ID and can use it as `issueId` for save_comment.
    integration::stage_response 'query-LocateSpecIssue' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]}}}"

    # ---- canned task-phase locate: empty (fixture 005 has no
    # tasks.md, so the reconciler shouldn't even query, but defensive
    # in case it does) ----
    integration::stage_response 'query-LocateTaskPhase' \
        '{"data":{"issues":{"nodes":[]}}}'

    # ---- comment locate query: returns ZERO nodes for every session
    # marker. The reconciler then has to issue three save_comment
    # CREATEs (one per session date). ----
    integration::stage_response 'query-LocateComment' \
        '{"data":{"comments":{"nodes":[]}}}'

    # Generic query fallback so anything else returns parseable JSON.
    # IMPORTANT: comments default to an empty list so the comment
    # dedup probe does NOT think a comment already exists.
    integration::stage_response 'query' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]},\"comments\":{\"nodes\":[]},\"issue\":{\"blocks\":{\"nodes\":[]}}}}"

    # ---- save_issue mutations succeed (the reconciler MAY still
    # update the spec Issue's memory block on this run; that's fine,
    # it just isn't what this test cares about) ----
    integration::stage_response 'mutation-IssueUpdate' \
        "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"${SPEC_ISSUE_ID}\",\"identifier\":\"OSH-5\",\"title\":\"005-clarify-sessions\"}}}}"

    integration::stage_response 'mutation-IssueCreate' \
        "{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":{\"id\":\"${SPEC_ISSUE_ID}\",\"identifier\":\"OSH-5\",\"title\":\"005-clarify-sessions\"}}}}"

    # ---- save_comment / commentCreate mutations succeed with a
    # unique-ish UUID echo back. The reconciler doesn't actually need
    # the UUID to dedupe — it dedupes by body marker — but the
    # response must be valid GraphQL. ----
    integration::stage_response 'mutation-CommentCreate' \
        '{"data":{"commentCreate":{"success":true,"comment":{"id":"ff000000-0000-4000-0000-00000000c001","createdAt":"2026-05-28T00:00:00Z"}}}}'

    integration::stage_response 'mutation-SaveComment' \
        '{"data":{"commentCreate":{"success":true,"comment":{"id":"ff000000-0000-4000-0000-00000000c002","createdAt":"2026-05-28T00:00:00Z"}}}}'

    # Generic mutation fallback for any reconciler-issued mutation
    # whose operation name doesn't match the above (e.g. an MCP-style
    # `save_comment` that flows through graphql.sh).
    integration::stage_response 'mutation' \
        '{"data":{"commentCreate":{"success":true,"comment":{"id":"ff000000-0000-4000-0000-00000000c099","createdAt":"2026-05-28T00:00:00Z"}}}}'

    integration::stage_response 'default' '{"data":{}}'
}

@test "T023: fresh clarify-mirror posts 3 comments in chronological order" {
    run integration::run_reconcile --spec 005

    # ---- exit code ----
    [ "$status" -eq 0 ]

    # ---- three save_comment mutations ----
    # The reconciler issues one mutation per `### Session YYYY-MM-DD`
    # block. The mutation may surface under any of the comment-shaped
    # operation names (CommentCreate, SaveComment, save_comment_mcp)
    # depending on the implementation path; we sum the matches so the
    # test is robust to either MCP-or-GraphQL routing.
    local comment_creates
    comment_creates="$(integration::count_op 'mutation:CommentCreate')"
    local comment_saves
    comment_saves="$(integration::count_op 'mutation:SaveComment')"
    local total_comments
    total_comments=$(( comment_creates + comment_saves ))
    [ "$total_comments" -eq 3 ]

    # ---- each session's date appears in at least one mutation body ----
    # FR-015: the body MUST contain the session's bullets. The
    # session-date marker (per the contract §4.5
    # `<!-- speckit-linear: clarify-session YYYY-MM-DD -->`) is the
    # most distinctive substring, but we also accept the bare date
    # token since implementations may format the marker differently.
    local session_2026_05_01
    session_2026_05_01="$(integration::calls_containing '2026-05-01')"
    [ "$session_2026_05_01" -ge 1 ]

    local session_2026_05_15
    session_2026_05_15="$(integration::calls_containing '2026-05-15')"
    [ "$session_2026_05_15" -ge 1 ]

    local session_2026_05_28
    session_2026_05_28="$(integration::calls_containing '2026-05-28')"
    [ "$session_2026_05_28" -ge 1 ]

    # ---- chronological order ----
    # The three comment-shaped mutations must appear in the calls.log
    # in date-ascending order: 2026-05-01 first, 2026-05-15 second,
    # 2026-05-28 third. We extract the line numbers of the first
    # occurrence of each session date in calls.log and verify
    # monotonic order.
    local line_01 line_15 line_28
    line_01=$(grep -n -F '2026-05-01' "${MOCK_LINEAR_STATE}/calls.log" | head -1 | cut -d: -f1)
    line_15=$(grep -n -F '2026-05-15' "${MOCK_LINEAR_STATE}/calls.log" | head -1 | cut -d: -f1)
    line_28=$(grep -n -F '2026-05-28' "${MOCK_LINEAR_STATE}/calls.log" | head -1 | cut -d: -f1)
    [ -n "$line_01" ]
    [ -n "$line_15" ]
    [ -n "$line_28" ]
    [ "$line_01" -lt "$line_15" ]
    [ "$line_15" -lt "$line_28" ]

    # ---- Q/A content from each session appears in some mutation body ----
    # FR-015 requires the comment body to contain that session's Q/A
    # bullets. We pick a distinctive answer phrase from each session
    # in the fixture (see tests/fixtures/specs/005-clarify-sessions/spec.md).
    local qa_session1
    qa_session1="$(integration::calls_containing 'idempotent')"
    [ "$qa_session1" -ge 1 ]

    local qa_session2
    qa_session2="$(integration::calls_containing 'Deterministic UUID')"
    [ "$qa_session2" -ge 1 ]

    local qa_session3
    qa_session3="$(integration::calls_containing 'append-only')"
    [ "$qa_session3" -ge 1 ]

    # ---- summary reports comments created ----
    # The summary's `Created:` counter is incremented per
    # summary::add created. Three comment-creates plus whatever spec /
    # sub-issue creates fire give Created: >= 3.
    [[ "$output" == *"speckit.linear summary"* ]]
    [[ "$output" == *"Created:"* ]]
}
