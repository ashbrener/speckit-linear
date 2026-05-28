#!/usr/bin/env bats
# shellcheck shell=bats
#
# tests/integration/install_e2e_discovery.bats — spec 002 US1 + US3
# end-to-end integration tests against a LIVE Linear workspace.
#
# Gating: this file is gated on `RUN_INTEGRATION_TESTS=1` AND a valid
# `LINEAR_API_KEY`. Without both, every `@test` block early-skips.
# Matches the spec 001 `tests/integration/*.bats` convention so the
# CI matrix's `RUN_INTEGRATION_TESTS=1` row picks it up automatically
# (per T202 audit).
#
# Phase 3 status: scaffold + one US1 smoke-test placeholder gated for
# the live-network row. Phase 5 (T252..T254) layers FR-046 / FR-047 /
# FR-049 safety-guard integration tests on top of this file.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
    export PROJECT_ROOT
    TEST_TMP="${BATS_TEST_TMPDIR}/work"
    mkdir -p "$TEST_TMP"
    cd "$TEST_TMP"
}

teardown() {
    :
}

@test "US1 e2e: live discovery flow resolves team + project via Linear (FR-037..FR-043)" {
    if [[ "${RUN_INTEGRATION_TESTS:-0}" != "1" ]]; then
        skip "RUN_INTEGRATION_TESTS != 1 — gated integration test"
    fi
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        skip "LINEAR_API_KEY missing — integration test requires a live key"
    fi
    # T231 wires this against the OSH-INFRA workspace. The Phase 3 commit
    # lands the scaffold; the full piped-stdin operator-pick simulation
    # lands alongside the T269 dogfood-002 harness (Phase 6).
    skip "T231 live integration body lands with T269 dogfood-002 harness"
}

# =============================================================================
# Phase 5 — User Story 3 (docs + safety guards) integration tests.
#
# T252 — SC-012 README walkthrough. Exercises the exact `specify
#        extension add --from <archive-zip-URL>` command documented in
#        README's Install section (per FR-047). Skipped without the
#        `specify` CLI on PATH (RUN_INTEGRATION_TESTS-gated).
#
# T253 — FR-046 self-install guard end-to-end. Invokes
#        `bash src/install.sh --dev <bridge-source-path>` from inside
#        the bridge's own checkout (target == source), asserts exit 2
#        with the verbatim FR-046 message from install-flags.md §4 and
#        zero filesystem mutations under
#        `.specify/extensions/linear/`. Runs at every push — no
#        live-network access — so it does NOT require
#        RUN_INTEGRATION_TESTS=1.
#
# T254 — FR-049 vendored `.git/` warning end-to-end. Runs `--dev`
#        install from a SEPARATE consumer sandbox where the source has
#        a vendored `.git/` under `.specify/extensions/linear/`;
#        asserts the FR-049 warning surfaces in the dependency report
#        and the summary's "next steps" block. Likewise runs at every
#        push (fixture-driven; no live Linear calls).
# =============================================================================

@test "T252: SC-012 README walkthrough — specify extension add --from <archive-zip-URL> succeeds (no BadZipFile)" {
    if [[ "${RUN_INTEGRATION_TESTS:-0}" != "1" ]]; then
        skip "RUN_INTEGRATION_TESTS != 1 — gated integration test (downloads the public archive)"
    fi
    if ! command -v specify >/dev/null 2>&1; then
        skip "specify CLI not on PATH — README walkthrough requires the spec-kit CLI"
    fi

    # Sandbox consumer repo, separate from the bridge's checkout (A12).
    local sandbox="${BATS_TEST_TMPDIR}/sandbox-consumer"
    mkdir -p "$sandbox"
    git init --quiet "$sandbox" >/dev/null
    git -C "$sandbox" commit --quiet --allow-empty -m "bootstrap" >/dev/null

    # Exact archive-URL form from README's Install section (FR-047).
    local archive_url="https://github.com/ashbrener/spec-kit-linear/archive/refs/heads/main.zip"

    pushd "$sandbox" >/dev/null
    run specify extension add linear --from "$archive_url"
    popd >/dev/null

    [ "$status" -eq 0 ]
    # The previously-broken `--from <repo-url>` form errored with
    # `BadZipFile`; the archive-zip form must NOT.
    [[ ! "$output" == *"BadZipFile"* ]]
}

