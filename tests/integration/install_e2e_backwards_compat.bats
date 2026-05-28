#!/usr/bin/env bats
# shellcheck shell=bats
#
# tests/integration/install_e2e_backwards_compat.bats — spec 002 US2
# end-to-end backwards-compatibility regression suite (SC-011).
#
# Gating: `RUN_INTEGRATION_TESTS=1` AND a valid `LINEAR_API_KEY` (with
# both `LINEAR_TEST_TEAM_UUID` and `LINEAR_TEST_PROJECT_UUID` pointing
# at a non-destructive sandbox project in the live OSH-INFRA test
# workspace). Without these, every `@test` block early-skips so CI
# matrix rows without secrets stay GREEN.
#
# Scope per tasks.md A11: ONE bats file, multiple `@test` blocks
# covering install-flags.md §5 backwards-compat table rows 1–4 + 8.
# Each row asserts that v0.1.0 CI invocations continue to install
# bit-for-bit identically in v0.1.1 (FR-044 + FR-045 + SC-011).
#
# =============================================================================
# Row coverage (install-flags.md §5):
#
#   T241 — Row 1 — `--team <UUID> --project <UUID>`
#                  (interactive default; discovery flow short-circuits
#                   at S3 + S4 via FR-044 fast path).
#
#   T242 — Row 2 — `--team <UUID> --project <UUID> --non-interactive`
#                  (canonical CI path; zero prompts fire).
#
#   T243 — Row 3+4 — `--team <UUID> --auto-create [--non-interactive]`
#                    (deprecated-but-functional auto-create path).
#
#   T244 — Row 8 — `--non-interactive` (no UUID flags) → HALT exit 2
#                  with verbatim FR-045 message from install-flags.md
#                  §3.3.
#
# =============================================================================
# Phase 4 status: TESTS LAND BEFORE IMPLEMENTATION (T248..T251). The
# row-8 strict-rule test (T244) will FAIL until T249 lands the
# tightened parse_args validation; tests T241..T243 may PASS today
# because the discovery-flow dispatcher already routes flag-driven
# invocations to the legacy v0.1.0 code path (per tasks.md A14).
# Documented in the tests-first discipline preamble.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
    export PROJECT_ROOT

    TEST_TMP="${BATS_TEST_TMPDIR}/work"
    mkdir -p "$TEST_TMP"
    cd "$TEST_TMP" || exit 1

    # Each test runs in an ephemeral sandbox consumer repo so the live
    # install drops `linear-config.yml` somewhere we can inspect + then
    # discard at teardown via bats-core's BATS_TEST_TMPDIR cleanup.
    git init --quiet "$TEST_TMP" >/dev/null
    git -C "$TEST_TMP" commit --quiet --allow-empty -m "bootstrap" >/dev/null
}

teardown() {
    :
}

# ---------------------------------------------------------------------------
# _require_integration_env
#
# Skip the current `@test` unless the integration environment is fully
# wired:
#   * RUN_INTEGRATION_TESTS=1
#   * LINEAR_API_KEY non-empty (a key with access to the test workspace)
#   * LINEAR_TEST_TEAM_UUID non-empty (test workspace's Team UUID)
#   * LINEAR_TEST_PROJECT_UUID non-empty (a sandbox project under the
#     test team that the install can attach to non-destructively)
# ---------------------------------------------------------------------------
_require_integration_env() {
    if [[ "${RUN_INTEGRATION_TESTS:-0}" != "1" ]]; then
        skip "RUN_INTEGRATION_TESTS != 1 — gated integration test"
    fi
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        skip "LINEAR_API_KEY missing — integration test requires a live key"
    fi
    if [[ -z "${LINEAR_TEST_TEAM_UUID:-}" ]]; then
        skip "LINEAR_TEST_TEAM_UUID missing — sandbox team UUID required for SC-011 row"
    fi
    if [[ -z "${LINEAR_TEST_PROJECT_UUID:-}" ]]; then
        skip "LINEAR_TEST_PROJECT_UUID missing — sandbox project UUID required for SC-011 row"
    fi
}

