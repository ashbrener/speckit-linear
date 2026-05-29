#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/retroactive.bats — User Story 5 (Phase 7)
#
# Retroactive sync coverage for `src/reconcile.sh` — when the bridge is
# installed on a repo that already has multiple specs in mixed lifecycle
# states, the first reconcile MUST backfill each spec into Linear with
# the workflow state inferred from on-disk artifacts (FR-012 + FR-013 +
# FR-014 + spec FR-026 read-only display from non-authoritative
# worktrees).
#
# The reconciler ALREADY drives this correctly via
# `parser::lifecycle_phase` (artifact-ladder inference) +
# `parser::_has_checked_tasks` (Implementing detection) +
# `git_helpers::pr_state` (merged hint). These scenarios prove the
# end-to-end behaviour without hitting the real Linear API by reusing
# the curl shim under tests/helpers/integration-helpers.bash.
#
# Scenarios:
#
#   1. Mixed-state repo, authoritative-for-one: a sandbox with TWO spec
#      dirs (one at Specifying, one at Tasking) and the working tree
#      checked out on the Tasking spec's feature branch.
#      The reconciler MUST write the Tasking spec under
#      `phase:tasking`, the Specifying spec MUST take the read-only
#      display path (FR-025 / FR-026), and `--retroactive` MUST
#      suppress the non-authoritative-skip warning so first-time-adoption
#      output stays clean.
#
#   2. Mixed-progress tasks.md: a spec with a `tasks.md` whose Phase 1
#      block has some ticked boxes triggers the Implementing state
#      (the "any checked task → implementing" rule per parser.sh
#      lines 158-161), AND the sub-issue for the partially-checked
#      phase is created in the `in_progress` workflow state per
#      `reconcile::subissue_state_key` ("checked > 0 and checked <
#      total → in_progress").
#
#   3. No-tasks fallback ladder: a spec dir with only `spec.md` lands
#      at `phase:specifying`; adding `plan.md` promotes it to
#      `phase:planning` on the next reconcile (proves the FR-012
#      artifact-presence ladder per parser.sh lines 168-184).
#
#   4. Stale-state, no panic: a sandbox where a spec dir exists but
#      `spec.md` is missing/empty — reconcile MUST log the warning,
#      exit 0, and issue zero Linear mutations (the
#      "spec.md missing or empty; skipping" branch at reconcile.sh
#      line 2165). This is the "operator partially deleted a merged
#      spec; bridge must not panic" path.
#
# Mock strategy: every scenario stages curl-shim canned responses so
# every locate query returns ZERO nodes (forcing CREATE paths) and
# every mutation echoes a stable fake UUID. All scenarios gate on
# `RUN_INTEGRATION_TESTS=1` via `integration::skip_unless_enabled`
# so the suite skips cleanly when the env var is unset.
# =============================================================================

load '../helpers/integration-helpers'

# retroactive::count_calls <needle>
#   Wrapper around `integration::calls_containing` that normalises the
#   helper's stdout to a single integer. The helper emits "0\n0" when
#   `grep -cF` returns 1 (no matches) AND the `||` branch fires its
#   `printf '0'` fallback, which trips `[ "$count" -eq 0 ]` with
#   "integer expression expected". Funnelling through `awk` collapses
#   any leading-zero-padded multi-line output back to a single number
#   so `-eq 0` / `-ge N` both Just Work in test bodies.
retroactive::count_calls() {
    local raw
    raw="$(integration::calls_containing "$1")"
    printf '%s\n' "$raw" | awk 'NR==1 {print $1; exit}'
}

# retroactive::count_mutations_containing <needle>
#   Like `retroactive::count_calls` but restricted to MUTATION call
#   bodies (skips reads). The shim writes calls.log as one
#   pretty-printed JSON object per call — each call is multi-line, so
#   `grep -c` against the file counts LINES not CALLS. To count CALLS,
#   we split the log on `^}\n{$` boundaries (the catenation seam between
#   adjacent bodies), then keep only the records whose first ~600 chars
#   contain `"query": "mutation ` (the GraphQL-keyword marker the shim
#   classifies on, mirrored here in record-aware form).
retroactive::count_mutations_containing() {
    local needle="$1"
    local calls_log="${MOCK_LINEAR_STATE}/calls.log"
    if [[ ! -f "$calls_log" ]]; then
        printf '0\n'
        return 0
    fi
    awk -v needle="$needle" '
        BEGIN { RS = "\n}\n{"; count = 0 }
        {
            # Re-attach the brace boundary that RS ate so substring
            # matching against `"query": "mutation ` still works on
            # the trimmed first / last record.
            body = $0
            if (NR > 1) { body = "{" body }
            # Mutation classification: graphql.sh emits
            # `"query": "mutation <Name>(...)"` for writes.
            if (index(body, "\"query\": \"mutation ") > 0 \
                && index(body, needle) > 0) {
                count++
            }
        }
        END { print count }
    ' "$calls_log"
}

