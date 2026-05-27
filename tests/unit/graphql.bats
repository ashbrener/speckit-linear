#!/usr/bin/env bats
# shellcheck shell=bats
#
# tests/unit/graphql.bats — unit tests for src/graphql.sh.
#
# =============================================================================
# Mock strategy
# =============================================================================
# We DO NOT make live Linear API calls. Instead each test prepares a private
# tempdir, drops a `curl` shim into it, and prepends that tempdir to PATH. The
# shim:
#
#   * Reads response bodies / status codes / response headers from numbered
#     files (response-1.body, response-1.code, response-1.headers, etc.).
#   * Tracks the call number in a counter file so the second invocation gets
#     response-2.* automatically. This is how we exercise the retry path —
#     response-1.code holds a 500, response-2.code a 200, the shim returns
#     each in sequence, and we assert the script saw both.
#   * Writes the body verbatim, then "\n<code>\n" to stdout exactly as real
#     curl does when invoked with `-w '\n%{http_code}\n'`. The shim does not
#     parse src/graphql.sh's curl arguments — it just plays back canned bytes.
#   * Honours the `-D <file>` flag by copying the canned headers file into the
#     header dump path so src/graphql.sh's rate-limit inspector has something
#     to read.
#
# This is portable (no python / no node / no actual HTTP server), keeps each
# test hermetic (private tempdir), and avoids the awkwardness of trying to
# speak GraphQL via `python -m http.server`.
# =============================================================================

setup() {
    # PROJECT_ROOT — resolve relative to this test file so the suite is
    # runnable from any cwd (bats invocations from CI vs. local differ).
    PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
    export PROJECT_ROOT

    # Each test gets its own ephemeral cwd. BATS_TEST_TMPDIR is auto-cleaned
    # by bats-core; we just chdir into it so any .env we create is scoped.
    TEST_TMP="${BATS_TEST_TMPDIR}/work"
    mkdir -p "$TEST_TMP"
    cd "$TEST_TMP"

    # Mock-curl bin lives alongside the test work dir so PATH manipulation is
    # straightforward. We DO NOT pollute /usr/local/bin or similar.
    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$MOCK_BIN"

    # The shim writes call-tracking data into MOCK_STATE. Tests stage canned
    # response files into MOCK_STATE before invoking the script under test.
    MOCK_STATE="${BATS_TEST_TMPDIR}/mock-state"
    mkdir -p "$MOCK_STATE"
    export MOCK_STATE

    # Always start the counter at 0 so the first call reads response-1.*.
    printf '0' > "${MOCK_STATE}/call_count"

    # Wipe LINEAR_API_KEY from the inherited env — individual tests opt-in via
    # either an exported key or a staged .env file.
    unset LINEAR_API_KEY

    # Point graphql.sh at a sentinel URL so any leak past the mock fails fast
    # with a connection error instead of silently hitting prod.
    export GRAPHQL_ENDPOINT_OVERRIDE="http://127.0.0.1:1/sentinel"

    # Speed retries up so tests don't sit on real sleeps.
    export GRAPHQL_RETRY_BACKOFF=0
}

teardown() {
    # bats-core auto-cleans BATS_TEST_TMPDIR; nothing else needs unwinding.
    :
}

# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------

