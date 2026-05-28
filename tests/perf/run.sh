#!/usr/bin/env bash
# =============================================================================
# tests/perf/run.sh
#
# T076 perf harness. Generates a synthetic consumer repo with N specs
# (each spec mirrors the spec-template fixture: spec.md + plan.md +
# tasks.md with 4 phases / 30 tasks) and times
# `src/reconcile.sh --dry-run --all` against it.
#
# Two-run protocol per N:
#   1. cold  — first invocation against the generated repo.
#   2. hot   — second invocation, immediately after.
# This matches the plan.md Performance Goals language
# (cold = first reconcile of an existing repo; hot = subsequent run).
#
# Thresholds (T076 + plan.md):
#   * Cold reconcile of the 10-spec / 30-task fixture: <= 30s.
#   * Hot  reconcile of the 10-spec / 30-task fixture: <= 5s.
# For N != 10 the thresholds are reported but not failed-against.
#
# This harness does NOT touch live Linear:
#   * `--dry-run` short-circuits every mutation in `reconcile.sh`.
#   * A `curl` shim on PATH returns `{"data":{}}` for any GraphQL
#     read query (LocateSpecIssue etc.) so the reconciler stays
#     hermetic.
#   * A `gh` shim on PATH returns "no PR found" so PR-state lookups
#     resolve to the git-only fallback.
#
# Exit codes:
#   0  All N values measured met their SC threshold (or were
#      threshold-exempt).
#   1  At least one measured N exceeded its SC threshold.
#   2  Harness setup error (missing reconcile.sh, bash too old, etc.).
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Paths & defaults.
# -----------------------------------------------------------------------------
PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PERF_DIR}/../.." && pwd)"
RECONCILE_SH="${REPO_ROOT}/src/reconcile.sh"
FIXTURE_TEMPLATE="${PERF_DIR}/fixtures/spec-template"

# Default N matrix. Override with --n 5,10 or --n 1 ...
DEFAULT_NS=(1 5 10 25 50)

# Cold / hot thresholds (seconds). Used for pass/fail on N=10.
COLD_THRESHOLD_S=30
HOT_THRESHOLD_S=5

# -----------------------------------------------------------------------------
# usage
# -----------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage: tests/perf/run.sh [--n LIST] [--keep-sandbox] [--quiet] [--help]

Options:
  --n LIST         Comma-separated list of N values to measure.
                   Defaults to: 1,5,10,25,50.
  --keep-sandbox   Do not delete the generated sandbox repos on exit.
  --quiet          Suppress per-step chatter (still prints the table).
  --help           Show this help.

SC thresholds (T076 + plan.md Performance Goals):
  cold reconcile (N=10, 30 tasks/spec): <= ${COLD_THRESHOLD_S}s
  hot  reconcile (N=10, 30 tasks/spec): <= ${HOT_THRESHOLD_S}s

Exit codes:
  0  All measured N met their threshold (or were exempt).
  1  At least one measured N exceeded its threshold.
  2  Harness setup error.
EOF
}

