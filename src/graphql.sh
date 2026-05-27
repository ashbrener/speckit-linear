#!/usr/bin/env bash
# shellcheck shell=bash
#
# src/graphql.sh — thin Linear GraphQL client (curl + jq).
#
# =============================================================================
# KEYS-AT-THE-EDGES BOUNDARY (constitution Principle VI)
# =============================================================================
# This script is the ONLY component in the bridge that touches the operator's
# Linear API key. Every other src/*.sh file MUST route GraphQL traffic through
# the public functions exported here so the key never escapes this module.
#
#   - Interactive AI-invoked paths use the Linear MCP via OAuth and never
#     load LINEAR_API_KEY at all.
#   - Direct-GraphQL paths (git hooks, the seed step, the GitHub Action) call
#     graphql::query / graphql::mutate, which read LINEAR_API_KEY from .env
#     (or the existing environment) exactly once per invocation and pass it as
#     the Authorization header.
#
# Per Linear's GraphQL docs (and confirmed in
# validation/github-action-mechanics.md §2) personal API keys are sent BARE on
# the Authorization header — there is NO `Bearer` prefix.
#
# =============================================================================
# CONTRACT
# =============================================================================
# Public surface:
#
#   graphql::query  <query_string>    <variables_json>
#   graphql::mutate <mutation_string> <variables_json>
#
# Both return the full Linear response JSON (the `{ "data": {...} }` envelope)
# on stdout. Errors are surfaced as structured messages on stderr (per
# constitution Principle VIII — observable failure) and the script exits with
# a non-zero status:
#
#   exit 2 — auth / config failure (missing LINEAR_API_KEY, HTTP 401/403)
#   exit 3 — transport failure (HTTP 5xx after one retry, or curl failure)
#   exit 4 — GraphQL-level failure (HTTP 200 with errors[] populated)
#
# Rate-limit handling:
#   Linear publishes per-endpoint rate-limit headers
#   (X-RateLimit-Requests-Remaining / X-RateLimit-Requests-Limit, and the
#   complexity equivalents). When Remaining drops below 10% of Limit we emit a
#   structured warning to stderr; the bridge's reconciler aggregates these into
#   the per-run summary. We deliberately do NOT pause here — the caller owns
#   throttling policy (see contracts/linear-graphql-mutations.md §7.2).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Module constants
# ---------------------------------------------------------------------------

# Linear's GraphQL endpoint. Hardcoded — there is exactly one URL and pinning
# it here keeps the test harness from accidentally hitting production.
readonly GRAPHQL_ENDPOINT="${GRAPHQL_ENDPOINT_OVERRIDE:-https://api.linear.app/graphql}"

# Single retry with a fixed 1-second backoff matches the contract
# (linear-graphql-mutations.md §4.1 — "retry once with 2s backoff" for spec
# Issues, §2.1 — "retry once with 2s backoff" for seed). 1s is sufficient for
# transient 5xx and keeps the local-hook wall-clock under FR-targeted 2s.
readonly RETRY_BACKOFF_SECONDS="${GRAPHQL_RETRY_BACKOFF:-1}"

# Threshold at which the rate-limit warning fires, expressed as the
# Remaining/Limit ratio × 100. Linear's docs flag 10% as the canonical
# self-throttle line (contracts/linear-graphql-mutations.md §7.2).
readonly RATE_LIMIT_WARN_PERCENT="${GRAPHQL_RATE_LIMIT_WARN_PERCENT:-10}"

# Curl path is configurable so unit tests can shim a mock binary onto PATH.
readonly CURL_BIN="${GRAPHQL_CURL_BIN:-curl}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# graphql::_log_error <message...>
#
# Emit a structured single-line error to stderr. The "speckit-linear: graphql"
# prefix lets log aggregators filter cleanly and matches the marker convention
# used by save_comment bodies (contracts/linear-graphql-mutations.md §4.5).
graphql::_log_error() {
    printf 'speckit-linear: graphql ERROR %s\n' "$*" >&2
}

# graphql::_log_warn <message...>
graphql::_log_warn() {
    printf 'speckit-linear: graphql WARN  %s\n' "$*" >&2
}

