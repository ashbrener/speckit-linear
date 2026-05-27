#!/usr/bin/env bats
# tests/unit/config.bats — unit tests for src/config.sh
#
# Covers:
#   - happy path: every getter returns the right UUID
#   - missing file: config::load exits 2 with "file not found"
#   - missing required field: config::validate names the field
#   - malformed UUID: config::validate flags it with file:field
#   - workflow-state UUID lookup for every lifecycle phase
#   - default-state UUID lookup for todo|in_progress|done
#
# Compatible with bats-core 1.11.0. Sources src/config.sh directly.

# Resolve repo root from this file's location so the tests run no
# matter where bats is invoked from (`bats tests/unit/config.bats`
# from the repo root, or `cd tests && bats unit/config.bats`).
SRC_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
CONFIG_SH="${SRC_ROOT}/src/config.sh"

# UUID fixtures — distinct so we can prove the right one comes back
# from each getter and not, e.g., a copy of the previous answer.
UUID_TEAM="11111111-1111-1111-1111-111111111111"
UUID_PROJECT="22222222-2222-2222-2222-222222222222"
UUID_SPECIFYING="aaaaaaaa-0001-0000-0000-000000000001"
UUID_CLARIFYING="aaaaaaaa-0001-0000-0000-000000000002"
UUID_PLANNING="aaaaaaaa-0001-0000-0000-000000000003"
UUID_TASKING="aaaaaaaa-0001-0000-0000-000000000004"
UUID_RED_TEAM="aaaaaaaa-0001-0000-0000-000000000005"
UUID_IMPLEMENTING="aaaaaaaa-0001-0000-0000-000000000006"
UUID_ANALYZING="aaaaaaaa-0001-0000-0000-000000000007"
UUID_READY="aaaaaaaa-0001-0000-0000-000000000008"
UUID_MERGED="aaaaaaaa-0001-0000-0000-000000000009"
UUID_TODO="bbbbbbbb-0002-0000-0000-000000000001"
UUID_IN_PROGRESS="bbbbbbbb-0002-0000-0000-000000000002"
UUID_DONE="bbbbbbbb-0002-0000-0000-000000000003"

setup() {
    TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/speckit-config-XXXXXX")"
    VALID_YAML="${TEST_TMP}/linear-config.yml"
    write_valid_config "${VALID_YAML}"
}

teardown() {
    if [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]]; then
        rm -rf "${TEST_TMP}"
    fi
}

# write_valid_config <path>
# Drops a fully-populated linear-config.yml at <path>. Includes the
# optional default_state_uuids block so the post-analyze remediation
# getters are exercised on the happy path too.
write_valid_config() {
    local path="$1"
    cat > "${path}" <<EOF
schema_version: 1
config_version: 1

linear:
  workspace:
    name: "Test-Workspace"
    url_key: "test-workspace"
  team:
    id: "${UUID_TEAM}"
    key: "TST"
    name: "Test Team"
  project:
    id: "${UUID_PROJECT}"
    name: "test-project"
  workflow_state_uuids:
    specifying:     "${UUID_SPECIFYING}"
    clarifying:     "${UUID_CLARIFYING}"
    planning:       "${UUID_PLANNING}"
    tasking:        "${UUID_TASKING}"
    red_team:       "${UUID_RED_TEAM}"
    implementing:   "${UUID_IMPLEMENTING}"
    analyzing:      "${UUID_ANALYZING}"
    ready_to_merge: "${UUID_READY}"
    merged:         "${UUID_MERGED}"
  default_state_uuids:
    todo:        "${UUID_TODO}"
    in_progress: "${UUID_IN_PROGRESS}"
    done:        "${UUID_DONE}"

sync:
  enabled: true
  idle_window_days: 30
  emit_summary: true

webhook:
  installed: false
  workflow_path: ".github/workflows/speckit-linear-sync.yml"
  secret_name: "LINEAR_API_TOKEN"

git_hooks:
  installed: false
  hooks:
    - post-checkout
    - post-commit
    - post-merge
EOF
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

@test "config::load parses a valid file without error" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "config::get_team_id returns the team UUID" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_team_id"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_TEAM}" ]
}

