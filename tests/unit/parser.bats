#!/usr/bin/env bats
# tests/unit/parser.bats — unit tests for src/parser.sh against
# tests/fixtures/specs/*. Targets bats-core 1.11.0 + bash 4+.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/src/parser.sh"
    FIXTURES="${BATS_TEST_DIRNAME}/../fixtures/specs"
}

# ---------------------------------------------------------------------------
# parser::feature_number
# ---------------------------------------------------------------------------

@test "feature_number extracts '001' from 001-minimal" {
    run parser::feature_number "${FIXTURES}/001-minimal"
    [ "$status" -eq 0 ]
    [ "$output" = "001" ]
}

@test "feature_number extracts '002' from 002-multi-phase" {
    run parser::feature_number "${FIXTURES}/002-multi-phase"
    [ "$status" -eq 0 ]
    [ "$output" = "002" ]
}

@test "feature_number tolerates a trailing slash" {
    run parser::feature_number "${FIXTURES}/004-already-merged/"
    [ "$status" -eq 0 ]
    [ "$output" = "004" ]
}

@test "feature_number fails on a non-numeric prefix" {
    tmp="$(mktemp -d)/no-prefix-feature"
    mkdir -p "$tmp"
    run parser::feature_number "$tmp"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    rm -rf "$(dirname "$tmp")"
}

# ---------------------------------------------------------------------------
# parser::short_name
# ---------------------------------------------------------------------------

@test "short_name extracts 'minimal' from 001-minimal" {
    run parser::short_name "${FIXTURES}/001-minimal"
    [ "$status" -eq 0 ]
    [ "$output" = "minimal" ]
}

@test "short_name extracts 'multi-phase' from 002-multi-phase" {
    run parser::short_name "${FIXTURES}/002-multi-phase"
    [ "$status" -eq 0 ]
    [ "$output" = "multi-phase" ]
}

@test "short_name extracts 'already-merged' (multi-hyphen kebab)" {
    run parser::short_name "${FIXTURES}/004-already-merged"
    [ "$status" -eq 0 ]
    [ "$output" = "already-merged" ]
}

@test "short_name extracts 'clarify-sessions'" {
    run parser::short_name "${FIXTURES}/005-clarify-sessions"
    [ "$status" -eq 0 ]
    [ "$output" = "clarify-sessions" ]
}

# ---------------------------------------------------------------------------
# parser::lifecycle_phase
# ---------------------------------------------------------------------------

@test "lifecycle_phase: 001-minimal returns 'specifying'" {
    run parser::lifecycle_phase "${FIXTURES}/001-minimal"
    [ "$status" -eq 0 ]
    [ "$output" = "specifying" ]
}

@test "lifecycle_phase: 002-multi-phase returns 'tasking'" {
    run parser::lifecycle_phase "${FIXTURES}/002-multi-phase"
    [ "$status" -eq 0 ]
    [ "$output" = "tasking" ]
}

@test "lifecycle_phase: 003-malformed-tasks returns 'tasking' (tasks.md present, no checks)" {
    run parser::lifecycle_phase "${FIXTURES}/003-malformed-tasks"
    [ "$status" -eq 0 ]
    [ "$output" = "tasking" ]
}

@test "lifecycle_phase: 004-already-merged returns 'analyzing' (artifacts only, no PR hint)" {
    run parser::lifecycle_phase "${FIXTURES}/004-already-merged"
    [ "$status" -eq 0 ]
    [ "$output" = "analyzing" ]
}

@test "lifecycle_phase: 004-already-merged + 'merged' PR hint returns 'merged'" {
    run parser::lifecycle_phase "${FIXTURES}/004-already-merged" "merged"
    [ "$status" -eq 0 ]
    [ "$output" = "merged" ]
}

@test "lifecycle_phase: 004-already-merged + 'open' PR hint returns 'ready_to_merge'" {
    run parser::lifecycle_phase "${FIXTURES}/004-already-merged" "open"
    [ "$status" -eq 0 ]
    [ "$output" = "ready_to_merge" ]
}