# graphql::_load_api_key
#
# Resolve LINEAR_API_KEY. Precedence:
#   1. Existing environment variable (set by CI / the GitHub Action).
#   2. .env file in the current working directory (the local dev path).
#
# The .env load is scoped — we toggle `set -a` only for the duration of the
# `source` so unrelated variables from .env don't leak into the calling
# environment. Sourcing .env in a subshell wouldn't work because the export has
# to land in *this* process.
#
# Exits 2 if no key can be resolved (constitution Principle VIII — never fail
# silently; surface the exact remediation).
graphql::_load_api_key() {
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        return 0
    fi

    if [[ -f .env ]]; then
        # .env is consumer-supplied and not statically analysable;
        # SC1091 below acknowledges shellcheck cannot follow the source.
        set -a
        # shellcheck disable=SC1091
        source .env
        set +a
    fi

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        graphql::_log_error \
            "LINEAR_API_KEY is not set. Add it to .env or export it before running. See .env.example for guidance."
        exit 2
    fi
}

# graphql::_check_rate_limit <header_file>
#
# Inspect the response header file written by curl's -D flag and emit a warn
# when Remaining drops below RATE_LIMIT_WARN_PERCENT% of Limit. Linear exposes
# two relevant pairs:
#
#   X-RateLimit-Requests-Remaining / X-RateLimit-Requests-Limit
#   X-RateLimit-Complexity-Remaining / X-RateLimit-Complexity-Limit
#
# We check both, since either can throttle the bridge first. Silent on the
# happy path.
graphql::_check_rate_limit() {
    local header_file="$1"
    local pair
    for pair in "Requests" "Complexity"; do
        local remaining_header limit_header remaining limit
        remaining_header="X-RateLimit-${pair}-Remaining"
        limit_header="X-RateLimit-${pair}-Limit"

        # Headers are case-insensitive on the wire; Linear ships them in
        # canonical Title-Case form but we grep case-insensitively to be safe.
        # `awk` strips the "Header: " prefix and any trailing CR.
        remaining="$(
            grep -i "^${remaining_header}:" "$header_file" 2>/dev/null \
                | awk -F': ' '{ sub(/\r$/, "", $2); print $2 }' \
                | tail -n1
        )"
        limit="$(
            grep -i "^${limit_header}:" "$header_file" 2>/dev/null \
                | awk -F': ' '{ sub(/\r$/, "", $2); print $2 }' \
                | tail -n1
        )"

        # Skip if headers absent (older responses, mock servers, etc.).
        if [[ -z "$remaining" || -z "$limit" ]]; then
            continue
        fi
        # Skip if either value isn't a positive integer — defensive parse.
        if ! [[ "$remaining" =~ ^[0-9]+$ ]] || ! [[ "$limit" =~ ^[0-9]+$ ]]; then
            continue
        fi
        if (( limit == 0 )); then
            continue
        fi

        # Integer math only — avoid bc/awk dependencies for a hot path.
        # remaining * 100 / limit < threshold  ⇔  remaining < limit * threshold / 100
        local threshold_units
        threshold_units=$(( limit * RATE_LIMIT_WARN_PERCENT / 100 ))
        if (( remaining < threshold_units )); then
            graphql::_log_warn \
                "Linear ${pair} rate limit at ${remaining}/${limit} (<${RATE_LIMIT_WARN_PERCENT}%). Self-throttle imminent."
        fi
    done
}

# graphql::_post <body_json> <header_out_file>
#
# Single HTTP POST. Writes the response headers to <header_out_file>, prints
# the response body followed by a single line containing the HTTP status code
# to stdout. Returns curl's exit code; the caller distinguishes transport
# failure from HTTP failure by inspecting the trailing status line.
#
# Why -sS + manual status capture instead of --fail-with-body: --fail-with-body
# requires curl 7.76+ which is not on every operator's machine (older macOS
# system curls in particular). Capturing %{http_code} after the body is
# universally portable.
graphql::_post() {
    local body_json="$1"
    local header_out="$2"

    # -s   silent (no progress bar)
    # -S   but still show errors on stderr
    # -X POST
    # -D   dump response headers (rate-limit inspection)
    # -w   append HTTP status code on its own line after the body
    # --max-time   hard ceiling so a hung Linear can't hang the operator's
    #              git hook beyond the FR-targeted 2s. 30s is a generous
    #              ceiling that still respects local-hook latency budgets.
    "$CURL_BIN" \
        -sS \
        -X POST \
        -D "$header_out" \
        --max-time 30 \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data "$body_json" \
        -w '\n%{http_code}\n' \
        "$GRAPHQL_ENDPOINT"
}

