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
#
# The drift round-trip is staged through the SEPARATE `query-LocateDriftIssue`
# response key that reconcile::_fetch_drift_issue_json consumes (distinct from
# `query-LocateSpecIssue`, the find-or-create lookup). compute_drift fires
# phase_drift only when ordinal(linear) > ordinal(disk); recency only
# CORROBORATES, never fires alone. The drift-issue JSON shape compute_drift
# reads is:
#   {"id":..,"updatedAt":"<iso>","state":{"type":..},
#    "labels":{"nodes":[{"name":"speckit-spec:NNN"},{"name":"phase:<token>"}]}}
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

# drift_e2e::_stage_drift_issue <feature_number> <phase_token> <updated_iso> [state_type]
#   Stage a `query-LocateDriftIssue` response carrying ONE spec Issue with the
#   given phase:* label + updatedAt + workflow state.type, scoped to the
#   speckit-spec:NNN label. This is the SEPARATE query reconcile's drift check
#   issues (see reconcile::_fetch_drift_issue_json). When phase ordinal >
#   disk ordinal, compute_drift fires phase_drift.
drift_e2e::_stage_drift_issue() {
    local feature_number="$1" phase_token="$2" updated_iso="$3"
    local state_type="${4:-started}"
    integration::stage_response 'query-LocateDriftIssue' \
        "$(printf '{"data":{"issues":{"nodes":[{"id":"99999999-9999-4999-9999-999999999999","updatedAt":"%s","state":{"type":"%s"},"labels":{"nodes":[{"name":"speckit-spec:%s"},{"name":"phase:%s"}]}}]}}}' \
            "$updated_iso" "$state_type" "$feature_number" "$phase_token")"
}

# drift_e2e::_stage_drift_absent
#   Stage a `query-LocateDriftIssue` response with zero nodes — genuinely
#   absent Issue, compute_drift returns fired=0 (US2 first reconcile).
drift_e2e::_stage_drift_absent() {
    integration::stage_response 'query-LocateDriftIssue' '{"data":{"issues":{"nodes":[]}}}'
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
    drift_e2e::setup_specs_on_main

    # 004-already-merged carries spec.md + plan.md + tasks.md + analyze-*.md;
    # WITHOUT a PR hint the artifact ladder infers `analyzing`. We present its
    # feature branch's PR as MERGED via the gh shim so reconcile::pr_state_hint
    # resolves `merged` and parser::lifecycle_phase short-circuits to `merged`
    # (FR-013/FR-014). The merged workflow-state UUID in config is
    # cccccccc-0009-4ccc-cccc-cccccccccccc.
    integration::install_gh_shim_merged

    # Linear is strictly BEHIND disk-inferred `merged` (phase:implementing,
    # ordinal 4 < merged ordinal 6) → fired=0, so NO backward-drift row and
    # the write proceeds (SC-014: Linear behind, not ahead).
    drift_e2e::_stage_drift_issue '004' 'implementing' '2026-05-26T09:00:00+00:00'

    run integration::run_reconcile --all
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # The merged spec write must land from main (the FR-025 gate is gone)...
    local spec004
    spec004="$(drift_e2e::count_mutations_containing 'speckit-spec:004')"
    [ "$spec004" -ge 1 ]

    # ...and it must target the MERGED lifecycle state UUID, proving the
    # post-merge view reached Linear (SC-014). The merged state UUID appears
    # in the issue mutation's stateId field.
    local merged_writes
    merged_writes="$(drift_e2e::count_mutations_containing 'cccccccc-0009-4ccc-cccc-cccccccccccc')"
    [ "$merged_writes" -ge 1 ]

    # Linear was behind (not ahead) → zero backward-drift warning (SC-014).
    [[ "$output" != *"backward-drift"* ]]
}

