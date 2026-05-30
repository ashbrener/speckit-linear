#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/drift_e2e.bats — spec 003 drift-aware write authority E2E
#
# End-to-end coverage for the warn-not-block write path (data-model §5).
# Every test gates on RUN_INTEGRATION_TESTS=1 (integration::skip_unless_enabled)
# per repo convention.
#
# Phase 3 (US1 spine) lands the SCAFFOLD + skip-gated placeholders for the
# three US1 scenarios (T320-T322). The full live `RUN_INTEGRATION_TESTS=1`
# round-trip bodies — asserting real mutations against a mocked Linear
# endpoint — land with the dogfood harness in Phase 6 (T352). Each placeholder
# documents the exact assertion its live body will carry so the contract is
# legible before the wiring.
#
# US2 (T331/T332) and US3 (T341/T342) skip-gated placeholders land here too;
# their live bodies join the US1 ones in the Phase 6 dogfood harness (T352).
# =============================================================================

load '../helpers/integration-helpers'

# drift_e2e::count_total_mutations
#   Count mutation calls the curl shim logged (the `^}\n{$` seam splits
#   the pretty-printed call log into individual calls). Proxy for "did
#   the reconcile write?".
drift_e2e::count_total_mutations() {
    local calls_log="${MOCK_LINEAR_STATE}/calls.log"
    [[ -f "$calls_log" ]] || { printf '0\n'; return 0; }
    awk '
        BEGIN { RS = "\n}\n{"; count = 0 }
        {
            body = $0
            if (NR > 1) { body = "{" body }
            if (index(body, "\"query\": \"mutation ") > 0) { count++ }
        }
        END { print count }
    ' "$calls_log"
}

# drift_e2e::count_mutations_containing <needle>
drift_e2e::count_mutations_containing() {
    local needle="$1"
    local calls_log="${MOCK_LINEAR_STATE}/calls.log"
    [[ -f "$calls_log" ]] || { printf '0\n'; return 0; }
    awk -v needle="$needle" '
        BEGIN { RS = "\n}\n{"; count = 0 }
        {
            body = $0
            if (NR > 1) { body = "{" body }
            if (index(body, "\"query\": \"mutation ") > 0 \
                && index(body, needle) > 0) { count++ }
        }
        END { print count }
    ' "$calls_log"
}

# drift_e2e::setup_specs_on_main
#   Two spec dirs committed to `main`; the working tree STAYS on `main`
#   (no feature-branch checkout). Under the pre-spec-003 FR-025 gate this
#   was the exact dogfood failure: every spec read-only-skipped because no
#   worktree matched the NNN-feature branch. After the T324 gate removal
#   the reconcile MUST write every spec from main with ZERO flags.
drift_e2e::setup_specs_on_main() {
    SANDBOX_REPO="${BATS_TEST_TMPDIR}/repo"
    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    MOCK_LINEAR_STATE="${BATS_TEST_TMPDIR}/mock-linear-state"
    LINEAR_CONFIG_PATH="${SANDBOX_REPO}/.specify/extensions/linear/linear-config.yml"

    mkdir -p "$SANDBOX_REPO" "$MOCK_BIN" "$MOCK_LINEAR_STATE"
    mkdir -p "${SANDBOX_REPO}/.specify/extensions/linear" "${SANDBOX_REPO}/specs"
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

    cp -R "${FIXTURES_ROOT}/001-minimal"  "${SANDBOX_REPO}/specs/001-minimal"
    cp -R "${FIXTURES_ROOT}/004-already-merged" "${SANDBOX_REPO}/specs/004-already-merged"
    git -C "$SANDBOX_REPO" add specs/
    git -C "$SANDBOX_REPO" commit --quiet -m 'mount two specs'

    # CRITICAL: we DO NOT check out any NNN-feature branch — we stay on
    # main. is_authoritative_for_spec returns false for both specs.

    integration::_write_config_yaml > "$LINEAR_CONFIG_PATH"
    cat > "${SANDBOX_REPO}/.env" <<'ENV'
LINEAR_API_KEY=lin_api_integration_fake
ENV

    # Locate queries → zero nodes (CREATE path); drift fetch → empty
    # (absent Issue → fired=0, no warning). Mutations succeed.
    integration::stage_response 'query-LocateSpecIssue' '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'query-LocateTaskPhase'  '{"data":{"issues":{"nodes":[]}}}'
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":{"blocks":{"nodes":[]}},"comments":{"nodes":[]},"workflowStates":{"nodes":[]}}}'
    integration::stage_response 'mutation' \
        '{"data":{"issueCreate":{"success":true,"issue":{"id":"11111111-1111-4111-1111-111111111111","identifier":"ACM-1","title":"created","state":{"id":"cccccccc-0001-4ccc-cccc-cccccccccccc"}}},"issueUpdate":{"success":true,"issue":{"id":"22222222-2222-4222-2222-222222222222","identifier":"ACM-2","title":"updated","state":{"id":"cccccccc-0001-4ccc-cccc-cccccccccccc"}}}}}'
    integration::stage_response 'default' '{"data":{}}'

    integration::_install_curl_shim
    integration::install_gh_shim_no_pr
    export PATH="${MOCK_BIN}:${PATH}"
}