# graphql::_request <operation_json>
#
# Core transport. Takes a JSON object containing { query, variables } and
# returns the response body on stdout. Handles:
#   * Auth (loads LINEAR_API_KEY)
#   * Single retry on 5xx with RETRY_BACKOFF_SECONDS backoff
#   * Exit-code mapping per the module contract above
#   * Rate-limit warning surface
#   * GraphQL `errors[]` detection on 200 responses
#
# The query/mutation distinction is purely semantic to the caller — Linear's
# wire protocol is identical for both, so they share this function.
graphql::_request() {
    local operation_json="$1"

    graphql::_load_api_key

    local header_file response_raw body status_code attempt max_attempts
    header_file="$(mktemp -t speckit-linear-graphql.XXXXXX)"
    # Always clean up the header tempfile, even on error/exit.
    # shellcheck disable=SC2064
    # Expand $header_file now (at trap-install time) — we want THIS file,
    # not whatever $header_file happens to be when the trap fires.
    trap "rm -f '${header_file}'" RETURN

    max_attempts=2
    attempt=1
    while (( attempt <= max_attempts )); do
        # Capture combined body + status-code line. The curl invocation will
        # always succeed at the shell level (no `set -e` abort) because we
        # capture its exit status separately.
        local curl_rc=0
        response_raw="$(graphql::_post "$operation_json" "$header_file")" || curl_rc=$?

        if (( curl_rc != 0 )); then
            # Curl transport failure (network, DNS, timeout). Retry once then
            # give up — same backoff cadence as 5xx.
            if (( attempt < max_attempts )); then
                graphql::_log_warn \
                    "curl transport failure (rc=${curl_rc}); retrying in ${RETRY_BACKOFF_SECONDS}s"
                sleep "$RETRY_BACKOFF_SECONDS"
                attempt=$(( attempt + 1 ))
                continue
            fi
            graphql::_log_error \
                "curl transport failure (rc=${curl_rc}) after ${max_attempts} attempts; giving up"
            exit 3
        fi

        # Split the trailing "\nHTTP_CODE\n" off the body. The body itself may
        # contain newlines so we work from the tail backwards.
        # The format from `-w '\n%{http_code}\n'` produces:
        #   <body>\n<code>\n
        status_code="$(printf '%s' "$response_raw" | tail -n1)"
        body="$(printf '%s' "$response_raw" | sed '$d')"

        # Defensive: if status_code isn't a 3-digit number, treat as transport
        # failure so the caller doesn't get a misleading error class.
        if ! [[ "$status_code" =~ ^[0-9]{3}$ ]]; then
            if (( attempt < max_attempts )); then
                graphql::_log_warn \
                    "Unparseable HTTP status from Linear (got '${status_code}'); retrying"
                sleep "$RETRY_BACKOFF_SECONDS"
                attempt=$(( attempt + 1 ))
                continue
            fi
            graphql::_log_error \
                "Unparseable HTTP status from Linear after ${max_attempts} attempts; giving up"
            exit 3
        fi

        graphql::_check_rate_limit "$header_file"

        case "$status_code" in
            2*)
                # 2xx — body should be valid JSON; check for GraphQL errors[].
                # `jq -e` returns non-zero when the filter yields false/null,
                # which lets us cheaply test for errors[] presence.
                if printf '%s' "$body" | jq -e '.errors and (.errors | length > 0)' >/dev/null 2>&1; then
                    local errors_pretty
                    errors_pretty="$(printf '%s' "$body" | jq -c '.errors')"
                    graphql::_log_error "Linear returned GraphQL errors: ${errors_pretty}"
                    exit 4
                fi
                printf '%s' "$body"
                return 0
                ;;
            401|403)
                # Authentication / authorization. Don't retry — the key is
                # either wrong, revoked, or lacks scope; retry won't help.
                local err_summary
                err_summary="$(printf '%s' "$body" | jq -r '.errors[0].message? // .message? // "<no error message in body>"' 2>/dev/null || printf '%s' "$body")"
                graphql::_log_error \
                    "Linear auth failed (HTTP ${status_code}): ${err_summary}. Check LINEAR_API_KEY scope or rotate the key."
                exit 2
                ;;
            4*)
                # Other 4xx — bad request, validation, rate-limited (400+code).
                # Don't retry; the input is the problem.
                local err_summary
                err_summary="$(printf '%s' "$body" | jq -r '.errors[0].message? // .message? // "<no error message in body>"' 2>/dev/null || printf '%s' "$body")"
                graphql::_log_error \
                    "Linear rejected the request (HTTP ${status_code}): ${err_summary}"
                exit 2
                ;;
            5*)
                # Server-side failure. Retry once.
                if (( attempt < max_attempts )); then
                    graphql::_log_warn \
                        "Linear returned HTTP ${status_code}; retrying in ${RETRY_BACKOFF_SECONDS}s"
                    sleep "$RETRY_BACKOFF_SECONDS"
                    attempt=$(( attempt + 1 ))
                    continue
                fi
                graphql::_log_error \
                    "Linear returned HTTP ${status_code} after ${max_attempts} attempts; giving up"
                exit 3
                ;;
            *)
                # Unexpected status (1xx/3xx) — treat as transport.
                graphql::_log_error \
                    "Unexpected HTTP status from Linear: ${status_code}"
                exit 3
                ;;
        esac
    done

    # Unreachable — every branch in the loop either returns, exits, or
    # continues. This line exists so a future edit doesn't accidentally fall
    # off the end of the function with an undefined status.
    graphql::_log_error "graphql::_request fell through the retry loop (bug)"
    exit 3
}

