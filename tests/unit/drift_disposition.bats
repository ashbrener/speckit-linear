#!/usr/bin/env bats
# =============================================================================
# tests/unit/drift_disposition.bats — spec 003 Phase 2 arg-parse + summary
#
# Covers the Phase-2 arg-parse + summary-plumbing foundation (no write path):
#   * --on-drift=abort|proceed parsing into ARG_ON_DRIFT (T307)
#   * --on-drift bad value → usage error at parse time (T307 / plan A11)
#   * --retroactive deprecation INFO row, exactly once (T308 / FR-061)
#   * summary.sh `info` event type → top-of-summary INFO line (T309)
#
# Disposition WIRING (the prompt, the abort skip, the proceed-and-warn write)
# is US2/US3 (T334/T343/T344) and is NOT exercised here — Phase 2 only lands
# the pure arg-parse + summary primitives.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
RECONCILE_SH="${REPO_ROOT}/src/reconcile.sh"
SUMMARY_SH="${REPO_ROOT}/src/summary.sh"

# Portable hang-guard for the SC-019 / A10 "never hangs" assertions.
#
# GNU coreutils `timeout` is NOT on macOS by default (and `gtimeout` only
# exists with a brew install), so a bare `run timeout 5 …` makes the bats
# (macos-latest) CI job fail with `timeout: command not found`. Prefer the
# real binary when present (Linux CI), otherwise fall back to a bash-native
# watcher that kills the command after N seconds — same time-bound, same
# no-hang intent, no external dependency.
#
# Usage: run _timeout SECONDS cmd args...   (mirrors `timeout SECONDS cmd…`).
if command -v timeout >/dev/null 2>&1; then
  _TIMEOUT_BIN="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
  _TIMEOUT_BIN="$(command -v gtimeout)"
else
  _TIMEOUT_BIN=""
fi

_timeout() {
  local secs="$1"; shift
  if [ -n "$_TIMEOUT_BIN" ]; then
    "$_TIMEOUT_BIN" "$secs" "$@"
    return $?
  fi
  # Bash-native fallback: run the command, kill it if it outlives `secs`.
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  # Stop the watcher (it has either already fired or is still sleeping).
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return "$rc"
}

# Run reconcile::parse_args in an isolated subshell with the given args and
# echo the resolved ARG_ON_DRIFT / ARG_RETROACTIVE. We stop right after
# parse_args so no config load or network fires.
_parse() {
  bash -c '
    set +e
    source "'"$RECONCILE_SH"'" 2>/dev/null
    reconcile::parse_args "$@"
    printf "on_drift=%s retroactive=%s spec=%s all=%s\n" \
      "$ARG_ON_DRIFT" "$ARG_RETROACTIVE" "$ARG_SPEC" "$ARG_ALL"
  ' _ "$@"
}

# -----------------------------------------------------------------------------
# --on-drift parsing (T307 / FR-056 / plan A11)
# -----------------------------------------------------------------------------

@test "--on-drift=abort parses into ARG_ON_DRIFT" {
  run _parse --all --on-drift=abort
  [ "$status" -eq 0 ]
  [[ "$output" == *"on_drift=abort"* ]]
}

@test "--on-drift=proceed parses into ARG_ON_DRIFT" {
  run _parse --all --on-drift=proceed
  [ "$status" -eq 0 ]
  [[ "$output" == *"on_drift=proceed"* ]]
}

@test "--on-drift space-separated form parses" {
  run _parse --all --on-drift abort
  [ "$status" -eq 0 ]
  [[ "$output" == *"on_drift=abort"* ]]
}

@test "--on-drift omitted leaves ARG_ON_DRIFT empty (proceed-and-warn default)" {
  run _parse --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"on_drift= "* ]]
}

@test "--on-drift with an unrecognised value is a usage error at parse time" {
  run _parse --all --on-drift=maybe
  [ "$status" -eq 2 ]
  [[ "$output" == *"--on-drift value must be abort or proceed"* ]]
}

@test "--on-drift with a missing value is a usage error" {
  run _parse --all --on-drift
  [ "$status" -eq 2 ]
  [[ "$output" == *"--on-drift requires a value"* ]]
}