@test "lifecycle_phase: 005-clarify-sessions returns 'clarifying'" {
    run parser::lifecycle_phase "${FIXTURES}/005-clarify-sessions"
    [ "$status" -eq 0 ]
    [ "$output" = "clarifying" ]
}

@test "lifecycle_phase: missing spec.md exits non-zero" {
    tmp="$(mktemp -d)/006-empty"
    mkdir -p "$tmp"
    run parser::lifecycle_phase "$tmp"
    [ "$status" -ne 0 ]
    rm -rf "$(dirname "$tmp")"
}

# ---------------------------------------------------------------------------
# parser::task_phases
# ---------------------------------------------------------------------------

@test "task_phases: 002-multi-phase returns 3 phases" {
    run parser::task_phases "${FIXTURES}/002-multi-phase/tasks.md"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = $'1\tSetup' ]
    [ "${lines[1]}" = $'2\tFoundational' ]
    [ "${lines[2]}" = $'3\tPolish' ]
}

@test "task_phases: 003-malformed-tasks returns 1 phase" {
    run parser::task_phases "${FIXTURES}/003-malformed-tasks/tasks.md"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = $'1\tSetup' ]
}

@test "task_phases: missing file yields no output, exit 0" {
    run parser::task_phases "/nonexistent/tasks.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# parser::tasks_in_phase
# ---------------------------------------------------------------------------

@test "tasks_in_phase: 002 Phase 1 returns two unchecked tasks" {
    run parser::tasks_in_phase "${FIXTURES}/002-multi-phase/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    # Trailing tab + empty 4th field = estimate column (FR-035), empty
    # when the task carries no [N] marker.
    [ "${lines[0]}" = $'T002-001\tunchecked\tCreate skeleton directories\t' ]
    [ "${lines[1]}" = $'T002-002\tunchecked\t[P] Configure tooling\t' ]
}

@test "tasks_in_phase: 002 Phase 2 returns two unchecked tasks" {
    run parser::tasks_in_phase "${FIXTURES}/002-multi-phase/tasks.md" 2
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = $'T002-003\tunchecked\tImplement core module A\t' ]
    [ "${lines[1]}" = $'T002-004\tunchecked\t[P] Implement core module B (depends on T002-001)\t' ]
}

@test "tasks_in_phase: 004 Phase 1 returns two checked tasks" {
    run parser::tasks_in_phase "${FIXTURES}/004-already-merged/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = $'T004-001\tchecked\tCreate skeleton\t' ]
    [ "${lines[1]}" = $'T004-002\tchecked\tWire CI\t' ]
}

@test "tasks_in_phase: 003 Phase 1 ignores the malformed line above the header" {
    run parser::tasks_in_phase "${FIXTURES}/003-malformed-tasks/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = $'T003-002\tunchecked\tFirst properly-grouped task\t' ]
    [ "${lines[1]}" = $'T003-003\tunchecked\tSecond properly-grouped task\t' ]
}

@test "tasks_in_phase: unknown phase index returns no lines" {
    run parser::tasks_in_phase "${FIXTURES}/002-multi-phase/tasks.md" 99
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# parser::tasks_in_phase — [N] estimate extraction (FR-035)
# ---------------------------------------------------------------------------

@test "tasks_in_phase: extracts [N] at start of description" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [ ] T001 [3] Author the contracts JSON
EOF
    run parser::tasks_in_phase "${tmp}/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'T001\tunchecked\tAuthor the contracts JSON\t3' ]
    rm -rf "$tmp"
}

@test "tasks_in_phase: extracts [N] after [P] and preserves [P] in desc" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [x] T002 [P] [5] Implement parser
EOF
    run parser::tasks_in_phase "${tmp}/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'T002\tchecked\t[P] Implement parser\t5' ]
    rm -rf "$tmp"
}

