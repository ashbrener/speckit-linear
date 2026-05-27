#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/summary.sh — structured summary emitter (Principle VIII)
#
# Every reconcile invocation MUST end with a structured, named-warning summary
# (constitution v1.0.0 Principle VIII; spec FR-023, FR-024). This module owns
# that contract. It is sourced — never executed — by:
#
#   * src/reconcile.sh    — the main reconciler (Layer D)
#   * src/install.sh      — install ceremony
#   * src/seed.sh         — workspace seed
#   * tests/unit/summary.bats — unit coverage
#
# Public API (all functions are namespaced `summary::*`):
#
#   summary::start [<title>]
#       Initialise module-level counters and the warning/message buffer.
#       Optional <title> is printed at the top of the emitted block (e.g. the
#       caller may pass "speckit.linear reconcile — repo: foo, branch: 001-…").
#       Safe to call multiple times in the same process; each call resets state.
#
#   summary::add <type> <message>
#       Record an event. <type> MUST be one of:
#         created | updated | archived | warned | skipped | error
#       Always increments the per-type counter. For warned / skipped / error
#       the <message> is also appended to the warning/message buffer rendered
#       in the `----- warnings -----` section of the emitted block. created /
#       updated / archived messages are counter-only; their text is discarded
#       to keep the summary block scannable (the structured count is the
#       contract, not per-event lines).
#
#   summary::emit
#       Print the final structured block to stderr (per Principle VIII Rule 1
#       and spec FR-023 — the summary is operator-facing observability, not
#       data piped to a downstream consumer; stdout stays clean for any future
#       script that pipes reconcile output). ANSI colour is applied to counter
#       LABELS only when stderr is a tty (`[ -t 2 ]`). No colour when stderr
#       is redirected to a file or another process.
#
#   summary::has_errors
#       Returns 0 (true) if any `error` events were recorded since the last
#       `summary::start`; returns 1 (false) otherwise. Use as the exit-status
#       hook for callers that want a non-zero exit on any error event.
#
#   summary::count <type>
#       Echoes the current count for <type>. Unknown types echo 0.
#
# Design notes:
#
#   * Bash 4+ associative arrays back the counters; the project's install step
#     already refuses macOS bash 3.2 (per plan.md Technical Context), so we
#     can rely on this without a fallback.
#   * No global state outside the `_SUMMARY_*` prefix — keeps this module safe
#     to source repeatedly without polluting the caller's namespace.
#   * Colour codes use `printf '\033[...m'` directly rather than `tput`. tput
#     requires a working TERM entry and is noisier under bats; raw escapes are
#     fine for the narrow `green / yellow / red` palette we need.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Module-private state. All names share the `_SUMMARY_` prefix so the caller
# can `set +u` / `set -u` around us without colliding on unset reads.
# -----------------------------------------------------------------------------

# Counter map, keyed by event type. Re-initialised by summary::start.
declare -gA _SUMMARY_COUNTS=()

# Ordered list of warning/skipped/error messages, in insertion order. Rendered
# under `----- warnings -----` by summary::emit.
declare -ga _SUMMARY_WARNINGS=()

# Optional header line printed at the top of the emitted block.
declare -g _SUMMARY_TITLE=""

# Sentinel set by summary::start so summary::emit can detect "called without a
# prior start" and still produce a valid (zero-everything) block rather than
# crashing on unbound-variable access.
declare -g _SUMMARY_INITIALISED="false"

# -----------------------------------------------------------------------------
# summary::_supports_colour
#   Internal: returns 0 if stderr is a tty AND NO_COLOR is unset / empty.
#   Honours the de-facto `NO_COLOR` convention (https://no-color.org/) so an
#   operator who explicitly opts out of colour gets monochrome even on a tty.
# -----------------------------------------------------------------------------
summary::_supports_colour() {
    # `[ -t 2 ]` is the canonical "stderr is a terminal" probe. If stderr is
    # redirected (e.g. `reconcile 2> log.txt` or `reconcile 2>&1 | tee`), this
    # returns 1 and we emit plain text — colour codes in a log file are noise.
    if [[ -n "${NO_COLOR:-}" ]]; then
        return 1
    fi
    if [[ -t 2 ]]; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# summary::_colour <ansi-code> <text>
#   Internal: wraps <text> in the given ANSI sequence iff colour is supported.
#   <ansi-code> is the numeric part (e.g. 32 for green); the function adds the
#   ESC[...m prefix and the ESC[0m reset.
# -----------------------------------------------------------------------------
summary::_colour() {
    local code="$1"
    local text="$2"
    if summary::_supports_colour; then
        printf '\033[%sm%s\033[0m' "$code" "$text"
    else
        printf '%s' "$text"
    fi
}

# -----------------------------------------------------------------------------
# summary::start [<title>]
# -----------------------------------------------------------------------------
summary::start() {
    # Reset every counter explicitly rather than `unset` + redeclare, so the
    # module remains usable across multiple start/emit cycles in one process
    # (e.g. a long-running test runner).
    _SUMMARY_COUNTS=(
        [created]=0
        [updated]=0
        [archived]=0
        [warned]=0
        [skipped]=0
        [error]=0
    )
    _SUMMARY_WARNINGS=()
    _SUMMARY_TITLE="${1:-}"
    _SUMMARY_INITIALISED="true"
}

# -----------------------------------------------------------------------------
# summary::add <type> <message>
# -----------------------------------------------------------------------------
summary::add() {
    local type="${1:-}"
    local message="${2:-}"

    # Lazy-init so callers that forgot summary::start still get a coherent
    # block; emit a warning event to surface the misuse rather than failing
    # silently (Principle VIII — observable failure).
    if [[ "$_SUMMARY_INITIALISED" != "true" ]]; then
        summary::start
        _SUMMARY_WARNINGS+=("summary::add called before summary::start; auto-initialised")
        _SUMMARY_COUNTS[warned]=$(( ${_SUMMARY_COUNTS[warned]:-0} + 1 ))
    fi

    case "$type" in
        created|updated|archived|warned|skipped|error)
            _SUMMARY_COUNTS[$type]=$(( ${_SUMMARY_COUNTS[$type]:-0} + 1 ))
            ;;
        *)
            # Unknown type — treat as a warning event so it is loud rather
            # than silently dropped. Principle VIII: surface, don't enforce.
            _SUMMARY_COUNTS[warned]=$(( ${_SUMMARY_COUNTS[warned]:-0} + 1 ))
            _SUMMARY_WARNINGS+=("summary::add called with unknown type '$type': $message")
            return 0
            ;;
    esac

    # Only warned / skipped / error events contribute to the warnings list.
    # Counter-only types (created/updated/archived) discard the message — the
    # summary block is meant to be a scannable digest, not a transcript.
    case "$type" in
        warned|skipped|error)
            _SUMMARY_WARNINGS+=("$message")
            ;;
    esac
}

