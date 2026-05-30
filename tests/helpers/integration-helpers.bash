# shellcheck shell=bash
# =============================================================================
# tests/helpers/integration-helpers.bash
#
# Shared scaffolding for the US1 reconcile integration tests
# (tests/integration/us1-*.bats).
#
# Each integration test mounts a hermetic sandbox that looks like a real
# consumer repo: a fresh git repo with `specs/NNN-feature/` populated
# from one of the existing fixtures, a populated
# `.specify/extensions/linear/linear-config.yml`, and a mocked Linear
# transport (curl shim) + a mocked `gh` (when PR-state is consulted).
#
# Reconcile-time the bridge talks to Linear exclusively via `src/graphql.sh`
# (which is a thin curl wrapper); intercepting `curl` is therefore the
# single chokepoint that gates every Linear write the reconciler can
# possibly issue. The shim:
#
#   * Always returns HTTP 200 with a canned response body chosen from
#     "state" files in $MOCK_LINEAR_STATE based on a content-based match
#     on the incoming GraphQL operation name OR a fallback default. This
#     lets a test stage `query:LocateSpecIssue` to return "no nodes" and
#     `mutation:IssueCreate` to echo a fresh UUID, without the test
#     having to predict the exact call order.
#
#   * Logs every request body verbatim into $MOCK_LINEAR_STATE/calls.log
#     (newline-delimited JSON, one line per call) and increments
#     $MOCK_LINEAR_STATE/call_count. Tests assert on the log to count
#     mutations and to fish out the GraphQL operation each call invoked.
#
#   * Classifies each call as `query:<name>` / `mutation:<name>` /
#     `unknown` by grepping the request payload for the first
#     `query OperationName(` / `mutation OperationName(` keyword. The
#     classification is appended into $MOCK_LINEAR_STATE/classified.log
#     (one line per call, plain text).
#
# Per-test rationale:
#
#   us1-fresh-reconcile.bats  — locate query returns ZERO nodes; every
#       subsequent save_issue is interpreted as a CREATE. Test counts
#       creates per fixture's task-phase / spec-issue / blocking-relation
#       expectations.
#
#   us1-idempotent-rerun.bats — locate query returns ONE node per
#       lookup; mutations are theoretically possible but the reconciler's
#       idempotency probe MUST skip them because the canned read
#       response matches the computed desired state. Assert zero
#       mutation calls.
#
#   us1-task-added.bats       — same canned state as idempotent-rerun
#       except the Phase-2 task-phase sub-issue's stored description
#       differs from the computed one (because we mutated tasks.md to
#       add a row). Assert exactly one mutation call, targeting the
#       Phase-2 sub-issue.
#
#   us1-clarify-mirror.bats   — locate query for spec Issue returns ONE
#       node (so reconcile resolves the parent); comments.startsWith
#       lookup returns ZERO nodes for each session marker (so all three
#       posts must fire). Assert three save_comment mutations in
#       chronological session-date order.
#
# What this helper does NOT do:
#
#   * It does NOT spawn a real HTTP server. The Linear mock is purely a
#     curl shim. This keeps the suite portable (no python3 dep, no port
#     contention, no teardown races).
#   * It does NOT stub the MCP path — the bridge's git-hook / on-demand
#     entry points all go through GraphQL (per
#     contracts/linear-graphql-mutations.md §1), so for US1 we only
#     intercept GraphQL.
#
# Integration tests gate on RUN_INTEGRATION_TESTS=1; the gating check
# itself happens inside each test file's setup() so the skip surfaces
# in bats output rather than at file-load time.
# =============================================================================

# Set once at load time; survives setup()'s cd's. PROJECT_ROOT is the
# bridge's own checkout, where src/ lives.
INTEGRATION_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${INTEGRATION_HELPERS_DIR}/../.." && pwd)"
export PROJECT_ROOT

# Fixture directory; tests copy from here into the sandbox.
FIXTURES_ROOT="${PROJECT_ROOT}/tests/fixtures/specs"
export FIXTURES_ROOT