@test "tasks_in_phase: extracts [N] after [P] [US1] and preserves both" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [x] T003 [P] [US1] [8] Wire reconcile flow
EOF
    run parser::tasks_in_phase "${tmp}/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'T003\tchecked\t[P] [US1] Wire reconcile flow\t8' ]
    rm -rf "$tmp"
}

@test "tasks_in_phase: leaves description untouched when no digit marker" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [ ] T004 [P] [US1] Plain task without estimate
EOF
    run parser::tasks_in_phase "${tmp}/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = $'T004\tunchecked\t[P] [US1] Plain task without estimate\t' ]
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# parser::phase_estimate & parser::spec_estimate
# ---------------------------------------------------------------------------

@test "phase_estimate: sums [N] markers within a phase" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [ ] T001 [3] First
- [x] T002 [P] [5] Second
- [ ] T003 No marker
## Phase 2: Other
- [ ] T010 [8] Eight
EOF
    run parser::phase_estimate "${tmp}/tasks.md" 1
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
    run parser::phase_estimate "${tmp}/tasks.md" 2
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
    rm -rf "$tmp"
}

@test "phase_estimate: empty when phase has no markers" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [ ] T001 No estimate
- [ ] T002 [P] Also no estimate
EOF
    run parser::phase_estimate "${tmp}/tasks.md" 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -rf "$tmp"
}

@test "spec_estimate: rolls up across all phases" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [ ] T001 [3] First
- [x] T002 [P] [5] Second
## Phase 2: Other
- [ ] T010 [13] Thirteen
## Phase 3: Empty
- [ ] T020 No marker here
EOF
    run parser::spec_estimate "${tmp}/tasks.md"
    [ "$status" -eq 0 ]
    [ "$output" = "21" ]
    rm -rf "$tmp"
}

@test "spec_estimate: empty when no task in any phase carries a marker" {
    local tmp
    tmp="$(mktemp -d)"
    cat > "${tmp}/tasks.md" <<'EOF'
## Phase 1: Setup
- [ ] T001 No estimate
## Phase 2: Other
- [ ] T010 [P] Also none
EOF
    run parser::spec_estimate "${tmp}/tasks.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# parser::malformed_task_lines
# ---------------------------------------------------------------------------

@test "malformed_task_lines: 003 flags the bare task above the first phase header" {
    run parser::malformed_task_lines "${FIXTURES}/003-malformed-tasks/tasks.md"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == *"T003-001 Bare task without a phase header"* ]]
}

@test "malformed_task_lines: 002 (well-formed) flags nothing" {
    run parser::malformed_task_lines "${FIXTURES}/002-multi-phase/tasks.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "malformed_task_lines: 004 (well-formed) flags nothing" {
    run parser::malformed_task_lines "${FIXTURES}/004-already-merged/tasks.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# parser::clarify_sessions
# ---------------------------------------------------------------------------

@test "clarify_sessions: 005 returns 3 sessions in chronological order" {
    run parser::clarify_sessions "${FIXTURES}/005-clarify-sessions/spec.md"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = $'2026-05-01\t2' ]
    [ "${lines[1]}" = $'2026-05-15\t2' ]
    [ "${lines[2]}" = $'2026-05-28\t2' ]
}

@test "clarify_sessions: 001-minimal returns no sessions" {
    run parser::clarify_sessions "${FIXTURES}/001-minimal/spec.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# parser::clarify_session_bullets
# ---------------------------------------------------------------------------

@test "clarify_session_bullets: 005 / 2026-05-15 returns 2 bullets" {
    run parser::clarify_session_bullets "${FIXTURES}/005-clarify-sessions/spec.md" "2026-05-15"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "- Q: How is each session keyed for idempotency?"* ]]
    [[ "${lines[1]}" == "- Q: Are sessions posted in chronological order?"* ]]
}

@test "clarify_session_bullets: 005 / unknown date returns nothing" {
    run parser::clarify_session_bullets "${FIXTURES}/005-clarify-sessions/spec.md" "1999-01-01"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