# T321 — US1 idempotent re-run (SC-022 + FR-063 + Acceptance Scenario 2)
#
# The reconciler's idempotency probe (sync_spec_issue update branch) diffs the
# STORED Linear Issue (read via `query GetIssueState`) against the freshly
# computed desired title/description/state/labels and skips the issueUpdate when
# they match. The curl shim is stateless — it cannot persist what the first run
# wrote — so to model the steady-state faithfully we CAPTURE the title +
# description the first reconcile emitted (the issueCreate mutation's input
# variables, logged in calls.log) and REPLAY them as the stored Issue on the
# second run. The git-derived memory-block fields (spec-dir last commit, branch)
# are stable across runs (no new commit), and the live "Last reconciled by" row
# is stripped before diffing (FR-036 co-binding), so a byte-faithful replay
# yields a zero-delta probe — exactly the real Linear round-trip's behaviour.
# Scoped to spec 001 (001-minimal has no tasks.md → no task-phase sub-issues to
# model).
@test "drift-e2e US1: a second reconcile from main is idempotent (zero churn)" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main

    # First reconcile (spec 001 only): locate → zero nodes → CREATE path.
    drift_e2e::_stage_drift_absent
    run integration::run_reconcile --spec 001
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    local first_creates
    first_creates="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    [ "$first_creates" -ge 1 ]

    # Capture the title + description the create wrote (the input variables of
    # the issueCreate mutation), so we can replay the stored Issue verbatim. The
    # curl shim logs each call body as a concatenated JSON object and the
    # GraphQL query string spans physical lines, so we slurp the whole log
    # (`jq -s`) and pick the create rather than grepping a single line.
    local created_desc created_title
    created_desc="$(jq -rs 'map(select((.query // "") | test("IssueUpsertCreate"))) | .[0].variables.input.description' "${MOCK_LINEAR_STATE}/calls.log")"
    created_title="$(jq -rs 'map(select((.query // "") | test("IssueUpsertCreate"))) | .[0].variables.input.title' "${MOCK_LINEAR_STATE}/calls.log")"
    [ -n "$created_desc" ]
    [ "$created_desc" != "null" ]

    # Stage the find-or-create lookup to return the now-existing Issue, and the
    # GetIssueState diff probe to echo back the EXACT stored title/description/
    # state/labels the first run wrote. 001-minimal infers `specifying`, whose
    # workflow-state UUID is cccccccc-0001-...; the label set is the canonical
    # speckit-spec:001 + phase:specifying pair.
    integration::stage_response 'query-LocateSpecIssue' \
        '{"data":{"issues":{"nodes":[{"id":"11111111-1111-4111-1111-111111111111","identifier":"ACM-1","updatedAt":"2026-05-28T00:00:00Z"}]}}}'
    integration::stage_response 'query-GetIssueState' \
        "$(jq -nc \
            --arg title "$created_title" \
            --arg desc "$created_desc" \
            '{data:{issue:{title:$title,description:$desc,state:{id:"cccccccc-0001-4ccc-cccc-cccccccccccc"},labels:{nodes:[{name:"speckit-spec:001"},{name:"phase:specifying"}]},estimate:null}}}')"

    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # Second reconcile: the stored Issue matches the computed desired state, so
    # the diff is empty and NO issueUpdate fires (SC-022 / FR-063).
    #
    # Finding #01: previously this re-run staged the drift fetch as ABSENT
    # (_stage_drift_absent), which makes compute_drift return fired=0 trivially —
    # so the test would have stayed green even under the OLD standalone-recency
    # bug. To genuinely pin the #01 fix (recency CORROBORATES phase drift, never
    # fires alone), we instead stage an EXISTING drift Issue at the SAME phase as
    # disk but with updatedAt FAR newer than the spec-dir commit — the exact
    # shape the old bug mis-fired on. 001-minimal infers `specifying`; we stage
    # Linear at `specifying` too (equal phase ⇒ phase_drift=0) with a 2099
    # updatedAt (the bridge's own prior write would have bumped updatedAt far
    # past the spec-dir commit). Equal phase + much-newer updatedAt MUST yield
    # fired=0: no phase drift to corroborate ⇒ recency stays silent. If the bug
    # regressed, recency would fire alone here → a backward-drift WARNING and a
    # drift-skip, both asserted against below.
    drift_e2e::_stage_drift_issue '001' 'specifying' '2099-01-01T00:00:00+00:00'
    run integration::run_reconcile --spec 001
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # ZERO new mutations on the unchanged-spec re-run — the spec is NOT
    # drift-skipped despite the far-newer Linear updatedAt (equal phase ⇒
    # fired=0). Under the old recency-only bug the spec would have been skipped
    # by the drift gate, also yielding zero mutations, so the no-warning
    # assertion below is what actually distinguishes the fixed behaviour.
    local spec001_second total_second
    spec001_second="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    [ "$spec001_second" -eq 0 ]
    total_second="$(drift_e2e::count_total_mutations)"
    [ "$total_second" -eq 0 ]

    # THE #01 regression pin: equal phase + far-newer updatedAt must fire
    # NOTHING, so NO backward-drift warning surfaces. The old standalone-recency
    # bug fired here; this assertion now fails loudly if it ever returns.
    [[ "$output" != *"backward-drift"* ]]
    # And no spec was skipped by the drift disposition (the write path was
    # reached and found nothing to change — a true no-op, not a drift skip).
    [[ "$output" != *"skipped by operator"* ]]
}