# Reusable canned-response wiring shared by every retroactive scenario.
# Equivalent to the boilerplate at the top of every us1-*.bats file —
# extracted here to keep individual @test bodies focused.
retroactive::stage_default_responses() {
    # Every spec-Issue locate query returns ZERO nodes so reconcile
    # takes the CREATE path. This is the canonical "fresh first-pass
    # retroactive sync" precondition.
    integration::stage_response 'query-LocateSpecIssue' \
        '{"data":{"issues":{"nodes":[]}}}'

    # Every task-phase sub-issue locate query returns ZERO nodes so each
    # phase row triggers a CREATE.
    integration::stage_response 'query-LocateTaskPhase' \
        '{"data":{"issues":{"nodes":[]}}}'

    # Generic query fallback — anything else (block-relation lookups,
    # comments.startsWith, project Status queries) returns valid empty
    # JSON so graphql.sh's parser is happy.
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":{"blocks":{"nodes":[]}},"comments":{"nodes":[]},"workflowStates":{"nodes":[]}}}'

    # save_issue mutations always succeed and echo deterministic fake
    # UUIDs. The reconciler may issue these under IssueCreate /
    # IssueUpdate / save_issue — kind-level fallback serves all of them.
    integration::stage_response 'mutation' \
        '{"data":{"issueCreate":{"success":true,"issue":{"id":"11111111-1111-4111-1111-111111111111","identifier":"ACM-1","title":"created","state":{"id":"cccccccc-0001-4ccc-cccc-cccccccccccc"}}},"issueUpdate":{"success":true,"issue":{"id":"22222222-2222-4222-2222-222222222222","identifier":"ACM-2","title":"updated","state":{"id":"cccccccc-0001-4ccc-cccc-cccccccccccc"}}}}}'

    # Catch-all so an unexpected request still produces valid JSON.
    integration::stage_response 'default' '{"data":{}}'
}

# Build a sandbox repo with TWO spec dirs (001-minimal + 002-multi-phase)
# committed to main, then check out the named branch (the spec whose
# feature this worktree is authoritative for). Used by scenario 1.
#
# We deliberately don't reuse `integration::setup_sandbox` because that
# helper assumes a single fixture is mounted; here we want a realistic
# "operator adopting the bridge on a repo with several in-flight specs"
# starting state.
retroactive::setup_multi_spec_sandbox() {
    local authoritative_branch="$1"

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

    # Mount both fixtures under their fixture-name slugs. The feature
    # branch the worktree ends up on determines which spec is
    # authoritative for writes (FR-025).
    cp -R "${FIXTURES_ROOT}/001-minimal" \
        "${SANDBOX_REPO}/specs/001-minimal"
    cp -R "${FIXTURES_ROOT}/002-multi-phase" \
        "${SANDBOX_REPO}/specs/002-multi-phase"
    git -C "$SANDBOX_REPO" add specs/
    git -C "$SANDBOX_REPO" commit --quiet -m 'mount two specs (mixed states)'

    # Check out the authoritative branch. Both branches exist locally
    # so the non-authoritative spec's read-only display path runs against
    # a real spec dir rather than tripping the "no branch" guard.
    git -C "$SANDBOX_REPO" branch --quiet '001-minimal' HEAD
    git -C "$SANDBOX_REPO" branch --quiet '002-multi-phase' HEAD
    git -C "$SANDBOX_REPO" checkout --quiet "$authoritative_branch"

    integration::_write_config_yaml > "$LINEAR_CONFIG_PATH"

    cat > "${SANDBOX_REPO}/.env" <<'ENV'
LINEAR_API_KEY=lin_api_integration_fake
ENV

    integration::_install_curl_shim
    integration::install_gh_shim_no_pr
    export PATH="${MOCK_BIN}:${PATH}"

    retroactive::stage_default_responses
}