@test "config::get_project_id returns the project UUID" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_project_id"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_PROJECT}" ]
}

@test "config::validate succeeds on a fully populated config" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::validate"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# ---------------------------------------------------------------------------
# Workflow-state lookup for every lifecycle phase
# ---------------------------------------------------------------------------

@test "config::get_workflow_state_uuid specifying" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid specifying"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_SPECIFYING}" ]
}

@test "config::get_workflow_state_uuid clarifying" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid clarifying"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_CLARIFYING}" ]
}

@test "config::get_workflow_state_uuid planning" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid planning"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_PLANNING}" ]
}

@test "config::get_workflow_state_uuid tasking" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid tasking"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_TASKING}" ]
}

@test "config::get_workflow_state_uuid red_team" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid red_team"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_RED_TEAM}" ]
}

@test "config::get_workflow_state_uuid implementing" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid implementing"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_IMPLEMENTING}" ]
}

@test "config::get_workflow_state_uuid analyzing" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid analyzing"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_ANALYZING}" ]
}

@test "config::get_workflow_state_uuid ready_to_merge" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid ready_to_merge"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_READY}" ]
}

@test "config::get_workflow_state_uuid merged" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid merged"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_MERGED}" ]
}

@test "config::get_workflow_state_uuid rejects an unknown phase" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_workflow_state_uuid bogus_phase"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown lifecycle phase: bogus_phase"* ]]
}

# ---------------------------------------------------------------------------
# Default-state lookup (post-analyze remediation: todo/in_progress/done)
# ---------------------------------------------------------------------------

@test "config::get_default_state_uuid todo" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_default_state_uuid todo"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_TODO}" ]
}

@test "config::get_default_state_uuid in_progress" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_default_state_uuid in_progress"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_IN_PROGRESS}" ]
}

@test "config::get_default_state_uuid done" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_default_state_uuid done"
    [ "${status}" -eq 0 ]
    [ "${output}" = "${UUID_DONE}" ]
}

@test "config::get_default_state_uuid rejects an unknown key" {
    run bash -c "source '${CONFIG_SH}'; config::load '${VALID_YAML}'; config::get_default_state_uuid blocked"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown default-state key: blocked"* ]]
}

# ---------------------------------------------------------------------------
# Missing file → exit 2, actionable message
# ---------------------------------------------------------------------------

@test "config::load on a missing file exits 2 with a clear 'file not found' message" {
    local missing="${TEST_TMP}/does-not-exist.yml"
    run bash -c "source '${CONFIG_SH}'; config::load '${missing}'"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"file not found"* ]]
    [[ "${output}" == *"${missing}"* ]]
    # Operator hint must point at the install command.
    [[ "${output}" == *"speckit-linear-install"* ]]
}

@test "config::load with zero arguments exits 2" {
    run bash -c "source '${CONFIG_SH}'; config::load"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"requires exactly one argument"* ]]
}

# ---------------------------------------------------------------------------
# Missing required field → validate names it
# ---------------------------------------------------------------------------

@test "config::validate flags a missing linear.team.id" {
    local broken="${TEST_TMP}/missing-team.yml"
    write_valid_config "${broken}"
    # Drop the team.id line entirely.
    grep -v '    id: "'"${UUID_TEAM}"'"' "${broken}" > "${broken}.tmp"
    mv "${broken}.tmp" "${broken}"

    run bash -c "source '${CONFIG_SH}'; config::load '${broken}'; config::validate"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"linear.team.id: missing"* ]]
    [[ "${output}" == *"${broken}"* ]]
}

