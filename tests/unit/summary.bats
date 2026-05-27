#!/usr/bin/env bats
# =============================================================================
# tests/unit/summary.bats — unit coverage for src/summary.sh
#
# Covers Principle VIII's observable-failure contract: every reconcile MUST
# end with a structured summary whose counts, warning list, error semantics,
# and tty-gated colour behaviour all match the spec (FR-023, FR-024).
#
# The tests source the module directly into the bats shell. Each test is
# self-contained — we always call summary::start at the top to reset the
# module's module-level state, so test order does not matter.
#
# Conventions:
#   * SUMMARY_SH is set once via setup_file() to the absolute path of the
#     module under test. Tests source it from there.
#   * Colour assertions probe for the bare ANSI prefix `\033[` (i.e. ESC + `[`)
#     rather than a specific code — robust against palette tweaks while still
#     proving "yes there are escape codes" vs "no there aren't".
#   * Stderr is captured via bats' standard `run` redirection trick
#     (`2>&1 1>/dev/null` inside a subshell), because summary::emit writes to
#     stderr (per Principle VIII) and `run` captures stdout by default.
# =============================================================================

setup_file() {
    # Resolve the module path once, relative to this test file's directory.
    # BATS_TEST_DIRNAME is set by bats-core to the dir containing the .bats.
    SUMMARY_SH="${BATS_TEST_DIRNAME}/../../src/summary.sh"
    export SUMMARY_SH
}

