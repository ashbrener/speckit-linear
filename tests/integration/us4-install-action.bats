#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us4-install-action.bats — T056
#
# User Story 4 (P2) acceptance scenario #1 (spec.md §User Story 4) +
# FR-027 + FR-029:
#
#   GIVEN a fresh sandbox consumer repo with the bridge available but
#         not yet installed,
#   WHEN  `src/install.sh --with-action ...` runs,
#   THEN  the install step drops the GitHub Action workflow into
#         `.github/workflows/spec-kit-linear-sync.yml` carrying the
#         three required triggers (pull_request: opened,
#         ready_for_review, closed), AND
#         the install report (stdout/stderr) includes the
#         `gh secret set LINEAR_API_TOKEN -R ...` provisioning line
#         per FR-029.
#   AND   the dropped workflow file passes `yamllint -d relaxed`
#         (or is gracefully skipped if yamllint is unavailable —
#         not a hard CI dep for this test).
#
# Maps to FR-018 + FR-027 + FR-029 + contracts/command-shapes.md §5.5.
#
# Mock strategy: reuses the curl-shim — install hits Linear for
# Project resolution (list_projects / save_project). We stage the
# "single team, single matching Project" canned path so the picker
# auto-selects and the install completes non-interactively.
# =============================================================================

load '../helpers/integration-helpers'

setup() {
    integration::skip_unless_enabled
    integration::setup_bare_sandbox
    integration::install_gh_shim_no_pr

    # T056/T063 alignment: the seed-state detector (install::prompt_seed_run)
    # treats a missing or all-zero workflow_state_uuids map as unseeded and
    # halts in --non-interactive mode per FR-022. Pre-populate the per-repo
    # config with a fully-seeded UUID map so this test exercises the Action
    # install path in isolation. A separate test (us4-seed-prompt.bats)
    # covers the unseeded branches.
    integration::_write_config_yaml > "$LINEAR_CONFIG_PATH"

    # ---- canned: list_teams returns the single sandbox team ----
    # FR-002: single-team workspaces auto-fill with no prompt.
    integration::stage_response 'query-ListTeams' \
        '{"data":{"teams":{"nodes":[{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","name":"ACME"}]}}}'

    # ---- canned: list_projects in the team returns empty ----
    # Forces --auto-create path so install issues exactly one
    # save_project mutation.
    integration::stage_response 'query-ListProjects' \
        '{"data":{"projects":{"nodes":[]}}}'

    integration::stage_response 'query' \
        '{"data":{"teams":{"nodes":[{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","key":"ACM","name":"ACME"}]},"projects":{"nodes":[]}}}'

    # ---- canned: save_project (or projectCreate) succeeds ----
    integration::stage_response 'mutation-ProjectCreate' \
        '{"data":{"projectCreate":{"success":true,"project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"repo","state":"planned"}}}}'
    integration::stage_response 'mutation-SaveProject' \
        '{"data":{"projectCreate":{"success":true,"project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"repo","state":"planned"}}}}'

    integration::stage_response 'mutation' \
        '{"data":{"projectCreate":{"success":true,"project":{"id":"bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb","name":"repo","state":"planned"}}}}'

    # ---- canned: viewer { id name email } for FR-034 operator capture ----
    integration::stage_response 'query-Me' \
        '{"data":{"viewer":{"id":"eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee","name":"Integration Tester","email":"integration@example.com"}}}'

    # ---- canned: catchall returns viewer JSON so any unstaged query path
    # (e.g. a workflow-state pre-check during T063 seed-state detection)
    # still parses cleanly. The reconciler/install caller code paths
    # under test are insensitive to the extra fields. ----
    integration::stage_response 'default' \
        '{"data":{"viewer":{"id":"eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee","name":"Integration Tester","email":"integration@example.com"}}}'
}

@test "T056: install --with-action drops workflow file + prints LINEAR_API_TOKEN provisioning line" {
    # The install contract (command-shapes.md §5.3) names the action
    # flag as the inverse (`--no-action` to suppress). FR-027's
    # acceptance scenario describes the opt-in path. We pass
    # --with-action explicitly so an implementation that defaults to
    # off (asking the operator) still installs the workflow file in
    # non-interactive mode.
    run integration::run_install \
        --auto-create \
        --team "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa" \
        --with-action \
        --no-prompt
    [ "$status" -eq 0 ]

    # ---- workflow file exists at the canonical path ----
    local workflow="${SANDBOX_REPO}/.github/workflows/spec-kit-linear-sync.yml"
    [ -f "$workflow" ]

    # ---- workflow file carries the three required pull_request
    # triggers per FR-027 ----
    grep -q 'pull_request:' "$workflow"
    grep -q 'opened' "$workflow"
    grep -q 'ready_for_review' "$workflow"
    grep -q 'closed' "$workflow"

    # ---- workflow file references LINEAR_API_TOKEN secret per FR-029 ----
    grep -q 'LINEAR_API_TOKEN' "$workflow"

    # ---- workflow file restricts permissions to contents: read ----
    # contracts/webhook-action.md mandates minimal permission scope.
    grep -qE 'permissions:' "$workflow"
    grep -qE 'contents:[[:space:]]*read' "$workflow"

    # ---- install report includes the gh secret set provisioning line ----
    # FR-029: "The bridge's install flow MUST surface the exact
    # token-provisioning steps to the operator (link to Linear's
    # API key page, gh secret set LINEAR_API_TOKEN example)."
    # The contract sample (command-shapes.md §5.5) shows:
    #   → Run: gh secret set LINEAR_API_TOKEN -R ashbrener/spec-kit-linear
    [[ "$output" == *"gh secret set LINEAR_API_TOKEN"* ]]

    # ---- the report also mentions where the operator gets the token ----
    # Sample shows a link to https://linear.app/settings/api.
    [[ "$output" == *"linear.app"* ]] || [[ "$output" == *"Linear API"* ]] || [[ "$output" == *"API key"* ]]

    # ---- workflow YAML is well-formed ----
    # Prefer yamllint -d relaxed; fall back to python's yaml parser;
    # if neither is available, skip the YAML-syntax assertion (the
    # other assertions above already prove the file landed with the
    # required fields).
    if command -v yamllint >/dev/null 2>&1; then
        run yamllint -d relaxed "$workflow"
        [ "$status" -eq 0 ]
    elif command -v python3 >/dev/null 2>&1; then
        run python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$workflow"
        [ "$status" -eq 0 ]
    else
        skip "yamllint and python3 both unavailable — YAML syntax assertion skipped (other field assertions still active)"
    fi

    # ---- linear-config.yml records the install ----
    # FR-002 + command-shapes.md §5.5: install writes team / project
    # UUIDs into linear-config.yml; webhook.installed flips to true
    # when the Action was installed.
    [ -f "$LINEAR_CONFIG_PATH" ]
    grep -q 'team:' "$LINEAR_CONFIG_PATH"
    grep -q 'project:' "$LINEAR_CONFIG_PATH"
}
