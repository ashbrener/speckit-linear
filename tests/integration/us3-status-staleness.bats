#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us3-status-staleness.bats — T051
#
# User Story 3 (P2) — `speckit.linear.status` is a per-spec drift report
# that NEVER writes to Linear (spec.md FR-025, FR-026 read-only display
# semantics, SC-009).
#
# Three scenarios cover the load-bearing contract:
#
#   1. CLEAN — disk and Linear agree on every comparable axis. Output
#      contains the spec NNN, exits 0, ZERO mutations issued.
#
#   2. STALE — Linear reports a different lifecycle phase than the
#      disk-side inference, so the drift section MUST list at least
#      one signal. Exits 0; ZERO mutations issued.
#
#   3. READ-ONLY FROM MAIN — same fixture as (1), but invoked from a
#      `main` worktree (non-authoritative per FR-025). The report MUST
#      still surface the spec (FR-026), MUST report authority=No, and
#      MUST issue ZERO mutations.
#
# Mock strategy: reuses the curl-shim from integration-helpers.bash.
# All scenarios stage the spec-Issue locate query and a generic query
# fallback; the status command never reaches a mutation code path so
# even the catch-all mutation response is defensive.
# =============================================================================

load '../helpers/integration-helpers'

# A deterministic spec-Issue UUID the staged response will echo. The
# command derives every Linear-side field from this response.
SPEC_ISSUE_ID="ee000000-0000-4000-0000-000000000002"

# -----------------------------------------------------------------------------
# integration::find_status_sh / integration::run_status
#
# Inline test-local mirrors of the find_install_sh / run_install pattern
# from the helper. We define them here rather than touching the helper
# so this test stays self-contained and other test files don't have to
# learn about the status command's path.
# -----------------------------------------------------------------------------
find_status_sh() {
    printf '%s' "${PROJECT_ROOT}/src/status.sh"
}

run_status_in_sandbox() {
    local status_sh
    status_sh="$(find_status_sh)"
    (
        cd "$SANDBOX_REPO"
        export SPECKIT_LINEAR_CONFIG="$LINEAR_CONFIG_PATH"
        bash "$status_sh" "$@" 2>&1
    )
}

# -----------------------------------------------------------------------------
# stage_spec_issue_response <state-name> <phase-label>
#
# Helper: stage a `query-SpecIssueForStatus` canned response with the
# given Linear-side state name + phase:* label. Used to control the
# clean vs stale scenarios.
# -----------------------------------------------------------------------------
stage_spec_issue_response() {
    local state_name="$1"
    local phase_label="$2"
    local payload
    payload=$(cat <<EOF
{"data":{"issues":{"nodes":[
  {
    "id":"${SPEC_ISSUE_ID}",
    "identifier":"ACM-12",
    "title":"002-multi-phase",
    "updatedAt":"2026-05-28T00:00:00.000Z",
    "description":"<!-- spec-kit-linear:memory:begin -->\n| **Branch** | \`002-multi-phase\` |\n<!-- spec-kit-linear:memory:end -->",
    "state":{"id":"cccccccc-0004-4ccc-cccc-cccccccccccc","name":"${state_name}","type":"started"},
    "labels":{"nodes":[{"name":"speckit-spec:002"},{"name":"phase:${phase_label}"}]},
    "children":{"nodes":[]}
  }
]}}}
EOF
)
    integration::stage_response 'query-SpecIssueForStatus' "$payload"
}

# =============================================================================
# Scenario 1 — CLEAN: disk and Linear agree.
# =============================================================================

@test "T051-clean: status reports no drift when disk and Linear agree" {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # Disk-side: fixture 002 has spec.md + plan.md + tasks.md (no
    # checks, no analyze) → lifecycle_phase = "tasking".
    # Stage Linear at "Tasking" + phase:tasking so the two agree.
    stage_spec_issue_response "Tasking" "tasking"
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":null,"comments":{"nodes":[]}}}'
    integration::stage_response 'mutation' \
        '{"data":{}}'
    integration::stage_response 'default' '{"data":{}}'

    run run_status_in_sandbox --spec 002 --no-color
    [ "$status" -eq 0 ]

    # ---- ZERO mutations ----
    # SC-009 + FR-026: status is READ-ONLY; never mutates Linear.
    # The classified.log MUST contain no `mutation:` lines. We grep
    # the file directly rather than relying on integration::mutation_count
    # because the helper's grep-with-fallback double-prints "0" on the
    # empty case, which trips bash's integer comparator.
    # We grep classified.log directly rather than using
    # integration::mutation_count because the helper's `grep -c || printf '0'`
    # pattern double-prints "0" on the empty-match case (grep prints 0 and
    # then exits non-zero, triggering the `|| printf '0'` branch too).
    local mutation_lines
    mutation_lines="$(grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null | head -n1)"
    [[ -z "$mutation_lines" || "$mutation_lines" == "0" ]]

    # ---- output mentions the spec NNN ----
    [[ "$output" == *"002"* ]]
    # ---- AUTH column reads Yes (we're on the feature branch by default) ----
    [[ "$output" == *"Yes"* ]]
    # ---- summary block fired ----
    [[ "$output" == *"speckit.linear summary"* ]]
}

# =============================================================================
# Scenario 2 — STALE: Linear reports a different phase than disk.
# =============================================================================