# _setup_mock_curl
#
# Drop a `curl` shim onto PATH that reads canned responses from MOCK_STATE.
# Subsequent calls to `_stage_response N <body> <code> [headers]` populate
# response-N.* files; the shim serves them in order.
_setup_mock_curl() {
    cat > "${MOCK_BIN}/curl" <<'SHIM'
#!/usr/bin/env bash
# Mock curl for graphql.bats. Returns canned responses from $MOCK_STATE.
set -euo pipefail

state="${MOCK_STATE:?MOCK_STATE is required}"
count_file="${state}/call_count"
count="$(cat "$count_file")"
count=$(( count + 1 ))
printf '%s' "$count" > "$count_file"

# Allow the shim to fail the transport entirely when a sentinel file exists.
# Used by tests that want curl itself to exit non-zero.
if [[ -f "${state}/fail-call-${count}" ]]; then
    rc="$(cat "${state}/fail-call-${count}")"
    exit "$rc"
fi

body_file="${state}/response-${count}.body"
code_file="${state}/response-${count}.code"
headers_file="${state}/response-${count}.headers"

# Honour -D <path> by copying the canned headers (or an empty file) into the
# location graphql.sh expects. We walk argv to find -D and its argument.
header_dump=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-D" ]]; then
        header_dump="$arg"
    fi
    prev="$arg"
done

if [[ -n "$header_dump" ]]; then
    if [[ -f "$headers_file" ]]; then
        cp "$headers_file" "$header_dump"
    else
        : > "$header_dump"
    fi
fi

# Emit body verbatim followed by "\n<code>\n" to mimic `-w '\n%{http_code}\n'`.
if [[ -f "$body_file" ]]; then
    cat "$body_file"
fi
if [[ -f "$code_file" ]]; then
    printf '\n%s\n' "$(cat "$code_file")"
else
    printf '\n000\n'
fi
SHIM
    chmod +x "${MOCK_BIN}/curl"

    # Prepend mock dir so `curl` resolves to the shim first.
    export PATH="${MOCK_BIN}:${PATH}"
}

# _stage_response <call_number> <body> <code> [headers_blob]
_stage_response() {
    local n="$1"
    local body="$2"
    local code="$3"
    local headers="${4:-}"
    printf '%s' "$body" > "${MOCK_STATE}/response-${n}.body"
    printf '%s' "$code" > "${MOCK_STATE}/response-${n}.code"
    if [[ -n "$headers" ]]; then
        printf '%s\n' "$headers" > "${MOCK_STATE}/response-${n}.headers"
    fi
}

# _call_count — convenience read of how many times the mock was invoked.
_call_count() {
    cat "${MOCK_STATE}/call_count"
}

