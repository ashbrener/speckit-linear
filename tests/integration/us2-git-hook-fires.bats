#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us2-git-hook-fires.bats — T036
#
# User Story 2 (P1) — local git triggers (spec.md FR-033):
#
#   GIVEN the bridge is installed in a sandbox repo (so `.git/hooks/`
#         carries the three local-git hooks per FR-033, with
#         post-checkout's placeholder `__SPECKIT_LINEAR_ROOT__`
#         resolved to PROJECT_ROOT by the install step), and the repo
#         has a second worktree currently on `main`,
#   WHEN  the second worktree switches to the spec's feature branch
#         (`git checkout 002-multi-phase`),
#   THEN  the post-checkout hook fires `src/reconcile.sh --spec 002`
#         exactly once and the reconciler issues at least one Linear
#         mutation referencing `speckit-spec:002`. Exit 0.
#
# Maps to FR-033 ("install local git hooks; invoke the same reconcile
# operation that spec-kit's after_* hooks invoke") + Principle II
# (reconcile, never event-push).
#
# Mock strategy: reuses the curl-shim from us1-* tests. The post-checkout
# template detaches reconcile with `& disown` (so the git checkout
# returns instantly); we wait briefly for the backgrounded reconciler
# to complete before reading the call log. SPECKIT_LINEAR_DOGFOOD_SAFE
# is set to "true" (the template's default opt-in) so the hook actually
# executes.
# =============================================================================

load '../helpers/integration-helpers'

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '002-multi-phase'
    integration::install_gh_shim_no_pr

    # Install the bridge so .git/hooks/post-checkout is populated and
    # its __SPECKIT_LINEAR_ROOT__ placeholder is rewritten to the
    # bridge's PROJECT_ROOT (per T043).
    run integration::run_install \
        --auto-create \
        --team "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa" \
        --no-action \
        --no-prompt

    # Reset call counters so the assertion run is measured against
    # only the hook-driven reconcile invocation.
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # ---- canned Linear responses for the reconcile pass ----
    integration::stage_response 'query-LocateSpecIssue' \
        '{"data":{"issues":{"nodes":[]}}}'

    integration::stage_response 'query-LocateTaskPhase' \
        '{"data":{"issues":{"nodes":[]}}}'

    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":{"blocks":{"nodes":[]}},"comments":{"nodes":[]}}}'

    integration::stage_response 'mutation' \
        '{"data":{"issueCreate":{"success":true,"issue":{"id":"11111111-1111-4111-1111-111111111111","identifier":"ACM-1","title":"created"}}}}'

    integration::stage_response 'default' '{"data":{}}'
}

@test "T036: post-checkout hook fires reconciler when switching to feature branch" {
    # ---- precondition: install populated .git/hooks/post-checkout ----
    local hook="${SANDBOX_REPO}/.git/hooks/post-checkout"
    [ -x "$hook" ]

    # The install step MUST have rewritten the placeholder to the
    # bridge's checkout. Without this rewrite the hook would no-op
    # at the `[[ -x "$RECONCILER" ]] || exit 0` guard.
    grep -q "${PROJECT_ROOT}/src/reconcile.sh" "$hook"
    ! grep -q '__SPECKIT_LINEAR_ROOT__' "$hook"

    # ---- set up a second worktree currently on `main` ----
    # setup_sandbox left us on branch `002-multi-phase`; switch the
    # primary worktree to main so the secondary worktree can hold
    # `002-multi-phase` exclusively. (`git worktree add` refuses to
    # share a branch.)
    git -C "$SANDBOX_REPO" checkout --quiet main
    integration::add_worktree '002-multi-phase'
    # SANDBOX_WORKTREE_002_MULTI_PHASE now points at the new worktree.

    # The freshly-created worktree was checked out at branch
    # `002-multi-phase`; that checkout ALREADY fired the post-checkout
    # hook via `git worktree add` (git invokes post-checkout in the
    # new worktree). Reset the log so the assertion-run measures a
    # deterministic single checkout.
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # ---- trigger a fresh `git checkout` in the secondary worktree ----
    # Switching from a branch to itself is a no-op, so we bounce
    # via main and back to drive the post-checkout invocation.
    git -C "${SANDBOX_WORKTREE_002_MULTI_PHASE}" checkout --quiet -B helper-branch
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # Now the load-bearing checkout: switch back to the feature branch.
    # This is the operator-visible action whose hook firing we assert on.
    SPECKIT_LINEAR_DOGFOOD_SAFE=true \
        git -C "${SANDBOX_WORKTREE_002_MULTI_PHASE}" checkout --quiet '002-multi-phase'

    # ---- wait for the backgrounded reconcile to land ----
    # post-checkout detaches via `& disown`; the curl shim's calls
    # append to MOCK_LINEAR_STATE/calls.log atomically. Poll for up
    # to ~10 seconds for the first call to land.
    local waited=0
    while [ "$waited" -lt 20 ]; do
        if [ -s "${MOCK_LINEAR_STATE}/calls.log" ]; then
            break
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    # Wait an extra moment for the reconcile to finish its mutation
    # batch (CREATE for spec + sub-issues).
    sleep 1

    # ---- the reconciler actually ran ----
    local queries mutations
    queries="$(integration::query_count)"
    mutations="$(integration::mutation_count)"
    [ "$queries" -ge 1 ]
    [ "$mutations" -ge 1 ]

    # ---- the reconcile was scoped to spec 002 (the new branch) ----
    # FR-004b: the spec Issue's identity label MUST appear in at least
    # one mutation body. This proves both:
    #   * the hook parsed `002-multi-phase` → feature number `002`
    #   * the hook actually shelled out to reconcile.sh with --spec 002
    local spec_label_calls
    spec_label_calls="$(integration::calls_containing 'speckit-spec:002')"
    [ "$spec_label_calls" -ge 1 ]

    # ---- the reconciler fired AT MOST ONCE per checkout ----
    # If the hook (or its dispatcher) re-entered itself, we'd see a
    # multiplied spec-Issue create. Count distinct title-creation
    # mutations and confirm just one reconcile pass happened.
    local title_plain title_escaped
    title_plain="$(integration::calls_containing '"title":"002-multi-phase"')"
    title_escaped="$(integration::calls_containing 'title\":\"002-multi-phase')"
    [ "$(( title_plain + title_escaped ))" -le 2 ]
}