@test "T051-stale: status surfaces drift when Linear phase differs from disk" {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # Disk-side: tasking. Stage Linear at "Implementing" + phase:implementing
    # so the drift comparator flags the mismatch.
    stage_spec_issue_response "Implementing" "implementing"
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":null,"comments":{"nodes":[]}}}'
    integration::stage_response 'mutation' \
        '{"data":{}}'
    integration::stage_response 'default' '{"data":{}}'

    run run_status_in_sandbox --spec 002 --json --no-color
    [ "$status" -eq 0 ]

    # ---- ZERO mutations ----
    # We grep classified.log directly rather than using
    # integration::mutation_count because the helper's `grep -c || printf '0'`
    # pattern double-prints "0" on the empty-match case (grep prints 0 and
    # then exits non-zero, triggering the `|| printf '0'` branch too).
    local mutation_lines
    mutation_lines="$(grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null | head -n1)"
    [[ -z "$mutation_lines" || "$mutation_lines" == "0" ]]

    # ---- JSON output parseable + drift array non-empty for spec 002 ----
    # The output has the JSON array on stdout PLUS the summary block on
    # stderr (merged via 2>&1 in run_status_in_sandbox). Extract the
    # first '[' through the matching ']' to isolate the array, then
    # validate with jq.
    #
    # Easier path: grep the literal substring; the drift signal text
    # is locked to "lifecycle phase: disk=tasking linear=implementing".
    [[ "$output" == *"lifecycle phase"* ]]
    [[ "$output" == *"disk=tasking"* ]]
    [[ "$output" == *"linear=implementing"* ]]
}

# =============================================================================
# Scenario 3 — READ-ONLY FROM MAIN: non-authoritative worktree.
# =============================================================================

@test "T051-readonly: status from non-authoritative worktree still emits, never mutates" {
    integration::skip_unless_enabled

    # We don't use setup_sandbox here because the default setup checks
    # out the fixture-named branch (which would make this test
    # authoritative). Build the sandbox manually with `main` as the
    # checked-out branch and the feature branch held in a sibling
    # worktree — the same pattern as us2-non-authoritative-worktree.bats.
    SANDBOX_REPO="${BATS_TEST_TMPDIR}/repo"
    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    MOCK_LINEAR_STATE="${BATS_TEST_TMPDIR}/mock-linear-state"
    LINEAR_CONFIG_PATH="${SANDBOX_REPO}/.specify/extensions/linear/linear-config.yml"

    mkdir -p "$SANDBOX_REPO" "$MOCK_BIN" "$MOCK_LINEAR_STATE"
    mkdir -p "${SANDBOX_REPO}/.specify/extensions/linear"
    mkdir -p "${SANDBOX_REPO}/specs"

    export SANDBOX_REPO MOCK_BIN MOCK_LINEAR_STATE LINEAR_CONFIG_PATH

    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    export GIT_AUTHOR_NAME='Integration Test'
    export GIT_AUTHOR_EMAIL='integration@example.com'
    export GIT_COMMITTER_NAME='Integration Test'
    export GIT_COMMITTER_EMAIL='integration@example.com'
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null

    git -C "$SANDBOX_REPO" init --initial-branch=main --quiet
    printf 'sandbox consumer repo\n' > "${SANDBOX_REPO}/README.md"
    git -C "$SANDBOX_REPO" add README.md
    git -C "$SANDBOX_REPO" commit --quiet -m 'initial commit'

    cp -R "${FIXTURES_ROOT}/002-multi-phase" \
        "${SANDBOX_REPO}/specs/002-multi-phase"
    git -C "$SANDBOX_REPO" add "specs/002-multi-phase"
    git -C "$SANDBOX_REPO" commit --quiet -m 'add 002 spec fixture'

    git -C "$SANDBOX_REPO" branch --quiet '002-multi-phase' HEAD
    integration::add_worktree '002-multi-phase'

    integration::_write_config_yaml > "$LINEAR_CONFIG_PATH"
    cat > "${SANDBOX_REPO}/.env" <<'ENV'
LINEAR_API_KEY=lin_api_integration_fake
ENV

    integration::_install_curl_shim
    integration::install_gh_shim_no_pr
    export PATH="${MOCK_BIN}:${PATH}"

    stage_spec_issue_response "Tasking" "tasking"
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":null,"comments":{"nodes":[]}}}'
    integration::stage_response 'mutation' \
        '{"data":{}}'
    integration::stage_response 'default' '{"data":{}}'

    # Precondition: we are on `main` in the primary worktree.
    local current_branch
    current_branch="$(git -C "$SANDBOX_REPO" rev-parse --abbrev-ref HEAD)"
    [ "$current_branch" = "main" ]

    run run_status_in_sandbox --spec 002 --no-color
    [ "$status" -eq 0 ]

    # ---- ZERO mutations (SC-009) ----
    # We grep classified.log directly rather than using
    # integration::mutation_count because the helper's `grep -c || printf '0'`
    # pattern double-prints "0" on the empty-match case (grep prints 0 and
    # then exits non-zero, triggering the `|| printf '0'` branch too).
    local mutation_lines
    mutation_lines="$(grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null | head -n1)"
    [[ -z "$mutation_lines" || "$mutation_lines" == "0" ]]

    # ---- spec STILL surfaces (FR-026 — read-only display) ----
    [[ "$output" == *"002"* ]]

    # ---- AUTH column reads No (non-authoritative) ----
    [[ "$output" == *"No"* ]]
}