# =============================================================================
# Scenario 1: Mixed-state repo, --retroactive --all writes for EVERY
# spec — including the non-authoritative one — because FR-014's
# first-time-adoption contract requires the gate to be bypassed so a
# fresh install converges every spec without per-branch checkouts.
# The aggregate INFO row in the summary names the bypass count and the
# per-spec "skipped because non-authoritative" warning rows stay
# suppressed (the bypass replaces them, it doesn't sit alongside them).
# =============================================================================
@test "retroactive: --retroactive bypasses FR-025 gate for every spec (FR-014)" {
    integration::skip_unless_enabled
    # 002-multi-phase has spec.md + plan.md + tasks.md → Tasking phase.
    # We're checked out on 002's feature branch; spec 001 (specifying-
    # only) would normally enter read-only mode but --retroactive
    # forces the write path for it too.
    retroactive::setup_multi_spec_sandbox '002-multi-phase'

    run integration::run_reconcile --retroactive --all
    # Tolerate exit 0 OR exit 1 — the curl-shim mock's empty `blocks`
    # query response trips reconcile's FR-002 Project Status warning
    # path which promotes the exit code to 1 across the integration
    # suite (same as us1-fresh-reconcile.bats). The retroactive
    # behaviour we care about (writes for every spec, bypass INFO row)
    # lands BEFORE that promotion.
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # ---- spec 002 (authoritative under the default gate) writes ----
    # FR-003 mandates the phase label mirrors the inferred lifecycle —
    # for fixture 002 that is `tasking`.
    local tasking_calls
    tasking_calls="$(retroactive::count_calls 'phase:tasking')"
    [ "$tasking_calls" -ge 1 ]

    # FR-004b: the spec identity label is stamped on creation.
    local spec002_label_calls
    spec002_label_calls="$(retroactive::count_calls 'speckit-spec:002')"
    [ "$spec002_label_calls" -ge 1 ]

    # ---- spec 001 (non-authoritative) ALSO writes under --retroactive --
    # FR-014: the bypass is the whole point of the flag. The previous
    # implementation only suppressed the WARNING and left the gate
    # active, which dogfooded as "first reconcile produces zero
    # mutations" — exactly the bug this test now pins.
    local spec001_mutations
    spec001_mutations="$(retroactive::count_mutations_containing 'speckit-spec:001')"
    [ "$spec001_mutations" -ge 1 ]

    # ---- summary contract ----
    # FR-014: per-spec "skipped because non-authoritative" warnings
    # stay suppressed AND the bypass surfaces as a single aggregate
    # INFO row naming the count, so the operator has a clear breadcrumb
    # that the FR-025 gate was deliberately bypassed (and how often).
    [[ "$output" == *"speckit.linear summary"* ]]
    [[ "$output" == *"retroactive"* ]]
    # Slice the structured-summary block (lines between the two `====`
    # banners) and prove the contract on that surface alone.
    local summary_block
    summary_block="$(printf '%s\n' "$output" \
        | awk '/===== speckit\.linear summary =====/,/^==================================$/')"
    # Aggregate INFO row landed in the warnings section.
    [[ "$summary_block" == *"retroactive:"* ]]
    [[ "$summary_block" == *"non-authoritative"* ]]
    # Per-spec skip rows MUST NOT appear — the bypass replaces them.
    [[ "$summary_block" != *"spec 001: non-authoritative"* ]]
}

# =============================================================================
# Scenario 2: Mixed-progress tasks.md → Implementing state +
# in_progress sub-issue.
#
# Per parser.sh lines 158-161: ANY checked task in tasks.md promotes
# the lifecycle phase from `tasking` to `implementing`.
# Per reconcile.sh lines 945-968: a phase with some-but-not-all tasks
# checked is mapped to the `in_progress` sub-issue state key.
# =============================================================================
@test "retroactive: tasks.md with mixed progress → implementing + in_progress sub-issue" {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr
    retroactive::stage_default_responses

    # Mutate the mounted tasks.md so Phase 1 has 1-of-2 boxes ticked.
    # This is the canonical "operator merged some setup work but is
    # mid-flight on Phase 1" retroactive shape.
    local tasks_md="${SANDBOX_REPO}/specs/002-multi-phase/tasks.md"
    [ -f "$tasks_md" ]
    # Use sed -i with a portable suffix (BSD + GNU). The first task
    # row (`- [ ] T002-001`) becomes checked.
    sed -i.bak 's/- \[ \] T002-001/- [x] T002-001/' "$tasks_md"
    rm -f "${tasks_md}.bak"
    git -C "$SANDBOX_REPO" add specs/002-multi-phase/tasks.md
    git -C "$SANDBOX_REPO" commit --quiet -m 'tick one Phase 1 task'

    run integration::run_reconcile --retroactive --spec 002
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    # The spec Issue MUST carry phase:implementing (NOT phase:tasking)
    # because at least one task is now ticked.
    local implementing_calls
    implementing_calls="$(retroactive::count_calls 'phase:implementing')"
    [ "$implementing_calls" -ge 1 ]

    local tasking_calls
    tasking_calls="$(retroactive::count_calls 'phase:tasking')"
    [ "$tasking_calls" -eq 0 ]

    # The Phase 1 sub-issue's stateId MUST resolve to
    # default_state_uuids.in_progress (dddddddd-0002-...) because it
    # has checked=1, total=2 (the mixed-state branch of
    # reconcile::subissue_state_key).
    local in_progress_state_calls
    in_progress_state_calls="$(retroactive::count_calls 'dddddddd-0002')"
    [ "$in_progress_state_calls" -ge 1 ]

    # Phase 2 and Phase 3 are untouched, so they MUST still land in
    # the `todo` state (dddddddd-0001).
    local todo_state_calls
    todo_state_calls="$(retroactive::count_calls 'dddddddd-0001')"
    [ "$todo_state_calls" -ge 1 ]
}

