#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us2-non-authoritative-worktree.bats — T038
#
# User Story 2 (P1) — write-authority gate from a non-authoritative
# worktree (spec.md FR-025, FR-026, SC-009):
#
#   GIVEN a sandbox repo with TWO worktrees:
#         * primary worktree on `001-spec-kit-linear-bridge` (this
#           branch holds write-authority for spec 001 per FR-025)
#         * secondary worktree on `main`
#   WHEN  the reconciler is invoked from the `main` worktree
#         (`bash src/reconcile.sh --spec 001`),
#   THEN  ZERO Linear mutations are issued for spec 001 (FR-025
#         denies write-authority on any worktree not on the spec's
#         feature branch). The reconcile pass MUST still query Linear
#         and surface the read-only display per FR-026. Exit 0. The
#         summary lists the spec under a "Read-only" / "skipped"
#         section.
#
# Maps to FR-025 + FR-026 + SC-009 ("No invocation of the bridge from
# a worktree that is not on a given spec's feature branch ever
# changes that spec's Linear state").
#
# Mock strategy: reuses the curl-shim. We stage spec-Issue locate
# responses returning ONE existing node (so reconcile has something
# to display in read-only mode), then assert mutation_count == 0
# from the non-authoritative worktree.
# =============================================================================

load '../helpers/integration-helpers'

SPEC_ISSUE_ID="ee000000-0000-4000-0000-000000000001"

setup() {
    integration::skip_unless_enabled

    # We don't use setup_sandbox here because the default setup checks
    # out the fixture-named branch (which would make the test worktree
    # authoritative). We build the sandbox manually to enforce two
    # explicit worktrees with distinct authorities.
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

    # ---- mount fixture under specs/001-spec-kit-linear-bridge/ ----
    # We use the 001-minimal fixture but mount it under a feature-NNN
    # branch name (001-spec-kit-linear-bridge) so the write-authority
    # gate has something concrete to refuse.
    cp -R "${FIXTURES_ROOT}/001-minimal" \
        "${SANDBOX_REPO}/specs/001-spec-kit-linear-bridge"
    git -C "$SANDBOX_REPO" add "specs/001-spec-kit-linear-bridge"
    git -C "$SANDBOX_REPO" commit --quiet -m 'add 001 spec fixture'

    # ---- create the AUTHORITATIVE feature branch ----
    git -C "$SANDBOX_REPO" branch --quiet '001-spec-kit-linear-bridge' HEAD

    # The primary worktree STAYS on `main`. We add a secondary
    # worktree on the feature branch so the branch is "checked out
    # somewhere" — the test will invoke reconcile from `main` and
    # assert it refuses to write.
    integration::add_worktree '001-spec-kit-linear-bridge'

    # ---- drop a valid linear-config.yml ----
    integration::_write_config_yaml > "$LINEAR_CONFIG_PATH"

    # ---- drop a .env ----
    cat > "${SANDBOX_REPO}/.env" <<'ENV'
LINEAR_API_KEY=lin_api_integration_fake
ENV

    # ---- curl + gh shims ----
    integration::_install_curl_shim
    integration::install_gh_shim_no_pr
    export PATH="${MOCK_BIN}:${PATH}"

    # ---- canned responses ----
    # Spec-issue locate returns ONE node so reconcile has a Linear-
    # current state to surface in read-only mode (FR-026). If reconcile
    # honours the write-authority gate, ZERO mutations follow.
    integration::stage_response 'query-LocateSpecIssue' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\",\"identifier\":\"ACM-1\",\"title\":\"001-spec-kit-linear-bridge\",\"state\":{\"id\":\"cccccccc-0001-4ccc-cccc-cccccccccccc\",\"name\":\"Specifying\"}}]}}}"

    integration::stage_response 'query-LocateTaskPhase' \
        '{"data":{"issues":{"nodes":[]}}}'

    integration::stage_response 'query' \
        "{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"${SPEC_ISSUE_ID}\",\"updatedAt\":\"2026-05-28T00:00:00Z\"}]},\"issue\":{\"id\":\"${SPEC_ISSUE_ID}\",\"blocks\":{\"nodes\":[]}},\"comments\":{\"nodes\":[]}}}"

    # If a mutation DOES fire (test failure mode), the response is
    # still parseable so reconcile doesn't crash before we assert.
    integration::stage_response 'mutation' \
        "{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"${SPEC_ISSUE_ID}\",\"identifier\":\"ACM-1\"}}}}"

    integration::stage_response 'default' '{"data":{}}'
}

@test "T038/T347: reconcile from a non-feature worktree (SUPERSEDED by spec 003 / FR-051)" {
    # SUPERSEDED — spec 003 (v2.0.0 Principle IV, drift-aware authority)
    # removed the FR-025 write-authority branch-gate this test was
    # written to verify. The premise — "reconcile from a non-feature
    # worktree NEVER mutates Linear (SC-009)" — is no longer true:
    # FR-051 lets ANY worktree write; backward-drift surfaces a WARNING
    # but does NOT block (Principle VIII).
    #
    # Per T347 ("do NOT delete; repurpose"), this scenario is redirected
    # rather than removed. The authoritative coverage for the new
    # write-from-any-branch + drift-warn-not-block behavior lives in
    # tests/integration/drift_e2e.bats (added in Phases 3-5):
    #   - "write-from-main writes every spec with zero flags" (FR-051)
    #   - "no drift → no backward-drift warning" (SC-017)
    #   - the --on-drift / interactive-prompt disposition tests
    # FR-026 read-only DISPLAY (status/pull from any worktree) is
    # retained and covered by us3-status-staleness.bats.
    #
    # Recorded as Assumption A19 in specs/003-drift-aware-authority/tasks.md:
    # a full behavioral inversion here would require re-staging the
    # create-path mock; the behavior is already authoritatively tested
    # in drift_e2e.bats, so this marker is skipped with a pointer
    # instead of duplicating that coverage with a fragile mock.
    skip "superseded by spec 003 FR-051 — see tests/integration/drift_e2e.bats (write-from-any-branch + drift disposition)"
}