# -----------------------------------------------------------------------------
# --retroactive deprecation (T308 / FR-061)
# -----------------------------------------------------------------------------

@test "--retroactive still parses (deprecated no-op) and implies --all" {
  run _parse --retroactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"retroactive=1"* ]]
  [[ "$output" == *"all=1"* ]]
}

@test "--retroactive sets no disposition global (no behavioral coupling)" {
  run _parse --retroactive
  [ "$status" -eq 0 ]
  # ARG_ON_DRIFT stays empty — --retroactive is purely a deprecation marker.
  [[ "$output" == *"on_drift= "* ]]
}

# -----------------------------------------------------------------------------
# summary.sh `info` event type → top-of-summary INFO line (T309)
# -----------------------------------------------------------------------------

@test "summary: info event renders as a top-of-summary INFO line above counters" {
  run bash -c '
    source "'"$SUMMARY_SH"'"
    summary::start "title-line"
    summary::add info "--retroactive is deprecated and now the default"
    summary::add created "x"
    summary::emit 2>&1 1>/dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO  --retroactive is deprecated and now the default"* ]]
  # The INFO line precedes the Created counter row (top-of-summary placement).
  local info_pos created_pos
  info_pos="$(printf '%s\n' "$output" | grep -n 'INFO ' | head -1 | cut -d: -f1)"
  created_pos="$(printf '%s\n' "$output" | grep -n 'Created:' | head -1 | cut -d: -f1)"
  [ "$info_pos" -lt "$created_pos" ]
}

@test "summary: info increments its own counter, not warned" {
  run bash -c '
    source "'"$SUMMARY_SH"'"
    summary::start ""
    summary::add info "note"
    printf "info=%s warned=%s\n" "$(summary::count info)" "$(summary::count warned)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"info=1 warned=0"* ]]
}

@test "summary: a clean run with no info emits no INFO line" {
  run bash -c '
    source "'"$SUMMARY_SH"'"
    summary::start ""
    summary::add created "x"
    summary::emit 2>&1 1>/dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"INFO "* ]]
}

# =============================================================================
# spec 003 Phase 3 (US1 spine) — drift WARNING emitter + disposition fork
#
#   * reconcile::_drift_verdict_field — verdict-line field parser (T323/T325)
#   * reconcile::_emit_drift_warning  — named WARNING row (T325 / FR-054)
#   * reconcile::_drift_disposition   — disposition fork, Phase 3 default arm
#       + the Phase 4/5 extension point (T326 / data-model §5 / FR-056)
#
# These exercise the pure, network-free pieces of the US1 write-path spine.
# The full write round-trip lands in tests/integration/drift_e2e.bats (T320-
# T322, skip-gated until the live dogfood harness in Phase 6 / T352).
# =============================================================================

# reconcile.sh sources clean (its main() is guarded), so we can pull its pure
# functions + summary.sh into one subshell for these assertions.
_drift_src='source "'"$SUMMARY_SH"'"; source "'"$RECONCILE_SH"'" 2>/dev/null'

# -----------------------------------------------------------------------------
# reconcile::_drift_verdict_field (T323 / A9 verdict parsing)
# -----------------------------------------------------------------------------