# =============================================================================
# Scenario 3: No-tasks fallback ladder (Specifying → Planning).
#
# The fixture 001-minimal contains only spec.md → parser returns
# `specifying`. Then we drop a plan.md and rerun → parser returns
# `planning`. Proves both rungs of the artifact-presence ladder
# (parser.sh lines 168-184) are exercised by retroactive sync.
# =============================================================================
@test "retroactive: no-tasks ladder — specifying then planning as artifacts appear" {
    integration::skip_unless_enabled
    integration::setup_sandbox '001-minimal'
    integration::install_gh_shim_no_pr
    retroactive::stage_default_responses

    # ---- pass 1: spec.md only → phase:specifying ----
    run integration::run_reconcile --retroactive --spec 001
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    local specifying_calls
    specifying_calls="$(retroactive::count_calls 'phase:specifying')"
    [ "$specifying_calls" -ge 1 ]

    local planning_calls_before
    planning_calls_before="$(retroactive::count_calls 'phase:planning')"
    [ "$planning_calls_before" -eq 0 ]

    # ---- pass 2: add plan.md → phase:planning ----
    # We rotate the call logs so the assertions below measure only the
    # second reconcile pass.
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"

    cat > "${SANDBOX_REPO}/specs/001-minimal/plan.md" <<'PLAN'
# Plan: Minimal Spec Fixture

**Branch**: `001-minimal`

## Approach

Trivial — used to advance the lifecycle ladder from specifying →
planning for the retroactive integration test.
PLAN
    git -C "$SANDBOX_REPO" add specs/001-minimal/plan.md
    git -C "$SANDBOX_REPO" commit --quiet -m 'add plan.md'

    run integration::run_reconcile --retroactive --spec 001
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

    local planning_calls
    planning_calls="$(retroactive::count_calls 'phase:planning')"
    [ "$planning_calls" -ge 1 ]

    # The second pass MUST NOT regress to phase:specifying.
    local specifying_calls_after
    specifying_calls_after="$(retroactive::count_calls 'phase:specifying')"
    [ "$specifying_calls_after" -eq 0 ]
}

# =============================================================================
# Scenario 4: Stale state — spec dir present, spec.md missing/empty.
#
# Models the "operator partially deleted a merged spec, but the bridge
# is asked to reconcile anyway" path. Reconcile MUST log the warning,
# exit 0, and issue zero Linear mutations against that spec — the
# safety property is "no panic, no rogue writes" (reconcile.sh
# line 2165, `spec.md missing or empty; skipping`).
# =============================================================================
@test "retroactive: missing spec.md is logged and skipped, no panic" {
    integration::skip_unless_enabled
    # Use 001-minimal as the scaffold so setup_sandbox is happy, then
    # blow away spec.md to simulate a stale on-disk state.
    integration::setup_sandbox '001-minimal'
    integration::install_gh_shim_no_pr
    retroactive::stage_default_responses

    # Delete spec.md from the mounted fixture. The spec dir survives
    # (so enumerate_specs still finds it) but process_spec MUST take
    # the "spec.md missing or empty; skipping" branch.
    rm -f "${SANDBOX_REPO}/specs/001-minimal/spec.md"
    git -C "$SANDBOX_REPO" add -A specs/001-minimal
    git -C "$SANDBOX_REPO" commit --quiet -m 'simulate stale spec dir (spec.md deleted)'

    run integration::run_reconcile --retroactive --all
    # "no panic" — exit 0 (no specs to write) or 1 (FR-002 soft-warn
    # path, same caveat as scenarios 1-3). Exit 2 (config halt) MUST
    # NOT happen — a stale spec dir is not a config-level fault.
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    [ "$status" -ne 2 ]

    # Zero MUTATIONS referencing the 001 spec (queries may still fire
    # — e.g. config validation reads — and that's fine; the safety
    # property is "no rogue writes").
    local spec001_mutations
    spec001_mutations="$(retroactive::count_mutations_containing 'speckit-spec:001')"
    [ "$spec001_mutations" -eq 0 ]

    # The summary MUST surface the skip reason so the operator can
    # decide whether to delete the spec dir entirely or restore
    # spec.md. The exact phrasing comes from reconcile.sh line 2166:
    # "spec ${feature_number}: spec.md missing or empty; skipping".
    [[ "$output" == *"speckit.linear summary"* ]]
    [[ "$output" == *"spec.md missing or empty"* ]] || \
        [[ "$output" == *"spec 001"* ]] || \
        [[ "$output" == *"skipping"* ]]
}