# -----------------------------------------------------------------------------
# log <msg...>
# -----------------------------------------------------------------------------
QUIET=0
log() {
    if (( QUIET == 1 )); then
        return 0
    fi
    printf 'perf-harness: %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
N_LIST=""
KEEP_SANDBOX=0
while (( $# > 0 )); do
    case "$1" in
        --n)
            if (( $# < 2 )); then
                printf 'perf-harness: --n requires an argument\n' >&2
                usage
                exit 2
            fi
            N_LIST="$2"
            shift 2
            ;;
        --n=*)
            N_LIST="${1#--n=}"
            shift
            ;;
        --keep-sandbox)
            KEEP_SANDBOX=1
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'perf-harness: unknown flag: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
done

# Resolve N matrix.
declare -a NS
if [[ -n "$N_LIST" ]]; then
    IFS=',' read -ra NS <<< "$N_LIST"
else
    NS=("${DEFAULT_NS[@]}")
fi

# Validate N entries are positive integers.
for n in "${NS[@]}"; do
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
        printf 'perf-harness: invalid N value: %s\n' "$n" >&2
        exit 2
    fi
done

# -----------------------------------------------------------------------------
# Sanity check the environment.
# -----------------------------------------------------------------------------
if [[ ! -x "$RECONCILE_SH" ]] && [[ ! -r "$RECONCILE_SH" ]]; then
    printf 'perf-harness: cannot find reconcile.sh at %s\n' "$RECONCILE_SH" >&2
    exit 2
fi

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'perf-harness: requires bash 4+, found %s\n' "$BASH_VERSION" >&2
    exit 2
fi

if [[ ! -d "$FIXTURE_TEMPLATE" ]]; then
    printf 'perf-harness: missing fixture template at %s\n' "$FIXTURE_TEMPLATE" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# write_config_yaml <path>
#   Mirrors tests/helpers/integration-helpers.bash::_write_config_yaml.
# -----------------------------------------------------------------------------
write_config_yaml() {
    local path="$1"
    cat > "$path" <<'YAML'
schema_version: 1
config_version: 1

linear:
  workspace:
    name: "OSH-INFRA"
    url_key: "osh-infra"
  team:
    id: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    key: "OSH"
    name: "OSH-INFRA"
  project:
    id: "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
    name: "spec-kit-linear-perf"
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
# install_shims <mock_bin>
#   Drop a curl + gh shim that keep the reconciler hermetic. curl
#   returns `{"data":{}}` followed by the `200` status line that
#   graphql.sh's `-w` flag expects. gh returns "no PR found".
# -----------------------------------------------------------------------------
install_shims() {
    local mock_bin="$1"
    mkdir -p "$mock_bin"

    cat > "${mock_bin}/curl" <<'SHIM'
#!/usr/bin/env bash
# Hermetic perf-harness curl shim. We deliberately ignore argv; any
# read query the reconciler issues is answered with empty data, which
# the reconciler treats as "spec issue does not yet exist" — it would
# then attempt a mutation, which --dry-run short-circuits.
set -euo pipefail

# Respect any -D <path> header dump request so callers that wrote
# `curl -D headers ...` don't see a missing file.
prev=""
for arg in "$@"; do
    case "$prev" in
        -D|--dump-header)
            : > "$arg"
            ;;
    esac
    prev="$arg"
done

printf '%s' '{"data":{}}'
# graphql.sh uses `-w '\n%{http_code}\n'`; honour that shape.
printf '\n%s\n' "200"
SHIM
    chmod +x "${mock_bin}/curl"

    cat > "${mock_bin}/gh" <<'SHIM'
#!/usr/bin/env bash
# Hermetic gh shim. `auth` => OK; `pr ...` => "no PR found"; anything
# else => silent success. Matches the no-PR helper from
# tests/helpers/integration-helpers.bash::install_gh_shim_no_pr.
case "${1:-}" in
    auth) exit 0 ;;
    pr)
        printf 'no pull requests found for branch\n' >&2
        exit 1
        ;;
    *)    exit 0 ;;
esac
SHIM
    chmod +x "${mock_bin}/gh"
}