# -----------------------------------------------------------------------------
# summary::count <type>
# -----------------------------------------------------------------------------
summary::count() {
    local type="${1:-}"
    printf '%s\n' "${_SUMMARY_COUNTS[$type]:-0}"
}

# -----------------------------------------------------------------------------
# summary::has_errors
#   Returns 0 if at least one error was recorded, 1 otherwise. The shape
#   matches bash's "true if test passes" convention so the caller can write:
#       if summary::has_errors; then exit 1; fi
# -----------------------------------------------------------------------------
summary::has_errors() {
    local count="${_SUMMARY_COUNTS[error]:-0}"
    if (( count > 0 )); then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# summary::emit
#   Print the structured block to stderr. Format is locked by the spec sample
#   (see specs/001-spec-kit-linear-bridge/spec.md FR-023 commentary):
#
#       ===== speckit.linear summary =====
#       <optional title line>
#       Created: 3   Updated: 12   Archived: 1
#       Skipped: 0   Warned: 2     Errors: 0
#       ----- warnings -----
#       - <message 1>
#       - <message 2>
#       ==================================
#
#   The warnings section is omitted entirely when no warning/skipped/error
#   messages were recorded — a clean reconcile prints just the counters.
# -----------------------------------------------------------------------------
summary::emit() {
    # Defensive: tolerate emit-without-start by lazily initialising. The
    # output will be the zero-everything block, which is the right thing to
    # show if a caller threaded summary::emit through an early-return path.
    if [[ "$_SUMMARY_INITIALISED" != "true" ]]; then
        summary::start
    fi

    local created="${_SUMMARY_COUNTS[created]:-0}"
    local updated="${_SUMMARY_COUNTS[updated]:-0}"
    local archived="${_SUMMARY_COUNTS[archived]:-0}"
    local skipped="${_SUMMARY_COUNTS[skipped]:-0}"
    local warned="${_SUMMARY_COUNTS[warned]:-0}"
    local errors="${_SUMMARY_COUNTS[error]:-0}"

    # Colour palette (Principle VIII counter coding):
    #   green  (32) — created / updated  — positive progress
    #   yellow (33) — warned / skipped   — operator attention warranted
    #   red    (31) — errors             — something failed
    # archived stays uncoloured: it's a neutral cleanup event, not progress
    # or trouble, and colouring it would dilute the signal of the other two.
    local lbl_created lbl_updated lbl_archived
    local lbl_skipped lbl_warned lbl_errors
    lbl_created=$(summary::_colour 32 "Created:")
    lbl_updated=$(summary::_colour 32 "Updated:")
    lbl_archived="Archived:"
    lbl_skipped=$(summary::_colour 33 "Skipped:")
    lbl_warned=$(summary::_colour 33 "Warned:")
    lbl_errors=$(summary::_colour 31 "Errors:")

    {
        printf '===== speckit.linear summary =====\n'
        if [[ -n "$_SUMMARY_TITLE" ]]; then
            printf '%s\n' "$_SUMMARY_TITLE"
        fi
        # Two counter rows. Spacing matches the spec sample so a grep on
        # "Created:" or "Errors:" finds exactly one line per reconcile.
        printf '%s %s   %s %s   %s %s\n' \
            "$lbl_created" "$created" \
            "$lbl_updated" "$updated" \
            "$lbl_archived" "$archived"
        printf '%s %s   %s %s     %s %s\n' \
            "$lbl_skipped" "$skipped" \
            "$lbl_warned" "$warned" \
            "$lbl_errors" "$errors"

        if (( ${#_SUMMARY_WARNINGS[@]} > 0 )); then
            printf -- '----- warnings -----\n'
            local msg
            for msg in "${_SUMMARY_WARNINGS[@]}"; do
                printf -- '- %s\n' "$msg"
            done
        fi
        printf '==================================\n'
    } >&2
}