# graphql::_build_operation <operation_string> <variables_json>
#
# Compose the wire-format JSON envelope. Uses jq's `--arg` for the operation
# (forces string encoding so triple-quoted GraphQL with embedded $variables
# survives untouched) and `--argjson` for variables (already valid JSON).
#
# Empty/omitted variables default to {} so callers can pass "" when their
# operation takes none.
graphql::_build_operation() {
    local operation="$1"
    local variables="${2:-}"

    if [[ -z "$variables" ]]; then
        variables='{}'
    fi

    # Validate variables JSON early — better to fail here with a clear message
    # than have Linear bounce a malformed request.
    if ! printf '%s' "$variables" | jq -e . >/dev/null 2>&1; then
        graphql::_log_error \
            "variables argument is not valid JSON: ${variables}"
        exit 2
    fi

    jq -n \
        --arg query "$operation" \
        --argjson variables "$variables" \
        '{ query: $query, variables: $variables }'
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# graphql::query <query_string> <variables_json>
#
# Issue a GraphQL query. Returns the response JSON on stdout.
#
# Example:
#   graphql::query \
#     'query($team: String!) { workflowStates(filter: { team: { id: { eq: $team } } }) { nodes { id name } } }' \
#     '{"team":"abc-123"}'
graphql::query() {
    if (( $# < 1 )); then
        graphql::_log_error "graphql::query requires a query string"
        exit 2
    fi
    local query="$1"
    local variables="${2:-}"
    local operation_json
    operation_json="$(graphql::_build_operation "$query" "$variables")"
    graphql::_request "$operation_json"
}

# graphql::mutate <mutation_string> <variables_json>
#
# Issue a GraphQL mutation. Semantically identical to graphql::query on the
# wire, but exposed as a distinct function so call sites read clearly and so
# future per-flavour middleware (e.g. mutation-only audit logging) has a hook.
#
# Example:
#   graphql::mutate \
#     'mutation($input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }' \
#     '{"id":"abc-123","input":{"stateId":"def-456"}}'
graphql::mutate() {
    if (( $# < 1 )); then
        graphql::_log_error "graphql::mutate requires a mutation string"
        exit 2
    fi
    local mutation="$1"
    local variables="${2:-}"
    local operation_json
    operation_json="$(graphql::_build_operation "$mutation" "$variables")"
    graphql::_request "$operation_json"
}
