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

@test "_drift_disposition: Phase 3 default arm resolves proceed (proceed-and-warn)" {
  run bash -c "$_drift_src; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing'"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "_drift_disposition: default arm proceeds regardless of --on-drift (US2/T334 layers that on)" {
  # Phase 3 has not yet wired the non-interactive ARG_ON_DRIFT arm; the
  # default proceed-and-warn holds until US2/US3 extend the fork. This pins
  # the Phase-3 contract so the later layering is an additive change.
  run bash -c "$_drift_src; ARG_ON_DRIFT=abort; reconcile::_drift_disposition 005 'fired=1 phase_drift=1 recency_drift=0 signals=phase_ordering disk=planning linear=implementing'"
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}