setup() {
    # Source the module fresh in every test's shell. bats runs each test in
    # its own subshell, so module-level state is naturally isolated, but we
    # still call summary::start at the top of every test to be explicit.
    # shellcheck disable=SC1090
    source "$SUMMARY_SH"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# emit_to_tty_simulated — runs summary::emit with stderr connected to a
# pseudo-tty so [ -t 2 ] returns true and colour codes are emitted. macOS and
# Linux both ship `script(1)` but with different argument shapes, and bats CI
# runs on ubuntu-latest, so we use the Linux form. For local macOS dev runs
# the colour-on test will skip gracefully if `script -q -c` is unavailable.
emit_with_tty_stderr() {
    # We want a TTY on FD 2. Easiest portable trick: run the whole pipeline
    # under `script` so its child believes it has a terminal, then redirect
    # stdout to /dev/null so only stderr-from-the-child reaches us.
    #
    # `script` writes to FD 1 (the captured "tty"), so we run our function
    # with its stderr swapped TO stdout (`2>&1 1>/dev/null`) inside the
    # scripted shell. The outer `script` then routes that combined stream to
    # the tty it controls, which is what we then capture.
    if ! command -v script >/dev/null 2>&1; then
        skip "script(1) not available — cannot simulate tty on FD 2"
    fi
    # Ubuntu's util-linux script: `script -q -c "<cmd>" /dev/null`.
    # macOS BSD script:           `script -q /dev/null <cmd> [args...]`.
    # We try Linux form first and fall back to skip on macOS to avoid a
    # noisy false negative in dev — CI is the binding signal.
    local out
    if out=$(script -q -c "bash -c 'source \"$SUMMARY_SH\"; summary::start; for i in 1 2 3; do summary::add created \"c\$i\"; done; for i in 1 2; do summary::add warned \"w\$i\"; done; summary::emit 2>&1 1>/dev/null'" /dev/null 2>&1); then
        printf '%s' "$out"
        return 0
    fi
    skip "script(1) form differs on this platform — colour-on test is CI-bound"
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

@test "summary::start then 3 created + 2 warned then emit produces correct counts" {
    summary::start "test header"
    summary::add created "spec 001"
    summary::add created "spec 002"
    summary::add created "spec 003"
    summary::add warned "malformed dep on line 47"
    summary::add warned "rate-limit headroom low"

    # Capture stderr only — emit writes there per Principle VIII.
    run bash -c "source '$SUMMARY_SH'
                 summary::start 'test header'
                 summary::add created 'spec 001'
                 summary::add created 'spec 002'
                 summary::add created 'spec 003'
                 summary::add warned 'malformed dep on line 47'
                 summary::add warned 'rate-limit headroom low'
                 summary::emit 2>&1 1>/dev/null"
    [ "$status" -eq 0 ]
    # Header block boundaries are part of the contract — assert both.
    [[ "$output" == *"===== speckit.linear summary ====="* ]]
    [[ "$output" == *"=================================="* ]]
    # Optional title is rendered on its own line.
    [[ "$output" == *"test header"* ]]
    # Counter line 1.
    [[ "$output" == *"Created:"* ]]
    [[ "$output" == *"Updated:"* ]]
    [[ "$output" == *"Archived:"* ]]
    # The numeric values land on the same line as their labels (per the spec
    # sample), so a substring like "Created: 3" pinpoints both.
    [[ "$output" == *"Created:"*"3"* ]]
    [[ "$output" == *"Warned:"*"2"* ]]
    [[ "$output" == *"Errors:"*"0"* ]]
}

@test "summary::has_errors returns 1 with no errors recorded" {
    summary::start
    summary::add created "no errors here"
    summary::add updated "still no errors"

    # has_errors returns 0 on errors-present, 1 on errors-absent.
    # bats' `run` puts the exit code in $status.
    run summary::has_errors
    [ "$status" -eq 1 ]
}

@test "summary::has_errors returns 0 after one error is added" {
    summary::start
    summary::add error "linear API returned 500"

    run summary::has_errors
    [ "$status" -eq 0 ]
}

@test "summary::emit suppresses ANSI escapes when stderr is not a tty" {
    # In the bats shell, stderr is captured (redirected) — not a tty — so
    # summary::_supports_colour MUST return false and the output MUST contain
    # no ANSI escape sequences.
    run bash -c "source '$SUMMARY_SH'
                 summary::start
                 summary::add created 'one'
                 summary::add warned 'two'
                 summary::emit 2>&1 1>/dev/null"
    [ "$status" -eq 0 ]
    # Probe for the bare ESC[ prefix that begins every ANSI sequence. If we
    # find any, colour leaked through despite the non-tty stderr.
    [[ "$output" != *$'\033['* ]]
}

@test "summary::emit emits ANSI escapes when stderr IS a tty" {
    out=$(emit_with_tty_stderr)
    # If emit_with_tty_simulated could not synthesise a tty (e.g. on a dev
    # workstation that lacks the Linux form of script(1)), the helper calls
    # `skip` so we never reach this point with a useless `out`.
    [[ "$out" == *$'\033['* ]]
    # Sanity: the structural block markers should still be present.
    [[ "$out" == *"===== speckit.linear summary ====="* ]]
    [[ "$out" == *"=================================="* ]]
}

@test "warning messages appear in the warnings section in order added" {
    run bash -c "source '$SUMMARY_SH'
                 summary::start
                 summary::add warned 'first warning'
                 summary::add warned 'second warning'
                 summary::add warned 'third warning'
                 summary::emit 2>&1 1>/dev/null"
    [ "$status" -eq 0 ]
    # The warnings section header must precede the bulleted entries.
    [[ "$output" == *"----- warnings -----"* ]]
    [[ "$output" == *"- first warning"* ]]
    [[ "$output" == *"- second warning"* ]]
    [[ "$output" == *"- third warning"* ]]

    # Ordering check: locate each substring's byte offset within $output and
    # assert monotonically increasing positions. Doing this via parameter
    # expansion keeps the test pure bash, no `awk`/`grep -n` dependency.
    local before_first="${output%%first warning*}"
    local before_second="${output%%second warning*}"
    local before_third="${output%%third warning*}"
    [ "${#before_first}" -lt "${#before_second}" ]
    [ "${#before_second}" -lt "${#before_third}" ]
}

@test "summary::count created returns 3 after three created events" {
    summary::start
    summary::add created "spec 001"
    summary::add created "spec 002"
    summary::add created "spec 003"

    # summary::count writes to stdout (not stderr) — bats captures stdout by
    # default, so a plain `run` works here.
    run summary::count created
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "summary::count returns 0 for an unknown type" {
    # Defensive contract: unknown type queries are safe and return 0 rather
    # than failing with an unbound-variable error.
    summary::start
    run summary::count made_up_type
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "summary::add with unknown type records a warning rather than crashing" {
    # Principle VIII: surface, don't enforce. Mis-typed event types should be
    # loud (counted as a warning) but never abort the reconcile.
    summary::start
    summary::add not_a_real_type "oops"
    run summary::count warned
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "summary::emit on a clean run omits the warnings section entirely" {
    # FR-023 sample shows the warnings block only when there are warnings.
    # A zero-warning reconcile should not print the `----- warnings -----`
    # divider at all — keeps the no-issues case maximally scannable.
    run bash -c "source '$SUMMARY_SH'
                 summary::start
                 summary::add created 'a'
                 summary::add updated 'b'
                 summary::emit 2>&1 1>/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"----- warnings -----"* ]]
}