# -----------------------------------------------------------------------------
# integration::skip_unless_enabled
#
# Gate the test on RUN_INTEGRATION_TESTS=1. Called as the first line of
# every test body. Uses bats' built-in `skip` so the test is reported
# as SKIPPED (not PASSED or FAILED) in CI output.
# -----------------------------------------------------------------------------
integration::skip_unless_enabled() {
    if [[ "${RUN_INTEGRATION_TESTS:-0}" != "1" ]]; then
        skip "integration tests require RUN_INTEGRATION_TESTS=1"
    fi
}

# -----------------------------------------------------------------------------
# integration::setup_sandbox <fixture_name>
#
# Build a hermetic consumer-repo sandbox at $SANDBOX_REPO with the
# given fixture spec mounted at specs/<fixture_name>/, the bridge's
# .specify/extensions/linear/linear-config.yml populated with valid
# UUIDs, and the working tree checked out on a branch named after the
# fixture (so the write-authority gate per FR-025 lets the reconciler
# write).
#
# Exports for the test body:
#   SANDBOX_REPO         — the consumer-repo working tree
#   MOCK_BIN             — directory placed first on PATH (curl + gh shims)
#   MOCK_LINEAR_STATE    — directory the curl shim reads canned responses
#                          from and writes call logs into
#   LINEAR_CONFIG_PATH   — absolute path to the populated config file
# -----------------------------------------------------------------------------
integration::setup_sandbox() {
    local fixture="$1"

    SANDBOX_REPO="${BATS_TEST_TMPDIR}/repo"
    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    MOCK_LINEAR_STATE="${BATS_TEST_TMPDIR}/mock-linear-state"
    LINEAR_CONFIG_PATH="${SANDBOX_REPO}/.specify/extensions/linear/linear-config.yml"

    mkdir -p "$SANDBOX_REPO" "$MOCK_BIN" "$MOCK_LINEAR_STATE"
    mkdir -p "${SANDBOX_REPO}/.specify/extensions/linear"
    mkdir -p "${SANDBOX_REPO}/specs"

    export SANDBOX_REPO MOCK_BIN MOCK_LINEAR_STATE LINEAR_CONFIG_PATH

    # Reset the per-test call counters so a previous test's residue can't
    # bleed into this one. (BATS_TEST_TMPDIR is fresh per-test, but be
    # explicit — easier to reason about.)
    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    # ---- git repo init: deterministic identity, no global-config bleed ----
    export GIT_AUTHOR_NAME='Integration Test'
    export GIT_AUTHOR_EMAIL='integration@example.com'
    export GIT_COMMITTER_NAME='Integration Test'
    export GIT_COMMITTER_EMAIL='integration@example.com'
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null

    git -C "$SANDBOX_REPO" init --initial-branch=main --quiet
    printf 'sandbox consumer repo\n' > "${SANDBOX_REPO}/README.md"
    git -C "$SANDBOX_REPO" add README.md
    git -C "$SANDBOX_REPO" commit --quiet -m 'initial commit'

    # ---- copy fixture into specs/<fixture>/ ----
    cp -R "${FIXTURES_ROOT}/${fixture}" "${SANDBOX_REPO}/specs/${fixture}"
    git -C "$SANDBOX_REPO" add "specs/${fixture}"
    git -C "$SANDBOX_REPO" commit --quiet -m "add ${fixture} fixture"

    # ---- check out a feature branch matching the spec NNN ----
    # The branch name MUST start with the fixture's leading NNN so
    # git_helpers::is_authoritative_for_spec returns true and reconcile
    # is permitted to write per FR-025.
    git -C "$SANDBOX_REPO" checkout --quiet -b "${fixture}"

    # ---- drop a valid linear-config.yml ----
    integration::_write_config_yaml > "$LINEAR_CONFIG_PATH"

    # ---- drop a .env so graphql.sh has a (fake) Linear key ----
    cat > "${SANDBOX_REPO}/.env" <<'ENV'
LINEAR_API_KEY=lin_api_integration_fake
ENV

    # ---- install the curl shim and PATH-prepend it ----
    integration::_install_curl_shim
    export PATH="${MOCK_BIN}:${PATH}"
}

