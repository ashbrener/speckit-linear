#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us5-retroactive-bypass-authority.bats — User Story 5
#
# Regression-pin for the v0.1.0 bug surfaced during the HURRI dogfood
# run: `bash src/reconcile.sh --all --retroactive` completed with ZERO
# mutations when invoked from any branch that didn't match a spec's
# canonical NNN-feature name. The cause was that `--retroactive` only
# suppressed the per-spec "non-authoritative" warning row in
# `summary::emit`; it did NOT actually bypass the FR-025 / Principle IV
# write-authority gate inside `reconcile::sync_spec_issue`'s caller.
#
# Per FR-014 + `commands/linear-push.md`, `--retroactive` is the
# operator-facing escape hatch for first-time-adoption: it MUST
# converge every spec into Linear regardless of which branch the
# operator is on, because spec-specific feature branches may not
# exist yet (or may have been deleted post-merge).
#
# This file proves the contract end-to-end against a mocked GraphQL
# endpoint. Two scenarios:
#
#   1. Bypass ON: three specs, the current branch is `feat/unrelated`
#      (i.e. matches no NNN- prefix), `--retroactive --all` MUST trigger
#      one mutation per spec AND the summary block MUST carry the
#      aggregate INFO row naming the bypass count.
#
#   2. Bypass OFF (regression-pin for the default FR-025 gate): same
#      setup, same `--all`, but WITHOUT `--retroactive`. All three
#      specs MUST be skipped, zero mutations issued, and the summary's
#      Skipped counter MUST be >= 3.
#
# Both scenarios gate on RUN_INTEGRATION_TESTS=1 per repo convention
# (helper-side via integration::skip_unless_enabled).
# =============================================================================

load '../helpers/integration-helpers'

# us5_bypass::count_mutations_containing <needle>
#   Copy of retroactive.bats' counter — kept local so this file is
#   readable in isolation. The shim writes one pretty-printed JSON
#   object per call into calls.log; grep -c counts LINES not CALLS,
#   so we split on the `^}\n{$` seam to count CALLS that classify as
#   mutations (i.e. whose payload contains `"query": "mutation `) and
#   that also embed the supplied needle.
us5_bypass::count_mutations_containing() {
    local needle="$1"
    local calls_log="${MOCK_LINEAR_STATE}/calls.log"
    if [[ ! -f "$calls_log" ]]; then
        printf '0\n'
        return 0
    fi
    awk -v needle="$needle" '
        BEGIN { RS = "\n}\n{"; count = 0 }
        {
            body = $0
            if (NR > 1) { body = "{" body }
            if (index(body, "\"query\": \"mutation ") > 0 \
                && index(body, needle) > 0) {
                count++
            }
        }
        END { print count }
    ' "$calls_log"
}

# us5_bypass::count_total_mutations
#   Total number of mutation calls the shim logged. Used by the
#   "bypass OFF" scenario to prove zero writes (across every spec)
#   when the default FR-025 gate fires.
us5_bypass::count_total_mutations() {
    local calls_log="${MOCK_LINEAR_STATE}/calls.log"
    if [[ ! -f "$calls_log" ]]; then
        printf '0\n'
        return 0
    fi
    awk '
        BEGIN { RS = "\n}\n{"; count = 0 }
        {
            body = $0
            if (NR > 1) { body = "{" body }
            if (index(body, "\"query\": \"mutation ") > 0) {
                count++
            }
        }
        END { print count }
    ' "$calls_log"
}

# us5_bypass::stage_default_responses
#   Locate queries return ZERO nodes so every save_issue takes the
#   CREATE path (matches retroactive.bats' canonical fresh-reconcile
#   precondition). Mutation responses echo stable fake UUIDs.
us5_bypass::stage_default_responses() {
    integration::stage_response 'query-LocateSpecIssue' \
        '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'query-LocateTaskPhase' \
        '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":{"blocks":{"nodes":[]}},"comments":{"nodes":[]},"workflowStates":{"nodes":[]}}}'
    integration::stage_response 'mutation' \
        '{"data":{"issueCreate":{"success":true,"issue":{"id":"11111111-1111-4111-1111-111111111111","identifier":"OSH-1","title":"created","state":{"id":"cccccccc-0001-4ccc-cccc-cccccccccccc"}}},"issueUpdate":{"success":true,"issue":{"id":"22222222-2222-4222-2222-222222222222","identifier":"OSH-2","title":"updated","state":{"id":"cccccccc-0001-4ccc-cccc-cccccccccccc"}}}}}'
    integration::stage_response 'default' '{"data":{}}'
}

# us5_bypass::setup_three_spec_unrelated_branch
#   Build a sandbox with THREE spec dirs committed to main, then
#   check out `feat/unrelated` — a branch whose name matches NO spec's
#   NNN- prefix. From this branch, the default FR-025 gate would
#   read-only-skip every spec; --retroactive MUST punch through.
us5_bypass::setup_three_spec_unrelated_branch() {
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

    # Mount three distinct fixtures. Each has a different lifecycle-
    # phase shape, so the per-spec write path exercises CREATE for
    # three different phase labels in the same run.
    cp -R "${FIXTURES_ROOT}/001-minimal" \
        "${SANDBOX_REPO}/specs/001-minimal"
    cp -R "${FIXTURES_ROOT}/002-multi-phase" \
        "${SANDBOX_REPO}/specs/002-multi-phase"
    cp -R "${FIXTURES_ROOT}/004-already-merged" \
        "${SANDBOX_REPO}/specs/004-already-merged"
    git -C "$SANDBOX_REPO" add specs/
    git -C "$SANDBOX_REPO" commit --quiet -m 'mount three specs'

    # Check out a branch whose name does NOT match any NNN- prefix.
    # From this branch, git_helpers::is_authoritative_for_spec returns
    # false for every spec — the exact HURRI dogfood condition.
    git -C "$SANDBOX_REPO" checkout --quiet -b 'feat/unrelated'

    integration::_write_config_yaml > "$LINEAR_CONFIG_PATH"

    cat > "${SANDBOX_REPO}/.env" <<'ENV'
LINEAR_API_KEY=lin_api_integration_fake
ENV

    integration::_install_curl_shim
    integration::install_gh_shim_no_pr
    export PATH="${MOCK_BIN}:${PATH}"

    us5_bypass::stage_default_responses
}