# _source_graphql — source the script under test in a way that survives
# `set -euo pipefail` in graphql.sh without bailing the test runner. The
# script is shellcheck-clean and our tests invoke its public functions inside
# `run`, which catches the exit codes we assert on.
_source_graphql() {
    # shellcheck source=src/graphql.sh
    source "${PROJECT_ROOT}/src/graphql.sh"
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

@test "happy path: 200 response is returned verbatim on stdout" {
    _setup_mock_curl
    _stage_response 1 '{"data":{"workflowStates":{"nodes":[{"id":"abc","name":"Specifying"}]}}}' 200
    export LINEAR_API_KEY="lin_api_fake_happy"

    _source_graphql
    run graphql::query 'query { workflowStates { nodes { id name } } }' '{}'

    [ "$status" -eq 0 ]
    # Body is returned exactly as Linear sent it (less the trailing newline
    # the wire format appends after %{http_code}).
    [[ "$output" == *'"workflowStates"'* ]]
    [[ "$output" == *'"Specifying"'* ]]
    # Exactly one curl invocation — no retry on a clean 200.
    [ "$(_call_count)" -eq 1 ]
}

@test "happy path: graphql::mutate succeeds the same way as ::query" {
    _setup_mock_curl
    _stage_response 1 '{"data":{"issueUpdate":{"success":true}}}' 200
    export LINEAR_API_KEY="lin_api_fake_mutate"

    _source_graphql
    run graphql::mutate \
        'mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }' \
        '{"id":"abc","input":{"stateId":"def"}}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'"success":true'* ]]
}

@test "auth failure: missing LINEAR_API_KEY exits 2 with a key-missing message" {
    _setup_mock_curl
    # No LINEAR_API_KEY exported, no .env present.

    _source_graphql
    run graphql::query 'query { __typename }' '{}'

    [ "$status" -eq 2 ]
    [[ "$output" == *"LINEAR_API_KEY is not set"* ]]
    # Mock curl must NEVER have been invoked — the key check fires first.
    [ "$(_call_count)" -eq 0 ]
}

@test "auth failure: HTTP 401 exits 2 with an auth-failed message and no retry" {
    _setup_mock_curl
    _stage_response 1 '{"errors":[{"message":"Authentication required"}]}' 401
    export LINEAR_API_KEY="lin_api_fake_bad"

    _source_graphql
    run graphql::query 'query { viewer { id } }' '{}'

    [ "$status" -eq 2 ]
    [[ "$output" == *"Linear auth failed"* ]]
    [[ "$output" == *"401"* ]]
    # Auth errors are non-retryable — exactly one curl call.
    [ "$(_call_count)" -eq 1 ]
}

@test "server error: HTTP 500 retries once then exits 3 when both attempts fail" {
    _setup_mock_curl
    _stage_response 1 '{"error":"internal"}' 500
    _stage_response 2 '{"error":"still internal"}' 500
    export LINEAR_API_KEY="lin_api_fake_5xx"

    _source_graphql
    run graphql::query 'query { __typename }' '{}'

    [ "$status" -eq 3 ]
    [[ "$output" == *"500"* ]]
    # Exactly two attempts — one initial + one retry.
    [ "$(_call_count)" -eq 2 ]
}

@test "server error: HTTP 500 then 200 succeeds via the single retry" {
    _setup_mock_curl
    _stage_response 1 '{"error":"transient"}' 500
    _stage_response 2 '{"data":{"viewer":{"id":"user-1"}}}' 200
    export LINEAR_API_KEY="lin_api_fake_recovers"

    _source_graphql
    run graphql::query 'query { viewer { id } }' '{}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'"user-1"'* ]]
    [ "$(_call_count)" -eq 2 ]
}

@test "graphql errors: HTTP 200 with errors[] populated exits 4 and lists them" {
    _setup_mock_curl
    _stage_response 1 \
        '{"data":null,"errors":[{"message":"Unknown field foo"},{"message":"Variable bar required"}]}' \
        200
    export LINEAR_API_KEY="lin_api_fake_graphql_errs"

    _source_graphql
    run graphql::mutate 'mutation { foo }' '{}'

    [ "$status" -eq 4 ]
    [[ "$output" == *"GraphQL errors"* ]]
    [[ "$output" == *"Unknown field foo"* ]]
    [[ "$output" == *"Variable bar required"* ]]
    # Errors-in-body are not retried — exactly one call.
    [ "$(_call_count)" -eq 1 ]
}

@test "graphql success: 200 with empty errors[] is still treated as success" {
    # Linear sometimes returns `errors: []` on a successful payload (the field
    # is present but empty). We must not exit 4 in that case.
    _setup_mock_curl
    _stage_response 1 '{"data":{"viewer":{"id":"u"}},"errors":[]}' 200
    export LINEAR_API_KEY="lin_api_fake_empty_errs"

    _source_graphql
    run graphql::query 'query { viewer { id } }' '{}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'"u"'* ]]
}

@test "rate limit: low Remaining triggers a warn on stderr but does not fail" {
    _setup_mock_curl
    # 5 remaining out of 1000 = 0.5%, well under the 10% threshold.
    _stage_response 1 \
        '{"data":{"viewer":{"id":"u"}}}' \
        200 \
        $'X-RateLimit-Requests-Remaining: 5\nX-RateLimit-Requests-Limit: 1000'
    export LINEAR_API_KEY="lin_api_fake_ratelimit"

    _source_graphql
    run graphql::query 'query { viewer { id } }' '{}'

    [ "$status" -eq 0 ]
    [[ "$output" == *"rate limit"* ]]
    [[ "$output" == *"5/1000"* ]]
}

@test ".env loading: LINEAR_API_KEY in .env file is picked up when env unset" {
    _setup_mock_curl
    _stage_response 1 '{"data":{"viewer":{"id":"u"}}}' 200

    # Write a .env in the current test working dir (set by setup()).
    cat > .env <<'ENV'
LINEAR_API_KEY=lin_api_from_dotenv
ENV

    _source_graphql
    run graphql::query 'query { viewer { id } }' '{}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'"u"'* ]]
}

@test "argument validation: malformed variables JSON exits 2 before any HTTP call" {
    _setup_mock_curl
    export LINEAR_API_KEY="lin_api_fake_valid_key"

    _source_graphql
    run graphql::query 'query { __typename }' 'not-json{'

    [ "$status" -eq 2 ]
    [[ "$output" == *"not valid JSON"* ]]
    # No HTTP call should have been made — argument validation gates the
    # transport layer.
    [ "$(_call_count)" -eq 0 ]
}