# -----------------------------------------------------------------------------
# integration::_write_config_yaml
#
# Emit a minimal-but-valid linear-config.yml that satisfies
# src/config.sh's validation contract. All UUIDs are deterministic
# v4-shaped strings the tests can grep for if they need to confirm
# "the reconciler used the team/project UUID from config".
# -----------------------------------------------------------------------------
integration::_write_config_yaml() {
    cat <<'YAML'
schema_version: 1
config_version: 1

linear:
  workspace:
    name: "ACME"
    url_key: "acme"
  team:
    id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    key: "ACM"
    name: "ACME"
  project:
    id: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
    name: "spec-kit-linear-test"
  workflow_state_uuids:
    specifying:     "cccccccc-0001-4ccc-cccc-cccccccccccc"
    clarifying:     "cccccccc-0002-4ccc-cccc-cccccccccccc"
    planning:       "cccccccc-0003-4ccc-cccc-cccccccccccc"
    tasking:        "cccccccc-0004-4ccc-cccc-cccccccccccc"
    red_team:       "cccccccc-0005-4ccc-cccc-cccccccccccc"
    implementing:   "cccccccc-0006-4ccc-cccc-cccccccccccc"
    analyzing:      "cccccccc-0007-4ccc-cccc-cccccccccccc"
    ready_to_merge: "cccccccc-0008-4ccc-cccc-cccccccccccc"
    merged:         "cccccccc-0009-4ccc-cccc-cccccccccccc"
  default_state_uuids:
    todo:           "dddddddd-0001-4ddd-dddd-dddddddddddd"
    in_progress:    "dddddddd-0002-4ddd-dddd-dddddddddddd"
    done:           "dddddddd-0003-4ddd-dddd-dddddddddddd"

sync:
  enabled: true
  idle_window_days: 30
  emit_summary: true

webhook:
  installed: false
  workflow_path: ".github/workflows/spec-kit-linear-sync.yml"
  secret_name: "LINEAR_API_TOKEN"

git_hooks:
  installed: false
  hooks:
    - post-checkout
    - post-commit
    - post-merge
YAML
}

# -----------------------------------------------------------------------------
# integration::_install_curl_shim
#
# Write a curl replacement into $MOCK_BIN. The shim is content-aware: it
# scans the POST body for a GraphQL operation name and serves the
# matching canned response from $MOCK_LINEAR_STATE/responses/<key>.json
# (or falls back to default.json). Every call is logged.
# -----------------------------------------------------------------------------
integration::_install_curl_shim() {
    mkdir -p "${MOCK_LINEAR_STATE}/responses"

    cat > "${MOCK_BIN}/curl" <<'SHIM'
#!/usr/bin/env bash
# Mock curl for US1 integration tests. Returns canned responses from
# $MOCK_LINEAR_STATE/responses/<key>.json based on the GraphQL
# operation name in the request body. Logs every call.
set -euo pipefail

state="${MOCK_LINEAR_STATE:?MOCK_LINEAR_STATE is required}"
count_file="${state}/call_count"
calls_log="${state}/calls.log"
classified_log="${state}/classified.log"

# Bump the call counter (read-modify-write; fine for single-threaded tests).
count="$(cat "$count_file")"
count=$(( count + 1 ))
printf '%s' "$count" > "$count_file"

# Walk argv to extract:
#   * the request body — looking for either `-d @<file>`, `--data @<file>`,
#     `-d <inline>`, `--data <inline>`, or `--data-binary <inline>/@<file>`.
#   * the -D <path> header dump request (so graphql.sh's rate-limit
#     inspector sees an empty headers file rather than a missing one).
body=""
header_dump=""
prev=""
for arg in "$@"; do
    case "$prev" in
        -d|--data|--data-binary|--data-raw)
            if [[ "$arg" == @* ]]; then
                path="${arg#@}"
                if [[ -f "$path" ]]; then
                    body="$(cat "$path")"
                fi
            else
                body="$arg"
            fi
            ;;
        -D|--dump-header)
            header_dump="$arg"
            ;;
    esac
    prev="$arg"
done

# Empty header file so the caller's -D flag is honoured even on success.
if [[ -n "$header_dump" ]]; then
    : > "$header_dump"