# =============================================================================
# User Story 1 — write-from-main now SUCCEEDS (the FR-025 gate removal proof)
#
# This is the load-bearing, RUNNABLE proof of T324: the same setup that the
# pre-spec-003 us5 scenario-2 regression-pinned as "skips every spec, zero
# mutations" now WRITES every spec with no flags. It is the SC-014 mechanism.
# =============================================================================
@test "drift-e2e US1: write-from-main writes every spec with zero flags (FR-025 gate removed)" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main

    # Precondition: on main, NOT on any NNN-feature branch.
    local current_branch
    current_branch="$(git -C "$SANDBOX_REPO" rev-parse --abbrev-ref HEAD)"
    [ "$current_branch" = "main" ]

    # NO --retroactive, NO --on-drift — bare --all from main.
    run integration::run_reconcile --all
    # Tolerate 0 or 1: the mock's empty workflowStates response trips the
    # FR-002 Project Status soft-warn AFTER the per-spec writes land (same
    # rationale as us5/retroactive.bats).
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # ---- the proof: every spec triggered a mutation from main ----
    local spec001 spec004
    spec001="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    spec004="$(drift_e2e::count_mutations_containing 'speckit-spec:004')"
    [ "$spec001" -ge 1 ]
    [ "$spec004" -ge 1 ]

    # ---- and NO read-only-skip / non-authoritative row appears ----
    [[ "$output" != *"non-authoritative"* ]]
    [[ "$output" != *"read-only mode"* ]]
}

@test "drift-e2e US1: write-from-main with no drift emits no backward-drift warning (SC-017)" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main

    run integration::run_reconcile --all
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # Absent Linear Issue (locate → zero nodes) means nothing to be ahead
    # of → fired=0 → the write proceeds SILENTLY (no WARNING row).
    [[ "$output" != *"backward-drift"* ]]
}

# =============================================================================
# User Story 1 — write the post-merge view of a merged spec from `main`
# =============================================================================

# T320 — US1 merged-spec-from-`main` end-to-end (SC-014 + Acceptance Scenario 1)
@test "drift-e2e US1: merged spec reconciles to Merged from main with zero flags" {
    integration::skip_unless_enabled
    skip "T320 placeholder — live body lands with the dogfood harness (Phase 6 / T352)"

    # Live body (T352) will:
    #   * mount a merged spec fixture, delete its NNN-feature branch, stay on main
    #   * stage Linear at a state strictly BEHIND disk-inferred `merged` (A15:
    #     spec_issue_merged_behind.json shape — Linear behind, so fired=0)
    #   * run integration::run_reconcile  (NO flags, NO --retroactive)
    #   * assert the spec Issue moves to Merged with its phase:* label cleared
    #     (FR-013), the write is recorded in the summary, and ZERO backward-
    #     drift warning row appears (Linear was behind, not ahead — SC-014).
    #   The pre-spec-003 gate would have read-only-skipped this from main; the
    #   FR-025 gate removal (T324) is what makes the write succeed.
}

# T321 — US1 idempotent re-run (SC-022 + FR-063 + Acceptance Scenario 2)
@test "drift-e2e US1: a second reconcile from main is idempotent (zero churn)" {
    integration::skip_unless_enabled
    skip "T321 placeholder — live body lands with the dogfood harness (Phase 6 / T352)"

    # Live body (T352) will:
    #   * run the T320 flow twice from main
    #   * assert the SECOND run produces zero label-modified timestamps, zero
    #     comment posts, zero relation rewrites (SC-022 / FR-063) — the drift
    #     check is read-only and the fired=0 write path is the v0.1.0 converge
    #     logic, so an unchanged spec yields zero observable mutation.
}