# ---------------------------------------------------------------------------
# T241 — Row 1: `--team <UUID> --project <UUID>` (interactive default).
#
# v0.1.0 behavior: install completes without prompts when both UUIDs
# are present. v0.1.1 (per FR-044 fast path + tasks.md A14) MUST
# produce the same outcome: a `linear-config.yml` that round-trips the
# passed UUIDs verbatim and a zero exit code.
# ---------------------------------------------------------------------------

@test "T241: row 1 — --team + --project installs bit-for-bit (SC-011 canonical)" {
    _require_integration_env

    run bash -c "
        cd '${TEST_TMP}'
        bash '${PROJECT_ROOT}/src/install.sh' \
            --dev \
            --team '${LINEAR_TEST_TEAM_UUID}' \
            --project '${LINEAR_TEST_PROJECT_UUID}' \
            --no-action </dev/null
    "
    [ "$status" -eq 0 ]

    # linear-config.yml MUST land at the expected path and MUST mirror
    # the passed UUIDs (bit-for-bit identical write per FR-044).
    local cfg="${TEST_TMP}/.specify/extensions/linear/linear-config.yml"
    [ -f "$cfg" ]
    grep -q "${LINEAR_TEST_TEAM_UUID}" "$cfg"
    grep -q "${LINEAR_TEST_PROJECT_UUID}" "$cfg"
}

# ---------------------------------------------------------------------------
# T242 — Row 2: `--team + --project + --non-interactive` (canonical CI).
#
# Asserts (a) the install completes with stdin closed (no prompts can
# fire) and (b) the resulting config matches the passed UUIDs. This is
# the canonical CI install pattern v0.1.0 ships and the SC-011 anchor.
# ---------------------------------------------------------------------------

@test "T242: row 2 — --team + --project + --non-interactive halts before any prompt" {
    _require_integration_env

    # Pipe /dev/null to stdin so any latent read prompt would block
    # forever (test would time out). Successful completion proves zero
    # prompts fire under FR-044 + FR-045.
    run bash -c "
        cd '${TEST_TMP}'
        bash '${PROJECT_ROOT}/src/install.sh' \
            --dev \
            --team '${LINEAR_TEST_TEAM_UUID}' \
            --project '${LINEAR_TEST_PROJECT_UUID}' \
            --non-interactive \
            --no-action </dev/null
    "
    [ "$status" -eq 0 ]

    local cfg="${TEST_TMP}/.specify/extensions/linear/linear-config.yml"
    [ -f "$cfg" ]
    grep -q "${LINEAR_TEST_TEAM_UUID}" "$cfg"
    grep -q "${LINEAR_TEST_PROJECT_UUID}" "$cfg"
}

# ---------------------------------------------------------------------------
# T243 — Row 3+4: `--team + --auto-create [--non-interactive]`.
#
# v0.1.0's `--auto-create` flag fires the same `projectCreate` mutation
# the new discovery flow's "Create new project" branch uses (named
# after the consumer repo's basename). install-flags.md §2 commits to
# bit-for-bit preservation in v0.1.1; the flag is deprecated but
# load-bearing for scripted installs.
#
# Two `@test` blocks: one for the interactive variant (row 3 — soft
# deprecation notice fires) and one for the non-interactive variant
# (row 4 — no deprecation notice; canonical CI auto-create path).
# ---------------------------------------------------------------------------

@test "T243: row 3 — --team + --auto-create fires projectCreate + soft-deprecation notice" {
    _require_integration_env

    run bash -c "
        cd '${TEST_TMP}'
        bash '${PROJECT_ROOT}/src/install.sh' \
            --dev \
            --team '${LINEAR_TEST_TEAM_UUID}' \
            --auto-create \
            --no-action </dev/null 2>&1
    "
    [ "$status" -eq 0 ]
    # install-flags.md §2 — soft deprecation notice fires only in
    # interactive mode (no --non-interactive).
    [[ "$output" == *"--auto-create is deprecated"* ]]

    local cfg="${TEST_TMP}/.specify/extensions/linear/linear-config.yml"
    [ -f "$cfg" ]
    grep -q "${LINEAR_TEST_TEAM_UUID}" "$cfg"
    # Auto-created project named after the sandbox basename (TEST_TMP's
    # parent dir name, which bats-core derives from BATS_TEST_TMPDIR).
    grep -q "project:" "$cfg"
}