fi

# ---- classify the call ----
# Find the first `query` or `mutation` keyword followed by an
# OperationName(... ). We grep the literal body string; the format
# graphql.sh sends is `{"query":"query OperationName($x:Y){...}", ...}`,
# so the operation name is the token after `query ` or `mutation `.
op_kind="unknown"
op_name=""
if [[ "$body" == *"\"query\":\"mutation "* ]]; then
    op_kind="mutation"
    rest="${body#*\"query\":\"mutation }"
    op_name="${rest%%[!a-zA-Z0-9_]*}"
elif [[ "$body" == *"\"query\":\"query "* ]]; then
    op_kind="query"
    rest="${body#*\"query\":\"query }"
    op_name="${rest%%[!a-zA-Z0-9_]*}"
elif [[ "$body" == *"mutation "* ]]; then
    op_kind="mutation"
    rest="${body#*mutation }"
    op_name="${rest%%[!a-zA-Z0-9_]*}"
elif [[ "$body" == *"query "* ]]; then
    op_kind="query"
    rest="${body#*query }"
    op_name="${rest%%[!a-zA-Z0-9_]*}"
fi

# Log raw body + classification for the test to assert on.
printf '%s\n' "$body" >> "$calls_log"
printf '%s:%s\n' "$op_kind" "$op_name" >> "$classified_log"

# ---- pick a canned response ----
# Resolution order:
#   1. responses/<op_kind>-<op_name>.json (most specific)
#   2. responses/<op_kind>.json           (kind-level fallback)
#   3. responses/default.json             (catch-all)
#   4. an empty `{"data":{}}` payload     (last resort — empty success)
response_file=""
for candidate in \
    "${state}/responses/${op_kind}-${op_name}.json" \
    "${state}/responses/${op_kind}.json" \
    "${state}/responses/default.json"; do
    if [[ -f "$candidate" ]]; then
        response_file="$candidate"
        break
    fi
done

if [[ -n "$response_file" ]]; then
    cat "$response_file"
else
    printf '%s' '{"data":{}}'
fi

# graphql.sh expects `-w '\n%{http_code}\n'` style suffix. Always serve 200.
printf '\n%s\n' "200"
SHIM
    chmod +x "${MOCK_BIN}/curl"
}

# -----------------------------------------------------------------------------
# integration::stage_response <key> <json_body>
#
# Stash a canned response payload under
# $MOCK_LINEAR_STATE/responses/<key>.json. The shim will serve it when
# the GraphQL operation name (e.g. `LocateSpecIssue`,
# `mutation-IssueCreate`) matches.
#
# Convenience key forms:
#   query-<OperationName>     — most specific
#   mutation-<OperationName>  — most specific
#   query                     — kind-level fallback
#   mutation                  — kind-level fallback
#   default                   — catch-all
# -----------------------------------------------------------------------------
integration::stage_response() {
    local key="$1"
    local body="$2"
    mkdir -p "${MOCK_LINEAR_STATE}/responses"
    printf '%s' "$body" > "${MOCK_LINEAR_STATE}/responses/${key}.json"
}

# -----------------------------------------------------------------------------
# integration::call_count
# integration::mutation_count
# integration::query_count
#
# Convenience counters read off classified.log.
# -----------------------------------------------------------------------------
integration::call_count() {
    cat "${MOCK_LINEAR_STATE}/call_count" 2>/dev/null || printf '0'
}

integration::mutation_count() {
    if [[ ! -f "${MOCK_LINEAR_STATE}/classified.log" ]]; then
        printf '0'
        return
    fi
    grep -c '^mutation:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null || printf '0'
}

integration::query_count() {
    if [[ ! -f "${MOCK_LINEAR_STATE}/classified.log" ]]; then
        printf '0'
        return
    fi
    grep -c '^query:' "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null || printf '0'
}

# integration::count_op <kind:name>
#   Count exact-match classifications (e.g. `mutation:IssueCreate`).
integration::count_op() {
    local needle="$1"
    if [[ ! -f "${MOCK_LINEAR_STATE}/classified.log" ]]; then
        printf '0'
        return
    fi
    grep -cF "$needle" "${MOCK_LINEAR_STATE}/classified.log" 2>/dev/null || printf '0'
}