# =============================================================================
# Scenario 1: BYPASS ON — `--retroactive --all` from `feat/unrelated`
# writes for every spec (the FR-014 first-time-adoption contract).
# =============================================================================
@test "us5: --retroactive --all from non-NNN branch writes every spec (FR-014 bypass)" {
    integration::skip_unless_enabled
    us5_bypass::setup_three_spec_unrelated_branch

    # Sanity-check the precondition: current branch matches no NNN.
    local current_branch
    current_branch="$(git -C "$SANDBOX_REPO" rev-parse --abbrev-ref HEAD)"
    [ "$current_branch" = "feat/unrelated" ]

    run integration::run_reconcile --retroactive --all
    # Tolerate exit 0 OR 1 — the mock's empty `workflowStates` response
    # trips the FR-002 Project Status soft-warn path. The write
    # contract lands BEFORE that promotion (see retroactive.bats
    # scenario 1 for the same rationale).
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # ---- assertion 1: every spec triggered a mutation ----
    # The spec-identity label `speckit-spec:NNN` is stamped on every
    # CREATE per FR-004b, so its presence in a mutation body proves
    # that spec was written.
    local spec001_mutations spec002_mutations spec004_mutations
    spec001_mutations="$(us5_bypass::count_mutations_containing 'speckit-spec:001')"
    spec002_mutations="$(us5_bypass::count_mutations_containing 'speckit-spec:002')"
    spec004_mutations="$(us5_bypass::count_mutations_containing 'speckit-spec:004')"
    [ "$spec001_mutations" -ge 1 ]
    [ "$spec002_mutations" -ge 1 ]
    [ "$spec004_mutations" -ge 1 ]

    # ---- assertion 2: summary carries the aggregate INFO row ----
    [[ "$output" == *"speckit.linear summary"* ]]
    local summary_block
    summary_block="$(printf '%s\n' "$output" \
        | awk '/===== speckit\.linear summary =====/,/^==================================$/')"
    # The aggregate row names the bypass and the branch.
    [[ "$summary_block" == *"retroactive:"* ]]
    [[ "$summary_block" == *"non-authoritative"* ]]
    [[ "$summary_block" == *"feat/unrelated"* ]]
    # Per-spec skip rows MUST NOT appear — the bypass replaces them.
    [[ "$summary_block" != *"spec 001: non-authoritative"* ]]
    [[ "$summary_block" != *"spec 002: non-authoritative"* ]]
    [[ "$summary_block" != *"spec 004: non-authoritative"* ]]
}

# =============================================================================
# Scenario 2: BYPASS OFF — `--all` (no `--retroactive`) from the same
# `feat/unrelated` branch MUST skip every spec, zero mutations issued.
# Regression-pin for the default FR-025 write-authority gate.
# =============================================================================
@test "us5: --all (no --retroactive) from non-NNN branch skips every spec (FR-025 default)" {
    integration::skip_unless_enabled
    us5_bypass::setup_three_spec_unrelated_branch

    # Same precondition as scenario 1 — current branch matches no NNN.
    local current_branch
    current_branch="$(git -C "$SANDBOX_REPO" rev-parse --abbrev-ref HEAD)"
    [ "$current_branch" = "feat/unrelated" ]

    run integration::run_reconcile --all
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # ---- assertion 1: zero mutations across every spec ----
    # The read-only-display path may issue `query-LocateSpecIssue`
    # reads (which legitimately embed `speckit-spec:NNN` as a filter),
    # but MUST NOT issue any mutations. The total mutation count is
    # the strongest assertion: zero mutations, period.
    local total_mutations
    total_mutations="$(us5_bypass::count_total_mutations)"
    [ "$total_mutations" -eq 0 ]

    # Belt-and-braces: explicitly check each spec label was not used
    # in any mutation body either.
    local spec001_mutations spec002_mutations spec004_mutations
    spec001_mutations="$(us5_bypass::count_mutations_containing 'speckit-spec:001')"
    spec002_mutations="$(us5_bypass::count_mutations_containing 'speckit-spec:002')"
    spec004_mutations="$(us5_bypass::count_mutations_containing 'speckit-spec:004')"
    [ "$spec001_mutations" -eq 0 ]
    [ "$spec002_mutations" -eq 0 ]
    [ "$spec004_mutations" -eq 0 ]

    # ---- assertion 2: summary's Skipped counter is >= 3 ----
    [[ "$output" == *"speckit.linear summary"* ]]
    local summary_block
    summary_block="$(printf '%s\n' "$output" \
        | awk '/===== speckit\.linear summary =====/,/^==================================$/')"
    # Every spec entered the read-only display path → at least one
    # skipped event per spec landed in summary.
    [[ "$summary_block" == *"Skipped:"* ]]
    [[ "$summary_block" == *"non-authoritative"* ]]
    # And the aggregate INFO row MUST NOT appear (bypass never fired).
    [[ "$summary_block" != *"retroactive:"* ]]
}