@test "T243: row 4 — --team + --auto-create + --non-interactive emits NO deprecation" {
    _require_integration_env

    run bash -c "
        cd '${TEST_TMP}'
        bash '${PROJECT_ROOT}/src/install.sh' \
            --dev \
            --team '${LINEAR_TEST_TEAM_UUID}' \
            --auto-create \
            --non-interactive \
            --no-action </dev/null 2>&1
    "
    [ "$status" -eq 0 ]
    # install-flags.md §2 — deprecation notice SUPPRESSED under
    # --non-interactive (the flag is load-bearing for CI).
    [[ ! "$output" == *"--auto-create is deprecated"* ]]

    local cfg="${TEST_TMP}/.specify/extensions/linear/linear-config.yml"
    [ -f "$cfg" ]
    grep -q "${LINEAR_TEST_TEAM_UUID}" "$cfg"
}

# ---------------------------------------------------------------------------
# T244 — Row 8: `--non-interactive` with no UUID flags → HALT exit 2.
#
# FR-045 tightens the v0.1.0 rule: --non-interactive without
# sufficient UUIDs MUST halt with the verbatim message from
# install-flags.md §3.3. v0.1.0 already halted in this case (its rule
# required --team); v0.1.1 updates the message text to point at the
# new interactive ergonomics path.
#
# This test does NOT need live Linear access (the halt fires at
# parse_args time, before any network call). It only needs the
# `--non-interactive` flag + no UUIDs; we drop the RUN_INTEGRATION_TESTS
# requirement for this row alone so the strict-rule regression is
# always gated in CI.
# ---------------------------------------------------------------------------

@test "T244: row 8 — --non-interactive alone halts exit 2 with verbatim FR-045 message" {
    # No _require_integration_env: this test exercises parse_args's
    # strict-rule check, which fires BEFORE any GraphQL round trip.
    # Always-on regression — protects FR-045 unconditionally.

    run bash -c "
        cd '${TEST_TMP}'
        bash '${PROJECT_ROOT}/src/install.sh' \
            --non-interactive \
            --no-action </dev/null 2>&1
    "
    [ "$status" -eq 2 ]
    # install-flags.md §3.3 — verbatim message anchor strings. We
    # assert the load-bearing phrases (not the full block) so cosmetic
    # whitespace drift doesn't flake the test. The v0.1.1 message
    # tightens the v0.1.0 phrasing to "requires both --team <UUID>
    # and --project <UUID>" — both versions contain "--non-interactive
    # requires" so this anchor is stable across the FR-045 tightening.
    [[ "$output" == *"--non-interactive requires"* ]]
    [[ "$output" == *"--team"* ]]
    # The v0.1.1 message MUST mention --project (per FR-045 §3.3
    # verbatim text). v0.1.0's message did NOT — so this assertion
    # SHOULD FAIL until T249 lands the tightened parse_args error
    # string. Tests-first discipline: this is an expected RED test.
    [[ "$output" == *"--project"* ]]
}

@test "T244: row 8 — --non-interactive halt fires before any filesystem write" {
    # Confirm the FR-045 halt is parse-time, not run-time: no
    # `.specify/extensions/linear/` tree gets created on the halt
    # path. Matches data-model.md §4 "quit before S6" invariant.

    run bash -c "
        cd '${TEST_TMP}'
        bash '${PROJECT_ROOT}/src/install.sh' \
            --non-interactive \
            --no-action </dev/null
    "
    [ "$status" -eq 2 ]
    [ ! -f "${TEST_TMP}/.specify/extensions/linear/linear-config.yml" ]
}