# T322 — US1 disk-ahead forward write (SC-017 + Acceptance Scenario 3)
@test "drift-e2e US1: disk-ahead spec writes the advance from main with no warning" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main

    # 004-already-merged infers `analyzing` from disk (analyze-*.md present),
    # but `analyzing` is NOT on the drift phase ladder (ordinal UNKNOWN), which
    # disables the phase signal. To exercise a clean FORWARD case (disk strictly
    # AHEAD of Linear), use 001-minimal: disk infers `specifying` (ordinal 1).
    # Stage Linear at `clarifying` (ordinal 0) → ordinal(linear) 0 < disk 1, so
    # phase_drift=0 → fired=0 → the advance is written SILENTLY (SC-017).
    drift_e2e::_stage_drift_issue '001' 'clarifying' '2026-05-20T09:00:00+00:00'

    run integration::run_reconcile --all
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # The forward advance is WRITTEN...
    local spec001
    spec001="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    [ "$spec001" -ge 1 ]

    # ...and forward movement is SILENT — no backward-drift row (SC-017, the
    # zero-false-positive guarantee).
    [[ "$output" != *"backward-drift"* ]]
}

# =============================================================================
# Phase 4 (US2) — retroactive first-reconcile + --retroactive parity
# =============================================================================

# T331 — US2 retroactive first-reconcile end-to-end (SC-015 + FR-062 + AS1)
@test "drift-e2e US2: retroactive first-reconcile converges 100% with zero flags" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main

    # EMPTY Linear: both the find-or-create lookup AND the drift fetch return
    # zero nodes (no pre-existing Issues). compute_drift returns fired=0 for
    # every spec (absent Issue → nothing to be ahead of, FR-062).
    drift_e2e::_stage_drift_absent

    # NO flags, NO --retroactive.
    run integration::run_reconcile --all
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # 100% of enumerated specs created/updated to match disk (SC-015).
    local spec001 spec004
    spec001="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    spec004="$(drift_e2e::count_mutations_containing 'speckit-spec:004')"
    [ "$spec001" -ge 1 ]
    [ "$spec004" -ge 1 ]

    # NO spec skipped for write-authority reasons (the FR-025 gate is gone)...
    [[ "$output" != *"non-authoritative"* ]]
    [[ "$output" != *"read-only mode"* ]]
    # ...and NO spurious backward-drift warning (every Issue absent → fired=0).
    [[ "$output" != *"backward-drift"* ]]
}

# T332 — US2 --retroactive parity (SC-021 + Acceptance Scenario 2)
@test "drift-e2e US2: --retroactive runs identically + emits exactly one INFO row" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main
    drift_e2e::_stage_drift_absent

    # Same convergence as the no-flag run, but WITH the deprecated --retroactive
    # alias (FR-061). It is a no-op for write behaviour and emits EXACTLY ONE
    # INFO deprecation row regardless of spec count (drift-warning-surface §6).
    run integration::run_reconcile --all --retroactive
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # Byte-identical convergence: every spec still written.
    local spec001 spec004
    spec001="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    spec004="$(drift_e2e::count_mutations_containing 'speckit-spec:004')"
    [ "$spec001" -ge 1 ]
    [ "$spec004" -ge 1 ]

    # EXACTLY ONE --retroactive deprecation INFO row (a single `INFO  ...`
    # line mentioning --retroactive), regardless of spec count.
    local info_rows
    info_rows="$(printf '%s\n' "$output" | grep -c 'INFO  .*--retroactive')"
    [ "$info_rows" -eq 1 ]
}

# =============================================================================
# Phase 5 (US3) — drift disposition fork (abort/proceed) + --on-drift=abort
# =============================================================================