@test "_drift_verdict_field: extracts a present field from the verdict line" {
  run bash -c "$_drift_src; reconcile::_drift_verdict_field 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' fired"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "_drift_verdict_field: extracts signals csv intact" {
  run bash -c "$_drift_src; reconcile::_drift_verdict_field 'fired=1 phase_drift=1 recency_drift=1 signals=phase_ordering,recency disk=planning linear=implementing disk_iso=A linear_iso=B skew=120' signals"
  [ "$status" -eq 0 ]
  [ "$output" = "phase_ordering,recency" ]
}

@test "_drift_verdict_field: absent field yields empty" {
  run bash -c "$_drift_src; reconcile::_drift_verdict_field 'fired=0 phase_drift=0 recency_drift=0 signals= disk=planning linear=' disk_iso"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# reconcile::_emit_drift_warning (T325 / FR-054 / drift-warning-surface §2)
# -----------------------------------------------------------------------------

@test "_emit_drift_warning: names spec, disk, linear, signals (phase-only fire)" {
  run bash -c "
    $_drift_src
    summary::start ''
    reconcile::_emit_drift_warning 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing'
    summary::emit 2>&1 1>/dev/null
  "
  [ "$status" -eq 0 ]
  # Renders in the existing FR-024 warnings section (A13 — reuse `warned`).
  [[ "$output" == *"----- warnings -----"* ]]
  [[ "$output" == *"spec 005 backward-drift:"* ]]
  [[ "$output" == *"disk=planning"* ]]
  [[ "$output" == *"linear=implementing"* ]]
  [[ "$output" == *"signals=phase_ordering"* ]]
  # No recency detail line on a phase-only fire.
  [[ "$output" != *"linear updatedAt"* ]]
}

@test "_emit_drift_warning: appends the recency detail line only when recency fired" {
  run bash -c "
    $_drift_src
    summary::start ''
    reconcile::_emit_drift_warning 011 'fired=1 phase_drift=0 recency_drift=1 signals=recency disk=planning linear=planning disk_iso=2026-05-26T09:31:00+00:00 linear_iso=2026-05-26T09:35:00+00:00 skew=120'
    summary::emit 2>&1 1>/dev/null
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"signals=recency"* ]]
  [[ "$output" == *"spec dir last commit 2026-05-26T09:31:00+00:00"* ]]
  [[ "$output" == *"linear updatedAt 2026-05-26T09:35:00+00:00 (> 120s)"* ]]
}

@test "_emit_drift_warning: increments the warned counter (audit trail)" {
  run bash -c "
    $_drift_src
    summary::start ''
    reconcile::_emit_drift_warning 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing'
    printf 'warned=%s\n' \"\$(summary::count warned)\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"warned=1"* ]]
}

# -----------------------------------------------------------------------------
# reconcile::_drift_disposition (T326 / Phase 3 default arm + extension point)
# -----------------------------------------------------------------------------

@test "_drift_disposition: non-interactive default (no flag, no TTY) resolves proceed (proceed-and-warn)" {
  # bats redirects stdin so `[[ -t 0 ]]` is false → non-interactive arm.
  run bash -c "$_drift_src; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

# =============================================================================
# spec 003 Phase 4 (US2) — non-interactive disposition resolution (T329-T335)
#
#   * --on-drift=proceed / unset → proceed-and-warn default (FR-056)
#   * --on-drift=abort → abort (skip the drifted spec) — even on a TTY (FR-056)
#   * --retroactive deprecation byte-identity (FR-061 / T329)
# =============================================================================

@test "US2/T334: non-interactive --on-drift unset → proceed (proceed-and-warn default)" {
  run bash -c "$_drift_src; ARG_ON_DRIFT=''; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "US2/T334: non-interactive --on-drift=proceed → proceed (writes + warns)" {
  run bash -c "$_drift_src; ARG_ON_DRIFT=proceed; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "US2/T334: non-interactive --on-drift=abort → abort (skip the drifted spec)" {
  run bash -c "$_drift_src; ARG_ON_DRIFT=abort; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "abort" ]
}

@test "US2/T334: non-interactive disposition NEVER hangs awaiting input (SC-019)" {
  # No --on-drift, no TTY → must resolve deterministically (proceed) without
  # blocking on a read. A 5s timeout guards against a regression to a hang.
  run _timeout 5 bash -c "$_drift_src; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "US2/T329: --on-drift=abort wins over a TTY (override, no prompt) — empty-stdin proxy" {
  # FR-056: an explicit --on-drift is an operator OVERRIDE that skips the
  # prompt everywhere. We can't allocate a real TTY here, so we assert the
  # precedence directly: with ARG_ON_DRIFT=abort the function returns `abort`
  # WITHOUT ever consulting the prompt/tty (it would otherwise read stdin).
  run bash -c "$_drift_src; ARG_ON_DRIFT=abort; printf 'p\n' | reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing'"
  [ "$status" -eq 0 ]
  # `p` on stdin would mean proceed IF the prompt were consulted; abort proves
  # the flag short-circuited the prompt.
  [ "$output" = "abort" ]
}

@test "US2/T329: the --retroactive deprecation INFO row carries the verbatim §6 text" {
  # The exact wording is contractual (drift-warning-surface §6). Pin it so a
  # future copy edit is a conscious, reviewed change.
  run bash -c '
    source "'"$SUMMARY_SH"'"
    summary::start ""
    summary::add info "--retroactive is deprecated and now the default — writing from any branch needs no flag (use --all to enumerate)"
    summary::emit 2>&1 1>/dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO  --retroactive is deprecated and now the default — writing from any branch needs no flag (use --all to enumerate)"* ]]
}

@test "US2/T329: --retroactive sets no behavioral global (byte-identical disposition path)" {
  # With --retroactive the disposition global ARG_ON_DRIFT stays empty, so the
  # disposition resolution is byte-identical to omitting the flag (no-op alias).
  local with off
  with="$(_parse --retroactive | sed 's/ retroactive=[01]//')"
  off="$(_parse --all | sed 's/ retroactive=[01]//')"
  [ "$with" = "$off" ]
}

@test "US2/T329: the retired _RECONCILE_RETROACTIVE_BYPASS_COUNT warned row no longer exists" {
  # A clean run that sets no warned events must emit no warnings section —
  # proving the v0.1.x retroactive-bypass aggregate row is gone (FR-061).
  run bash -c '
    source "'"$SUMMARY_SH"'"
    summary::start ""
    summary::add info "--retroactive is deprecated and now the default"
    summary::add created "x"
    summary::emit 2>&1 1>/dev/null
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"retroactive"*"bypass"* ]]
  [[ "$output" != *"----- warnings -----"* ]]
}

