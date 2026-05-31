#!/usr/bin/env bats
# =============================================================================
# tests/unit/drift_detection.bats — spec 003 Phase 2 foundational drift units
#
# Covers the PURE drift machinery landed in Phase 2 (no write-path coupling):
#   * git_helpers::iso_to_epoch        — cross-platform ISO→epoch (T304/T317)
#   * git_helpers::spec_dir_last_commit — recency disk key (T302/T316)
#   * git_helpers::worktrees_touching_spec — multi-worktree ranking (T303/T336)
#   * reconcile::_phase_ordinal        — lifecycle ladder (T305/T319)
#   * reconcile::compute_drift         — pure comparator (T306/T318/T337)
#
# Strategy mirrors git_helpers.bats: each test runs in a hermetic temp git
# repo. The compute_drift fixtures live in tests/fixtures/linear_responses/.
# These are PURE-unit tests — no Linear network, no MCP, no writes.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
GIT_HELPERS_SH="${REPO_ROOT}/src/git_helpers.sh"
RECONCILE_SH="${REPO_ROOT}/src/reconcile.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures/linear_responses"

setup() {
  # Source git_helpers directly. reconcile.sh is sourced for its pure
  # functions; the `if [[ BASH_SOURCE == 0 ]]` guard at its tail means
  # sourcing does NOT run main(), so no config load / network fires.
  # shellcheck source=../../src/git_helpers.sh
  source "$GIT_HELPERS_SH"
  # shellcheck source=../../src/reconcile.sh
  source "$RECONCILE_SH"

  export GIT_AUTHOR_NAME='Test Author'
  export GIT_AUTHOR_EMAIL='test@example.com'
  export GIT_COMMITTER_NAME='Test Author'
  export GIT_COMMITTER_EMAIL='test@example.com'
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init --initial-branch=main --quiet
  printf 'hello\n' > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m 'initial commit'
}

# Helper: commit a spec dir with an explicit committer date so recency is
# deterministic. $1 = spec subpath (e.g. specs/005-foo), $2 = ISO date.
_commit_spec_at() {
  local rel="$1" iso="$2"
  mkdir -p "$REPO/$rel"
  printf 'spec body %s\n' "$RANDOM" > "$REPO/$rel/spec.md"
  git -C "$REPO" add "$rel/spec.md"
  GIT_COMMITTER_DATE="$iso" GIT_AUTHOR_DATE="$iso" \
    git -C "$REPO" commit --quiet -m "spec $rel"
}

# -----------------------------------------------------------------------------
# git_helpers::iso_to_epoch (T304 / T317 / recency-comparison §2)
# -----------------------------------------------------------------------------

@test "iso_to_epoch: offset and Z spellings of the same instant yield the same epoch" {
  run git_helpers::iso_to_epoch "2026-05-20T14:02:11+00:00"
  [ "$status" -eq 0 ]
  local with_offset="$output"
  run git_helpers::iso_to_epoch "2026-05-20T14:02:11Z"
  [ "$status" -eq 0 ]
  local with_z="$output"
  [ -n "$with_offset" ]
  [ "$with_offset" = "$with_z" ]
  # 2026-05-20T14:02:11Z is a known epoch; assert the exact value.
  [ "$with_offset" -eq 1779285731 ]
}