# integration::calls_containing <substring>
#   Echo the count of request bodies containing the given substring.
#   Handy for "did the reconciler issue ANY mutation whose body
#   referenced the Phase 2 sub-issue UUID?".
integration::calls_containing() {
    local needle="$1"
    if [[ ! -f "${MOCK_LINEAR_STATE}/calls.log" ]]; then
        printf '0'
        return
    fi
    grep -cF "$needle" "${MOCK_LINEAR_STATE}/calls.log" 2>/dev/null || printf '0'
}

# integration::find_reconcile_sh
#   Echo the absolute path to src/reconcile.sh under PROJECT_ROOT. The
#   reconciler is implemented in parallel with these tests; if it does
#   not exist yet, the test will fail loudly when it tries to execute
#   the returned path — which is the intended contract enforcement.
integration::find_reconcile_sh() {
    printf '%s' "${PROJECT_ROOT}/src/reconcile.sh"
}

# integration::run_reconcile [args...]
#   Run the reconciler with the sandbox repo as cwd, with our PATH
#   override (curl + gh shims) active. Captures stdout, stderr, and
#   exit code into the bats `run` shape so tests can assert on
#   `$status` / `$output`.
#
# This helper expects the caller to use bats' `run` wrapper:
#
#     run integration::run_reconcile --spec 002
#
# That way `$status` / `$output` / `$lines` are populated as usual.
integration::run_reconcile() {
    local reconcile
    reconcile="$(integration::find_reconcile_sh)"
    (
        cd "$SANDBOX_REPO"
        # Pass the sandbox repo root via env in case the reconciler
        # wants to know it without re-deriving from pwd.
        export SPECKIT_LINEAR_CONFIG="$LINEAR_CONFIG_PATH"
        bash "$reconcile" "$@" 2>&1
    )
}

# integration::install_gh_shim_no_pr
#   Install a `gh` shim that always reports "no PR found" so the
#   reconciler's PR-state lookups return the git-only fallback path.
#   Used by US1 tests that aren't trying to exercise the merged-state
#   detection — they just want gh to be a no-op.
integration::install_gh_shim_no_pr() {
    cat > "${MOCK_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    auth)
        exit 0
        ;;
    pr)
        # `gh pr view` with no PR → exit 1, no JSON. graphql_helpers
        # interprets that as "no PR / not merged".
        echo "no pull requests found for branch" >&2
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "${MOCK_BIN}/gh"
}

# -----------------------------------------------------------------------------
# integration::find_install_sh
# integration::find_seed_sh
#
# Echo the absolute paths to `src/install.sh` and `src/seed.sh` under
# PROJECT_ROOT. Phase 4 / Phase 6 implementation lands in parallel with
# these tests; if a script does not yet exist, the test invocation will
# fail with exit 127 / "No such file" — that is the intended contract
# enforcement until the implementation agents land their changes.
# -----------------------------------------------------------------------------
integration::find_install_sh() {
    printf '%s' "${PROJECT_ROOT}/src/install.sh"
}

integration::find_seed_sh() {
    printf '%s' "${PROJECT_ROOT}/src/seed.sh"
}

# integration::run_install [args...]
#   Run the install script with the sandbox repo as cwd and our PATH
#   override (curl + gh shims) active. Captures stdout, stderr, and
#   exit code into the bats `run` shape so tests can assert on
#   `$status` / `$output`.
#
# Use as:
#     run integration::run_install --auto-create --team SANDBOX_TEAM
integration::run_install() {
    local install_sh
    install_sh="$(integration::find_install_sh)"
    (
        cd "$SANDBOX_REPO"
        export SPECKIT_LINEAR_CONFIG="$LINEAR_CONFIG_PATH"
        export SPECKIT_LINEAR_ROOT="$PROJECT_ROOT"
        bash "$install_sh" "$@" 2>&1
    )
}

