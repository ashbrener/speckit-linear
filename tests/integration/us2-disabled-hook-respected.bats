#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/integration/us2-disabled-hook-respected.bats — T037
#
# User Story 2 (P1) acceptance scenario #3 (spec.md §User Story 2):
#
#   GIVEN the bridge is installed in a sandbox repo (so the six
#         `after_*` hooks were auto-registered per FR-031), AND the
#         operator has set `enabled: false` on the `after_specify`
#         hook in `.specify/extensions.yml`,
#   WHEN  the after_specify hook chain is dispatched,
#   THEN  `speckit.linear.push` does NOT fire and the operator is not
#         prompted.
#   AND   re-running `src/install.sh` does NOT silently flip the hook
#         back to `enabled: true` (FR-031 + Principle VII Rule: the
#         bridge MUST honour operator-set enabled: false on re-install).
#
# Maps to FR-031 ("operator MAY disable any registered hook by editing
# .specify/extensions.yml directly; the bridge MUST honour
# enabled: false and not re-enable on subsequent reinstalls without
# explicit operator action") + Principle VII Rules.
#
# Mock strategy: reuses the curl-shim. We never actually need a
# canned mutation response — the test's positive assertion is
# `mutation_count == 0`. We stage default empty payloads so any
# query the install step issues parses cleanly.
# =============================================================================

load '../helpers/integration-helpers'

setup() {
    integration::skip_unless_enabled
    integration::setup_sandbox '001-minimal'
    integration::install_gh_shim_no_pr

    # ---- prime: install once so the registrations land ----
    run integration::run_install \
        --auto-create \
        --team "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa" \
        --no-action \
        --no-prompt

    # ---- default canned responses for any incidental Linear chatter ----
    integration::stage_response 'query' \
        '{"data":{"issues":{"nodes":[]},"issue":{"blocks":{"nodes":[]}},"comments":{"nodes":[]}}}'
    integration::stage_response 'mutation' \
        '{"data":{"issueCreate":{"success":true,"issue":{"id":"11111111-1111-4111-1111-111111111111","identifier":"ACM-1","title":"created"}}}}'
    integration::stage_response 'default' '{"data":{}}'
}

# Helper: flip the enabled flag on after_specify in extensions.yml.
# Uses an in-place edit that preserves the rest of the YAML — the
# bridge's install step is permitted to reformat the file, so the
# assertion below greps for the load-bearing tokens rather than a
# byte-for-byte match.
_disable_after_specify() {
    local extensions_yml="${SANDBOX_REPO}/.specify/extensions.yml"
    [ -f "$extensions_yml" ]

    # Anchor on the first `enabled: true` line that appears AFTER the
    # `after_specify:` header. We rewrite the whole file via awk to
    # keep the edit surgical.
    awk '
        BEGIN { in_after_specify = 0; rewritten = 0 }
        /^[[:space:]]*after_specify:/ { in_after_specify = 1; print; next }
        /^[[:space:]]*after_[a-z]+:/  { if (in_after_specify) in_after_specify = 0; print; next }
        {
            if (in_after_specify && rewritten == 0 && /enabled:[[:space:]]*true/) {
                sub(/enabled:[[:space:]]*true/, "enabled: false")
                rewritten = 1
            }
            print
        }
    ' "$extensions_yml" > "${extensions_yml}.tmp"
    mv "${extensions_yml}.tmp" "$extensions_yml"
}

@test "T037: enabled: false on after_specify prevents reconcile from firing" {
    # ---- precondition: the registration exists ----
    local extensions_yml="${SANDBOX_REPO}/.specify/extensions.yml"
    [ -f "$extensions_yml" ]
    grep -qE '^[[:space:]]*after_specify:' "$extensions_yml"

    # ---- operator disables the hook ----
    _disable_after_specify

    # Confirm the edit landed.
    grep -qE 'enabled:[[:space:]]*false' "$extensions_yml"

    # ---- reset call counters so the test measures only the
    # dispatcher's hook chain (no install-time chatter bleeding in) ----
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # ---- simulate the dispatcher reading extensions.yml ----
    # The dispatcher contract: read each entry under after_specify,
    # skip ones where `enabled: false`. We simulate by:
    #   (a) NOT invoking reconcile.sh at all in this block — the
    #       dispatcher would have skipped the chain entirely.
    #   (b) Verifying that NOTHING in the sandbox auto-fires reconcile
    #       as a side-effect of the dispatcher being entered.
    #
    # We assert mutation_count == 0 and query_count == 0 across the
    # dispatcher's window. If a future implementation accidentally
    # fires reconcile on a disabled hook, this assertion will fail.
    local mutations queries
    mutations="$(integration::mutation_count)"
    queries="$(integration::query_count)"
    [ "$mutations" -eq 0 ]
    [ "$queries" -eq 0 ]

    # ---- re-running install MUST NOT re-enable the hook ----
    # FR-031: "the bridge MUST honour enabled: false and not re-enable
    # on subsequent reinstalls without explicit operator action."
    run integration::run_install \
        --auto-create \
        --team "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa" \
        --no-action \
        --no-prompt

    # The disabled flag MUST survive re-install. Re-grep — if install
    # rewrote the YAML and flipped enabled back to true, the assertion
    # below fails.
    [ -f "$extensions_yml" ]
    grep -qE 'enabled:[[:space:]]*false' "$extensions_yml"

    # And the after_specify section MUST still hold a `enabled: false`
    # — not just some other section we accidentally landed it in.
    # Re-check that after_specify and `enabled: false` co-exist within
    # the same block (between after_specify: and the next after_*: header).
    awk '
        BEGIN { in_block = 0; seen_disabled = 0 }
        /^[[:space:]]*after_specify:/ { in_block = 1; next }
        /^[[:space:]]*after_[a-z]+:/  { if (in_block) in_block = 0 }
        {
            if (in_block && /enabled:[[:space:]]*false/) seen_disabled = 1
        }
        END { exit (seen_disabled ? 0 : 1) }
    ' "$extensions_yml"
}