# T341 — US3 abort/proceed disposition fork (SC-018 + AS3).
#
# Two harness limitations force the design below, both faithfully noted rather
# than papered over:
#
#   1. The INTERACTIVE prompt arm is unreachable under bats. reconcile's
#      disposition fork only reaches reconcile::_drift_prompt (and thus consults
#      the RECONCILE_DRIFT_TTY seam) when `[[ -t 0 ]]` is true — i.e. stdin is a
#      real terminal. `bats` runs each test with a NON-tty stdin, so the fork
#      always takes the non-interactive arm; the RECONCILE_DRIFT_TTY file is
#      never read. Per the task's documented fallback, we model the two operator
#      choices via `--on-drift=abort` / `--on-drift=proceed`, which is the SAME
#      disposition fork (reconcile::_drift_disposition arm 1) the prompt resolves
#      to — the explicit flag and the prompt answer converge on one code path.
#      The prompt's own read/abort-default behaviour is covered by the PURE unit
#      on reconcile::_drift_prompt (tests/unit/drift_disposition.bats).
#
#   2. The multi-worktree FR-058/SC-020 worktree-naming assertion is likewise
#      not expressible here: adding a second linked worktree (`git worktree add`)
#      perturbs the in-process drift fetch under the reconciler's
#      `set -e -o pipefail` so drift stops firing — an interaction at the
#      mock-transport ↔ git-worktree-enumeration boundary, not in the drift
#      logic, that can't be fixed without rebuilding the curl shim or editing
#      src/ (both out of remit). The canonical/touching-set rendering
#      (FR-058/FR-059) is already covered by the PURE unit on
#      reconcile::_drift_worktree_lines / git_helpers::worktrees_touching_spec
#      (tests/unit/drift_detection.bats).
#
# What IS faithfully expressible — the load-bearing SC-018/AS3 contract — is the
# disposition fork on a single drifted spec: ABORT leaves Linear unchanged,
# PROCEED overwrites it.
@test "drift-e2e US3: drift abort leaves Linear unchanged; proceed overwrites" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main

    # Linear ahead of main's disk view for spec 001: disk=`specifying` (ord 1),
    # Linear at `implementing` (ord 4) → phase_drift=1 → fired=1.
    drift_e2e::_stage_drift_issue '001' 'implementing' '2026-05-29T09:00:00+00:00'

    # ---- ARM 1: ABORT (== the prompt's [a]bort answer) ----
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"
    run integration::run_reconcile --all --on-drift=abort
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # The drift fired → WARNING row present, naming the spec (FR-054).
    [[ "$output" == *"spec 001 backward-drift"* ]]
    # Abort disposition → skip note recorded.
    [[ "$output" == *"skipped by operator"* ]]
    # ABORT → zero mutations for the drifted spec (Linear unchanged, SC-018).
    local spec001_aborted
    spec001_aborted="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    [ "$spec001_aborted" -eq 0 ]

    # ---- ARM 2: PROCEED (== the prompt's [p]roceed answer) ----
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"
    run integration::run_reconcile --all --on-drift=proceed
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # The WARNING still surfaces (the audit trail holds regardless, FR-054)...
    [[ "$output" == *"spec 001 backward-drift"* ]]
    # ...and PROCEED → Linear is overwritten from main's disk view (AS3): the
    # spec write lands despite the fired drift.
    local spec001_proceeded
    spec001_proceeded="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    [ "$spec001_proceeded" -ge 1 ]
}

# T342 — US3 --on-drift=abort non-interactive skip (SC-019 + Acceptance Scenario 4)
@test "drift-e2e US3: --on-drift=abort non-interactively skips the drifted spec with no prompt" {
    integration::skip_unless_enabled
    drift_e2e::setup_specs_on_main

    # Drifted spec 001: disk `specifying` (ord 1), Linear `implementing`
    # (ord 4) → fired=1.
    drift_e2e::_stage_drift_issue '001' 'implementing' '2026-05-29T09:00:00+00:00'

    # Non-interactive (bats run has no TTY on fd 0) + --on-drift=abort: the
    # flag wins everywhere, no prompt fires, never hangs (SC-019).
    run integration::run_reconcile --all --on-drift=abort
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # WARNING row present (the audit trail holds on every drift, FR-054)...
    [[ "$output" == *"spec 001 backward-drift"* ]]
    # ...a skip note is recorded...
    [[ "$output" == *"skipped by operator"* ]]
    # ...and ZERO Linear mutation lands for the drifted spec (FR-057).
    local spec001
    spec001="$(drift_e2e::count_mutations_containing 'speckit-spec:001')"
    [ "$spec001" -eq 0 ]

    # The NON-drifted spec 004 still writes (only 001 is ahead in Linear) —
    # one bad spec must not abort the whole --all sweep. 004's drift fetch
    # reuses the staged 001 issue, but the speckit-spec label is filtered by
    # query in production; under the mock the same response is served, so 004
    # sees a phase:implementing issue labelled speckit-spec:001. 004 disk =
    # `analyzing` (ordinal UNKNOWN) → phase signal disabled → fired=0, so 004
    # writes regardless. Assert 004 still reached Linear.
    local spec004
    spec004="$(drift_e2e::count_mutations_containing 'speckit-spec:004')"
    [ "$spec004" -ge 1 ]
}