@test "config::validate flags a missing workflow_state_uuids.merged" {
    local broken="${TEST_TMP}/missing-merged.yml"
    write_valid_config "${broken}"
    grep -v "merged:         \"${UUID_MERGED}\"" "${broken}" > "${broken}.tmp"
    mv "${broken}.tmp" "${broken}"

    run bash -c "source '${CONFIG_SH}'; config::load '${broken}'; config::validate"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"linear.workflow_state_uuids.merged: missing"* ]]
    [[ "${output}" == *"speckit-linear-seed"* ]]
}

@test "config::validate flags a missing schema_version" {
    local broken="${TEST_TMP}/missing-schema.yml"
    write_valid_config "${broken}"
    grep -v '^schema_version: 1' "${broken}" > "${broken}.tmp"
    mv "${broken}.tmp" "${broken}"

    run bash -c "source '${CONFIG_SH}'; config::load '${broken}'; config::validate"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"schema_version"* ]]
    [[ "${output}" == *"missing"* ]]
}

# ---------------------------------------------------------------------------
# Malformed UUID → validate flags it with file:field location
# ---------------------------------------------------------------------------

@test "config::validate flags a malformed team UUID with file:field location" {
    local broken="${TEST_TMP}/malformed-team.yml"
    write_valid_config "${broken}"
    sed -i.bak "s|${UUID_TEAM}|not-a-uuid|" "${broken}"
    rm -f "${broken}.bak"

    run bash -c "source '${CONFIG_SH}'; config::load '${broken}'; config::validate"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"${broken}: linear.team.id: malformed UUID"* ]]
    [[ "${output}" == *"'not-a-uuid'"* ]]
}

@test "config::validate flags a malformed workflow-state UUID" {
    local broken="${TEST_TMP}/malformed-wfs.yml"
    write_valid_config "${broken}"
    sed -i.bak "s|${UUID_PLANNING}|deadbeef|" "${broken}"
    rm -f "${broken}.bak"

    run bash -c "source '${CONFIG_SH}'; config::load '${broken}'; config::validate"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"${broken}: linear.workflow_state_uuids.planning: malformed UUID"* ]]
}

@test "config::validate flags the zero-placeholder UUID as unresolved" {
    local broken="${TEST_TMP}/zero-team.yml"
    write_valid_config "${broken}"
    sed -i.bak "s|${UUID_TEAM}|00000000-0000-0000-0000-000000000000|" "${broken}"
    rm -f "${broken}.bak"

    run bash -c "source '${CONFIG_SH}'; config::load '${broken}'; config::validate"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"linear.team.id"* ]]
    [[ "${output}" == *"zero placeholder"* ]]
}

# ---------------------------------------------------------------------------
# Default-state block: optional in aggregate, all-or-nothing in detail
# ---------------------------------------------------------------------------

@test "config::validate accepts a config without the default_state_uuids block" {
    local minus_defaults="${TEST_TMP}/no-defaults.yml"
    write_valid_config "${minus_defaults}"
    # Strip the default_state_uuids block and its three children.
    awk '
        /^  default_state_uuids:/ { in_block = 1; next }
        in_block && /^    / { next }
        { in_block = 0; print }
    ' "${minus_defaults}" > "${minus_defaults}.tmp"
    mv "${minus_defaults}.tmp" "${minus_defaults}"

    run bash -c "source '${CONFIG_SH}'; config::load '${minus_defaults}'; config::validate"
    [ "${status}" -eq 0 ]
}

@test "config::validate rejects a partial default_state_uuids block" {
    local partial="${TEST_TMP}/partial-defaults.yml"
    write_valid_config "${partial}"
    # Remove only the `done:` child; keep `todo:` and `in_progress:`.
    grep -v "done: " "${partial}" > "${partial}.tmp"
    mv "${partial}.tmp" "${partial}"

    run bash -c "source '${CONFIG_SH}'; config::load '${partial}'; config::validate"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"linear.default_state_uuids.done: missing"* ]]
}

# ---------------------------------------------------------------------------
# Getter guards
# ---------------------------------------------------------------------------

@test "getters refuse to run before config::load" {
    run bash -c "source '${CONFIG_SH}'; config::get_team_id"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"no config loaded"* ]]
}