@test "US2/T335: --retroactive does not alter the disposition (FR-062 convergence default)" {
  # A drifted spec resolves identically whether or not --retroactive was
  # passed — the flag changes nothing but the one INFO row.
  local a b
  a="$(bash -c "$_drift_src; ARG_RETROACTIVE=1; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null")"
  b="$(bash -c "$_drift_src; ARG_RETROACTIVE=0; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null")"
  [ "$a" = "$b" ]
  [ "$a" = "proceed" ]
}

@test "US2/T333: pre-existing-ahead spec, no flag, no TTY → default proceeds-and-warns" {
  # FR-056 default + Acceptance Scenario 3: a spec whose Linear Issue is
  # genuinely ahead, reconciled non-interactively with no --on-drift, takes
  # the proceed-and-warn arm (writes disk state, keeps the WARNING row).
  run bash -c "
    $_drift_src
    summary::start ''
    reconcile::_emit_drift_warning 010 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing'
    disp=\"\$(reconcile::_drift_disposition 010 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null)\"
    printf 'disp=%s warned=%s\n' \"\$disp\" \"\$(summary::count warned)\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"disp=proceed warned=1"* ]]
}

# =============================================================================
# spec 003 Phase 5 (US3) — interactive prompt arm (T336-T346)
#
#   reconcile::_drift_prompt drives the operator prompt via a redirectable
#   tty seam (RECONCILE_DRIFT_TTY, A10) so the prompt body is exercisable
#   without a real terminal: p/proceed→proceed, a/abort/empty→abort, invalid
#   re-prompts. The `[[ -t 0 ]]` gate itself can't be simulated in bats
#   (stdin is always redirected), so the interactive-gate assertion is
#   skipped with a reason; the prompt BODY is fully covered via the seam.
# =============================================================================

# Drive the prompt with a canned answer file via the RECONCILE_DRIFT_TTY seam.
_prompt() {
  local answers="$1"
  local tty_file="$BATS_TEST_TMPDIR/ttyin.$$"
  printf '%s' "$answers" > "$tty_file"
  bash -c "$_drift_src; RECONCILE_DRIFT_TTY='$tty_file' reconcile::_drift_prompt 005 2>/dev/null"
}