# integration::run_seed [args...]
#   Run the seed script with the sandbox repo as cwd and the PATH
#   override active. The seed script reads `linear.team.id` from
#   `linear-config.yml` (the helper-emitted default uses
#   `aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa`), or honours an explicit
#   `--team <UUID>` flag.
integration::run_seed() {
    local seed_sh
    seed_sh="$(integration::find_seed_sh)"
    (
        cd "$SANDBOX_REPO"
        export SPECKIT_LINEAR_CONFIG="$LINEAR_CONFIG_PATH"
        export SPECKIT_LINEAR_ROOT="$PROJECT_ROOT"
        bash "$seed_sh" "$@" 2>&1
    )
}

# -----------------------------------------------------------------------------
# integration::setup_bare_sandbox
#
# Build a hermetic consumer-repo sandbox that does NOT yet have the
# bridge installed: no `.specify/extensions/linear/linear-config.yml`,
# no `.specify/extensions.yml`, no `.git/hooks/post-checkout` from the
# bridge. Used by US4 (install + seed ceremony) and by US2 install-test
# scenarios that need to exercise the install path itself.
#
# Exports SANDBOX_REPO / MOCK_BIN / MOCK_LINEAR_STATE / LINEAR_CONFIG_PATH
# identically to `setup_sandbox`, but does NOT drop the config file —
# `install.sh` is expected to create it.
# -----------------------------------------------------------------------------
integration::setup_bare_sandbox() {
    SANDBOX_REPO="${BATS_TEST_TMPDIR}/repo"
    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    MOCK_LINEAR_STATE="${BATS_TEST_TMPDIR}/mock-linear-state"
    LINEAR_CONFIG_PATH="${SANDBOX_REPO}/.specify/extensions/linear/linear-config.yml"

    mkdir -p "$SANDBOX_REPO" "$MOCK_BIN" "$MOCK_LINEAR_STATE"
    mkdir -p "${SANDBOX_REPO}/.specify/extensions/linear"
    mkdir -p "${SANDBOX_REPO}/specs"

    export SANDBOX_REPO MOCK_BIN MOCK_LINEAR_STATE LINEAR_CONFIG_PATH

    printf '0' > "${MOCK_LINEAR_STATE}/call_count"
    : > "${MOCK_LINEAR_STATE}/calls.log"
    : > "${MOCK_LINEAR_STATE}/classified.log"

    export GIT_AUTHOR_NAME='Integration Test'
    export GIT_AUTHOR_EMAIL='integration@example.com'
    export GIT_COMMITTER_NAME='Integration Test'
    export GIT_COMMITTER_EMAIL='integration@example.com'
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null

    git -C "$SANDBOX_REPO" init --initial-branch=main --quiet
    printf 'sandbox consumer repo\n' > "${SANDBOX_REPO}/README.md"
    git -C "$SANDBOX_REPO" add README.md
    git -C "$SANDBOX_REPO" commit --quiet -m 'initial commit'

    cat > "${SANDBOX_REPO}/.env" <<'ENV'
LINEAR_API_KEY=lin_api_integration_fake
ENV

    integration::_install_curl_shim
    export PATH="${MOCK_BIN}:${PATH}"
}

# -----------------------------------------------------------------------------
# integration::add_worktree <branch>
#
# Add a worktree under $BATS_TEST_TMPDIR/wt-<branch> tracking the named
# branch. Creates the branch from the current HEAD if it does not yet
# exist. Exports SANDBOX_WORKTREE_<UPPER> for the test body.
#
# Used by US2 multi-worktree scenarios (T036, T038). The branch name
# determines write-authority per FR-025.
# -----------------------------------------------------------------------------
integration::add_worktree() {
    local branch="$1"
    local wt_path="${BATS_TEST_TMPDIR}/wt-${branch}"

    if ! git -C "$SANDBOX_REPO" show-ref --verify --quiet "refs/heads/${branch}"; then
        git -C "$SANDBOX_REPO" branch --quiet "${branch}" HEAD
    fi
    git -C "$SANDBOX_REPO" worktree add --quiet "$wt_path" "$branch"

    local var_name="SANDBOX_WORKTREE_$(printf '%s' "$branch" | tr '[:lower:]-' '[:upper:]_')"
    export "${var_name}=${wt_path}"
}
