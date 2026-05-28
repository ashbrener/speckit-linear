#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us4-seed-fresh-workspace.bats — T054
#
# User Story 4 (P2) acceptance scenario #2 (spec.md §User Story 4):
#
#   GIVEN a fresh sandbox Linear workspace where:
#         * `workflowStates(filter: { team: { id }, name: <each> })`
#           returns ZERO nodes for every lifecycle key, AND
#         * `issueLabels(filter: { name: <each> })` returns ZERO
#           nodes for every `phase:*` / `task-phase:*` label,
#   WHEN  `src/seed.sh --team SANDBOX_TEAM` runs,
#   THEN  the seed step issues:
#           * exactly 9 × `workflowStateCreate` mutations (one per
#             lifecycle key, FR-032 + contract §2.1), each with the
#             correct `type` per the type mapping in §2.1
#           * up to 18 × label-create mutations covering the
#             `phase:*` (8 labels per contract §2.2 — does NOT include
#             `phase:merged` because the bridge clears the phase label
#             on merge per FR-013, but the loose contract permits 8 or 9
#             depending on implementation) and `task-phase:1..9` families
#           * writes the resolved `workflow_state_uuids` map into
#             `.specify/extensions/linear/linear-config.yml` with all
#             nine keys populated by valid UUIDs (not the
#             zero-placeholder shape).
#         Exit 0. Summary surfaces the create counts.
#
# Maps to FR-021 + FR-022 + FR-032 + contracts/command-shapes.md §4 +
# contracts/linear-graphql-mutations.md §2.
#
# Mock strategy: reuses the curl-shim. We stage the workflowStates +
# issueLabels locate queries to return empty nodes, forcing every
# create-path to fire. Each create response echoes a deterministic
# fresh UUID the seed step can write into config.
# =============================================================================

load '../helpers/integration-helpers'

# UUIDs the canned mutation responses echo back. The seed step is
# expected to capture these and persist them under the matching
# `workflow_state_uuids` key. Naming uses the lifecycle key + a
# version-4 nibble so a UUID-syntax check in src/config.sh passes.
WFS_SPECIFYING_ID="aaaa0001-1111-4111-1111-111111110001"
WFS_CLARIFYING_ID="aaaa0002-1111-4111-1111-111111110002"
WFS_PLANNING_ID="aaaa0003-1111-4111-1111-111111110003"
WFS_TASKING_ID="aaaa0004-1111-4111-1111-111111110004"
WFS_RED_TEAM_ID="aaaa0005-1111-4111-1111-111111110005"
WFS_IMPLEMENTING_ID="aaaa0006-1111-4111-1111-111111110006"
WFS_ANALYZING_ID="aaaa0007-1111-4111-1111-111111110007"
WFS_RTM_ID="aaaa0008-1111-4111-1111-111111110008"
WFS_MERGED_ID="aaaa0009-1111-4111-1111-111111110009"