# -----------------------------------------------------------------------------
# generate_repo <root> <n>
#   Create a sandbox consumer repo with N specs mounted under specs/.
#   Each spec is rendered from FIXTURE_TEMPLATE with NNN substituted.
# -----------------------------------------------------------------------------
generate_repo() {
    local root="$1"
    local n="$2"
    local i nnn spec_dir src dst

    mkdir -p "$root/specs" "$root/.specify/extensions/linear"

    # Hermetic git init.
    GIT_AUTHOR_NAME='Perf Harness' \
    GIT_AUTHOR_EMAIL='perf@example.com' \
    GIT_COMMITTER_NAME='Perf Harness' \
    GIT_COMMITTER_EMAIL='perf@example.com' \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$root" init --initial-branch=main --quiet

    printf 'perf sandbox\n' > "${root}/README.md"
    GIT_AUTHOR_NAME='Perf Harness' \
    GIT_AUTHOR_EMAIL='perf@example.com' \
    GIT_COMMITTER_NAME='Perf Harness' \
    GIT_COMMITTER_EMAIL='perf@example.com' \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$root" add README.md
    GIT_AUTHOR_NAME='Perf Harness' \
    GIT_AUTHOR_EMAIL='perf@example.com' \
    GIT_COMMITTER_NAME='Perf Harness' \
    GIT_COMMITTER_EMAIL='perf@example.com' \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$root" commit --quiet -m 'initial'

    # Render N specs. NNN is zero-padded to 3 digits.
    for (( i = 1; i <= n; i++ )); do
        nnn="$(printf '%03d' "$i")"
        spec_dir="${root}/specs/${nnn}-perf-fixture"
        mkdir -p "$spec_dir"
        for src in "${FIXTURE_TEMPLATE}"/*.md; do
            dst="${spec_dir}/$(basename "$src")"
            # Substitute __NNN__ at copy-time; sed is portable and fast.
            sed "s/__NNN__/${nnn}/g" "$src" > "$dst"
        done
    done

    write_config_yaml "${root}/.specify/extensions/linear/linear-config.yml"

    # .env with a fake Linear key so graphql.sh's bootstrap doesn't bail.
    printf 'LINEAR_API_KEY=lin_api_perf_fake\n' > "${root}/.env"

    # Check out a branch that is authoritative for spec 001. The
    # reconciler's per-spec write-authority gate (FR-025) only permits
    # writes when the current branch matches the spec being reconciled
    # OR the spec's branch does not exist. Our generated specs don't
    # have feature branches, so authority defaults to permitted for
    # all of them — main is fine.
    :
}

# -----------------------------------------------------------------------------
# time_reconcile <sandbox_root> <mock_bin>
#   Echo the wall-clock seconds (3-decimal) for one
#   `reconcile.sh --all --dry-run --quiet` invocation. Uses bash's
#   builtin EPOCHREALTIME (microsecond precision, no fork). Reconcile
#   stderr/stdout is discarded to /dev/null.
# -----------------------------------------------------------------------------
time_reconcile() {
    local sandbox="$1"
    local mock_bin="$2"
    local start end elapsed

    start="${EPOCHREALTIME}"
    (
        cd "$sandbox"
        export PATH="${mock_bin}:${PATH}"
        export SPECKIT_LINEAR_CONFIG="${sandbox}/.specify/extensions/linear/linear-config.yml"
        bash "$RECONCILE_SH" --all --dry-run --quiet >/dev/null 2>&1 || true
    )
    end="${EPOCHREALTIME}"

    # EPOCHREALTIME is "<seconds>.<microseconds>". Subtract in awk for
    # portable float math (bc not guaranteed on minimal CI runners).
    elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e - s }')"
    printf '%s' "$elapsed"
}

# -----------------------------------------------------------------------------
# threshold_for <kind:cold|hot> <n>
#   Echo the SC threshold (seconds) for the given run kind + N. N=10
#   is the spec-defined target; other N values report informational
#   thresholds scaled linearly off N=10 (so the table conveys "this
#   would have been fine at scale" without forcing a fail).
# -----------------------------------------------------------------------------
threshold_for() {
    local kind="$1"
    local n="$2"
    if [[ "$kind" == "cold" ]]; then
        printf '%s' "$COLD_THRESHOLD_S"
    else
        printf '%s' "$HOT_THRESHOLD_S"
    fi
    # n is informational here; suppress shellcheck unused-var noise.
    : "$n"
}

# -----------------------------------------------------------------------------
# Main loop.
# -----------------------------------------------------------------------------
TMP_ROOT="$(mktemp -d -t spec-kit-linear-perf.XXXXXX)"
# shellcheck disable=SC2329  # invoked via `trap cleanup EXIT` below.
cleanup() {
    if (( KEEP_SANDBOX == 1 )); then
        log "keeping sandbox: ${TMP_ROOT}"
        return 0
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

log "perf harness — N matrix: ${NS[*]}"
log "sandbox root: ${TMP_ROOT}"
log "thresholds (N=10 only): cold <= ${COLD_THRESHOLD_S}s, hot <= ${HOT_THRESHOLD_S}s"

# Results table header.
printf '\n'
printf '%-6s %-12s %-12s %-10s %-10s %s\n' \
    "N" "cold_s" "hot_s" "cold_thr" "hot_thr" "status"
printf '%-6s %-12s %-12s %-10s %-10s %s\n' \
    "---" "------" "-----" "--------" "-------" "------"

OVERALL_RC=0
declare -a RESULT_ROWS=()

for n in "${NS[@]}"; do
    log "scenario N=${n} — generating ${n} synthetic specs"
    sandbox="${TMP_ROOT}/N-${n}"
    mock_bin="${sandbox}/mock-bin"
    install_shims "$mock_bin"
    generate_repo "$sandbox" "$n"

    log "scenario N=${n} — cold reconcile"
    cold="$(time_reconcile "$sandbox" "$mock_bin")"

    log "scenario N=${n} — hot reconcile"
    hot="$(time_reconcile "$sandbox" "$mock_bin")"

    cold_thr="$(threshold_for cold "$n")"
    hot_thr="$(threshold_for hot "$n")"

    # Threshold pass/fail only enforced at N=10 (the SC-defined point).
    status="ok"
    if [[ "$n" == "10" ]]; then
        cold_ok="$(awk -v v="$cold" -v t="$cold_thr" 'BEGIN { print (v <= t) ? 1 : 0 }')"
        hot_ok="$(awk -v v="$hot" -v t="$hot_thr"  'BEGIN { print (v <= t) ? 1 : 0 }')"
        if [[ "$cold_ok" != "1" ]]; then
            status="FAIL(cold)"
            OVERALL_RC=1
        fi
        if [[ "$hot_ok" != "1" ]]; then
            if [[ "$status" == "FAIL(cold)" ]]; then
                status="FAIL(cold+hot)"
            else
                status="FAIL(hot)"
            fi
            OVERALL_RC=1
        fi
    else
        status="info"
    fi

    printf '%-6s %-12s %-12s %-10s %-10s %s\n' \
        "$n" "$cold" "$hot" "${cold_thr}s" "${hot_thr}s" "$status"

    RESULT_ROWS+=("${n}|${cold}|${hot}|${status}")
done

printf '\n'
log "done — overall exit ${OVERALL_RC}"

# Emit a one-line JSON-ish footer the operator can paste into baselines.json
# without re-running. Format:
#   {"N":<n>,"cold_seconds":<s>,"hot_seconds":<s>,"sc_007_met":<bool>}
# (We name the field sc_007_met for symmetry with T076's success-criteria
# language, even though the spec.md SC-007 line is about malformed entries
# rather than perf; the binding threshold lives in T076 + plan.md.)
printf '\nbaselines.json rows (for paste-in):\n'
for row in "${RESULT_ROWS[@]}"; do
    n="${row%%|*}"; rest="${row#*|}"
    cold="${rest%%|*}"; rest="${rest#*|}"
    hot="${rest%%|*}"; status="${rest#*|}"
    met="true"
    if [[ "$status" == FAIL* ]]; then
        met="false"
    fi
    printf '  {"N":%s,"cold_seconds":%s,"hot_seconds":%s,"threshold_met":%s,"note":"%s"}\n' \
        "$n" "$cold" "$hot" "$met" "$status"
done

exit "$OVERALL_RC"