@test "iso_to_epoch: unparseable string yields empty (recency unavailable)" {
  run git_helpers::iso_to_epoch "not-a-date"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "iso_to_epoch: empty input yields empty" {
  run git_helpers::iso_to_epoch ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# git_helpers::spec_dir_last_commit (T302 / T316 / recency-comparison §1)
# -----------------------------------------------------------------------------

@test "spec_dir_last_commit: returns the committing ISO date for a touched dir" {
  _commit_spec_at "specs/005-foo" "2026-05-20T14:02:11+00:00"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && git_helpers::spec_dir_last_commit 'specs/005-foo'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # The returned string MUST parse to a sane epoch via the T304 converter.
  run bash -c "source '$GIT_HELPERS_SH' && git_helpers::iso_to_epoch \"\$(cd '$REPO' && git_helpers::spec_dir_last_commit 'specs/005-foo')\""
  [ "$status" -eq 0 ]
  [ "$output" -eq 1779285731 ]
}

@test "spec_dir_last_commit: empty git history for the dir returns empty (unavailable)" {
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && git_helpers::spec_dir_last_commit 'specs/999-never-committed'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spec_dir_last_commit: empty arg returns empty" {
  run git_helpers::spec_dir_last_commit ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -----------------------------------------------------------------------------
# reconcile::_phase_ordinal (T305 / T319 / data-model §2)
# -----------------------------------------------------------------------------

@test "_phase_ordinal: ladder is total and strictly ordered clarifying<...<merged" {
  local prev=-1 tok ord
  for tok in clarifying specifying planning tasking implementing ready_to_merge merged; do
    ord="$(reconcile::_phase_ordinal "$tok")"
    [ "$ord" -gt "$prev" ]
    prev="$ord"
  done
  [ "$(reconcile::_phase_ordinal merged)" -eq 6 ]
  [ "$(reconcile::_phase_ordinal clarifying)" -eq 0 ]
}

@test "_phase_ordinal: unknown token returns the phase-signal-disabling sentinel" {
  run reconcile::_phase_ordinal "bogus"
  [ "$status" -eq 0 ]
  [ "$output" -eq "$RECONCILE_PHASE_ORDINAL_UNKNOWN" ]
  [ "$output" -lt 0 ]
  run reconcile::_phase_ordinal ""
  [ "$output" -eq "$RECONCILE_PHASE_ORDINAL_UNKNOWN" ]
}

# -----------------------------------------------------------------------------
# reconcile::compute_drift — no-drift / forward cases (T318 / SC-017)
# -----------------------------------------------------------------------------

@test "compute_drift: forward (disk ahead) fires nothing" {
  _commit_spec_at "specs/312-fwd" "2026-05-26T09:31:00+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_forward.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 312 'specs/312-fwd' '$json' implementing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=0"* ]]
  [[ "$output" == *"phase_drift=0"* ]]
  [[ "$output" == *"recency_drift=0"* ]]
}

@test "compute_drift: within clock-skew (+30s, equal phase) fires nothing" {
  _commit_spec_at "specs/313-skew" "2026-05-26T09:31:00+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_within_skew.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 313 'specs/313-skew' '$json' implementing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=0"* ]]
}

@test "compute_drift: disk merged, Linear behind at implementing fires nothing (US1)" {
  _commit_spec_at "specs/314-merged" "2026-05-26T10:00:00+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_merged_behind.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 314 'specs/314-merged' '$json' merged"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=0"* ]]
}

@test "compute_drift: absent Linear Issue fires nothing (US2 first reconcile)" {
  _commit_spec_at "specs/315-absent" "2026-05-26T09:31:00+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_absent.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 315 'specs/315-absent' '$json' planning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=0"* ]]
}

@test "compute_drift: uninferrable disk phase disables phase signal (recency-only)" {
  # Disk commit equal to Linear updatedAt; disk phase unknown → phase skipped,
  # recency not fired → fired=0 (degrade to available signal, never fabricate).
  _commit_spec_at "specs/313-skew" "2026-05-26T09:31:30+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_within_skew.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 313 'specs/313-skew' '$json' garbage"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=0"* ]]
  [[ "$output" == *"phase_drift=0"* ]]
}

# -----------------------------------------------------------------------------
# reconcile::compute_drift — drift-fired cases (T337 / SC-016)
# -----------------------------------------------------------------------------

@test "compute_drift: phase-only fire (recency unavailable) names phase_ordering" {
  # No committed spec dir → recency unavailable; Linear implementing > disk planning.
  local json; json="$(cat "$FIXTURES/spec_issue_linear_ahead_phase.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 310 'specs/310-uncommitted' '$json' planning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=1"* ]]
  [[ "$output" == *"phase_drift=1"* ]]
  [[ "$output" == *"recency_drift=0"* ]]
  [[ "$output" == *"signals=phase_ordering"* ]]
  [[ "$output" != *"signals=phase_ordering,recency"* ]]
}

@test "compute_drift: equal phase + Linear updatedAt far ahead fires NOTHING (#01 idempotency / SC-017)" {
  # Recency is a CORROBORATING signal only — it never fires on its own (#01).
  # disk commit 09:31:00, Linear updatedAt 09:35:00 (+240s) but BOTH planning
  # (equal phase). This is the shape of a no-op re-run after the bridge's own
  # write bumped updatedAt; the old behaviour fired recency alone here and
  # broke idempotency. The new contract suppresses it: no phase drift to
  # corroborate ⇒ nothing fires.
  _commit_spec_at "specs/311-recency" "2026-05-26T09:31:00+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_linear_ahead_recency.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 311 'specs/311-recency' '$json' planning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=0"* ]]
  [[ "$output" == *"phase_drift=0"* ]]
  [[ "$output" == *"recency_drift=0"* ]]
  [[ "$output" != *"signals=recency"* ]]
}