@test "US3/T338: interactive prompt — 'p' resolves proceed" {
  run _prompt $'p\n'
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "US3/T338: interactive prompt — 'proceed' resolves proceed" {
  run _prompt $'proceed\n'
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "US3/T338: interactive prompt — 'a' resolves abort" {
  run _prompt $'a\n'
  [ "$status" -eq 0 ]
  [ "$output" = "abort" ]
}

@test "US3/T338: interactive prompt — 'abort' resolves abort" {
  run _prompt $'abort\n'
  [ "$status" -eq 0 ]
  [ "$output" = "abort" ]
}

@test "US3/T338: interactive prompt — empty-enter resolves abort (plan A5 safe default)" {
  run _prompt $'\n'
  [ "$status" -eq 0 ]
  [ "$output" = "abort" ]
}

@test "US3/T338: interactive prompt — invalid input re-prompts then resolves (no crash, no silent pick)" {
  # First answer is garbage (re-prompt), second is a valid proceed.
  run _prompt $'xyz\np\n'
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "US3/T343: interactive prompt — EOF (no answer) collapses to the safe abort (never hangs)" {
  # Empty answer file → immediate EOF on read → abort, under a 5s hang guard.
  local tty_file="$BATS_TEST_TMPDIR/empty.$$"
  : > "$tty_file"
  run _timeout 5 bash -c "$_drift_src; RECONCILE_DRIFT_TTY='$tty_file' reconcile::_drift_prompt 005 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "abort" ]
}

@test "US3/T343: prompt reads its tty seam, NOT the inherited stdin stream (A10)" {
  # The spec-enumeration stdin carries 'p' (would proceed if consumed); the
  # tty seam carries 'a'. The disposition MUST honour the tty (abort),
  # proving the prompt does not consume the enumeration stdin.
  local tty_file="$BATS_TEST_TMPDIR/tty.$$"
  printf 'a\n' > "$tty_file"
  run bash -c "$_drift_src; printf 'p\n' | { RECONCILE_DRIFT_TTY='$tty_file' reconcile::_drift_prompt 005 2>/dev/null; }"
  [ "$status" -eq 0 ]
  [ "$output" = "abort" ]
}

@test "US3/T343: the [[ -t 0 ]] interactive GATE itself cannot be simulated in bats" {
  skip "bats always redirects stdin so [[ -t 0 ]] is false; the gate is exercised live (integration T341). The prompt BODY is fully covered above via the RECONCILE_DRIFT_TTY seam (A10), mirroring spec 001's summary tty-test skip."
}

@test "US3/T339: --on-drift=abort skips a drifted spec (override) — no prompt on a TTY-less run" {
  run bash -c "$_drift_src; ARG_ON_DRIFT=abort; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "abort" ]
}

@test "US3/T339: --on-drift=proceed writes + warns" {
  run bash -c "$_drift_src; ARG_ON_DRIFT=proceed; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "US3/T339: an unrecognised --on-drift value is a usage error at parse time (plan A11)" {
  run _parse --all --on-drift=maybe
  [ "$status" -eq 2 ]
  [[ "$output" == *"--on-drift value must be abort or proceed"* ]]
}

@test "US3/T340: an abort disposition records ONLY the WARNING + skip rows (zero mutation proxy, SC-018)" {
  # Drive the full process_spec disposition branch surface in isolation:
  # emit the WARNING (audit trail) then resolve abort → skip note. Assert
  # zero created/updated events for that spec (FR-057).
  run bash -c "
    $_drift_src
    summary::start ''
    reconcile::_emit_drift_warning 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing'
    ARG_ON_DRIFT=abort
    disp=\"\$(reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing' < /dev/null)\"
    if [[ \"\$disp\" == abort ]]; then
      summary::add skipped 'spec 005 skipped by operator (backward-drift abort) — Linear unchanged'
    fi
    printf 'created=%s updated=%s warned=%s skipped=%s\n' \
      \"\$(summary::count created)\" \"\$(summary::count updated)\" \
      \"\$(summary::count warned)\" \"\$(summary::count skipped)\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"created=0 updated=0 warned=1 skipped=1"* ]]
}

@test "US3/T345: drift WARNING worktree lines collapse to nothing in the single-worktree case" {
  # _drift_worktree_lines returns empty when ≤1 worktree touches the spec
  # (contract §2). Run outside a multi-worktree repo → no canonical lines.
  run bash -c "$_drift_src; reconcile::_drift_worktree_lines 999"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