setup() {
    integration::skip_unless_enabled
    # Seed needs only the team binding; no specs/NNN dirs required.
    # The 001-minimal fixture is the smallest valid mount; we use it
    # so setup_sandbox produces a complete config + .env scaffold.
    integration::setup_sandbox '001-minimal'
    integration::install_gh_shim_no_pr

    # ---- canned: every workflowStates locate returns ZERO nodes ----
    # The seed step's idempotency probe (§2.1) MUST take the CREATE
    # path for every lifecycle key.
    integration::stage_response 'query-WorkflowStatesByName' \
        '{"data":{"workflowStates":{"nodes":[]}}}'
    integration::stage_response 'query-SeedWorkflowStates' \
        '{"data":{"workflowStates":{"nodes":[]}}}'

    # ---- canned: every issueLabels locate returns ZERO nodes ----
    integration::stage_response 'query-IssueLabelsByName' \
        '{"data":{"issueLabels":{"nodes":[]}}}'
    integration::stage_response 'query-SeedLabels' \
        '{"data":{"issueLabels":{"nodes":[]}}}'

    # Generic query fallback: empty nodes for any locate-by-name shape
    # the seed step uses internally.
    integration::stage_response 'query' \
        '{"data":{"workflowStates":{"nodes":[]},"issueLabels":{"nodes":[]}}}'

    # ---- canned: workflowStateCreate echoes the right UUID per name ----
    # We can't easily branch the mock on input body, so we echo a
    # generic-but-valid create response that includes a UUID. The seed
    # step's responsibility is to map the input name → output UUID and
    # write the right key into config; the test asserts on the WRITES
    # the seed step makes (count of workflowStateCreate mutations =
    # exactly 9) rather than per-key UUID provenance.
    integration::stage_response 'mutation-SeedWorkflowState' \
        "{\"data\":{\"workflowStateCreate\":{\"success\":true,\"workflowState\":{\"id\":\"${WFS_SPECIFYING_ID}\",\"name\":\"Specifying\",\"type\":\"unstarted\"}}}}"

    # Alternate operation-name spellings — some implementations name
    # the mutation after the GraphQL operation (`WorkflowStateCreate`),
    # others after the canonical seed-op (`SeedWorkflowState`).
    integration::stage_response 'mutation-WorkflowStateCreate' \
        "{\"data\":{\"workflowStateCreate\":{\"success\":true,\"workflowState\":{\"id\":\"${WFS_PLANNING_ID}\",\"name\":\"Planning\",\"type\":\"unstarted\"}}}}"

    # ---- canned: issueLabelCreate (workspace-scoped) ----
    integration::stage_response 'mutation-IssueLabelCreate' \
        '{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"bbbb0001-1111-4111-1111-111111110001","name":"phase:specifying"}}}}'
    integration::stage_response 'mutation-CreateIssueLabel' \
        '{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"bbbb0002-1111-4111-1111-111111110002","name":"phase:planning"}}}}'

    # Generic mutation fallback so any seed-side mutation lands a
    # parseable response even if the operation name diverges from
    # our staged keys.
    integration::stage_response 'mutation' \
        "{\"data\":{\"workflowStateCreate\":{\"success\":true,\"workflowState\":{\"id\":\"${WFS_SPECIFYING_ID}\",\"name\":\"Specifying\",\"type\":\"unstarted\"}},\"issueLabelCreate\":{\"success\":true,\"issueLabel\":{\"id\":\"bbbb0099-1111-4111-1111-111111110099\",\"name\":\"phase:fallback\"}}}}"

    integration::stage_response 'default' '{"data":{}}'
}