@test "compute_drift: both signals fire → signals=phase_ordering,recency" {
  # disk planning committed long ago; Linear implementing + much newer.
  _commit_spec_at "specs/310-both" "2026-05-20T14:02:11+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_linear_ahead_phase.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 310 'specs/310-both' '$json' planning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fired=1"* ]]
  [[ "$output" == *"phase_drift=1"* ]]
  [[ "$output" == *"recency_drift=1"* ]]
  [[ "$output" == *"signals=phase_ordering,recency"* ]]
}

@test "compute_drift: skew tolerance is overridable via the environment" {
  # Recency only corroborates a phase drift (#01), so keep a phase drift live
  # (disk planning < Linear implementing) and vary only whether recency
  # piggybacks. disk commit 09:28:00, Linear updatedAt 09:31:00 (+180s). A
  # huge override (9999s) puts the gap WITHIN tolerance → recency suppressed,
  # phase drift still fires alone; proving the env value is honoured (default
  # 120s would have let recency corroborate — see the next test).
  _commit_spec_at "specs/310-skew" "2026-05-26T09:28:00+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_linear_ahead_phase.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS=9999 reconcile::compute_drift 310 'specs/310-skew' '$json' planning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"phase_drift=1"* ]]
  [[ "$output" == *"recency_drift=0"* ]]
  [[ "$output" == *"signals=phase_ordering"* ]]
  [[ "$output" != *"signals=phase_ordering,recency"* ]]
}

@test "compute_drift: default skew lets recency corroborate a phase drift" {
  # Same phase drift, default 120s tolerance: +180s gap > 120s → recency
  # corroborates → both signals named.
  _commit_spec_at "specs/310-skew2" "2026-05-26T09:28:00+00:00"
  local json; json="$(cat "$FIXTURES/spec_issue_linear_ahead_phase.json")"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && source '$RECONCILE_SH' && reconcile::compute_drift 310 'specs/310-skew2' '$json' planning"
  [ "$status" -eq 0 ]
  [[ "$output" == *"phase_drift=1"* ]]
  [[ "$output" == *"recency_drift=1"* ]]
  [[ "$output" == *"signals=phase_ordering,recency"* ]]
  [[ "$output" == *"skew=120"* ]]
}

# -----------------------------------------------------------------------------
# git_helpers::worktrees_touching_spec ranking (T303 / T336 / recency §4)
# -----------------------------------------------------------------------------

@test "worktrees_touching_spec: single worktree → one line for the invoking tree" {
  _commit_spec_at "specs/005-foo" "2026-05-20T14:02:11+00:00"
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && git_helpers::worktrees_touching_spec 005"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  # epoch \t path \t branch — epoch is the committed instant, branch is main.
  [[ "${lines[0]}" == *$'\t'*"/repo"*$'\t'"main" ]]
  [[ "${lines[0]}" == "1779285731"$'\t'* ]]
}

@test "worktrees_touching_spec: omits worktrees without the spec dir" {
  # No spec dir committed at all → no touching worktree.
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && git_helpers::worktrees_touching_spec 005"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "worktrees_touching_spec: ranks two worktrees by spec-dir commit epoch, not branch" {
  _commit_spec_at "specs/006-bar" "2026-05-20T10:00:00+00:00"
  # Add a second worktree on a feature branch with a NEWER spec-dir commit.
  local wt="$BATS_TEST_TMPDIR/repo-feature"
  git -C "$REPO" worktree add --quiet -b 006-bar "$wt" main
  printf 'newer\n' >> "$wt/specs/006-bar/spec.md"
  GIT_COMMITTER_DATE="2026-05-25T10:00:00+00:00" GIT_AUTHOR_DATE="2026-05-25T10:00:00+00:00" \
    git -C "$wt" commit --quiet -am 'advance spec on feature'

  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && git_helpers::worktrees_touching_spec 006"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  # The canonical line is the MAX epoch — sort the emitted epochs and assert
  # the newest belongs to the feature worktree (NOT decided by branch name).
  local max_line
  max_line="$(printf '%s\n' "${lines[@]}" | sort -t$'\t' -k1,1n | tail -1)"
  [[ "$max_line" == *"repo-feature"*$'\t'"006-bar" ]]
}