# T322 — US1 disk-ahead forward write (SC-017 + Acceptance Scenario 3)
@test "drift-e2e US1: disk-ahead spec writes the advance from main with no warning" {
    integration::skip_unless_enabled
    skip "T322 placeholder — live body lands with the dogfood harness (Phase 6 / T352)"

    # Live body (T352) will:
    #   * mount a spec whose disk state is `implementing` while Linear is
    #     `planning` (forward — disk ahead of Linear), on main
    #   * run integration::run_reconcile  (NO flags)
    #   * assert the advance is WRITTEN (state + phase:implementing label) and
    #     NO drift warning row appears — forward movement is the normal write
    #     case and MUST be silent (SC-017, the zero-false-positive guarantee).
}

# =============================================================================
# Phase 4 (US2) — retroactive first-reconcile + --retroactive parity
# =============================================================================

# T331 — US2 retroactive first-reconcile end-to-end (SC-015 + FR-062 + AS1)
@test "drift-e2e US2: retroactive first-reconcile converges 100% with zero flags" {
    integration::skip_unless_enabled
    skip "T331 placeholder — live body lands with the dogfood harness (Phase 6 / T352)"

    # Live body (T352) will:
    #   * mount a fresh repo with several specs (a mix of merged + in-flight),
    #     no feature-branch worktree, EMPTY Linear (no pre-existing Issues)
    #   * run integration::run_reconcile  (NO flags, NO --retroactive)
    #   * assert 100% of enumerated specs are created/updated to match disk,
    #     NO spec skipped for write-authority reasons (the FR-025 gate is gone),
    #     and NO spurious backward-drift warning fires — every spec's Linear
    #     Issue is absent, so compute_drift returns fired=0 (SC-015 / FR-062).
}

# T332 — US2 --retroactive parity (SC-021 + Acceptance Scenario 2)
@test "drift-e2e US2: --retroactive runs identically + emits exactly one INFO row" {
    integration::skip_unless_enabled
    skip "T332 placeholder — live body lands with the dogfood harness (Phase 6 / T352)"

    # Live body (T352) will:
    #   * run the T331 flow a second time WITH --retroactive
    #   * assert convergence is byte-identical to the no-flag run (no-op alias)
    #   * assert EXACTLY ONE INFO deprecation row appears in the summary,
    #     regardless of how many specs are processed (drift-warning-surface §6).
}

# =============================================================================
# Phase 5 (US3) — multi-worktree interactive abort/proceed + --on-drift=abort
# =============================================================================

# T341 — US3 multi-worktree interactive abort/proceed (SC-018 + SC-020 + AS1-3)
@test "drift-e2e US3: multi-worktree interactive abort leaves Linear unchanged; proceed overwrites" {
    integration::skip_unless_enabled
    skip "T341 placeholder — live body lands with the dogfood harness (Phase 6 / T352)"

    # Live body (T352) will:
    #   * set up TWO worktrees on one repo: one on `main` (behind), one on
    #     NNN-feature (ahead — spec advanced to implementing), with Linear
    #     reflecting the feature branch's advanced phase
    #   * run integration::run_reconcile from main with a /dev/tty stand-in
    #     (RECONCILE_DRIFT_TTY) driving the prompt:
    #       - ABORT answer  → assert ZERO Linear mutation for the drifted spec
    #         (zero label timestamps, zero comments, zero relations — SC-018),
    #         the WARNING row names BOTH worktree paths + the canonical
    #         most-recent-commit holder (SC-020 / FR-058), and the spec is
    #         recorded skipped-by-operator.
    #       - PROCEED answer → assert Linear is overwritten from main's disk
    #         view and the override is recorded in the summary (AS3).
}

# T342 — US3 --on-drift=abort non-interactive skip (SC-019 + Acceptance Scenario 4)
@test "drift-e2e US3: --on-drift=abort non-interactively skips the drifted spec with no prompt" {
    integration::skip_unless_enabled
    skip "T342 placeholder — live body lands with the dogfood harness (Phase 6 / T352)"

    # Live body (T352) will:
    #   * use the same two-worktree setup as T341, run from main NON-interactively
    #     (no TTY) with --on-drift=abort
    #   * assert the drifted spec is skipped with a WARNING row + skip note,
    #     NO prompt fires (SC-019 — never hangs), and ZERO Linear mutation lands
    #     for that spec (FR-057).
}