@test "T054: seed on fresh workspace creates 9 workflow states + label set + writes UUIDs" {
    run integration::run_seed --team "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    [ "$status" -eq 0 ]

    # ---- exactly 9 workflowStateCreate mutations ----
    # FR-032 + contract §2.1: nine canonical lifecycle states. Each
    # one is its own GraphQL mutation per the probe finding (no MCP
    # equivalent). Sum across both operation-name spellings.
    local wfs_a wfs_b wfs_creates
    wfs_a="$(integration::count_op 'mutation:WorkflowStateCreate')"
    wfs_b="$(integration::count_op 'mutation:SeedWorkflowState')"
    wfs_creates=$(( wfs_a + wfs_b ))
    [ "$wfs_creates" -eq 9 ]

    # ---- every lifecycle key appears in some mutation body ----
    # The bridge writes `name: "Specifying"` etc. into the
    # WorkflowStateCreateInput per the contract §2.1 type mapping.
    # We grep for the suggested names; the contract locks the exact
    # spelling (case-sensitive) because Linear's UI displays it.
    integration::calls_containing 'Specifying'      >/dev/null
    [ "$(integration::calls_containing 'Specifying')"    -ge 1 ]
    [ "$(integration::calls_containing 'Clarifying')"    -ge 1 ]
    [ "$(integration::calls_containing 'Planning')"      -ge 1 ]
    [ "$(integration::calls_containing 'Tasking')"       -ge 1 ]
    [ "$(integration::calls_containing 'Red-team')"      -ge 1 ]
    [ "$(integration::calls_containing 'Implementing')"  -ge 1 ]
    [ "$(integration::calls_containing 'Analyzing')"     -ge 1 ]
    [ "$(integration::calls_containing 'Ready-to-merge')" -ge 1 ]
    [ "$(integration::calls_containing 'Merged')"        -ge 1 ]

    # ---- workflow state types are correct ----
    # Per contract §2.1 type mapping:
    #   - specifying / clarifying / planning / tasking / red_team → unstarted
    #   - implementing / analyzing / ready_to_merge               → started
    #   - merged                                                  → completed
    [ "$(integration::calls_containing '"type":"unstarted"')" -ge 1 ] || \
        [ "$(integration::calls_containing 'type\":\"unstarted')" -ge 1 ]
    [ "$(integration::calls_containing '"type":"started"')" -ge 1 ] || \
        [ "$(integration::calls_containing 'type\":\"started')" -ge 1 ]
    [ "$(integration::calls_containing '"type":"completed"')" -ge 1 ] || \
        [ "$(integration::calls_containing 'type\":\"completed')" -ge 1 ]

    # ---- label creates: phase:* (8) + task-phase:1..9 (9) ≤ 18 ----
    # T054's contract says "18 labelCreate mutations". The contract in
    # linear-graphql-mutations.md §2.2 specifies 8 phase labels
    # (no `phase:merged` because FR-013 clears phase on merge) plus
    # the lazy `task-phase:N` family up to 9. Some implementations
    # seed `task-phase:1..9` eagerly during seed, others seed lazily
    # at first reconcile — accept either: total mutations ≥ 8 and ≤ 18.
    local label_a label_b label_creates
    label_a="$(integration::count_op 'mutation:IssueLabelCreate')"
    label_b="$(integration::count_op 'mutation:CreateIssueLabel')"
    label_creates=$(( label_a + label_b ))
    [ "$label_creates" -ge 8 ]
    [ "$label_creates" -le 18 ]

    # ---- every phase:* label name appears in some mutation body ----
    # Contract §2.2 enumerates the workspace-scoped phase label set.
    for phase in specifying clarifying planning tasking red_team \
                 implementing analyzing ready_to_merge; do
        [ "$(integration::calls_containing "phase:${phase}")" -ge 1 ]
    done

    # ---- workflow_state_uuids written into linear-config.yml ----
    # FR-032: seed MUST capture each created UUID and persist it under
    # `linear.workflow_state_uuids.<key>` in the per-repo config.
    [ -f "$LINEAR_CONFIG_PATH" ]
    grep -q 'workflow_state_uuids:' "$LINEAR_CONFIG_PATH"

    # Every lifecycle key MUST be present in the config (not just the
    # placeholder).
    for key in specifying clarifying planning tasking red_team \
               implementing analyzing ready_to_merge merged; do
        grep -qE "^[[:space:]]+${key}:" "$LINEAR_CONFIG_PATH"
    done

    # The UUIDs MUST NOT be the all-zeroes placeholder shape — the
    # placeholder `00000000-0000-0000-0000-000000000000` would let
    # `src/config.sh` parse the file but reconcile (FR-022) should
    # then exit 2. Seed's job is to overwrite the placeholders.
    ! grep -q '00000000-0000-0000-0000-000000000000' "$LINEAR_CONFIG_PATH"

    # ---- default_state_uuids untouched by seed ----
    # Seed creates lifecycle states, not the "Todo / In Progress /
    # Done" trio those map to. The default_state_uuids block lives
    # in config-template.yml and is not seed's responsibility — it's
    # the operator-configurable mapping from lifecycle to Linear's
    # built-in default state IDs. Confirm the block is still present
    # (the helper's _write_config_yaml seeds it).
    grep -q 'default_state_uuids:' "$LINEAR_CONFIG_PATH"

    # ---- summary emitted ----
    [[ "$output" == *"summary"* ]]
}