@test "T253: FR-046 self-install guard halts with exit 2 + zero mutations when source == target" {
    # Sandbox is a CLONE of the bridge's own checkout — running install
    # against itself simulates the `--dev <bridge-source-path>` case
    # from inside the bridge tree.
    local sandbox="${BATS_TEST_TMPDIR}/self-install-target"
    cp -R "${PROJECT_ROOT}" "$sandbox"

    # Snapshot the target's install-managed directory state BEFORE the
    # halt fires so we can prove zero writes happened.
    local config_dir="${sandbox}/.specify/extensions/linear"
    local config_path="${config_dir}/linear-config.yml"
    local extensions_yml="${sandbox}/.specify/extensions.yml"

    local pre_config_exists="no"
    local pre_config_sha="absent"
    if [[ -f "$config_path" ]]; then
        pre_config_exists="yes"
        pre_config_sha="$(shasum -a 256 "$config_path" | awk '{print $1}')"
    fi
    local pre_extensions_sha="absent"
    if [[ -f "$extensions_yml" ]]; then
        pre_extensions_sha="$(shasum -a 256 "$extensions_yml" | awk '{print $1}')"
    fi

    # Invoke install from inside the sandbox so cwd == sandbox.
    # `--dev` keeps install pointed at this same source tree (S0 sees
    # source == target).
    pushd "$sandbox" >/dev/null
    run bash "${sandbox}/src/install.sh" --dev
    popd >/dev/null

    # Verbatim FR-046 surface from install-flags.md §4.
    [ "$status" -eq 2 ]
    [[ "$output" == *"source path equals target path"* ]]
    [[ "$output" == *"FR-046"* ]]

    # Zero filesystem mutations under the target — the guard must fire
    # BEFORE any write attempt.
    local post_config_exists="no"
    local post_config_sha="absent"
    if [[ -f "$config_path" ]]; then
        post_config_exists="yes"
        post_config_sha="$(shasum -a 256 "$config_path" | awk '{print $1}')"
    fi
    local post_extensions_sha="absent"
    if [[ -f "$extensions_yml" ]]; then
        post_extensions_sha="$(shasum -a 256 "$extensions_yml" | awk '{print $1}')"
    fi
    [ "$pre_config_exists" = "$post_config_exists" ]
    [ "$pre_config_sha" = "$post_config_sha" ]
    [ "$pre_extensions_sha" = "$post_extensions_sha" ]
}

@test "T254: FR-049 vendored .git/ warning surfaces in dependency report when source carries .git/" {
    # Run `--dev` install from a sandbox SOURCE that carries a
    # vendored `.git/` under `.specify/extensions/linear/` (the
    # CLI-vendoring footgun FR-049 catches) into a DIFFERENT
    # consumer-sandbox target. The dependency report MUST surface the
    # FR-049 warning row; the install summary's next-steps block MUST
    # carry the matching remediation per install-prompts.md §7.
    local source_sandbox="${BATS_TEST_TMPDIR}/vendored-source"
    cp -R "${PROJECT_ROOT}" "$source_sandbox"
    # Vendor a `.git/` under the bridge's own checkout — simulates the
    # spec-kit-CLI `--dev` vendoring path.
    mkdir -p "${source_sandbox}/.specify/extensions/linear/.git"
    touch "${source_sandbox}/.specify/extensions/linear/.git/HEAD"

    # Distinct consumer-sandbox target so the FR-046 guard does NOT
    # short-circuit before we reach the dependency report.
    local target_sandbox="${BATS_TEST_TMPDIR}/vendored-target"
    mkdir -p "$target_sandbox"
    git init --quiet "$target_sandbox" >/dev/null
    git -C "$target_sandbox" commit --quiet --allow-empty -m "bootstrap" >/dev/null

    # Run install from the source — the dependency report should
    # surface the FR-049 warning row. We pass fake-but-UUID-shaped
    # `--team` + `--project` + `--non-interactive` so `parse_args`
    # accepts the invocation and the run reaches
    # `install::run_dependency_report` (where T259 wires the FR-049
    # check). The downstream GraphQL `quick_validate_binding` call
    # will fail against the fake UUIDs — that's fine; the FR-049
    # warning fires before that point and remains in `$output`.
    pushd "$target_sandbox" >/dev/null
    run bash "${source_sandbox}/src/install.sh" \
        --dev \
        --team "00000000-0000-4000-8000-000000000001" \
        --project "00000000-0000-4000-8000-000000000002" \
        --non-interactive
    popd >/dev/null

    # The dependency-report row must surface the vendored-`.git/`
    # warning with FR-049 + the rm -rf remediation path.
    [[ "$output" == *"FR-049"* ]]
    [[ "$output" == *".specify/extensions/linear/.git"* ]]
    [[ "$output" == *"rm -rf"* ]]
}