@test "worktrees_touching_spec: epoch tie → invoking worktree canonical, both in the touching set (T336c)" {
  # Two worktrees touching specs/007-baz with the SAME spec-dir commit epoch.
  # The invoking worktree (emitted first by git worktree list) is canonical
  # on a tie; both still appear in the set (FR-058 / FR-059 / recency §4).
  _commit_spec_at "specs/007-baz" "2026-05-22T12:00:00+00:00"
  local wt="$BATS_TEST_TMPDIR/repo-feature-007"
  git -C "$REPO" worktree add --quiet -b 007-baz "$wt" main
  # The feature worktree shares the identical spec-dir commit (no new commit),
  # so both worktrees resolve to the same commit epoch — a true tie.
  run bash -c "cd '$REPO' && source '$GIT_HELPERS_SH' && git_helpers::worktrees_touching_spec 007"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  # Both lines carry the same epoch (the tie).
  local e0 e1
  e0="$(printf '%s' "${lines[0]}" | cut -f1)"
  e1="$(printf '%s' "${lines[1]}" | cut -f1)"
  [ "$e0" = "$e1" ]
  # The invoking worktree (the main /repo checkout) is emitted first → it is
  # the tie-break canonical; both paths are present in the touching set.
  [[ "$output" == *"/repo"$'\t'"main"* ]]
  [[ "$output" == *"repo-feature-007"*$'\t'"007-baz"* ]]
}

@test "worktrees_touching_spec: epoch tie → LINKED invoking worktree wins over porcelain-first main (T336c, finding #07)" {
  # Finding #07: the test above invokes from the MAIN worktree, which `git
  # worktree list --porcelain` already lists FIRST. So "emitted first" there is
  # satisfied by porcelain order alone and cannot distinguish the documented
  # invoking-worktree tie-break (git_helpers.sh §worktrees_touching_spec, which
  # resolves invoking_root via `rev-parse --show-toplevel` from the CWD and
  # buffers that row ahead of the porcelain order) from "main happens to be
  # first". This test removes that confound: it invokes from the LINKED
  # worktree, which is NOT porcelain-first, so the only way it can appear first
  # is the reorder logic actually firing.
  _commit_spec_at "specs/008-tie" "2026-05-22T12:00:00+00:00"
  git -C "$REPO" worktree add --quiet -b 008-tie "$BATS_TEST_TMPDIR/repo-feature-008" main
  # Linked worktree shares main's identical spec-dir commit (no new commit) →
  # exact epoch tie. main is the spec's authoring worktree; the linked tree
  # merely checks the same commit out, so neither has a strictly-greater epoch.

  # Resolve BOTH worktree roots to the realpaths git itself reports in
  # porcelain output. On macOS $BATS_TEST_TMPDIR lives under /var → /private/var,
  # and `git worktree add` records the resolved /private/var form, so the literal
  # "$BATS_TEST_TMPDIR/repo-feature-008" is not always cd-able. Reading the path
  # back from `git worktree list --porcelain` gives a canonical, cd-able value.
  local main_wt linked_wt
  main_wt="$(git -C "$REPO" worktree list --porcelain \
    | awk '/^worktree / && /repo$/{print $2; exit}')"
  linked_wt="$(git -C "$REPO" worktree list --porcelain \
    | awk '/^worktree / && /repo-feature-008$/{print $2; exit}')"
  [ -n "$main_wt" ]
  [ -n "$linked_wt" ]
  [ -d "$linked_wt" ]

  # Precondition: confirm porcelain order lists MAIN first, NOT the linked
  # worktree — otherwise this test would prove nothing (same blind spot as the
  # original). The linked worktree winning despite this is the real signal.
  local porcelain_first
  porcelain_first="$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
  [ "$porcelain_first" = "$main_wt" ]
  [ "$porcelain_first" != "$linked_wt" ]

  # Invoke FROM the linked worktree: invoking_root resolves to the linked tree,
  # so the tie-break must surface IT first despite porcelain order.
  run bash -c "cd '$linked_wt' && source '$GIT_HELPERS_SH' && git_helpers::worktrees_touching_spec 008"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]

  # Both lines carry the same epoch (the tie we constructed).
  local e0 e1
  e0="$(printf '%s' "${lines[0]}" | cut -f1)"
  e1="$(printf '%s' "${lines[1]}" | cut -f1)"
  [ "$e0" = "$e1" ]

  # THE load-bearing assertion: the invoking (LINKED) worktree is emitted
  # FIRST — line 0 is the 008-tie feature path, NOT main. Under porcelain
  # order main would be first; only the invoking-root reorder puts the linked
  # tree ahead. This is what the original main-invoked test could not prove.
  [[ "${lines[0]}" == *"repo-feature-008"*$'\t'"008-tie" ]]
  [[ "${lines[0]}" != *$'\t'"main" ]]
  # ...and main still appears in the touching set (both worktrees present).
  [[ "$output" == *"/repo"$'\t'"main"* ]]
}
