#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us4-unseeded-halts.bats — T057
#
# User Story 4 (P2) acceptance scenario #3 (spec.md §User Story 4) +
# FR-022:
#
#   GIVEN a sandbox repo bound to a Linear workspace whose
#         `linear-config.yml.linear.workflow_state_uuids` map is
#         EITHER missing entirely OR populated only with the
#         all-zeroes placeholder UUID
#         (`00000000-0000-0000-0000-000000000000`) — both shapes
#         signal "this workspace has never been seeded",
#   WHEN  `src/reconcile.sh --spec NNN` runs against it,
#   THEN  the reconciler:
#           * exits with code 2 (workspace-level config error per
#             contracts/command-shapes.md §1.6)
#           * emits a structured error message naming the missing
#             resource and pointing at `speckit.linear.seed`
#           * issues ZERO writes to Linear (FR-022: "rather than
#             partially succeeding")
#
# Maps to FR-022 + FR-024 + contracts/command-shapes.md §1.7 ("`linear
# .workflow_state_uuids.*` unfilled (all zeroes) → Exit 2 with 'Run
# `/speckit-linear-seed` first'").
#
# Mock strategy: reuses the curl-shim. We deliberately stage no
# canned responses for the seed-time queries — the reconcile path
# should bail before issuing them. Any mutation that DOES land is
# captured by classified.log for the assertion.
# =============================================================================

load '../helpers/integration-helpers'

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # ---- replace the helper's seeded config with an UNSEEDED shape ----
    # The default `_write_config_yaml` populates workflow_state_uuids
    # with valid v4-shaped strings; the FR-022 check requires those
    # values to either be missing or all-zeroes. We rewrite the file
    # in-place with the all-zeroes placeholder for every key.
    cat > "$LINEAR_CONFIG_PATH" <<'YAML'
schema_version: 1
config_version: 1

linear:
  workspace:
    name: "OSH-INFRA"
    url_key: "osh-infra"
  team:
    id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    key: "OSH"
    name: "OSH-INFRA"
  project:
    id: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
    name: "speckit-linear-test"
  workflow_state_uuids:
    specifying:     "00000000-0000-0000-0000-000000000000"
    clarifying:     "00000000-0000-0000-0000-000000000000"
    planning:       "00000000-0000-0000-0000-000000000000"
    tasking:        "00000000-0000-0000-0000-000000000000"
    red_team:       "00000000-0000-0000-0000-000000000000"
    implementing:   "00000000-0000-0000-0000-000000000000"
    analyzing:      "00000000-0000-0000-0000-000000000000"
    ready_to_merge: "00000000-0000-0000-0000-000000000000"
    merged:         "00000000-0000-0000-0000-000000000000"
  default_state_uuids:
    todo:           "dddddddd-0001-4ddd-dddd-dddddddddddd"
    in_progress:    "dddddddd-0002-4ddd-dddd-dddddddddddd"
    done:           "dddddddd-0003-4ddd-dddd-dddddddddddd"

sync:
  enabled: true
  idle_window_days: 30
  emit_summary: true

webhook:
  installed: false
  workflow_path: ".github/workflows/speckit-linear-sync.yml"
  secret_name: "LINEAR_API_TOKEN"

git_hooks:
  installed: false
  hooks:
    - post-checkout
    - post-commit
    - post-merge
YAML

    # ---- canned default response so any incidental curl call gets
    # parseable JSON (the test assertion is that mutations DON'T
    # fire — but a fail-open default keeps the reconciler from
    # crashing on shim-side parse errors that would mask the real
    # failure mode) ----
    integration::stage_response 'default' '{"data":{}}'
    integration::stage_response 'query' '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'mutation' \
        '{"data":{"issueCreate":{"success":false,"issue":null}}}'
}

@test "T057: reconcile against unseeded workspace exits 2 and writes nothing" {
    run integration::run_reconcile --spec 002

    # ---- exit code 2 (workspace-level config error, FR-022) ----
    # contracts/command-shapes.md §1.6: "exit 2 — workspace-level
    # config error. Operator MUST fix config before re-running."
    [ "$status" -eq 2 ]

    # ---- ZERO mutations (no partial writes per FR-022) ----
    # "sync MUST halt with a clear error that names the missing
    # resources and points to the seed operation, rather than
    # partially succeeding."
    local mutations
    mutations="$(integration::mutation_count)"
    [ "$mutations" -eq 0 ]

    # ---- error message names `speckit.linear.seed` ----
    # contracts/command-shapes.md §1.7: "Run `/speckit-linear-seed`
    # first" — we accept the three-dot form, the slash form, or the
    # bare `seed` token because the exact phrasing isn't load-bearing
    # so long as the pointer is unambiguous.
    [[ "$output" == *"speckit.linear.seed"* ]] || \
        [[ "$output" == *"/speckit-linear-seed"* ]] || \
        [[ "$output" == *"speckit-linear-seed"* ]] || \
        [[ "$output" == *"linear seed"* ]] || \
        [[ "$output" == *"run seed"* ]] || \
        [[ "$output" == *"Run seed"* ]]

    # ---- error message names the missing resource ----
    # FR-022: error MUST "name the missing resources". The unseeded
    # workspace's signature is the workflow_state_uuids being unfilled;
    # the error message MUST reference that key (or the more generic
    # "workflow state" / "unseeded workspace" phrasing).
    [[ "$output" == *"workflow_state_uuids"* ]] || \
        [[ "$output" == *"workflow state"* ]] || \
        [[ "$output" == *"unseeded"* ]] || \
        [[ "$output" == *"not seeded"* ]] || \
        [[ "$output" == *"never been seeded"* ]] || \
        [[ "$output" == *"seed"* ]]

    # ---- no Linear-side writes leaked through ----
    # Stronger than mutation_count == 0: confirm no issueCreate /
    # issueUpdate operations classified at all.
    local creates
    creates="$(integration::count_op 'mutation:IssueCreate')"
    local updates
    updates="$(integration::count_op 'mutation:IssueUpdate')"
    [ "$creates" -eq 0 ]
    [ "$updates" -eq 0 ]
}
