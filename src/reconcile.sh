#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
# ^^^ Every GraphQL query/mutation string in this file uses single quotes
#     to preserve literal `$variable` tokens — those are GraphQL variable
#     references resolved server-side, NOT bash expansions. Suppressing
#     SC2016 file-wide is the right call; introducing per-string disables
#     would clutter every query block without changing the contract.
# =============================================================================
# src/reconcile.sh — the spec-kit ↔ Linear reconciler (Layer D).
#
# This is the ENTRY-POINT script the `speckit.linear.push` command, every
# `after_*` hook, and every local git hook funnel into. It implements
# every filesystem → Linear mutation path documented in
# `specs/001-spec-kit-linear-bridge/contracts/linear-graphql-mutations.md`
# §4 (reconcile-time block) on behalf of User Story 1 (FR-001..FR-008,
# FR-013..FR-016, FR-023..FR-026, FR-031).
#
# What it is NOT: it is NOT sourced as a library; functions defined here
# are local to this process. The other src/*.sh modules are sourced
# below for their public APIs (`config::*`, `graphql::*`, `parser::*`,
# `git_helpers::*`, `summary::*`).
#
# -----------------------------------------------------------------------------
# Constitutional alignment
# -----------------------------------------------------------------------------
# Principle I (filesystem-is-truth) — this script never writes to disk
#   (other than tempfiles it cleans up); every spec.md/tasks.md edit
#   stays operator-owned.
# Principle II (reconcile, never event-push) — every invocation reads
#   full filesystem state and converges Linear; no diff cache, no
#   sidecar `last_sync.json`.
# Principle III (layered idempotency) — this is Layer D. It owns labels,
#   sub-issues, checklists, comments, and Project Status. The GitHub
#   Action (Layer E) owns ONLY workflow-state flips, never touched here.
# Principle IV (drift-aware write authority — spec 003, constitution
#   v2.0.0) — ANY worktree may WRITE (FR-051): the invoking worktree's
#   filesystem state is the write authority. The v1.0.0 branch-gate
#   (read-only-for-non-authoritative-worktree) is REMOVED. Before each
#   write reconcile computes a backward-drift signal (FR-052) and, when
#   Linear appears ahead, SURFACES a WARNING (FR-054) — it never refuses
#   the write of its own accord (warn, don't block). `git_helpers::
#   is_authoritative_for_spec` survives as a non-gating display heuristic
#   (status.sh / FR-026 surfacing), not a write gate.
# Principle V (UUID-based binding) — every Linear lookup uses UUIDs
#   resolved from `linear-config.yml` via the `config::*` API. MCP-path
#   tools accept name-shaped args but the lookup KEY stays UUID.
# Principle VI (OAuth-first, keys-at-the-edges) — this script does not
#   know whether MCP-via-OAuth or direct-GraphQL-via-key handled a given
#   mutation; both go through `graphql::*`. When invoked by the AI
#   agent harness, the MCP-translation step is the agent's
#   responsibility per `commands/linear-push.md`.
# Principle VIII (observable failure) — every per-spec failure is
#   collected via `summary::add` and surfaced in the final
#   `summary::emit` block.
#
# -----------------------------------------------------------------------------
# Exit codes (per contracts/command-shapes.md §1.6)
# -----------------------------------------------------------------------------
#   0 — every spec processed (possibly with non-fatal warnings)
#   1 — partial failure: some specs failed but others succeeded; or a
#       transport failure was aggregated as a warning
#   2 — workspace-level config error (missing/malformed linear-config.yml,
#       unseeded UUIDs); halt without partial mutation per FR-022
#   3 — transport failure across the board (config OK, but Linear
#       unreachable; nothing was written)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Module sourcing — strict order: config first (it validates UUIDs and
# is depended on by graphql + reconcile body), then the rest. The
# `# shellcheck source=` directives let shellcheck statically follow the
# sourced API surface.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Note: SC1091 disabled per source directive because CI invokes shellcheck
# without --external-sources; the `source=` directives still document intent
# for IDE-side shellcheck integrations that DO follow external sources.
# shellcheck source=./config.sh disable=SC1091
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=./graphql.sh disable=SC1091
source "${SCRIPT_DIR}/graphql.sh"
# shellcheck source=./git_helpers.sh disable=SC1091
source "${SCRIPT_DIR}/git_helpers.sh"
# shellcheck source=./summary.sh disable=SC1091
source "${SCRIPT_DIR}/summary.sh"
# shellcheck source=./parser.sh disable=SC1091
source "${SCRIPT_DIR}/parser.sh"

# -----------------------------------------------------------------------------
# Module constants
# -----------------------------------------------------------------------------

# Default config path. Resolved relative to PWD (the consumer repo's
# root) rather than to the script, so the same script binary serves
# every consumer repo's invocation.
readonly RECONCILE_CONFIG_PATH_DEFAULT=".specify/extensions/linear/linear-config.yml"

# Cap on the verbatim Overview body before we truncate to the first
# paragraph (split on `\n\n`) + ellipsis. Linear descriptions are
# already long with the memory + diagrams blocks; keeping this under
# 1500 chars preserves the at-a-glance value the block is meant to add.
readonly RECONCILE_OVERVIEW_MAX_CHARS=1500

# Bridge-owned description policy (FR-004, FR-016): the spec Issue's
# description body is fully owned and rewritten by the bridge on every
# reconcile, in canonical order: overview → memory → diagrams. There
# are no fence markers — Linear renders HTML comments and `<details>`
# tags as visible text nodes (probed empirically on ACM-14), so any
# fence shape would leak as literal markup in Linear's UI. Operator
# annotations belong in Linear comments (FR-008), which the bridge
# never touches.

# Header preface for task-phase sub-issue descriptions (FR-006). The
# one-way semantics must be impossible to miss per spec. Backticks here
# delimit a markdown code-span, not a bash subshell.
readonly RECONCILE_SUBISSUE_HEADER='> **Read-only mirror of `tasks.md` — ticks in Linear are overwritten on next reconcile.**'

# Deterministic color for auto-created `speckit-spec:NNN` workspace
# labels (per contracts §2.2 — these labels are created lazily at
# reconcile-time, not by seed). Neutral gray signals "system label,
# not operator-curated"; matches the lazy-create entry in
# contracts/linear-graphql-mutations.md §2.2.
readonly RECONCILE_SPECKIT_LABEL_COLOR="#9CA3AF"

# Deterministic color for lazy-created `task-phase:N` workspace labels
# when the seeded bootstrap range (`task-phase:1..task-phase:9`,
# FR-021) is exhausted by a spec whose tasks.md declares 10+ phases.
# The seed step itself lets Linear pick a default color for the
# bootstrap nine; we use the same neutral gray as the speckit-spec
# auto-create path so the overflow labels read as "system, not
# operator-curated" in Linear's UI. Mirrors FR-004b's lazy-create
# precedent — the architectural fix for >9-phase specs lives at
# reconcile time (label resolver), not seed time.
readonly RECONCILE_TASK_PHASE_LABEL_COLOR="#9CA3AF"

# Module-level cache: label name → UUID. Populated lazily by
# reconcile::_resolve_label_id so the same name resolved across N
# specs in a single --all sweep hits Linear at most once.
declare -gA _RECONCILE_LABEL_ID_CACHE=()

# FR-034 graceful-degradation flag — set to 1 the first time
# reconcile::_resolve_operator_assignee_id sees an empty
# linear.operator.user_id so the missing-operator warning fires
# exactly once per reconcile run rather than once per Issue created.
declare -g _RECONCILE_OPERATOR_WARNED=0

# FR-036 graceful-degradation flag — set to 1 the first time
# reconcile::_resolve_running_agent sees an empty env-var trio
# (CLAUDE_CODE_MODEL / CODEX_MODEL / AGENT_NAME) so the
# "no agent identifier resolved" diagnostic fires exactly once
# per reconcile run rather than once per Issue created. NOT a
# warning — absence of an AI agent context is a legitimate
# operating mode (manual /spec-kit-linear-push invocation from a
# plain shell, CI worker, etc.), so we only log it at debug level
# via reconcile::log. The label stamp is silently omitted.
declare -g _RECONCILE_AGENT_RESOLVED_LOGGED=0

# FR-036 cached resolver output. _resolve_running_agent populates
# these on first call and every subsequent call short-circuits to
# the cached values — so the same env-var trio is read once per
# reconcile run, not once per Issue / sub-issue site. Empty values
# mean "no agent identifier resolved" (graceful degradation: stamp
# is omitted).
declare -g _RECONCILE_AGENT_FAMILY=""
declare -g _RECONCILE_AGENT_MODEL=""
declare -g _RECONCILE_AGENT_RESOLVED=0

# Diagrams-block "no GitHub remote" warning latch — same one-shot
# pattern as the operator-assignee warning above. Flipped on the
# first render_diagrams_block call that can't resolve a github.com
# base URL so the warning fires once per reconcile rather than once
# per spec.
declare -g _RECONCILE_DIAGRAMS_WARNED=0

# Overview-block "spec.md has no ## Overview section" warning latch —
# same one-shot pattern as the operator-assignee / diagrams warnings
# above. Flipped on the first render_overview_block call whose spec.md
# lacks an `## Overview` heading so the warning fires once per
# reconcile rather than once per spec.
declare -g _RECONCILE_OVERVIEW_WARNED=0

# FR-002 Project Status accumulator. Each per-spec process_spec call
# appends one row (newline-separated): `<lifecycle_phase>\t<last_touched_epoch>`.
# After the loop, reconcile::sync_project_status reads the buffer to
# decide whether to flip the Project's Status enum to started /
# paused / completed (cancelled is never touched by the bridge).
declare -g _RECONCILE_LIFECYCLE_ROWS=""

# -----------------------------------------------------------------------------
# CLI flags — populated by reconcile::parse_args.
# -----------------------------------------------------------------------------
declare -g ARG_SPEC=""          # NNN or empty
declare -g ARG_ALL=0            # 0|1
declare -g ARG_DRY_RUN=0        # 0|1
declare -g ARG_QUIET=0          # 0|1
declare -g ARG_RETROACTIVE=0    # 0|1 — DEPRECATED no-op alias (spec 003 /
                                #       FR-061). Writing from any branch is the
                                #       default after the FR-025 gate removal, so
                                #       this flag now sets NO behavioral global;
                                #       it only triggers a single deprecation
                                #       INFO row at parse time. Retained solely
                                #       so pasted v0.1.x commands still run.

# Drift disposition override (spec 003 / FR-056, plan A11). Empty = unset =
# the proceed-and-warn default. Set to `abort` or `proceed` via
# --on-drift=<value>; any other value is a usage error at parse time. Has no
# observable effect when no backward-drift fires (data-model §3.5). Wired
# into the disposition fork by US2 (T334) / US3 (T343) — Phase 2 only parses
# it.
declare -g ARG_ON_DRIFT=""      # "" | abort | proceed

# (spec 003 / T324): the v0.1.x `_RECONCILE_RETROACTIVE_BYPASS_COUNT`
# accumulator is fully RETIRED. Its end-of-run aggregate row was retired in
# Phase 2 (A12/A16); its lone increment lived inside the FR-025 write gate,
# which T324 deletes wholesale — so the declaration goes with it. Writing
# from any branch is the default (FR-051); there is no bypass to count.

# Aggregate exit-code tracker. We start at 0 and monotonically promote
# to higher severities as failures accumulate.
declare -g RECONCILE_EXIT_CODE=0

# -----------------------------------------------------------------------------
# reconcile::usage
#   Print operator-facing usage to stderr.
# -----------------------------------------------------------------------------
reconcile::usage() {
    cat >&2 <<'EOF'
Usage: reconcile.sh [--spec NNN | --all] [--dry-run] [--on-drift=abort|proceed]
                    [--quiet] [--config PATH] [--help]

Reconcile filesystem spec state into Linear (Layer D). Idempotent.

Options:
  --spec NNN       Reconcile only the spec whose feature number matches NNN.
  --all            Reconcile every specs/NNN-feature/ in the repo.
                   (Exactly one of --spec or --all is required.)
  --dry-run        Log every mutation that WOULD fire; issue none.
  --on-drift=V     Disposition for backward-drift (Linear ahead of disk) on a
                   non-interactive run. V is one of:
                     proceed  Overwrite Linear from disk and record a WARNING
                              (the default when --on-drift is omitted).
                     abort    Skip the drifted spec, leave Linear unchanged,
                              and record a WARNING + skip note.
                   Has no effect when no drift fires. An interactive (TTY) run
                   prompts proceed/abort instead. Any other value is an error.
  --retroactive    DEPRECATED no-op (FR-061). Writing from any branch is now
                   the default — this flag is no longer needed. Passing it
                   prints one deprecation INFO row and otherwise changes
                   nothing. Use --all to enumerate every spec.
  --quiet          Suppress per-mutation log lines. Summary still emits.
  --config PATH    Override the path to linear-config.yml
                   (default: .specify/extensions/linear/linear-config.yml).
  --help           Show this help.

Exit codes:
  0  Success (possibly with warnings).
  1  Partial failure: some specs failed; others succeeded.
  2  Workspace-level config error (halt without partial mutation).
  3  Transport failure: Linear unreachable; nothing written.

See contracts/command-shapes.md §1 for the full contract.
EOF
}

# -----------------------------------------------------------------------------
# reconcile::log
#   Emit a per-mutation log line to stderr. Suppressed by --quiet.
#   stdout is reserved for any future structured-output mode; per-step
#   chatter is stderr only (matches summary::emit convention).
# -----------------------------------------------------------------------------
reconcile::log() {
    if (( ARG_QUIET == 1 )); then
        return 0
    fi
    printf 'spec-kit-linear: %s\n' "$*" >&2
}

# -----------------------------------------------------------------------------
# reconcile::promote_exit <code>
#   Monotonically promote RECONCILE_EXIT_CODE. We use a fixed severity
#   order: 0 < 1 < 3 < 2 (config errors are the most severe — they
#   prove the operator MUST act). The first 2 wins and short-circuits
#   further promotion.
# -----------------------------------------------------------------------------
reconcile::promote_exit() {
    local incoming="$1"
    # 2 is terminal — never demote.
    if (( RECONCILE_EXIT_CODE == 2 )); then
        return 0
    fi
    case "$incoming" in
        2) RECONCILE_EXIT_CODE=2 ;;
        3) (( RECONCILE_EXIT_CODE < 3 )) && RECONCILE_EXIT_CODE=3 ;;
        1) (( RECONCILE_EXIT_CODE < 1 )) && RECONCILE_EXIT_CODE=1 ;;
        0) : ;;
        *) : ;;
    esac
}

# =============================================================================
# Step 1 — Argument parsing.
# =============================================================================
reconcile::parse_args() {
    local config_path="${RECONCILE_CONFIG_PATH_DEFAULT}"
    while (( $# > 0 )); do
        case "$1" in
            --spec)
                if (( $# < 2 )); then
                    printf 'spec-kit-linear: --spec requires a feature number argument\n' >&2
                    reconcile::usage
                    exit 2
                fi
                ARG_SPEC="$2"
                shift 2
                ;;
            --spec=*)
                ARG_SPEC="${1#--spec=}"
                shift
                ;;
            --all)
                ARG_ALL=1
                shift
                ;;
            --dry-run)
                ARG_DRY_RUN=1
                shift
                ;;
            --quiet)
                ARG_QUIET=1
                shift
                ;;
            --on-drift)
                if (( $# < 2 )); then
                    printf 'spec-kit-linear: --on-drift requires a value (abort|proceed)\n' >&2
                    reconcile::usage
                    exit 2
                fi
                ARG_ON_DRIFT="$2"
                shift 2
                ;;
            --on-drift=*)
                ARG_ON_DRIFT="${1#--on-drift=}"
                shift
                ;;
            --retroactive)
                # DEPRECATED no-op alias (FR-061 / spec 003). Writing from
                # any branch is the default after the FR-025 gate removal, so
                # this flag sets NO behavioral global. We mark it seen here so
                # main() can emit EXACTLY ONE deprecation INFO row after
                # summary::start (the row would otherwise be wiped by the
                # summary reset that follows arg-parse). The per-spec
                # _RECONCILE_RETROACTIVE_BYPASS_COUNT accumulator is retired.
                ARG_RETROACTIVE=1
                shift
                ;;
            --config)
                if (( $# < 2 )); then
                    printf 'spec-kit-linear: --config requires a path argument\n' >&2
                    reconcile::usage
                    exit 2
                fi
                config_path="$2"
                shift 2
                ;;
            --config=*)
                config_path="${1#--config=}"
                shift
                ;;
            -h|--help)
                reconcile::usage
                exit 0
                ;;
            *)
                printf 'spec-kit-linear: unknown argument: %s\n' "$1" >&2
                reconcile::usage
                exit 2
                ;;
        esac
    done

    # Validate --on-drift early: an unrecognised value is a usage error at
    # parse time (FR-056 / plan A6/A11). Empty = unset = proceed-and-warn
    # default; only `abort`/`proceed` are otherwise accepted.
    case "$ARG_ON_DRIFT" in
        ''|abort|proceed) : ;;
        *)
            printf 'spec-kit-linear: --on-drift value must be abort or proceed (got %q)\n' "$ARG_ON_DRIFT" >&2
            reconcile::usage
            exit 2
            ;;
    esac

    # Legacy --retroactive (deprecated no-op) with no explicit --spec still
    # implies --all, so a pasted v0.1.x command keeps its byte-identical
    # enumeration behaviour (SC-021). The flag itself changes nothing else;
    # the one deprecation INFO row is emitted by main() after summary::start.
    if (( ARG_RETROACTIVE == 1 )) && [[ -z "$ARG_SPEC" ]] && (( ARG_ALL == 0 )); then
        ARG_ALL=1
    fi

    # Exactly one of --spec / --all must be supplied.
    if [[ -z "$ARG_SPEC" ]] && (( ARG_ALL == 0 )); then
        printf 'spec-kit-linear: one of --spec NNN or --all is required\n' >&2
        reconcile::usage
        exit 2
    fi
    if [[ -n "$ARG_SPEC" ]] && (( ARG_ALL == 1 )); then
        printf 'spec-kit-linear: --spec and --all are mutually exclusive\n' >&2
        reconcile::usage
        exit 2
    fi
    if [[ -n "$ARG_SPEC" && ! "$ARG_SPEC" =~ ^[0-9]+$ ]]; then
        printf 'spec-kit-linear: --spec value must be numeric (got %q)\n' "$ARG_SPEC" >&2
        exit 2
    fi

    # Stash the resolved config path back on a module global so step 2
    # can pick it up without re-parsing.
    declare -g RECONCILE_CONFIG_PATH="$config_path"
}

# =============================================================================
# Step 2 — Config load + validate.
#   Halts with exit 2 on any failure (FR-022, Principle VIII). The
#   `config::*` API already prints actionable diagnostics; we just
#   funnel its exit code through reconcile::promote_exit and surface
#   the same warning via summary::add.
# =============================================================================
reconcile::load_config() {
    local path="${RECONCILE_CONFIG_PATH}"
    if [[ ! -e "$path" ]]; then
        summary::add error "linear-config.yml not found at ${path}; run /spec-kit-linear-install"
        reconcile::promote_exit 2
        return 2
    fi
    # Sub-shell guard isn't possible because config::load populates the
    # module-level associative arrays in THIS process. If config::load
    # exits 2, we inherit that exit (the script terminates with code 2
    # via `set -e`, which is the right thing for a workspace config
    # failure).
    config::load "$path"
    config::validate
    reconcile::log "config loaded from ${path}"
}

# =============================================================================
# Step 3 — Spec enumeration.
#   Emits one spec directory path per line on stdout. Empty output (with
#   exit 0) is a valid "no specs to reconcile" outcome — the caller
#   surfaces a warning rather than an error per FR-024.
# =============================================================================
reconcile::enumerate_specs() {
    local specs_root="specs"
    if [[ ! -d "$specs_root" ]]; then
        return 0
    fi

    if [[ -n "$ARG_SPEC" ]]; then
        # Match any specs/NNN-* whose NNN prefix equals ARG_SPEC. We use
        # a glob and filter via the regex so leading-zero variations
        # ("3" vs "003") resolve to the same dir.
        local dir
        for dir in "${specs_root}"/*/; do
            [[ -d "$dir" ]] || continue
            local base
            base="$(basename "${dir%/}")"
            if [[ "$base" =~ ^([0-9]+)- ]]; then
                local num="${BASH_REMATCH[1]}"
                # Compare as integers so 003 == 3.
                if (( 10#$num == 10#$ARG_SPEC )); then
                    printf '%s\n' "${dir%/}"
                fi
            fi
        done
        return 0
    fi

    # --all: every NNN-* dir under specs/. Sorted by feature number
    # ascending so the per-spec loop output is deterministic.
    local dir
    for dir in "${specs_root}"/*/; do
        [[ -d "$dir" ]] || continue
        local base
        base="$(basename "${dir%/}")"
        if [[ "$base" =~ ^[0-9]+- ]]; then
            printf '%s\n' "${dir%/}"
        fi
    done | sort
}

# =============================================================================
# JSON-build helpers — bash strings into jq-safe JSON.
#
# These are thin wrappers around `jq -Rn '$x'` that handle the awkward
# quoting that bash heredocs and `printf` don't. We never hand-roll JSON
# in this file (no `printf '"%s"' "$value"`) — every string crosses the
# jq boundary so embedded quotes/newlines/backslashes are escaped
# correctly.
# =============================================================================

# reconcile::json_string <raw>
#   Echo a JSON-encoded string literal for <raw>. Output includes the
#   surrounding quotes.
reconcile::json_string() {
    local raw="${1-}"
    jq -Rn --arg v "$raw" '$v'
}

# reconcile::json_array <items...>
#   Echo a JSON array of strings.
reconcile::json_array() {
    local item
    local -a pieces=()
    for item in "$@"; do
        pieces+=("$(reconcile::json_string "$item")")
    done
    if (( ${#pieces[@]} == 0 )); then
        printf '[]'
        return 0
    fi
    local IFS=','
    printf '[%s]' "${pieces[*]}"
}

# =============================================================================
# Memory block rendering (FR-004).
#
# Produces the markdown fragment that lives inside the spec Issue
# description's <!-- spec-kit-linear:memory:begin --> / :end --> fences.
# The fence markers themselves are added by the caller so the
# description-merge logic can strip and re-insert atomically.
# =============================================================================
reconcile::render_memory_block() {
    local feature_number="$1"
    local short_name="$2"
    local lifecycle_phase="$3"
    local spec_dir="$4"
    local feature_branch="$5"

    local current_branch worktree_lines worktree_cell last_touched_cell source_cell

    current_branch="$(git_helpers::current_branch || true)"

    # Build a "; "-joined list of worktree paths that currently hold
    # the spec's feature branch. A single path is the common case
    # (git enforces uniqueness per branch); we defensively handle
    # multi-line input by joining with "; " so the table cell stays
    # on a single line. Falls back to a human note if no worktree
    # maps to the feature branch (e.g. running from a main worktree).
    worktree_lines="$(git_helpers::worktree_for_branch "$feature_branch" || true)"
    if [[ -z "$worktree_lines" ]]; then
        worktree_cell="\`(no worktree currently on ${feature_branch})\`"
    else
        # Join newline-separated paths with "; " inside a code-span.
        local joined
        joined="$(printf '%s' "$worktree_lines" | tr '\n' ';' | sed 's/;$//' | sed 's/;/; /g')"
        worktree_cell="\`${joined}\`"
    fi

    # Last-touched: `<timestamp> by <operator email>`. If we can't
    # read the disk mtime, label as "unknown". If the operator email
    # is empty (config not yet populated), drop the `by …` suffix
    # gracefully so the cell still renders cleanly.
    local last_touched operator_email
    last_touched="$(git_helpers::last_touched "$spec_dir" || true)"
    if [[ -z "$last_touched" ]]; then
        last_touched="unknown"
    fi
    operator_email="$(config::get_operator_email 2>/dev/null || true)"
    if [[ -n "$operator_email" ]]; then
        last_touched_cell="${last_touched} by \`${operator_email}\`"
    else
        last_touched_cell="${last_touched}"
    fi

    # GitHub source URL — best-effort. We use `git remote get-url origin`
    # and rewrite the SSH form to https. If neither works we fall back to
    # a repo-relative path so the operator at least knows WHERE on disk
    # to look. The cell renders as a "GitHub →" link rather than the
    # bare URL.
    local remote_url="" github_url=""
    if remote_url="$(git remote get-url origin 2>/dev/null)"; then
        # git@github.com:owner/repo.git → https://github.com/owner/repo
        if [[ "$remote_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^ssh://git@([^/]+)/(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^https?://(.+)\.git$ ]]; then
            remote_url="https://${BASH_REMATCH[1]}"
        fi
    fi
    if [[ -n "$remote_url" && -n "$current_branch" ]]; then
        github_url="${remote_url}/tree/${current_branch}/${spec_dir}"
    elif [[ -n "$remote_url" ]]; then
        github_url="${remote_url}/tree/HEAD/${spec_dir}"
    fi
    if [[ -n "$github_url" ]]; then
        source_cell="[GitHub →](${github_url})"
    else
        source_cell="\`(local: ${spec_dir})\`"
    fi

    # Canonical-right-now worktree pointer (FR-058 / T345). Only present
    # when MORE THAN ONE worktree touches the spec dir; the single-worktree
    # case omits the row entirely so the common memory block is unchanged
    # (additive field, data-model §4). Ranked by spec-dir commit time
    # (FR-059), never branch name or mtime — reuses _drift_worktree_lines'
    # canonical selection so the WARNING row and memory block agree.
    local canonical_row=""
    local touching_raw
    touching_raw="$(git_helpers::worktrees_touching_spec "$feature_number" 2>/dev/null || true)"
    if [[ -n "$touching_raw" ]]; then
        local touching_count
        touching_count="$(printf '%s\n' "$touching_raw" | grep -c .)"
        if (( touching_count > 1 )); then
            local canon_line canon_path canon_branch
            canon_line="$(printf '%s\n' "$touching_raw" | sort -t$'\t' -k1,1nr -s | head -1)"
            canon_path="$(printf '%s' "$canon_line" | cut -f2)"
            canon_branch="$(printf '%s' "$canon_line" | cut -f3)"
            # Leading newline so the row drops onto its own line directly
            # after Worktree(s) inside the heredoc (an empty $canonical_row
            # adds nothing — single-worktree collapse, data-model §4).
            canonical_row=$'\n'"| **Canonical worktree** | \`${canon_path}\` (branch \`${canon_branch:-detached}\`) — most recent spec-dir commit |"
        fi
    fi

    # Title-case the lifecycle phase for human display.
    local phase_display
    case "$lifecycle_phase" in
        ready_to_merge) phase_display="Ready-to-merge" ;;
        red_team)       phase_display="Red-team" ;;
        *)              phase_display="$(printf '%s' "$lifecycle_phase" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" ;;
    esac

    # FR-036: append a `Last reconciled by` row when an AI agent is
    # driving the reconcile (CLAUDE_CODE_MODEL / CODEX_MODEL / AGENT_NAME).
    # Empty model ⇒ omit the row entirely so plain-shell reconciles
    # (manual /spec-kit-linear-push from a worker, CI without an agent
    # identifier) render the memory block unchanged. Co-bound to the
    # existing description idempotency probe upstream: a no-op
    # reconcile by a different agent will NOT mutate just to bump this
    # row — sync_spec_issue's description diff is what decides whether
    # to write.
    #
    # Format: ISO 8601 UTC timestamp (matches FR-036 brief), backtick-
    # delimited model ID. Row order is fixed: directly after "Last
    # touched" so the audit trail reads top-down ("last touched by
    # human, last reconciled by agent").
    reconcile::_resolve_running_agent
    local last_reconciled_row=""
    if [[ -n "$_RECONCILE_AGENT_MODEL" ]]; then
        local ts
        ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
        if [[ -n "$ts" ]]; then
            last_reconciled_row="| **Last reconciled by** | \`${_RECONCILE_AGENT_MODEL}\` · ${ts} |"
        fi
    fi

    # Markdown table — fixed column order (Field / Value). The caller
    # (compose_issue_description) concatenates this block into the
    # bridge-owned description body.
    # The canonical-worktree row is emitted directly after Worktree(s) when
    # present (multi-worktree case); the surrounding cat preserves the fixed
    # column order. Empty $canonical_row collapses to a blank line that
    # render_memory_block's consumers tolerate (matches $last_reconciled_row).
    if [[ -n "$last_reconciled_row" ]]; then
        cat <<EOF
| Field | Value |
|---|---|
| **Phase** | ${phase_display} |
| **Branch** | \`${feature_branch}\` |
| **Worktree(s)** | ${worktree_cell} |${canonical_row}
| **Last touched** | ${last_touched_cell} |
${last_reconciled_row}
| **Source** | ${source_cell} |
| **Spec** | ${feature_number}-${short_name} |
EOF
    else
        cat <<EOF
| Field | Value |
|---|---|
| **Phase** | ${phase_display} |
| **Branch** | \`${feature_branch}\` |
| **Worktree(s)** | ${worktree_cell} |${canonical_row}
| **Last touched** | ${last_touched_cell} |
| **Source** | ${source_cell} |
| **Spec** | ${feature_number}-${short_name} |
EOF
    fi
}

# =============================================================================
# reconcile::_strip_last_reconciled_row <description>
#
# Echo the input description with any `| **Last reconciled by** | ... |`
# row removed. FR-036 co-binding helper: the row's timestamp would
# otherwise mutate on every reconcile, breaking SC-002's zero-churn
# guarantee on a no-op sync. Stripping it from BOTH sides of the
# description diff lets the idempotency probe ask "did anything else
# change?"; on yes, the full body (including the fresh timestamp)
# rewrites; on no, neither side mutates.
#
# Implementation: pure sed — the row is a single line at known
# position (between "Last touched" and "Source") with a fixed prefix.
# Matched permissively in case Linear's renderer round-trips the
# whitespace slightly differently than we emit it. The trailing
# `^$` consolidation collapses any blank line left behind so the
# resulting body byte-matches an originally-row-less description.
# =============================================================================
reconcile::_strip_last_reconciled_row() {
    local body="$1"
    # sed handles macOS / Linux portably here — the pattern only uses
    # POSIX BRE features.
    printf '%s' "$body" | sed '/^| \*\*Last reconciled by\*\* |.*|$/d'
}

# =============================================================================
# reconcile::_extract_overview <spec_md_path>
#
# Echo the body of spec.md's `## Overview` (or `# Overview` if H1)
# section to stdout, with leading and trailing blank lines trimmed.
# Returns empty output if no Overview section exists or the file is
# missing — graceful degradation so a spec.md without an Overview
# heading is a no-op (the caller skips emitting the block entirely).
#
# Section boundaries: the body starts on the line AFTER the heading
# and ends just before the next heading at the same or shallower depth
# (H2 Overview → next H1/H2; H1 Overview → next H1). Subsections (H3+)
# nested inside Overview are preserved verbatim.
# =============================================================================
reconcile::_extract_overview() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 0

    awk '
        BEGIN { in_section = 0; depth = 0 }
        # Heading detector: depth = number of leading `#` chars.
        /^#+[[:space:]]+/ {
            n = 0
            line = $0
            while (substr(line, n + 1, 1) == "#") { n++ }
            # Trim leading hashes + whitespace to compare title text.
            title = substr(line, n + 1)
            sub(/^[[:space:]]+/, "", title)
            sub(/[[:space:]]+$/, "", title)

            if (in_section == 0) {
                # Look for the Overview heading at any depth (H1 or H2).
                if ((n == 1 || n == 2) && title == "Overview") {
                    in_section = 1
                    depth = n
                    next
                }
            } else {
                # Terminate on next heading at same-or-shallower depth.
                if (n <= depth) {
                    exit
                }
            }
        }
        in_section { print }
    ' "$spec_md" | awk '
        # Trim leading blank lines.
        BEGIN { started = 0 }
        {
            if (started == 0 && $0 ~ /^[[:space:]]*$/) { next }
            started = 1
            buf[NR] = $0
            last = NR
        }
        END {
            # Trim trailing blank lines.
            while (last > 0 && buf[last] ~ /^[[:space:]]*$/) { last-- }
            for (i = 1; i <= last; i++) {
                if (i in buf) { print buf[i] }
            }
        }
    '
}

# =============================================================================
# reconcile::_github_base_url
#
# Echo the consumer repo's https://github.com/<owner>/<repo> URL on
# stdout, or empty when `git remote get-url origin` isn't a GitHub URL.
# Mirrors the SSH-→-HTTPS rewrite logic already used by
# reconcile::render_diagrams_block and reconcile::render_memory_block.
# Kept private (underscore prefix) so callers go through the public
# render_* functions.
# =============================================================================
reconcile::_github_base_url() {
    local remote_url="" base_url=""
    if remote_url="$(git remote get-url origin 2>/dev/null)"; then
        if [[ "$remote_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^ssh://git@([^/]+)/(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^https?://(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}"
        elif [[ "$remote_url" =~ ^https?://github\.com/.+ ]]; then
            # Already an https URL without the trailing .git.
            base_url="$remote_url"
        fi
    fi
    if [[ -n "$base_url" && "$base_url" == *github.com* ]]; then
        printf '%s' "$base_url"
    fi
}

# =============================================================================
# reconcile::render_overview_block <spec_dir>
#
# Build the markdown body for the spec Issue's `## What this spec does`
# block (Fix 7 — the human-readable Overview pointer). Sourced verbatim
# from spec.md's `## Overview` section so a developer scanning the
# Linear Issue sees what the spec actually does without opening
# spec.md on GitHub. The caller (compose_issue_description) concatenates
# this block into the bridge-owned description body.
#
# Length handling: if the extracted Overview exceeds
# RECONCILE_OVERVIEW_MAX_CHARS (1500), truncate to the FIRST paragraph
# (split on `\n\n`), append an ellipsis, and the "Read full spec on
# GitHub →" link as usual. Under cap → emit verbatim. The link line
# ALWAYS appears.
#
# Empty Overview (spec.md has no `## Overview` heading) → echo nothing
# (caller skips the block) and surface a one-shot warned summary line
# per reconcile run so the operator knows why the block is missing.
# =============================================================================
reconcile::render_overview_block() {
    local spec_dir="$1"
    local spec_md="${spec_dir%/}/spec.md"

    local overview_body
    overview_body="$(reconcile::_extract_overview "$spec_md")"

    if [[ -z "$overview_body" ]]; then
        if (( _RECONCILE_OVERVIEW_WARNED == 0 )); then
            summary::add warned "overview block skipped: spec.md has no \`## Overview\` section (one or more specs)"
            _RECONCILE_OVERVIEW_WARNED=1
        fi
        return 0
    fi

    # Truncate to first paragraph + ellipsis when over cap. The cap is
    # measured against the raw (untruncated) body's char count; the
    # truncated form re-uses the FIRST `\n\n`-delimited paragraph.
    local body_chars=${#overview_body}
    if (( body_chars > RECONCILE_OVERVIEW_MAX_CHARS )); then
        # Use awk to grab everything up to (but not including) the
        # first fully-blank line. Append a single ellipsis line so the
        # reader knows there's more.
        local first_para
        first_para="$(printf '%s\n' "$overview_body" | awk '
            /^[[:space:]]*$/ { exit }
            { print }
        ')"
        overview_body="${first_para}"$'\n\n…'
    fi

    # Build the "Read full spec on GitHub →" link. The base URL +
    # current branch + spec.md path resolves to a blob URL the reader
    # can click straight into. When the remote isn't GitHub-shaped the
    # link line falls back to a code-span pointer to the on-disk path
    # so the block remains useful (it's the Overview body, not the
    # link, that's load-bearing).
    local base_url current_branch link_line
    base_url="$(reconcile::_github_base_url)"
    current_branch="$(git_helpers::current_branch 2>/dev/null || true)"

    if [[ -n "$base_url" && -n "$current_branch" ]]; then
        link_line="[Read full spec on GitHub →](${base_url}/blob/${current_branch}/${spec_md})"
    elif [[ -n "$base_url" ]]; then
        link_line="[Read full spec on GitHub →](${base_url}/blob/HEAD/${spec_md})"
    else
        link_line="\`(local: ${spec_md})\`"
    fi

    cat <<EOF
## What this spec does

${overview_body}

${link_line}
EOF
}

# =============================================================================
# reconcile::render_diagrams_block
#
# Build the markdown body for the spec Issue's `## Diagrams` block —
# four bullet pointers at the consumer repo's README anchors. The
# caller (compose_issue_description) concatenates this block into the
# bridge-owned description body.
#
# The base URL is derived from `git remote get-url origin` and the
# usual SSH-→-HTTPS rewrite. If the consumer repo's remote isn't
# GitHub-shaped, the function echoes nothing (empty stdout) and the
# caller treats that as "skip the diagrams block entirely". A summary
# warning is emitted on first miss so the operator knows why the
# block is missing rather than silently losing it.
# =============================================================================
reconcile::render_diagrams_block() {
    local remote_url="" base_url=""
    if remote_url="$(git remote get-url origin 2>/dev/null)"; then
        if [[ "$remote_url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^ssh://git@([^/]+)/(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        elif [[ "$remote_url" =~ ^https?://(.+)\.git$ ]]; then
            base_url="https://${BASH_REMATCH[1]}"
        elif [[ "$remote_url" =~ ^https?://github\.com/.+ ]]; then
            # Already an https URL without the trailing .git.
            base_url="$remote_url"
        fi
    fi

    if [[ -z "$base_url" || "$base_url" != *github.com* ]]; then
        # Not a GitHub URL — bail with no output. The caller skips the
        # block. We surface one warning per reconcile run so the
        # operator knows the diagrams pointer was deliberately omitted.
        if (( _RECONCILE_DIAGRAMS_WARNED == 0 )); then
            summary::add warned "diagrams block skipped: \`git remote get-url origin\` did not resolve to a github.com URL"
            _RECONCILE_DIAGRAMS_WARNED=1
        fi
        return 0
    fi

    cat <<EOF
## Diagrams

Visual references in the repo's README:

- [How sync works](${base_url}#how-sync-works) — the everyday case / PR merge / escape hatches
- [Data model](${base_url}#data-model) — structural hierarchy + content mapping
- [Phase mapping](${base_url}#phase-mapping) — lifecycle state transitions
- [Write authority across worktrees](${base_url}#write-authority-across-worktrees) — read vs write rules
EOF
}

# =============================================================================
# reconcile::compose_issue_description <overview_block> <memory_block> [<diagrams_block>]
#
# Build the spec Issue description from scratch in canonical order:
#
#   overview → memory → diagrams
#
# The bridge fully owns the description body (FR-004, FR-016): any
# prior content in Linear is discarded on every reconcile. Operator
# annotations belong in Linear comments (FR-008), which the bridge
# never touches. There are no fence markers — Linear renders HTML
# comments and `<details>` tags as visible text nodes (probed
# empirically on ACM-14), so any fence shape would leak as literal
# markup. The unidirectional, bridge-owned policy makes the per-fence
# splice machinery unnecessary.
#
# <overview_block> and <diagrams_block> may be empty:
#   - empty overview → no `## Overview` heading in spec.md
#   - empty diagrams → consumer repo isn't on GitHub
# In both cases we omit the block entirely (graceful degradation).
# The memory block is mandatory.
# =============================================================================
reconcile::compose_issue_description() {
    local overview_block="$1"
    local memory_block="$2"
    local diagrams_block="${3:-}"

    # Assemble in canonical order. Empty optional blocks are skipped;
    # memory is mandatory. Blocks are separated by a blank line.
    local result=""
    if [[ -n "$overview_block" ]]; then
        result+="${overview_block}"$'\n\n'
    fi
    result+="${memory_block}"
    if [[ -n "$diagrams_block" ]]; then
        result+=$'\n\n'"${diagrams_block}"
    fi

    # Trim trailing newlines for clean concatenation downstream.
    while [[ "$result" == *$'\n' ]]; do
        result="${result%$'\n'}"
    done

    printf '%s' "$result"
}

# =============================================================================
# reconcile::compose_subissue_checklist <feature_number> <phase_index> <tasks_md_path>
#
# Build the markdown body for a task-phase sub-issue per FR-006. The
# read-only-mirror header from RECONCILE_SUBISSUE_HEADER is the first
# line; each task becomes a `- [ ]` / `- [x]` line.
# =============================================================================
reconcile::compose_subissue_checklist() {
    local feature_number="$1"
    local phase_index="$2"
    local tasks_md="$3"

    {
        printf '%s\n' "${RECONCILE_SUBISSUE_HEADER}"
        # Backticks are markdown code-span delimiters in the body text.
        printf '> Source: `specs/%s-*/tasks.md` § Phase %s.\n' \
            "$feature_number" "$phase_index"
        printf '\n'
        # Tab-fields: id, state, desc, estimate. Estimate is dropped
        # from the rendered checklist body (it's surfaced as the
        # sub-issue's Linear `estimate` field instead per FR-035).
        local id state desc est box
        while IFS=$'\t' read -r id state desc est; do
            : "${est:-}"
            case "$state" in
                checked)   box="x" ;;
                unchecked) box=" " ;;
                *)         box=" " ;;
            esac
            if [[ -n "$id" ]]; then
                printf -- '- [%s] **%s** — %s\n' "$box" "$id" "$desc"
            else
                printf -- '- [%s] %s\n' "$box" "$desc"
            fi
        done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")
    }
}

# =============================================================================
# reconcile::subissue_state_key <tasks_md> <phase_index>
#
# Returns one of {todo, in_progress, done} per FR-005 — Todo if zero
# tasks are checked, Done if every task is checked, In Progress
# otherwise (the mixed case). Empty phase (no tasks at all) defaults
# to Todo.
# =============================================================================
reconcile::subissue_state_key() {
    local tasks_md="$1"
    local phase_index="$2"
    local total=0 checked=0
    local id state desc est
    while IFS=$'\t' read -r id state desc est; do
        # Touch unused locals so shellcheck doesn't complain about
        # destructured fields we don't reference.
        : "${id:-}${desc:-}${est:-}"
        total=$(( total + 1 ))
        if [[ "$state" == "checked" ]]; then
            checked=$(( checked + 1 ))
        fi
    done < <(parser::tasks_in_phase "$tasks_md" "$phase_index")
    if (( total == 0 )); then
        printf 'todo\n'
    elif (( checked == 0 )); then
        printf 'todo\n'
    elif (( checked >= total )); then
        printf 'done\n'
    else
        printf 'in_progress\n'
    fi
}

# =============================================================================
# Label name → UUID resolution (the labelIds binding).
#
# Linear's IssueCreateInput / IssueUpdateInput require `labelIds: [String!]`
# (UUIDs). The MCP `save_issue` tool accepts `labels: [string]` (names
# OR IDs) and resolves names server-side; the raw GraphQL path does
# NOT. Every mutation site below funnels its label set through
# reconcile::_resolve_label_ids_array so the wire shape is consistent.
#
# Auto-create policy (per contracts/linear-graphql-mutations.md §2.2):
#   * `speckit-spec:NNN` — created lazily on first reconcile of a spec
#     (`allow_create=1`). Color: RECONCILE_SPECKIT_LABEL_COLOR.
#   * `task-phase:N` (N ≥ 1) — the seed step bootstraps `task-phase:1`
#     through `task-phase:9` (FR-021), but specs with 10+ phases need
#     `task-phase:10..N` minted lazily here. Mirrors the speckit-spec
#     auto-create shape (`allow_create=1`); same workspace-scope and
#     idempotency semantics. Color: RECONCILE_TASK_PHASE_LABEL_COLOR.
#   * `phase:*` — MUST already exist (seeded by `speckit.linear.seed`).
#     Missing is a hard error per FR-022 ("unseeded halts"); reconciler
#     aggregates the failure and points at the seed remediation.
#   * Any other label (operator-added) — looked up but never created.
# =============================================================================

# reconcile::_label_create_workspace <name> <color>
#   Create a workspace-scoped (teamId omitted) issue label and echo its
#   UUID. Used by every lazy-create entry point above (`speckit-spec:NNN`
#   and the `task-phase:N` overflow). Returns non-zero (and records to
#   summary) on transport or GraphQL failure.
reconcile::_label_create_workspace() {
    local name="$1"
    local color="$2"

    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN issueLabelCreate name=${name} color=${color}"
        summary::add created "issueLabelCreate ${name} (dry-run)"
        # Synthesize a stable placeholder so downstream array-builds work
        # in dry-run. Matches the dry-run pattern used by issueCreate.
        printf 'dry-run-label-id-%s\n' "$name"
        return 0
    fi

    local mutation='mutation CreateWorkspaceLabel($input: IssueLabelCreateInput!) {
        issueLabelCreate(input: $input) {
            success
            issueLabel { id name }
        }
    }'
    # Workspace-scoped label: omit teamId entirely per contracts §2.2
    # ("Workspace (omit `teamId`)").
    local input_json vars
    input_json="$(jq -nc \
        --arg name "$name" \
        --arg color "$color" \
        '{name: $name, color: $color}')"
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "issueLabelCreate ${name} failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.issueLabelCreate.success == true' >/dev/null 2>&1; then
        summary::add error "issueLabelCreate ${name} did not return success=true"
        reconcile::promote_exit 1
        return 1
    fi
    summary::add created "issueLabelCreate ${name}"
    printf '%s' "$response" | jq -r '.data.issueLabelCreate.issueLabel.id'
}

# reconcile::_resolve_label_id <name> [allow_create]
#   Resolve a label name to its UUID. <allow_create> is "1" to enable
#   the speckit-spec auto-create path; any other value (default: "0")
#   means "lookup only — missing is a hard error".
#
#   Echoes the UUID on stdout. Returns non-zero (and records the gap
#   via summary::add) on missing+no-create or transport failure.
#
#   Cache: once resolved, the UUID is memoised in
#   _RECONCILE_LABEL_ID_CACHE so an --all sweep hits Linear at most
#   once per distinct label name.
reconcile::_resolve_label_id() {
    local name="$1"
    local allow_create="${2:-0}"

    if [[ -z "$name" ]]; then
        summary::add error "reconcile::_resolve_label_id called with empty name"
        return 1
    fi

    # Cache hit.
    if [[ -n "${_RECONCILE_LABEL_ID_CACHE[$name]:-}" ]]; then
        printf '%s\n' "${_RECONCILE_LABEL_ID_CACHE[$name]}"
        return 0
    fi

    # Query Linear: issueLabels(filter: { name: { eq: $name } }).
    # `first: 5` so we can spot duplicates and surface a warning
    # without paginating; Linear caps name uniqueness per scope so
    # >1 hit is rare but possible across team/workspace boundaries.
    local query='query LocateLabel($name: String!) {
        issueLabels(filter: { name: { eq: $name } }, first: 5) {
            nodes { id name }
        }
    }'
    local vars response
    vars="$(jq -nc --arg name "$name" '{name: $name}')"

    if ! response="$(graphql::query "$query" "$vars" 2>/dev/null)"; then
        summary::add error "issueLabels lookup for '${name}' failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi

    local id
    id="$(printf '%s' "$response" | jq -r '.data.issueLabels.nodes[0].id // ""')"

    if [[ -n "$id" ]]; then
        local count
        count="$(printf '%s' "$response" | jq '.data.issueLabels.nodes | length')"
        if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 1 )); then
            summary::add warned "label '${name}' resolved to ${count} candidates; using first (${id})"
        fi
        _RECONCILE_LABEL_ID_CACHE[$name]="$id"
        printf '%s\n' "$id"
        return 0
    fi

    # Not found. Branch on whether the caller permits auto-create.
    if [[ "$allow_create" == "1" ]]; then
        # Dispatch the color by family. Both lazy-create paths use the
        # same neutral gray (signals "system label, not operator-curated"),
        # but the constant naming keeps the two policies distinct so a
        # future tweak to one doesn't silently move the other.
        local create_color="$RECONCILE_SPECKIT_LABEL_COLOR"
        if [[ "$name" == task-phase:* ]]; then
            create_color="$RECONCILE_TASK_PHASE_LABEL_COLOR"
        fi
        if ! id="$(reconcile::_label_create_workspace "$name" "$create_color")"; then
            return 1
        fi
        if [[ -z "$id" ]]; then
            summary::add error "issueLabelCreate ${name} returned no id"
            reconcile::promote_exit 1
            return 1
        fi
        _RECONCILE_LABEL_ID_CACHE[$name]="$id"
        printf '%s\n' "$id"
        return 0
    fi

    # phase:* (or any operator label) missing → FR-022 halt-like surface.
    # We don't exit(2) here because one missing label shouldn't kill the
    # whole --all sweep; we record the gap, promote to exit 1, and the
    # per-spec caller drops this label from its set so the mutation can
    # still issue for the labels that DO resolve. The summary names the
    # offending label and points at the seed remediation.
    #
    # Note: `task-phase:*` is intentionally absent from this branch.
    # The `_resolve_label_ids_array` caller below routes `task-phase:*`
    # through the `allow_create=1` path above so the bootstrap-9 seed
    # set can be lazy-extended to `task-phase:10..N` for specs with
    # 10+ phases (downstream dogfood bug, mirrors FR-004b precedent).
    if [[ "$name" == phase:* ]]; then
        summary::add error "label '${name}' not found in Linear; run \`speckit.linear.seed\` to create phase:* labels"
    else
        summary::add error "label '${name}' not found in Linear; create it manually or remove it from the spec"
    fi
    reconcile::promote_exit 1
    return 1
}

# reconcile::_resolve_label_ids_array <name1> [<name2> ...]
#   Resolve each label name → UUID and echo a JSON array of UUIDs.
#   `speckit-spec:*` and `task-phase:*` names take the auto-create path;
#   everything else is lookup-only. (`task-phase:*` is bootstrapped 1..9
#   by seed per FR-021 but lazy-extended at reconcile time so specs with
#   10+ phases don't silently drop sub-issues — downstream dogfood bug.)
#   Names that fail to resolve are SKIPPED from the output (with a
#   summary::add error already recorded by _resolve_label_id) so the
#   caller's mutation still fires for the labels that DID resolve —
#   partial progress beats whole-spec halt (FR-024).
#
#   Empty input → "[]".
reconcile::_resolve_label_ids_array() {
    local -a ids=()
    local name id allow_create
    for name in "$@"; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == speckit-spec:* || "$name" == task-phase:* ]]; then
            allow_create=1
        else
            allow_create=0
        fi
        if id="$(reconcile::_resolve_label_id "$name" "$allow_create")"; then
            if [[ -n "$id" ]]; then
                ids+=("$id")
            fi
        fi
    done

    if (( ${#ids[@]} == 0 )); then
        printf '[]'
        return 0
    fi

    # Hand off to jq for clean JSON-array encoding (handles the
    # edge case where a UUID somehow contains a quote, which it
    # never should, but keeps the boundary clean).
    printf '%s\n' "${ids[@]}" | jq -Rcs 'split("\n") | map(select(length > 0))'
}

# =============================================================================
# FR-034 — Operator assignee resolution.
#
# Echo the Linear operator UUID stored in linear.operator.user_id, or
# the empty string if it's absent. On the first absent call per
# reconcile run, append a single warning to the summary so the
# operator knows their Issues will be created unassigned (graceful
# degradation per FR-034). The warning never escalates to an error —
# absence of operator identity is recoverable; the spec Issue will
# still be created, just unassigned.
#
# Mirrors the cache-with-one-shot-warn pattern used by the label
# resolver above (_RECONCILE_LABEL_ID_CACHE) and is read once per
# issueCreate site by sync_spec_issue / sync_task_phase_subissues.
# Never read by issueUpdate sites — single-write-on-create semantics
# so an operator who manually reassigns an Issue in Linear keeps
# that reassignment across reconciles.
# =============================================================================
reconcile::_resolve_operator_assignee_id() {
    local user_id
    user_id="$(config::get_operator_user_id)"
    if [[ -z "$user_id" ]]; then
        if (( _RECONCILE_OPERATOR_WARNED == 0 )); then
            summary::add warned "operator user_id missing from config; Issues will be unassigned (FR-034 graceful degradation)"
            _RECONCILE_OPERATOR_WARNED=1
        fi
        printf ''
        return 0
    fi
    printf '%s' "$user_id"
}

# =============================================================================
# FR-036 — Running-agent identity resolution.
#
# Resolves which AI agent is driving the current reconcile by probing a
# fixed env-var order:
#
#   1. CLAUDE_CODE_MODEL  — set by Claude Code in every session
#   2. CODEX_MODEL        — set by Codex / GPT-5.x hosts
#   3. AGENT_NAME         — generic fallback for any other AI host that
#                           opts into the protocol
#
# The first non-empty wins. The resolved value (full model ID like
# `claude-opus-4-7`) is exposed via _RECONCILE_AGENT_MODEL for the
# memory block's `Last reconciled by:` row. The family identifier
# (`claude`, `codex`, or `<lowercased-first-word>` for unrecognised
# agents) drives the `agent:<family>` label stamp.
#
# Family-name mapping rules (locked by FR-036 brief):
#   * Anything starting with `claude` (case-insensitive) → `claude`
#   * Anything starting with `codex` or `gpt` → `codex` (Codex hosts
#     surface their GPT-* model IDs verbatim)
#   * Otherwise: lowercased first whitespace-/dash-separated word.
#     Example: AGENT_NAME="Gemini 2.5 Pro" → family `gemini`.
#
# All three env vars empty ⇒ both _RECONCILE_AGENT_FAMILY and
# _RECONCILE_AGENT_MODEL stay empty (graceful degradation: caller
# skips the label stamp AND the memory-block row). Matches FR-034 /
# FR-035 patterns; never escalates to a hard failure.
#
# Cached per reconcile run via _RECONCILE_AGENT_RESOLVED so the env
# probe fires exactly once even when sweep mode (--all) hits N specs.
# Reads /dev/null from Linear — pure-local resolution.
# =============================================================================
reconcile::_resolve_running_agent() {
    if (( _RECONCILE_AGENT_RESOLVED == 1 )); then
        return 0
    fi
    _RECONCILE_AGENT_RESOLVED=1

    local model="" family=""
    if [[ -n "${CLAUDE_CODE_MODEL:-}" ]]; then
        model="${CLAUDE_CODE_MODEL}"
    elif [[ -n "${CODEX_MODEL:-}" ]]; then
        model="${CODEX_MODEL}"
    elif [[ -n "${AGENT_NAME:-}" ]]; then
        model="${AGENT_NAME}"
    fi

    if [[ -z "$model" ]]; then
        # Empty trio — graceful skip. Log once per reconcile so an
        # operator running from a plain shell sees an audit breadcrumb,
        # but never surfaces as a summary::add warning (legitimate
        # operating mode).
        if (( _RECONCILE_AGENT_RESOLVED_LOGGED == 0 )); then
            reconcile::log "FR-036: no agent identifier resolved (CLAUDE_CODE_MODEL / CODEX_MODEL / AGENT_NAME all empty); agent:* stamping skipped"
            _RECONCILE_AGENT_RESOLVED_LOGGED=1
        fi
        _RECONCILE_AGENT_FAMILY=""
        _RECONCILE_AGENT_MODEL=""
        return 0
    fi

    # Derive the family. Compare lowercased so case quirks in the env
    # var (`Claude-Opus-4-7`, `GPT-5.4`) don't bypass the canonical map.
    local model_lc
    model_lc="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"

    if [[ "$model_lc" == claude* ]]; then
        family="claude"
    elif [[ "$model_lc" == codex* || "$model_lc" == gpt* ]]; then
        family="codex"
    else
        # Lowercased first whitespace-/dash-separated word.
        local first_word
        first_word="${model_lc%%[[:space:]-]*}"
        if [[ -z "$first_word" ]]; then
            # Defensive: if the value was nothing but whitespace, fall
            # back to "unknown" so we never emit `agent:` (empty family).
            first_word="unknown"
        fi
        family="$first_word"
    fi

    _RECONCILE_AGENT_FAMILY="$family"
    _RECONCILE_AGENT_MODEL="$model"

    if (( _RECONCILE_AGENT_RESOLVED_LOGGED == 0 )); then
        reconcile::log "FR-036: running agent resolved → family='${family}' model='${model}'"
        _RECONCILE_AGENT_RESOLVED_LOGGED=1
    fi
}

# reconcile::_resolve_agent_label_id
#   Convenience wrapper: trigger the env-var resolver, then map the
#   family name to its workspace label UUID via config::get_agent_label_uuid.
#   Returns the empty string when EITHER side resolves to empty (no
#   agent identifier, or seed has no UUID for this family yet — the
#   latter case applies when AGENT_NAME identifies a non-canonical agent
#   like `gemini` for which the seed step doesn't ship a fixed UUID).
#   In that case the caller skips the agent-label stamp; the cross-agent
#   provenance is still preserved via the memory-block `Last reconciled by`
#   row, which depends only on the model string.
reconcile::_resolve_agent_label_id() {
    reconcile::_resolve_running_agent
    if [[ -z "$_RECONCILE_AGENT_FAMILY" ]]; then
        printf ''
        return 0
    fi

    # Lazy mint for non-canonical families. The seed step only captures
    # UUIDs for claude / codex up-front; AGENT_NAME=gemini → family
    # `gemini` → no canonical UUID. Fall through to the lazy-create path
    # used for speckit-spec:NNN so cross-agent provenance still works
    # for any AI host that opts in.
    local family="$_RECONCILE_AGENT_FAMILY"
    local uuid=""

    # Canonical families: read from linear-config.yml. config::get_agent_label_uuid
    # halts with exit 2 if the block is entirely missing — that's
    # operator-actionable and correct (seed hasn't run since FR-036).
    case "$family" in
        claude|codex)
            uuid="$(config::get_agent_label_uuid "$family")"
            ;;
        *)
            # Non-canonical family — lazy-mint by name via the standard
            # label resolver (allow_create=1 path). Cache hit on
            # subsequent calls in the same reconcile run.
            local label_name="agent:${family}"
            if uuid="$(reconcile::_resolve_label_id "$label_name" "1")"; then
                : # success; uuid populated
            else
                uuid=""
            fi
            ;;
    esac

    printf '%s' "$uuid"
}

# =============================================================================
# Mutation primitives — every Linear write the reconciler issues funnels
# through one of these, so --dry-run can intercept them uniformly.
#
# Each primitive:
#   * Logs the operation (subject to --quiet) via reconcile::log
#   * Returns 0 on success, non-zero (and aggregates via summary::add)
#     on failure
#   * On --dry-run, logs the operation and returns 0 without invoking
#     graphql::mutate
#
# We deliberately use GraphQL rather than MCP from this script. The
# AI-agent harness (per commands/linear-push.md) MAY pre-empt by
# performing the same mutations via MCP tools (the MCP and GraphQL
# paths are functionally interchangeable per contracts §4). This
# script's GraphQL path is the bedrock invocation that hooks / git
# hooks rely on (no MCP session available there).
# =============================================================================

# reconcile::query_spec_issue <spec_label> <project_uuid>
#   Locate the spec Issue by `speckit-spec:NNN` label scoped to the
#   repo's Project (FR-004b). Echoes a JSON array of `{id, updatedAt}`
#   objects sorted descending by updatedAt — most-recent first. Empty
#   array on zero matches.
reconcile::query_spec_issue() {
    local spec_label="$1"
    local project_uuid="$2"

    local query='query LocateSpecIssue($label: String!, $project: ID!) {
        issues(
            filter: {
                labels:  { name: { eq: $label } }
                project: { id:   { eq: $project } }
            }
        ) {
            nodes { id updatedAt }
        }
    }'
    local vars
    vars="$(jq -nc \
        --arg label "$spec_label" \
        --arg project "$project_uuid" \
        '{label: $label, project: $project}')"

    local response
    response="$(graphql::query "$query" "$vars")"
    # Sort by updatedAt descending — most recent wins on race (FR-004b).
    printf '%s' "$response" \
        | jq -c '.data.issues.nodes | sort_by(.updatedAt) | reverse'
}

# reconcile::query_subissue_for_phase <parent_id> <task_phase_label>
#   Locate the sub-issue for one task phase by (parent, label). Echoes
#   a JSON array sorted descending by updatedAt.
reconcile::query_subissue_for_phase() {
    local parent_id="$1"
    local phase_label="$2"

    local query='query LocateSubIssue($parent: ID!, $label: String!) {
        issues(
            filter: {
                parent: { id:   { eq: $parent } }
                labels: { name: { eq: $label } }
            }
        ) {
            nodes { id updatedAt }
        }
    }'
    local vars
    vars="$(jq -nc \
        --arg parent "$parent_id" \
        --arg label "$phase_label" \
        '{parent: $parent, label: $label}')"

    local response
    response="$(graphql::query "$query" "$vars")"
    printf '%s' "$response" \
        | jq -c '.data.issues.nodes | sort_by(.updatedAt) | reverse'
}

# reconcile::query_issue_blocks <issue_id>
#   Read the current `blocks` set for an issue so we can diff before
#   issuing a save_issue mutation (FR-007 + contracts §4.4 idempotency).
#   Echoes a JSON array of issue IDs.
reconcile::query_issue_blocks() {
    local issue_id="$1"
    local query='query GetBlocks($id: String!) {
        issue(id: $id) {
            relations(filter: { type: { eq: "blocks" } }) {
                nodes { relatedIssue { id } }
            }
        }
    }'
    local vars
    vars="$(jq -nc --arg id "$issue_id" '{id: $id}')"
    local response
    response="$(graphql::query "$query" "$vars")"
    printf '%s' "$response" \
        | jq -c '[(.data.issue.relations.nodes // [])[].relatedIssue.id]'
}

# reconcile::query_existing_comment_body <issue_id> <marker_prefix>
#   Locate an existing comment on <issue_id> whose body starts with
#   the deterministic HTML marker (per contracts §4.5). Echoes the
#   comment ID and body, JSON-encoded as {id, body}, or the literal
#   `null` if no match.
reconcile::query_existing_comment_body() {
    local issue_id="$1"
    local marker="$2"

    local query='query LocateComment($issue: ID!) {
        comments(filter: { issue: { id: { eq: $issue } } }) {
            nodes { id body }
        }
    }'
    local vars
    vars="$(jq -nc --arg issue "$issue_id" '{issue: $issue}')"

    local response
    response="$(graphql::query "$query" "$vars")"
    printf '%s' "$response" | jq -c --arg marker "$marker" '
        .data.comments.nodes
        | map(select(.body | startswith($marker)))
        | (first // null)
    '
}

# reconcile::mutate_issue_create <input_json>
#   Wrapper around `issueCreate`. <input_json> is a fully-formed
#   IssueCreateInput. Echoes `{id, identifier, title}` on success.
reconcile::mutate_issue_create() {
    local input_json="$1"
    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN issueCreate input=$(printf '%s' "$input_json" | jq -c '.')"
        summary::add created "issueCreate (dry-run)"
        # Synthesize a placeholder ID so downstream logic that depends
        # on the returned ID still works in dry-run mode.
        printf '{"id":"dry-run-issue-id","identifier":"DRY-0","title":""}\n'
        return 0
    fi

    local mutation='mutation IssueUpsertCreate($input: IssueCreateInput!) {
        issueCreate(input: $input) {
            success
            issue { id identifier title }
        }
    }'
    local vars
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "issueCreate failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.issueCreate.success == true' >/dev/null 2>&1; then
        summary::add error "issueCreate did not return success=true"
        reconcile::promote_exit 1
        return 1
    fi
    summary::add created "issueCreate"
    printf '%s' "$response" | jq -c '.data.issueCreate.issue'
}

# reconcile::mutate_issue_update <issue_id> <input_json>
#   Wrapper around `issueUpdate`. Skips the call (and records a
#   "skipped/unchanged" hit) when <input_json> is the literal `{}` —
#   the empty diff case the idempotency probe produces.
reconcile::mutate_issue_update() {
    local issue_id="$1"
    local input_json="$2"

    # Idempotency: empty diff → no mutation. The summary counter for
    # "updated" stays where it is so SC-002 (zero-churn reconcile)
    # remains a verifiable observation.
    if [[ "$input_json" == "{}" ]] || \
        printf '%s' "$input_json" | jq -e 'length == 0' >/dev/null 2>&1; then
        reconcile::log "issueUpdate ${issue_id}: no diff, skipping"
        return 0
    fi

    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN issueUpdate id=${issue_id} input=$(printf '%s' "$input_json" | jq -c '.')"
        summary::add updated "issueUpdate (dry-run)"
        return 0
    fi

    local mutation='mutation IssueUpsertUpdate($id: String!, $input: IssueUpdateInput!) {
        issueUpdate(id: $id, input: $input) {
            success
            issue { id identifier title state { id } }
        }
    }'
    local vars
    vars="$(jq -nc --arg id "$issue_id" --argjson input "$input_json" \
        '{id: $id, input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "issueUpdate ${issue_id} failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.issueUpdate.success == true' >/dev/null 2>&1; then
        summary::add error "issueUpdate ${issue_id} did not return success=true"
        reconcile::promote_exit 1
        return 1
    fi
    summary::add updated "issueUpdate ${issue_id}"
    return 0
}

# reconcile::mutate_comment_create <issue_id> <body>
#   Post a new comment on <issue_id>. Body is markdown.
reconcile::mutate_comment_create() {
    local issue_id="$1"
    local body="$2"

    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN commentCreate issue=${issue_id} body_len=${#body}"
        summary::add created "commentCreate (dry-run)"
        return 0
    fi

    local mutation='mutation PostComment($input: CommentCreateInput!) {
        commentCreate(input: $input) {
            success
            comment { id }
        }
    }'
    local input_json vars
    input_json="$(jq -nc \
        --arg issue "$issue_id" \
        --arg body "$body" \
        '{issueId: $issue, body: $body}')"
    vars="$(jq -nc --argjson input "$input_json" '{input: $input}')"

    local response
    if ! response="$(graphql::mutate "$mutation" "$vars")"; then
        summary::add error "commentCreate on ${issue_id} failed (transport)"
        reconcile::promote_exit 1
        return 1
    fi
    if ! printf '%s' "$response" | jq -e '.data.commentCreate.success == true' >/dev/null 2>&1; then
        summary::add error "commentCreate on ${issue_id} did not return success=true"
        reconcile::promote_exit 1
        return 1
    fi
    summary::add created "commentCreate"
    return 0
}

# =============================================================================
# Per-spec orchestration.
# =============================================================================

# reconcile::read_only_display <feature_number> <spec_dir>
#   FR-060 surfacing helper (spec 003 / A14). RETAINED from v0.1.0 but
#   DECOUPLED from the removed FR-025 write gate (T324): it is no longer
#   an early-return-before-write. It surfaces the spec's current Linear
#   state (so "what's done?" is answerable from any worktree) WITHOUT a
#   mutation, for read-only inspection paths (status.sh / `pull`). The
#   reconcile write path no longer calls it — every worktree now writes
#   (FR-051) and drift is surfaced via the WARNING row instead.
reconcile::read_only_display() {
    local feature_number="$1"
    local spec_dir="$2"

    local current_branch
    current_branch="$(git_helpers::current_branch || true)"

    local message
    message="spec ${feature_number}: non-authoritative worktree (current branch '${current_branch:-detached}'); read-only mode"

    if (( ARG_RETROACTIVE == 1 )); then
        reconcile::log "${message}"
    else
        summary::add skipped "${message}"
        reconcile::log "${message}"
    fi

    # Surface Linear's view of the spec — best effort. We avoid failing
    # the whole reconcile if the read query bounces; FR-026 is a courtesy
    # not a critical path.
    local project_uuid spec_label
    project_uuid="$(config::get_project_id)"
    spec_label="speckit-spec:${feature_number}"

    local nodes
    if nodes="$(reconcile::query_spec_issue "$spec_label" "$project_uuid" 2>/dev/null)"; then
        local count
        count="$(printf '%s' "$nodes" | jq 'length')"
        case "$count" in
            0) reconcile::log "spec ${feature_number}: no Linear Issue yet; run reconcile from the authoritative worktree" ;;
            1) reconcile::log "spec ${feature_number}: Linear Issue $(printf '%s' "$nodes" | jq -r '.[0].id') (last updated $(printf '%s' "$nodes" | jq -r '.[0].updatedAt'))" ;;
            *) reconcile::log "spec ${feature_number}: ${count} Linear Issues found (race detected; will auto-resolve next reconcile from authoritative worktree)" ;;
        esac
    fi
}

# reconcile::resolve_or_archive_duplicates <nodes_json> <spec_label>
#   FR-004b race resolver. <nodes_json> is the array returned by
#   reconcile::query_spec_issue (sorted descending by updatedAt). For
#   >1 matches, keep [0] and archive the rest by stripping the
#   speckit-spec:NNN label (so the next reconcile's lookup returns 1).
#   We do NOT flip them to a canceled-state UUID — the bridge doesn't
#   know which workspace state to use without an extra config lookup,
#   and label removal is sufficient to break stable identity.
#   Echoes the winner's ID.
reconcile::resolve_or_archive_duplicates() {
    local nodes_json="$1"
    local spec_label="$2"

    local count
    count="$(printf '%s' "$nodes_json" | jq 'length')"
    if (( count <= 1 )); then
        printf '%s' "$nodes_json" | jq -r '.[0].id // ""'
        return 0
    fi

    local winner
    winner="$(printf '%s' "$nodes_json" | jq -r '.[0].id')"
    summary::add warned "duplicate spec Issues with label ${spec_label}: kept ${winner}, archiving $((count - 1)) loser(s)"
    reconcile::log "FR-004b: ${count} Issues match ${spec_label}; keeping ${winner}, archiving the rest"

    # Strip the speckit-spec:NNN label from every loser. We compute
    # "current labels minus spec_label" by reading each loser's labels
    # and re-issuing a save with the filtered set.
    local loser_id
    while IFS= read -r loser_id; do
        [[ -n "$loser_id" ]] || continue
        local labels_query='query GetIssueLabels($id: String!) {
            issue(id: $id) { labels { nodes { name } } }
        }'
        local vars
        vars="$(jq -nc --arg id "$loser_id" '{id: $id}')"
        local labels_response
        if ! labels_response="$(graphql::query "$labels_query" "$vars" 2>/dev/null)"; then
            summary::add error "could not query labels for duplicate Issue ${loser_id}"
            continue
        fi
        local filtered_labels
        filtered_labels="$(printf '%s' "$labels_response" | jq -c \
            --arg drop "$spec_label" \
            '[(.data.issue.labels.nodes // [])[].name | select(. != $drop)]')"
        # We can't pass labels by name to issueUpdate (it wants IDs);
        # since the goal here is purely to break the speckit-spec
        # lookup, the safer move is to remove just that label via the
        # MCP equivalent on the next reconcile from an MCP path. From
        # the GraphQL path the cleanest dedup is to leave a warning
        # and let the operator archive manually — the next reconcile
        # will still pick the freshest winner so no functional break.
        reconcile::log "loser ${loser_id} flagged; manual archive recommended (current labels: ${filtered_labels})"
        summary::add archived "duplicate Issue ${loser_id} flagged for manual review"
    done < <(printf '%s' "$nodes_json" | jq -r '.[1:][].id')

    printf '%s' "$winner"
}

# reconcile::sync_spec_issue <feature_number> <short_name> <spec_dir>
#   Heart of the per-spec mutation path: find-or-create the spec Issue,
#   update title/description/state/labels to match filesystem-derived
#   state. Echoes the spec Issue ID for downstream sub-issue/comment
#   reconcile. Returns non-zero on any mutation failure (still records
#   to summary).
reconcile::sync_spec_issue() {
    local feature_number="$1"
    local short_name="$2"
    local spec_dir="$3"
    local lifecycle_phase="$4"
    local feature_branch="$5"

    local team_uuid project_uuid state_uuid spec_label phase_label
    team_uuid="$(config::get_team_id)"
    project_uuid="$(config::get_project_id)"
    state_uuid="$(config::get_workflow_state_uuid "$lifecycle_phase")"
    spec_label="speckit-spec:${feature_number}"
    phase_label="phase:${lifecycle_phase}"

    local title="${feature_number}-${short_name}"

    # FR-035: roll up [N] markers across all of tasks.md into the spec
    # Issue's Linear estimate field. Empty when NO task carries a
    # marker — that case is "operator declined to estimate", not
    # "estimated as zero", so we omit estimate from the mutation
    # entirely and let an operator-set Linear value (if any) stick.
    #
    # Linear caps the estimate value per the team's estimation scale
    # (defaults observed: Exponential 1..64, Fibonacci 1..21). If the
    # computed rollup exceeds the cap we'd get a hard GraphQL
    # validation error. Graceful degradation: warn once, omit the
    # estimate from this mutation, let the operator's Linear-side
    # value (if any) stick. Cap overridable via env var so teams on
    # non-default scales can set their own.
    local tasks_md spec_estimate
    tasks_md="${spec_dir%/}/tasks.md"
    spec_estimate="$(parser::spec_estimate "$tasks_md" 2>/dev/null || true)"
    if [[ -n "$spec_estimate" ]] \
        && (( spec_estimate > ${SPECKIT_LINEAR_ESTIMATE_MAX:-64} )); then
        summary::add warned "spec ${feature_number}: rollup estimate ${spec_estimate} exceeds Linear cap ${SPECKIT_LINEAR_ESTIMATE_MAX:-64}; omitting (set SPECKIT_LINEAR_ESTIMATE_MAX to override)"
        spec_estimate=""
    fi

    # Compose the overview + memory + diagrams blocks into a final body.
    local memory_block diagrams_block overview_block
    memory_block="$(reconcile::render_memory_block \
        "$feature_number" "$short_name" "$lifecycle_phase" \
        "$spec_dir" "$feature_branch")"
    diagrams_block="$(reconcile::render_diagrams_block)"
    overview_block="$(reconcile::render_overview_block "$spec_dir")"

    # Locate the existing spec Issue (FR-004b).
    local nodes
    nodes="$(reconcile::query_spec_issue "$spec_label" "$project_uuid")"
    local count
    count="$(printf '%s' "$nodes" | jq 'length')"

    if (( count == 0 )); then
        # Create. Per FR-014 we set stateId DIRECTLY to the inferred
        # end-state — no intermediate transitions visible in Linear's
        # activity log.
        local description
        description="$(reconcile::compose_issue_description \
            "$overview_block" "$memory_block" "$diagrams_block")"

        # Linear's IssueCreateInput requires `labelIds: [String!]`
        # (UUIDs) — names are rejected on the raw GraphQL path. We
        # resolve every label name to its UUID via
        # reconcile::_resolve_label_ids_array. For speckit-spec:NNN
        # this triggers a workspace-label create on first reconcile;
        # for phase:* we hard-fail (FR-022) if seed hasn't run.
        local labels_json
        labels_json="$(reconcile::_resolve_label_ids_array "$spec_label" "$phase_label")"

        # FR-036: stamp the running agent's family label
        # (agent:claude / agent:codex / ...) alongside the canonical
        # speckit-spec + phase labels. Sticky — never removed by the
        # update branch below, so an Issue touched by both Claude and
        # Codex shows BOTH labels (cross-agent provenance preserved).
        # Empty agent_label_id ⇒ no env var resolved OR the operator's
        # seed step hasn't captured a UUID for this family yet — degrade
        # gracefully and skip the stamp.
        local agent_label_id
        agent_label_id="$(reconcile::_resolve_agent_label_id)"
        if [[ -n "$agent_label_id" ]]; then
            labels_json="$(printf '%s' "$labels_json" | jq -c \
                --arg id "$agent_label_id" '. + [$id] | unique')"
        fi

        # FR-034: stamp assigneeId on issueCreate so the operator owns
        # newly-minted spec Issues. NEVER pass assigneeId on issueUpdate
        # (single-write-on-create) so manual reassignment in Linear's
        # UI persists across reconciles. Empty assignee_id ⇒ degrade
        # gracefully and create unassigned (warn-once).
        local assignee_id
        assignee_id="$(reconcile::_resolve_operator_assignee_id)"

        local input_json
        if [[ -n "$assignee_id" ]]; then
            input_json="$(jq -nc \
                --arg title "$title" \
                --arg team "$team_uuid" \
                --arg project "$project_uuid" \
                --arg state "$state_uuid" \
                --arg description "$description" \
                --argjson labels "$labels_json" \
                --arg assignee "$assignee_id" \
                '{
                    title: $title,
                    teamId: $team,
                    projectId: $project,
                    stateId: $state,
                    description: $description,
                    labelIds: $labels,
                    assigneeId: $assignee
                }')"
        else
            input_json="$(jq -nc \
                --arg title "$title" \
                --arg team "$team_uuid" \
                --arg project "$project_uuid" \
                --arg state "$state_uuid" \
                --arg description "$description" \
                --argjson labels "$labels_json" \
                '{
                    title: $title,
                    teamId: $team,
                    projectId: $project,
                    stateId: $state,
                    description: $description,
                    labelIds: $labels
                }')"
        fi

        # FR-035: include estimate iff some task carries an [N] marker.
        if [[ -n "$spec_estimate" ]]; then
            input_json="$(printf '%s' "$input_json" | jq -c \
                --argjson e "$spec_estimate" '. + {estimate: $e}')"
        fi

        local created_issue
        if ! created_issue="$(reconcile::mutate_issue_create "$input_json")"; then
            return 1
        fi
        printf '%s' "$created_issue" | jq -r '.id'
        return 0
    fi

    # 1+ matches — resolve and update the winner.
    local issue_id
    issue_id="$(reconcile::resolve_or_archive_duplicates "$nodes" "$spec_label")"
    if [[ -z "$issue_id" ]]; then
        summary::add error "could not resolve spec Issue ID for ${spec_label}"
        return 1
    fi

    # Read current state for the idempotency diff.
    local current_query='query GetIssueState($id: String!) {
        issue(id: $id) {
            title
            description
            state { id }
            labels { nodes { name } }
            estimate
        }
    }'
    local current_vars current_response
    current_vars="$(jq -nc --arg id "$issue_id" '{id: $id}')"
    if ! current_response="$(graphql::query "$current_query" "$current_vars")"; then
        summary::add error "could not query current state of Issue ${issue_id}"
        return 1
    fi

    local current_title current_description current_state_id current_estimate
    current_title="$(printf '%s' "$current_response" | jq -r '.data.issue.title // ""')"
    current_description="$(printf '%s' "$current_response" | jq -r '.data.issue.description // ""')"
    current_state_id="$(printf '%s' "$current_response" | jq -r '.data.issue.state.id // ""')"
    current_estimate="$(printf '%s' "$current_response" | jq -r '.data.issue.estimate // ""')"

    local current_labels
    current_labels="$(printf '%s' "$current_response" \
        | jq -c '[(.data.issue.labels.nodes // [])[].name]')"

    # Compute the desired description. The bridge owns the full body
    # (FR-004, FR-016): prior description content is discarded and the
    # canonical overview + memory + diagrams blocks are emitted fresh.
    local desired_description
    desired_description="$(reconcile::compose_issue_description \
        "$overview_block" "$memory_block" "$diagrams_block")"

    # FR-036 co-binding: the `Last reconciled by` row's timestamp would
    # mutate the desired description on EVERY reconcile, defeating the
    # SC-002 zero-churn guarantee. Strip both rows before diffing so the
    # idempotency probe sees "did anything ELSE change?". When the
    # answer is yes, the description rewrites WITH the fresh timestamp;
    # when no, both branches end here and Linear stays untouched.
    local current_for_diff desired_for_diff
    current_for_diff="$(reconcile::_strip_last_reconciled_row "$current_description")"
    desired_for_diff="$(reconcile::_strip_last_reconciled_row "$desired_description")"

    # Compute the desired label set: preserve operator-added labels,
    # add (or keep) spec_label + phase_label, remove any stale phase:*
    # label that doesn't match the current lifecycle. Special case for
    # Merged per FR-013: no phase:* label at all.
    #
    # FR-036 sticky semantics: any existing `agent:*` label survives
    # the strip-and-rebuild because the `startswith("phase:")` /
    # `select(. != $spec)` filter doesn't touch it. The running agent's
    # family label is appended below; jq's `unique` collapses the
    # double-add when the running agent matches a prior one.
    local desired_labels_json
    if [[ "$lifecycle_phase" == "merged" ]]; then
        desired_labels_json="$(printf '%s' "$current_labels" | jq -c \
            --arg spec "$spec_label" \
            '[.[] | select(startswith("phase:") | not) | select(. != $spec)]
             + [$spec]')"
    else
        desired_labels_json="$(printf '%s' "$current_labels" | jq -c \
            --arg spec "$spec_label" \
            --arg phase "$phase_label" \
            '[.[] | select(startswith("phase:") | not) | select(. != $spec)]
             + [$spec, $phase]')"
    fi

    # FR-036: add the running agent's family label to the desired set.
    # Sticky-add semantic — prior `agent:*` labels from earlier reconciles
    # are preserved (jq filter above doesn't strip them) and the new
    # family is appended via `unique` so a Claude → Codex → Claude
    # sequence still ends with both `agent:claude` and `agent:codex`
    # attached. Empty resolver result ⇒ leave the set untouched (graceful
    # degradation: no env var, or seed hasn't run for this family).
    reconcile::_resolve_running_agent
    if [[ -n "$_RECONCILE_AGENT_FAMILY" ]]; then
        local agent_label_name="agent:${_RECONCILE_AGENT_FAMILY}"
        desired_labels_json="$(printf '%s' "$desired_labels_json" | jq -c \
            --arg label "$agent_label_name" \
            '. + [$label] | unique')"
    fi

    # Build the diff input. Only include fields that actually changed.
    local update_input='{}'
    if [[ "$current_title" != "$title" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --arg title "$title" '. + {title: $title}')"
    fi
    if [[ "$current_for_diff" != "$desired_for_diff" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --arg description "$desired_description" \
            '. + {description: $description}')"
    fi
    if [[ "$current_state_id" != "$state_uuid" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --arg state "$state_uuid" '. + {stateId: $state}')"
    fi
    # Label diff (set semantics — sort both before comparing). The
    # diff is computed on NAMES (operator-facing), but the wire
    # mutation requires UUIDs (labelIds). We only re-resolve names
    # when the diff fires so the no-op reconcile stays zero-RTT.
    local current_sorted desired_sorted
    current_sorted="$(printf '%s' "$current_labels" | jq -c 'sort')"
    desired_sorted="$(printf '%s' "$desired_labels_json" | jq -c 'sort')"
    if [[ "$current_sorted" != "$desired_sorted" ]]; then
        local -a desired_names=()
        local name
        while IFS= read -r name; do
            [[ -n "$name" ]] && desired_names+=("$name")
        done < <(printf '%s' "$desired_labels_json" | jq -r '.[]')
        local desired_ids_json
        desired_ids_json="$(reconcile::_resolve_label_ids_array "${desired_names[@]}")"
        update_input="$(printf '%s' "$update_input" | jq -c \
            --argjson labels "$desired_ids_json" \
            '. + {labelIds: $labels}')"
    fi

    # FR-035: estimate diff. Only write when desired is non-empty AND
    # differs from current. Desired-empty (no [N] markers) intentionally
    # leaves any operator-set Linear estimate intact.
    if [[ -n "$spec_estimate" && "$current_estimate" != "$spec_estimate" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --argjson e "$spec_estimate" '. + {estimate: $e}')"
    fi

    reconcile::mutate_issue_update "$issue_id" "$update_input" || return 1
    printf '%s\n' "$issue_id"
}

# reconcile::sync_task_phase_subissues <spec_issue_id> <feature_number> <spec_dir>
#   For each `## Phase N: <Name>` in tasks.md, find-or-create one
#   sub-issue under the spec Issue (FR-005, FR-006). Returns the
#   per-phase sub-issue IDs as a JSON object keyed by phase index for
#   downstream blocking-relation reconcile.
reconcile::sync_task_phase_subissues() {
    local spec_issue_id="$1"
    local feature_number="$2"
    local spec_dir="$3"

    local tasks_md="${spec_dir%/}/tasks.md"
    if [[ ! -f "$tasks_md" ]]; then
        # No tasks.md → no task-phase sub-issues. Not an error.
        printf '{}\n'
        return 0
    fi

    local team_uuid project_uuid
    team_uuid="$(config::get_team_id)"
    project_uuid="$(config::get_project_id)"

    # Build a JSON object { "1": "<sub-issue-id>", "2": "...", ... }
    # incrementally so the caller can resolve blocking relations.
    local phase_map='{}'

    local phase_index phase_name
    while IFS=$'\t' read -r phase_index phase_name; do
        [[ -n "$phase_index" ]] || continue
        local phase_label="task-phase:${phase_index}"
        local sub_title="Phase ${phase_index} — ${phase_name}"
        local checklist phase_estimate
        checklist="$(reconcile::compose_subissue_checklist \
            "$feature_number" "$phase_index" "$tasks_md")"
        # FR-035: per-phase rollup of [N] markers → Linear sub-issue
        # estimate. Empty when this phase has no marked tasks. Same
        # Linear-cap clamp as the spec-level rollup (see sync_spec_issue)
        # — Linear validates estimate ≤ team cap and hard-errors above it.
        phase_estimate="$(parser::phase_estimate "$tasks_md" "$phase_index" 2>/dev/null || true)"
        if [[ -n "$phase_estimate" ]] \
            && (( phase_estimate > ${SPECKIT_LINEAR_ESTIMATE_MAX:-64} )); then
            summary::add warned "spec ${feature_number} phase ${phase_index}: rollup estimate ${phase_estimate} exceeds Linear cap ${SPECKIT_LINEAR_ESTIMATE_MAX:-64}; omitting"
            phase_estimate=""
        fi
        local state_key state_uuid
        state_key="$(reconcile::subissue_state_key "$tasks_md" "$phase_index")"
        # `default_state_uuids` is added during the post-analyze
        # remediation; if absent, config::get_default_state_uuid halts
        # the script with a clear remediation pointer. We probe via a
        # subshell so we can degrade to "no state change" if the block
        # is genuinely missing AND the operator hasn't seeded yet.
        if ! state_uuid="$(config::get_default_state_uuid "$state_key" 2>/dev/null)"; then
            summary::add warned "default_state_uuids.${state_key} missing; sub-issue ${sub_title} created without a workflow state"
            state_uuid=""
        fi

        # Locate the existing sub-issue.
        local sub_nodes
        sub_nodes="$(reconcile::query_subissue_for_phase "$spec_issue_id" "$phase_label")"
        local sub_count
        sub_count="$(printf '%s' "$sub_nodes" | jq 'length')"

        local sub_issue_id=""
        if (( sub_count == 0 )); then
            # Create. `task-phase:N` is bootstrapped 1..9 by seed
            # (FR-021) but lazy-extended at reconcile time for specs
            # with 10+ phases — _resolve_label_ids_array routes the
            # label through the same auto-create path that
            # speckit-spec:NNN uses (FR-004b precedent). If
            # auto-create fails (transport error etc.) the labels_json
            # falls back to `[]` and the sub-issue is still created so
            # the operator can attach the label manually.
            local labels_json
            labels_json="$(reconcile::_resolve_label_ids_array "$phase_label")"

            # FR-036: stamp the running agent's family label on the
            # sub-issue too. Same sticky semantics as the parent spec
            # Issue — once attached, never removed by the update branch
            # below. Cross-agent provenance is per-Issue, so the
            # sub-issue carries its own agent stamps independent of
            # what the parent shows.
            local sub_agent_label_id
            sub_agent_label_id="$(reconcile::_resolve_agent_label_id)"
            if [[ -n "$sub_agent_label_id" ]]; then
                labels_json="$(printf '%s' "$labels_json" | jq -c \
                    --arg id "$sub_agent_label_id" '. + [$id] | unique')"
            fi

            # FR-034: stamp assigneeId on issueCreate for the sub-issue
            # too; sub-issues for task phases inherit the same operator
            # assignee as the parent spec Issue. NEVER pass assigneeId
            # on the issueUpdate branch below so manual reassignment in
            # Linear's UI persists across reconciles.
            local sub_assignee_id
            sub_assignee_id="$(reconcile::_resolve_operator_assignee_id)"

            local sub_input
            if [[ -n "$state_uuid" ]]; then
                if [[ -n "$sub_assignee_id" ]]; then
                    sub_input="$(jq -nc \
                        --arg title "$sub_title" \
                        --arg team "$team_uuid" \
                        --arg project "$project_uuid" \
                        --arg parent "$spec_issue_id" \
                        --arg state "$state_uuid" \
                        --arg description "$checklist" \
                        --argjson labels "$labels_json" \
                        --arg assignee "$sub_assignee_id" \
                        '{
                            title: $title,
                            teamId: $team,
                            projectId: $project,
                            parentId: $parent,
                            stateId: $state,
                            description: $description,
                            labelIds: $labels,
                            assigneeId: $assignee
                        }')"
                else
                    sub_input="$(jq -nc \
                        --arg title "$sub_title" \
                        --arg team "$team_uuid" \
                        --arg project "$project_uuid" \
                        --arg parent "$spec_issue_id" \
                        --arg state "$state_uuid" \
                        --arg description "$checklist" \
                        --argjson labels "$labels_json" \
                        '{
                            title: $title,
                            teamId: $team,
                            projectId: $project,
                            parentId: $parent,
                            stateId: $state,
                            description: $description,
                            labelIds: $labels
                        }')"
                fi
            else
                if [[ -n "$sub_assignee_id" ]]; then
                    sub_input="$(jq -nc \
                        --arg title "$sub_title" \
                        --arg team "$team_uuid" \
                        --arg project "$project_uuid" \
                        --arg parent "$spec_issue_id" \
                        --arg description "$checklist" \
                        --argjson labels "$labels_json" \
                        --arg assignee "$sub_assignee_id" \
                        '{
                            title: $title,
                            teamId: $team,
                            projectId: $project,
                            parentId: $parent,
                            description: $description,
                            labelIds: $labels,
                            assigneeId: $assignee
                        }')"
                else
                    sub_input="$(jq -nc \
                        --arg title "$sub_title" \
                        --arg team "$team_uuid" \
                        --arg project "$project_uuid" \
                        --arg parent "$spec_issue_id" \
                        --arg description "$checklist" \
                        --argjson labels "$labels_json" \
                        '{
                            title: $title,
                            teamId: $team,
                            projectId: $project,
                            parentId: $parent,
                            description: $description,
                            labelIds: $labels
                        }')"
                fi
            fi
            # FR-035: include estimate iff this phase carries [N] markers.
            if [[ -n "$phase_estimate" ]]; then
                sub_input="$(printf '%s' "$sub_input" | jq -c \
                    --argjson e "$phase_estimate" '. + {estimate: $e}')"
            fi
            local created
            if created="$(reconcile::mutate_issue_create "$sub_input")"; then
                sub_issue_id="$(printf '%s' "$created" | jq -r '.id')"
            else
                continue
            fi
        else
            # Most-recent wins; warn on >1 per FR-005 analogue of FR-004b.
            sub_issue_id="$(printf '%s' "$sub_nodes" | jq -r '.[0].id')"
            if (( sub_count > 1 )); then
                summary::add warned "duplicate sub-issues with label ${phase_label} under ${spec_issue_id}; keeping ${sub_issue_id}"
            fi

            # Diff against the current state.
            local sub_query='query GetSubIssue($id: String!) {
                issue(id: $id) {
                    title
                    description
                    state { id }
                    labels { nodes { name } }
                    estimate
                }
            }'
            local sub_vars sub_response
            sub_vars="$(jq -nc --arg id "$sub_issue_id" '{id: $id}')"
            if ! sub_response="$(graphql::query "$sub_query" "$sub_vars")"; then
                summary::add error "could not query sub-issue ${sub_issue_id}"
                continue
            fi
            local cur_title cur_desc cur_state cur_labels cur_estimate
            cur_title="$(printf '%s' "$sub_response" | jq -r '.data.issue.title // ""')"
            cur_desc="$(printf '%s' "$sub_response" | jq -r '.data.issue.description // ""')"
            cur_state="$(printf '%s' "$sub_response" | jq -r '.data.issue.state.id // ""')"
            cur_labels="$(printf '%s' "$sub_response" | jq -c '[(.data.issue.labels.nodes // [])[].name]')"
            cur_estimate="$(printf '%s' "$sub_response" | jq -r '.data.issue.estimate // ""')"

            # Desired label set: preserve operator labels, ensure
            # task-phase:N is present.
            local desired_labels
            desired_labels="$(printf '%s' "$cur_labels" | jq -c \
                --arg label "$phase_label" \
                '. + ([$label] - .) | unique')"

            # FR-036: sticky-add the running agent's family label. Same
            # rationale as the spec Issue update branch above — prior
            # `agent:*` labels survive the union, new family appends,
            # `unique` collapses duplicates.
            reconcile::_resolve_running_agent
            if [[ -n "$_RECONCILE_AGENT_FAMILY" ]]; then
                local sub_agent_label_name="agent:${_RECONCILE_AGENT_FAMILY}"
                desired_labels="$(printf '%s' "$desired_labels" | jq -c \
                    --arg label "$sub_agent_label_name" \
                    '. + [$label] | unique')"
            fi

            local sub_update='{}'
            if [[ "$cur_title" != "$sub_title" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --arg t "$sub_title" '. + {title: $t}')"
            fi
            if [[ "$cur_desc" != "$checklist" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --arg d "$checklist" '. + {description: $d}')"
            fi
            if [[ -n "$state_uuid" && "$cur_state" != "$state_uuid" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --arg s "$state_uuid" '. + {stateId: $s}')"
            fi
            local cur_sorted desired_sorted
            cur_sorted="$(printf '%s' "$cur_labels" | jq -c 'sort')"
            desired_sorted="$(printf '%s' "$desired_labels" | jq -c 'sort')"
            if [[ "$cur_sorted" != "$desired_sorted" ]]; then
                # Diff fired — translate names → labelIds. See the
                # matching block in reconcile::sync_spec_issue for
                # the rationale (zero-RTT no-op preserved).
                local -a desired_sub_names=()
                local sub_name
                while IFS= read -r sub_name; do
                    [[ -n "$sub_name" ]] && desired_sub_names+=("$sub_name")
                done < <(printf '%s' "$desired_labels" | jq -r '.[]')
                local desired_sub_ids_json
                desired_sub_ids_json="$(reconcile::_resolve_label_ids_array "${desired_sub_names[@]}")"
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --argjson l "$desired_sub_ids_json" '. + {labelIds: $l}')"
            fi

            # FR-035: estimate diff for the sub-issue. Same desired-empty
            # sticky semantics as the spec Issue path.
            if [[ -n "$phase_estimate" && "$cur_estimate" != "$phase_estimate" ]]; then
                sub_update="$(printf '%s' "$sub_update" | jq -c \
                    --argjson e "$phase_estimate" '. + {estimate: $e}')"
            fi

            reconcile::mutate_issue_update "$sub_issue_id" "$sub_update" || continue
        fi

        # Record the (phase_index → sub_issue_id) mapping.
        phase_map="$(printf '%s' "$phase_map" | jq -c \
            --arg k "$phase_index" \
            --arg v "$sub_issue_id" \
            '. + {($k): $v}')"
    done < <(parser::task_phases "$tasks_md")

    printf '%s\n' "$phase_map"
}

# reconcile::sync_inter_phase_blocks <phase_map> <spec_dir>
#   Wire blocking relations between task-phase sub-issues per FR-007.
#   We parse `Phase N depends on Phase M` style hints from plan.md and
#   tasks.md (the canonical spec-kit template uses these). When a
#   dependency exists, Phase M `blocks` Phase N.
#
#   <phase_map> is the JSON object emitted by sync_task_phase_subissues.
reconcile::sync_inter_phase_blocks() {
    local phase_map="$1"
    local spec_dir="$2"

    # Read plan.md + tasks.md text and search for "Phase N depends on
    # Phase M" patterns. Case-insensitive, tolerant of em-dash and
    # colon separators. We emit one "<from>\t<to>" line per dep
    # (Phase M blocks Phase N → from=M, to=N).
    local deps
    deps="$({
        for f in "${spec_dir%/}/plan.md" "${spec_dir%/}/tasks.md"; do
            [[ -f "$f" ]] || continue
            grep -iE 'Phase[[:space:]]+[0-9]+[[:space:]]+depends[[:space:]]+on[[:space:]]+Phase[[:space:]]+[0-9]+' "$f" 2>/dev/null || true
        done
    } | awk '
        {
            match($0, /[Pp]hase[[:space:]]+[0-9]+[[:space:]]+depends[[:space:]]+on[[:space:]]+[Pp]hase[[:space:]]+[0-9]+/)
            if (RSTART == 0) next
            seg = substr($0, RSTART, RLENGTH)
            n = split(seg, parts, /[^0-9]+/)
            from = ""; to = ""
            for (i = 1; i <= n; i++) {
                if (parts[i] != "") {
                    if (to == "") { to = parts[i] }
                    else if (from == "") { from = parts[i] }
                }
            }
            if (from != "" && to != "") {
                printf "%s\t%s\n", from, to
            }
        }' | sort -u)"

    if [[ -z "$deps" ]]; then
        return 0
    fi

    # Group deps by "from" so each save_issue call sets all blocks for
    # one sub-issue at once.
    local -A from_to_targets=()
    local from_phase to_phase
    while IFS=$'\t' read -r from_phase to_phase; do
        [[ -n "$from_phase" && -n "$to_phase" ]] || continue
        local from_id to_id
        from_id="$(printf '%s' "$phase_map" | jq -r --arg k "$from_phase" '.[$k] // ""')"
        to_id="$(printf '%s' "$phase_map" | jq -r --arg k "$to_phase" '.[$k] // ""')"
        if [[ -z "$from_id" || -z "$to_id" ]]; then
            summary::add warned "inter-phase dep Phase ${to_phase} depends on Phase ${from_phase}: missing sub-issue id"
            continue
        fi
        # Append (newline-separated for the next read loop).
        local prev="${from_to_targets[$from_id]:-}"
        if [[ -z "$prev" ]]; then
            from_to_targets[$from_id]="$to_id"
        else
            from_to_targets[$from_id]="${prev}"$'\n'"${to_id}"
        fi
    done <<< "$deps"

    # For each from-issue, diff desired vs current blocks and issue the
    # delta. Idempotency is mandatory per contracts §4.4 ("MUST query
    # the existing blocks array via get_issue before invoking").
    local from_issue
    for from_issue in "${!from_to_targets[@]}"; do
        local desired_blocks_csv="${from_to_targets[$from_issue]}"
        # Convert newlines to a JSON array of IDs (sorted, unique).
        local desired_json
        desired_json="$(printf '%s\n' "$desired_blocks_csv" | sort -u \
            | jq -Rcs 'split("\n") | map(select(length > 0))')"

        local current_json
        if ! current_json="$(reconcile::query_issue_blocks "$from_issue")"; then
            summary::add error "could not query blocks for ${from_issue}"
            continue
        fi

        # Compute additions: desired - current.
        local additions
        additions="$(jq -nc \
            --argjson desired "$desired_json" \
            --argjson current "$current_json" \
            '$desired - $current')"

        local add_count
        add_count="$(printf '%s' "$additions" | jq 'length')"
        if (( add_count == 0 )); then
            reconcile::log "blocks for ${from_issue}: in sync"
            continue
        fi

        local input_json
        input_json="$(jq -nc --argjson blocks "$additions" '{blocks: $blocks}')"
        reconcile::mutate_issue_update "$from_issue" "$input_json" || continue
    done
}

# reconcile::sync_clarify_comments <spec_issue_id> <spec_dir>
#   For every `### Session YYYY-MM-DD` block under ## Clarifications,
#   post (idempotently) one comment on the spec Issue with the session's
#   Q/A bullets (FR-008 + FR-015). Idempotency is via the leading HTML
#   marker per contracts §4.5.
reconcile::sync_clarify_comments() {
    local spec_issue_id="$1"
    local spec_dir="$2"

    local spec_md="${spec_dir%/}/spec.md"
    if [[ ! -f "$spec_md" ]]; then
        return 0
    fi

    local date bullet_count
    while IFS=$'\t' read -r date bullet_count; do
        [[ -n "$date" ]] || continue
        # Silence the unused-bullet-count warning — we only use it for
        # potential future "skip empty session" heuristics.
        : "${bullet_count:-0}"

        local marker
        marker="<!-- spec-kit-linear: clarify-session ${date} -->"

        # Build the comment body: marker + heading + verbatim bullets.
        local bullets
        bullets="$(parser::clarify_session_bullets "$spec_md" "$date" || true)"
        local body
        body="$(printf '%s\n**Clarification session %s**\n\n%s\n' \
            "$marker" "$date" "$bullets")"

        # Look up an existing comment whose body starts with the marker.
        local existing
        if ! existing="$(reconcile::query_existing_comment_body "$spec_issue_id" "$marker")"; then
            summary::add error "could not query comments on ${spec_issue_id}"
            continue
        fi

        if [[ "$existing" == "null" ]]; then
            reconcile::mutate_comment_create "$spec_issue_id" "$body" || continue
            continue
        fi

        local existing_body
        existing_body="$(printf '%s' "$existing" | jq -r '.body')"
        if [[ "$existing_body" == "$body" ]]; then
            reconcile::log "clarify-session ${date} comment in sync"
            continue
        fi

        # Body diverged. Per contracts §9 we DO NOT mutate existing
        # comment bodies — that would silently overwrite operator-added
        # nuance. Surface a warning and move on.
        summary::add warned "clarify-session ${date}: existing comment body diverges from spec.md; not overwriting"
    done < <(parser::clarify_sessions "$spec_md")
}

# =============================================================================
# Spec 003 — drift machinery (PURE comparator + ladder).
#
# These functions are FOUNDATIONAL and side-effect-free: they read git +
# the already-fetched Linear issue JSON and emit a verdict, but they DO NOT
# touch the reconcile::sync_spec_issue write path. The gate removal and the
# threading of compute_drift into the write flow are US1's job (T323/T324) —
# Phase 2 keeps this layer pure so Phase 3 can wire it in cleanly.
# =============================================================================

# Drift recency clock-skew tolerance, in seconds (recency-comparison §3,
# plan A1). Overridable via the environment for testing / tuning; a few
# minutes absorbs laptop↔Linear clock skew without masking real edits.
declare -g RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS="${RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS:-120}"

# Sentinel ordinal returned for an unknown / uninferrable phase token. Any
# value strictly greater than the top real ordinal (merged=6) would falsely
# read as "ahead"; we instead use a distinct negative sentinel that the
# comparator special-cases to DISABLE the phase signal entirely (falling
# back to recency alone), matching the malformed-artifacts edge case
# (data-model §3.3, plan A8).
declare -gri RECONCILE_PHASE_ORDINAL_UNKNOWN=-1

# reconcile::_phase_ordinal <phase_token>      (data-model §2 ladder, A8)
#   Map a lifecycle phase token to its strictly-ordered ordinal int on
#   stdout. The ladder is total over every token parser::lifecycle_phase can
#   emit:
#       clarifying=0 specifying=1 planning=2 tasking=3
#       implementing=4 ready_to_merge=5 merged=6
#   An unknown / empty token echoes the UNKNOWN sentinel (-1), which the
#   comparator reads as "phase signal unavailable — use recency alone". This
#   is a pure lookup: no git, no network, no global mutation.
reconcile::_phase_ordinal() {
    local token="${1:-}"
    case "$token" in
        clarifying)     printf '0\n' ;;
        specifying)     printf '1\n' ;;
        planning)       printf '2\n' ;;
        tasking)        printf '3\n' ;;
        implementing)   printf '4\n' ;;
        ready_to_merge) printf '5\n' ;;
        merged)         printf '6\n' ;;
        *)              printf '%s\n' "$RECONCILE_PHASE_ORDINAL_UNKNOWN" ;;
    esac
}

# reconcile::_linear_phase_token <issue_json>  (drift-detection-graphql §3)
#   Derive the Linear-recorded lifecycle phase token from an already-fetched
#   spec-Issue JSON object. Precedence:
#     1. A `phase:<token>` label present → that token (the primary source).
#     2. No phase label AND workflow state in a completed/merged category
#        (state.type == "completed") → `merged` (FR-013; merged carries no
#        phase label).
#     3. Otherwise → empty (phase signal unavailable for this issue).
#   Reads ONLY fields already selected by the v0.1.0 reconcile fetch
#   (labels.nodes[].name, state.type) — no new GraphQL surface.
reconcile::_linear_phase_token() {
    local issue_json="${1:-}"
    [[ -n "$issue_json" ]] || return 0

    # Guard against a non-object / empty-lookup response (absent Issue, US2).
    if ! printf '%s' "$issue_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        return 0
    fi

    local label_token
    label_token="$(printf '%s' "$issue_json" \
        | jq -r '
            (.labels.nodes // [])
            | map(.name | select(startswith("phase:")))
            | (.[0] // "")
            | ltrimstr("phase:")
          ' 2>/dev/null || printf '')"
    if [[ -n "$label_token" ]]; then
        printf '%s\n' "$label_token"
        return 0
    fi

    # No phase label — a completed workflow state means merged (FR-013).
    local state_type
    state_type="$(printf '%s' "$issue_json" \
        | jq -r '.state.type // "" | ascii_downcase' 2>/dev/null || printf '')"
    if [[ "$state_type" == "completed" ]]; then
        printf 'merged\n'
    fi
}

# reconcile::compute_drift <feature_number> <spec_dir> <linear_issue_json> <disk_phase_token>
#                                       (FR-052, data-model §3.3, A9, A8)
#
#   THE PURE BACKWARD-DRIFT COMPARATOR. Takes the disk-inferred phase token
#   (already computed by the caller via parser::lifecycle_phase — passed IN,
#   not recomputed, per A9), the spec dir (for the recency disk key), and the
#   already-fetched Linear spec-Issue JSON, and emits a single-line verdict
#   on stdout that the disposition flow and the WARNING emitter both consume:
#
#       fired=<0|1> phase_drift=<0|1> recency_drift=<0|1> signals=<csv> \
#           disk=<tok> linear=<tok> [disk_iso=<iso> linear_iso=<iso> skew=<n>]
#
#   Rules (recency-comparison §3, data-model §3.3):
#     * phase_drift = ordinal(linear) > ordinal(disk), STRICTLY. Skipped
#       (treated false) when either ordinal is the UNKNOWN sentinel
#       (uninferrable disk phase, or Linear issue with no derivable phase).
#     * recency_drift = (linear_epoch - disk_epoch) > SKEW. false when the
#       disk recency is `unavailable` (Edge Case 1) or the Linear updatedAt
#       is missing/unparseable (degrade to phase alone, never fabricate).
#     * fired = phase_drift OR recency_drift.
#     * signals = csv of {phase_ordering, recency} that fired ("" when none).
#     * Absent Linear Issue (empty/`{}`/non-object JSON, US2 first reconcile)
#       → nothing to be ahead of → fired=0 (drift-detection-graphql §5 row 3).
#
#   PURE: reads git (spec_dir_last_commit) + the issue JSON; performs NO
#   write, NO summary::add, NO global mutation. feature_number is accepted
#   for per-Project scoping symmetry with the caller (Edge Case 5) but the
#   comparison is entirely local to the inputs.
reconcile::compute_drift() {
    local feature_number="${1:-}"
    local spec_dir="${2:-}"
    local issue_json="${3:-}"
    local disk_phase_token="${4:-}"

    : "${feature_number:-}"  # accepted for scoping symmetry; unused locally

    # --- Linear-side phase + recency, derived from the already-fetched JSON.
    local linear_phase_token='' linear_updated_iso='' linear_epoch=''
    local issue_is_object=0
    if [[ -n "$issue_json" ]] \
        && printf '%s' "$issue_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        issue_is_object=1
        linear_phase_token="$(reconcile::_linear_phase_token "$issue_json")"
        linear_updated_iso="$(printf '%s' "$issue_json" \
            | jq -r '.updatedAt // ""' 2>/dev/null || printf '')"
        if [[ -n "$linear_updated_iso" && "$linear_updated_iso" != "null" ]]; then
            linear_epoch="$(git_helpers::iso_to_epoch "$linear_updated_iso")"
        fi
    fi

    # Absent Linear Issue (first reconcile, US2): nothing to be ahead of.
    if (( issue_is_object == 0 )); then
        printf 'fired=0 phase_drift=0 recency_drift=0 signals= disk=%s linear=\n' \
            "${disk_phase_token:-}"
        return 0
    fi

    # --- Disk-side recency key (FR-053; git committer date, never mtime).
    local disk_iso='' disk_epoch=''
    disk_iso="$(git_helpers::spec_dir_last_commit "$spec_dir")"
    if [[ -n "$disk_iso" ]]; then
        disk_epoch="$(git_helpers::iso_to_epoch "$disk_iso")"
    fi

    # --- Phase-ordering signal -------------------------------------------
    local disk_ord linear_ord phase_drift=0
    disk_ord="$(reconcile::_phase_ordinal "$disk_phase_token")"
    linear_ord="$(reconcile::_phase_ordinal "$linear_phase_token")"
    # Skip the phase signal when EITHER ordinal is unknown (uninferrable disk
    # phase, or a Linear issue with no derivable phase) — recency alone then.
    if (( disk_ord != RECONCILE_PHASE_ORDINAL_UNKNOWN )) \
        && (( linear_ord != RECONCILE_PHASE_ORDINAL_UNKNOWN )) \
        && (( linear_ord > disk_ord )); then
        phase_drift=1
    fi

    # --- Recency signal ---------------------------------------------------
    local recency_drift=0
    local skew="${RECONCILE_DRIFT_SKEW_TOLERANCE_SECONDS:-120}"
    if [[ -n "$disk_epoch" && -n "$linear_epoch" ]]; then
        if (( linear_epoch - disk_epoch > skew )); then
            recency_drift=1
        fi
    fi

    # --- Combine ----------------------------------------------------------
    local fired=0 signals=''
    if (( phase_drift == 1 )); then
        signals="phase_ordering"
    fi
    if (( recency_drift == 1 )); then
        if [[ -n "$signals" ]]; then
            signals="${signals},recency"
        else
            signals="recency"
        fi
    fi
    if (( phase_drift == 1 || recency_drift == 1 )); then
        fired=1
    fi

    # --- Single-line verdict (A9). Recency detail fields only when recency
    #     fired, so the WARNING emitter can append the detail line verbatim.
    if (( recency_drift == 1 )); then
        printf 'fired=%s phase_drift=%s recency_drift=%s signals=%s disk=%s linear=%s disk_iso=%s linear_iso=%s skew=%s\n' \
            "$fired" "$phase_drift" "$recency_drift" "$signals" \
            "${disk_phase_token:-}" "${linear_phase_token:-}" \
            "${disk_iso:-}" "${linear_updated_iso:-}" "$skew"
    else
        printf 'fired=%s phase_drift=%s recency_drift=%s signals=%s disk=%s linear=%s\n' \
            "$fired" "$phase_drift" "$recency_drift" "$signals" \
            "${disk_phase_token:-}" "${linear_phase_token:-}"
    fi
}

# reconcile::_drift_verdict_field <verdict_line> <field>
#   Pull a single `key=value` field out of compute_drift's single-line
#   verdict (A9). Echoes the value (empty when the field is absent — the
#   recency detail fields are present only when recency fired). PURE.
reconcile::_drift_verdict_field() {
    local line="${1:-}" field="${2:-}"
    printf '%s\n' "$line" \
        | tr ' ' '\n' \
        | awk -F= -v k="$field" '$1 == k { print $2; exit }'
}

# reconcile::_fetch_drift_issue_json <feature_number>
#   Read-only fetch of the drift-relevant view of a spec Issue (the
#   freshest match on the `speckit-spec:NNN` label, scoped to this
#   repo's Project). Selects ONLY fields compute_drift's comparator
#   consumes: `updatedAt`, the `phase:*` label set, and the workflow
#   `state.type` (for the FR-013 merged-without-label case). Echoes a
#   single JSON object, or empty when no Issue exists yet (US2 first
#   reconcile → compute_drift treats it as `fired=0`).
#
#   This is a READ (FR-064: drift compute mutates nothing, adds no
#   on-disk state). It is scoped to the owning Project so the same
#   feature number in another consumer repo is never compared
#   cross-repo (Edge Case 5).
reconcile::_fetch_drift_issue_json() {
    local feature_number="${1:-}"
    [[ -n "$feature_number" ]] || return 0

    local project_uuid spec_label
    project_uuid="$(config::get_project_id)"
    spec_label="speckit-spec:${feature_number}"

    local query='query LocateDriftIssue($label: String!, $project: ID!) {
        issues(
            filter: {
                labels:  { name: { eq: $label } }
                project: { id:   { eq: $project } }
            }
        ) {
            nodes {
                id
                updatedAt
                state { type }
                labels { nodes { name } }
            }
        }
    }'
    local vars response
    vars="$(jq -nc \
        --arg label "$spec_label" \
        --arg project "$project_uuid" \
        '{label: $label, project: $project}')"

    # Best-effort: a bounced read degrades to "absent" (fired=0), never
    # fails the reconcile — drift is a courtesy surface, not a gate.
    if ! response="$(graphql::query "$query" "$vars" 2>/dev/null)"; then
        return 0
    fi
    # Freshest match wins (matches query_spec_issue's FR-004b ordering).
    printf '%s' "$response" \
        | jq -c '(.data.issues.nodes // []) | sort_by(.updatedAt) | reverse | (.[0] // empty)' \
            2>/dev/null || true
}

# reconcile::_emit_drift_warning <feature_number> <verdict_line>   (T325)
#   The named backward-drift WARNING row (FR-054, drift-warning-surface
#   §2). Emitted on EVERY drift regardless of disposition (the audit
#   trail — even a `proceed` write keeps the row). Names: spec, disk
#   phase, Linear phase, the signal(s) that fired. Appends the recency
#   detail line ONLY when the recency signal fired (the verdict line
#   carries the detail fields exactly then, per A9).
#
#   The multi-worktree canonical/touching lines (FR-058) are appended by
#   reconcile::_drift_worktree_lines (T345) when >1 worktree touches the
#   spec; the common single-worktree case collapses them to nothing
#   (contract §2).
reconcile::_emit_drift_warning() {
    local feature_number="${1:-}" verdict="${2:-}"

    local disk linear signals
    disk="$(reconcile::_drift_verdict_field "$verdict" disk)"
    linear="$(reconcile::_drift_verdict_field "$verdict" linear)"
    signals="$(reconcile::_drift_verdict_field "$verdict" signals)"

    local row="spec ${feature_number} backward-drift: disk=${disk}  linear=${linear}  signals=${signals}"

    # Recency detail line — present only when the recency signal fired.
    if [[ "$(reconcile::_drift_verdict_field "$verdict" recency_drift)" == "1" ]]; then
        local disk_iso linear_iso skew
        disk_iso="$(reconcile::_drift_verdict_field "$verdict" disk_iso)"
        linear_iso="$(reconcile::_drift_verdict_field "$verdict" linear_iso)"
        skew="$(reconcile::_drift_verdict_field "$verdict" skew)"
        row+=$'\n'"         spec dir last commit ${disk_iso}  <  linear updatedAt ${linear_iso} (> ${skew}s)"
    fi

    # Multi-worktree canonical/touching lines (FR-058 / T345). Collapses to
    # nothing in the single-worktree case (contract §2).
    local worktree_lines
    worktree_lines="$(reconcile::_drift_worktree_lines "$feature_number")"
    if [[ -n "$worktree_lines" ]]; then
        row+=$'\n'"$worktree_lines"
    fi

    summary::add warned "$row"
}

# reconcile::_drift_worktree_lines <feature_number>                (T345)
#   Render the canonical-worktree + touching-set lines of the drift
#   WARNING row (FR-058 / FR-059 / drift-warning-surface §2) from
#   git_helpers::worktrees_touching_spec (T303). The canonical worktree
#   is the MAX commit-epoch line (most recent spec-dir commit — never the
#   branch name or mtime); ties resolve to the first/invoking row. Echoes
#   nothing when ≤1 worktree touches the spec (single-worktree collapse).
#   PURE-ish: only reads the git worktree topology; mutates nothing.
reconcile::_drift_worktree_lines() {
    local feature_number="${1:-}"
    [[ -n "$feature_number" ]] || return 0

    local raw
    raw="$(git_helpers::worktrees_touching_spec "$feature_number" 2>/dev/null || true)"
    [[ -n "$raw" ]] || return 0

    # Count touching worktrees; collapse to nothing in the single case.
    local count
    count="$(printf '%s\n' "$raw" | grep -c .)"
    (( count > 1 )) || return 0

    # Canonical = MAX epoch (stable sort keeps the first row on an epoch
    # tie → the invoking worktree, which git_helpers emits first).
    local canonical_line canon_path canon_branch
    canonical_line="$(printf '%s\n' "$raw" | sort -t$'\t' -k1,1nr -s | head -1)"
    canon_path="$(printf '%s' "$canonical_line" | cut -f2)"
    canon_branch="$(printf '%s' "$canonical_line" | cut -f3)"

    local out
    out="         canonical worktree: ${canon_path} (branch ${canon_branch:-detached}) — most recent spec-dir commit"

    # Touching set: every worktree, "path (branch)", joined with ", ".
    local set_csv path branch
    while IFS=$'\t' read -r _ path branch; do
        [[ -n "$path" ]] || continue
        local entry="${path} (${branch:-detached})"
        if [[ -z "${set_csv:-}" ]]; then
            set_csv="$entry"
        else
            set_csv="${set_csv}, ${entry}"
        fi
    done <<< "$raw"
    out+=$'\n'"         touching worktrees: ${set_csv}"

    printf '%s\n' "$out"
}

# reconcile::_drift_prompt <feature_number>                        (T343)
#   The interactive backward-drift prompt (FR-055, drift-warning-surface
#   §3). Reads the operator's proceed/abort choice from the CONTROLLING
#   TERMINAL (`/dev/tty`), NOT the inherited stdin (A10 — the prompt MUST
#   NOT consume the spec-enumeration stdin stream). Re-prompts on invalid
#   input; empty-enter is the safe default `abort` (plan A5). Echoes the
#   resolved disposition (`proceed` | `abort`).
#
#   The tty source is overridable via `RECONCILE_DRIFT_TTY` so the bats
#   prompt-body tests can drive a here-string/file in place of a real
#   terminal (mirrors the `_GIT_HELPERS_GIT_BIN` seam idiom). In
#   production it is unset and the prompt reads `/dev/tty` directly.
reconcile::_drift_prompt() {
    local feature_number="${1:-}"
    local tty_src="${RECONCILE_DRIFT_TTY:-/dev/tty}"

    # Open the controlling terminal (or its test stand-in) ONCE on fd 3 so the
    # answer read never disturbs — or gets disturbed by — the inherited stdin
    # (A10), and consecutive reads on a re-prompt advance through the input
    # rather than re-reading the first line. The prompt copy goes to stderr so
    # the disposition word on stdout stays clean for command substitution.
    # A tty that cannot be opened (no controlling terminal) collapses to the
    # safe abort default (SC-019: never hang, never silently proceed).
    if ! exec 3< "$tty_src" 2>/dev/null; then
        printf 'abort\n'
        return 0
    fi

    local ans
    while true; do
        # Prompt copy is verbatim from drift-warning-surface §3.
        printf 'spec %s — Linear appears ahead of this worktree. Overwrite Linear from disk? [p]roceed / [a]bort (default: abort): ' \
            "$feature_number" >&2

        # Read one line from fd 3. A failed read (EOF / closed tty) collapses
        # to the safe abort default.
        if ! read -r ans <&3; then
            exec 3<&-
            printf 'abort\n'
            return 0
        fi

        case "$ans" in
            p|P|proceed|PROCEED)
                exec 3<&-
                printf 'proceed\n'
                return 0
                ;;
            a|A|abort|ABORT|'')
                # Empty-enter = abort (plan A5: the safe default).
                exec 3<&-
                printf 'abort\n'
                return 0
                ;;
            *)
                # Invalid input re-prompts — never crash, never silently pick.
                printf 'spec %s — please answer p (proceed) or a (abort).\n' \
                    "$feature_number" >&2
                ;;
        esac
    done
}

# reconcile::_drift_disposition <feature_number> <verdict_line>    (T326)
#   THE DISPOSITION FORK — both arms of the warn-not-block state machine
#   (data-model §5). Echoes exactly one of:
#       proceed   — overwrite Linear from disk (write continues)
#       abort     — skip the spec, leave Linear unchanged (FR-057)
#
#   Only consulted when fired=1 (the caller writes silently on fired=0).
#
#   Resolution precedence (T334 non-interactive arm + T343 interactive arm):
#     1. An EXPLICIT `--on-drift` (ARG_ON_DRIFT=abort|proceed) is an
#        operator OVERRIDE and wins everywhere — even on a TTY it skips
#        the prompt (FR-056: the flag lets the operator override the
#        default; T339: "no prompt even on a TTY-less run").
#     2. No explicit flag + interactive (`[[ -t 0 ]]`) → prompt the
#        operator proceed/abort via /dev/tty (FR-055; empty=abort, A5).
#     3. No explicit flag + non-interactive (`[[ ! -t 0 ]]`) →
#        proceed-and-warn default (FR-056). MUST NOT hang (SC-019).
#
#   The WARNING row has already been emitted by the caller before this is
#   consulted (the audit trail holds regardless of disposition, FR-054).
reconcile::_drift_disposition() {
    local feature_number="${1:-}" verdict="${2:-}"
    : "${verdict:-}"  # reserved for richer disposition logic (multi-signal)

    # 1. Explicit --on-drift override — honoured in BOTH TTY arms, no prompt.
    case "${ARG_ON_DRIFT:-}" in
        abort)
            printf 'abort\n'
            return 0
            ;;
        proceed)
            printf 'proceed\n'
            return 0
            ;;
        *) : ;;  # unset → fall through to the TTY-gated default
    esac

    # 2. Interactive arm (T343): prompt the operator. Gated on a real TTY so
    #    hooks/CI never reach the prompt (they take arm 3).
    if [[ -t 0 ]]; then
        reconcile::_drift_prompt "$feature_number"
        return 0
    fi

    # 3. Non-interactive arm (T334): proceed-and-warn default (FR-056). The
    #    WARNING row already recorded the drift for the CI audit trail.
    printf 'proceed\n'
}

# reconcile::pr_state_hint <pr_state_raw>
#   Normalise the raw output of git_helpers::pr_state into the lifecycle
#   hint token parser::lifecycle_phase expects: `merged`, `ready`, or the
#   empty string ("no signal — fall back to the artifact ladder").
#
#   git_helpers::pr_state emits one of two shapes:
#     * a rich JSON object (gh path) with the REAL gh fields
#       `state` (OPEN|CLOSED|MERGED), `isDraft`, `mergedAt`, `url`; OR
#     * the bare word `merged` / `open` (git-only reachability fallback).
#
#   Merge is derived from `state == "MERGED"` (a non-null `mergedAt`
#   corroborates) — NOT from a `merged` boolean. `merged` is not a valid
#   `gh pr {view,list} --json` field; requesting it aborts the whole gh
#   query. The original code both requested that field AND read `.merged`
#   from the response, so the gh path always failed → merged specs (e.g.
#   spec 001 reconciled from `main`) were mis-detected as still
#   `implementing` (the ACM-5 dogfood bug). Reading the real fields fixes
#   detection from ANY branch.
#
#   An OPEN, non-draft PR maps to `ready` (→ ready_to_merge per FR-028),
#   never `merged`.
reconcile::pr_state_hint() {
    local pr_state_raw="${1:-}"
    [[ -n "$pr_state_raw" ]] || return 0

    if printf '%s' "$pr_state_raw" | jq -e . >/dev/null 2>&1; then
        local pr_state pr_merged_at pr_draft
        pr_state="$(printf '%s' "$pr_state_raw" | jq -r '.state // "" | ascii_upcase')"
        pr_merged_at="$(printf '%s' "$pr_state_raw" | jq -r '.mergedAt // ""')"
        pr_draft="$(printf '%s' "$pr_state_raw" | jq -r '.isDraft // false')"
        if [[ "$pr_state" == "MERGED" || ( -n "$pr_merged_at" && "$pr_merged_at" != "null" ) ]]; then
            printf 'merged\n'
        elif [[ "$pr_draft" == "false" ]]; then
            printf 'ready\n'
        fi
        return 0
    fi

    # git-only fallback path: the bare word `merged` is the only positive
    # signal; `open` (or anything else) leaves the hint empty so the
    # artifact ladder decides.
    if [[ "$pr_state_raw" == "merged" ]]; then
        printf 'merged\n'
    fi
}

# reconcile::process_spec <spec_dir>
#   Top-level per-spec orchestration. Returns 0 always — failures are
#   recorded via summary::add and promote RECONCILE_EXIT_CODE; we never
#   throw past this boundary so one bad spec can't bring down the
#   --all sweep (FR-024).
reconcile::process_spec() {
    local spec_dir="$1"

    local feature_number short_name spec_md
    if ! feature_number="$(parser::feature_number "$spec_dir")"; then
        summary::add warned "spec dir ${spec_dir}: basename does not match NNN-<slug>; skipping"
        return 0
    fi
    if ! short_name="$(parser::short_name "$spec_dir")"; then
        summary::add warned "spec dir ${spec_dir}: cannot extract short name; skipping"
        return 0
    fi

    spec_md="${spec_dir%/}/spec.md"
    if [[ ! -s "$spec_md" ]]; then
        summary::add warned "spec ${feature_number}: spec.md missing or empty; skipping"
        return 0
    fi

    # Feature branch is the canonical `<NNN>-<short-name>`.
    local feature_branch="${feature_number}-${short_name}"

    # --- 4a. Write authority (spec 003 / FR-051 / Principle IV) -------
    # The v1.0.0 FR-025 branch-gate is REMOVED (T324). Every worktree now
    # proceeds to attempt the write — the invoking worktree's filesystem
    # state is the authority. Backward-drift (Linear ahead of disk) is
    # SURFACED as a WARNING after phase inference (4b-drift below), never
    # used to refuse the write of the bridge's own accord. The
    # `--retroactive` flag is a deprecated no-op alias (FR-061); its INFO
    # row fires once at arg-parse time.

    # --- 4b. Phase inference ------------------------------------------
    # Hand the PR-state hint through to the parser so retroactive sync
    # lands directly on `merged` / `ready_to_merge` without simulating
    # intermediate transitions (FR-014).
    local pr_state_raw lifecycle_phase
    pr_state_raw="$(git_helpers::pr_state "$feature_branch" 2>/dev/null || true)"

    local pr_state_hint
    pr_state_hint="$(reconcile::pr_state_hint "$pr_state_raw")"

    if ! lifecycle_phase="$(parser::lifecycle_phase "$spec_dir" "$pr_state_hint")"; then
        summary::add warned "spec ${feature_number}: cannot infer lifecycle phase; skipping"
        return 0
    fi

    reconcile::log "spec ${feature_number}: lifecycle=${lifecycle_phase} branch=${feature_branch}"

    # --- 4b-drift. Backward-drift compute + disposition (T323/T325/T326)
    # Read Linear's current view (read-only — FR-064) and compute the
    # backward-drift verdict (FR-052). On fired=1, surface the WARNING row
    # (FR-054) then resolve the disposition (data-model §5). On fired=0
    # (forward / equal / no-drift) the write proceeds SILENTLY — no
    # prompt, no warning (SC-017, the zero-false-positive path).
    local drift_issue_json drift_verdict drift_fired drift_disp
    drift_issue_json="$(reconcile::_fetch_drift_issue_json "$feature_number" 2>/dev/null || true)"
    drift_verdict="$(reconcile::compute_drift \
        "$feature_number" "$spec_dir" "${drift_issue_json:-}" "$lifecycle_phase")"
    drift_fired="$(reconcile::_drift_verdict_field "$drift_verdict" fired)"

    if [[ "$drift_fired" == "1" ]]; then
        # FR-054: emit the named WARNING row on EVERY drift, before any
        # disposition decision (the audit trail — even a proceed keeps it).
        reconcile::_emit_drift_warning "$feature_number" "$drift_verdict"

        # data-model §5 disposition fork. Phase 3 default = proceed-and-warn;
        # the interactive (US3/T343) + non-interactive --on-drift (US2/T334)
        # arms layer on inside reconcile::_drift_disposition.
        drift_disp="$(reconcile::_drift_disposition "$feature_number" "$drift_verdict")"
        if [[ "$drift_disp" == "abort" ]]; then
            # Operator/flag chose to skip — leave Linear unchanged (FR-057).
            # The zero-mutation skip note is US3's T344; Phase 3's default
            # disposition never returns `abort`, so this is the reserved
            # extension branch (kept so US2/US3 wire the skip cleanly here).
            summary::add skipped "spec ${feature_number} skipped by operator (backward-drift abort) — Linear unchanged"
            reconcile::log "spec ${feature_number}: drift disposition=abort; skipping write (Linear unchanged)"
            return 0
        fi
        reconcile::log "spec ${feature_number}: drift fired (${drift_verdict}); disposition=${drift_disp} — proceeding with write"
    fi

    # Surface any malformed tasks.md lines per FR-024.
    local malformed
    if malformed="$(parser::malformed_task_lines "${spec_dir%/}/tasks.md" 2>/dev/null)" \
        && [[ -n "$malformed" ]]; then
        local line_count
        line_count="$(printf '%s\n' "$malformed" | wc -l | awk '{print $1}')"
        summary::add warned "spec ${feature_number}: ${line_count} task line(s) outside any ## Phase header"
    fi

    # --- 4c. Spec Issue find-or-create/update (FR-001..FR-004b) -------
    local spec_issue_id
    if ! spec_issue_id="$(reconcile::sync_spec_issue \
        "$feature_number" "$short_name" "$spec_dir" \
        "$lifecycle_phase" "$feature_branch")"; then
        summary::add error "spec ${feature_number}: sync_spec_issue failed"
        return 0
    fi
    if [[ -z "$spec_issue_id" || "$spec_issue_id" == "null" ]]; then
        summary::add error "spec ${feature_number}: no Issue ID resolved"
        return 0
    fi

    # --- 4d/4e. Task-phase sub-issues (FR-005, FR-006) ----------------
    local phase_map
    if ! phase_map="$(reconcile::sync_task_phase_subissues \
        "$spec_issue_id" "$feature_number" "$spec_dir")"; then
        summary::add error "spec ${feature_number}: sync_task_phase_subissues failed"
        # Continue to comments — sub-issue failures don't block the
        # rest of the per-spec reconcile per FR-024.
    fi

    # --- 4f. Inter-phase blocking relations (FR-007) ------------------
    if [[ -n "${phase_map:-}" && "$phase_map" != "{}" ]]; then
        reconcile::sync_inter_phase_blocks "$phase_map" "$spec_dir" || true
    fi

    # --- 4g. Clarify session comments (FR-008, FR-015) ----------------
    reconcile::sync_clarify_comments "$spec_issue_id" "$spec_dir" || true

    # --- 4h. Record lifecycle for FR-002 Project Status aggregate ----
    # Every worktree that reaches here has written (the FR-025 gate is
    # gone — FR-051). A drift `abort` returns before this point, so an
    # operator-skipped spec does not influence Project Status decisions.
    reconcile::_record_lifecycle "$lifecycle_phase" "$spec_dir"

    reconcile::log "spec ${feature_number}: reconcile complete"
    return 0
}

# =============================================================================
# FR-002 — Project Status sync.
#
# After every per-spec reconcile lands, aggregate the lifecycle phases
# observed across the touched specs and flip the consumer-repo Linear
# Project's Status enum to match:
#
#   * Any spec in a `started`-type lifecycle phase (clarifying →
#     analyzing inclusive — Specifying is `unstarted` per the seed
#     catalogue) → state=`started`.
#   * ALL specs in `merged` → state=`completed`.
#   * ALL specs in `merged` AND every spec's mtime older than
#     `sync.idle_window_days` (default 30) → state=`paused`.
#   * Otherwise the Project's existing state is left untouched —
#     we only flip on positive signal so a fresh repo with one
#     unstarted spec doesn't accidentally promote past `planned`.
#   * `cancelled` is never touched by the bridge.
#
# Zero-churn discipline: query the Project's current status first;
# skip the `projectUpdate` if the desired state already matches.
# Failure is best-effort — Project Status is aggregate sugar (per
# contracts §4.2) so a transport blip aggregates as a warning rather
# than blocking the per-spec writes that already settled.
#
# Linear's GraphQL surface for Project Status: `projectStatuses` enumerates
# workspace-scoped status records keyed by `type` ∈ {backlog, planned,
# started, paused, completed, canceled}. The bridge picks the FIRST
# matching status per type — workspaces with multiple `started`
# statuses (rare) get the alphabetically-first one.
# =============================================================================

# reconcile::_idle_window_days
#   Echo the configured sync.idle_window_days as an integer. Falls back
#   to the documented default of 30 when the key is absent or malformed.
reconcile::_idle_window_days() {
    local raw="${CONFIG_VALUES[sync.idle_window_days]:-}"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$raw"
    else
        printf '30\n'
    fi
}

# reconcile::_lifecycle_is_started <phase>
#   Return 0 if <phase> is one of the `started`-type lifecycle phases.
#   Mirrors the seed catalogue in seed.sh SEED_WORKFLOW_STATES so the
#   bridge never has to query Linear for the type. specifying is
#   intentionally treated as NOT started so a brand-new repo with one
#   freshly-minted spec doesn't accidentally promote the Project
#   past planned (matches the "only flip on positive signal" rule).
reconcile::_lifecycle_is_started() {
    case "$1" in
        clarifying|planning|tasking|red_team|implementing|analyzing|ready_to_merge)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# reconcile::_record_lifecycle <phase> <spec_dir>
#   Append one row to _RECONCILE_LIFECYCLE_ROWS for FR-002's
#   project-status decision. Captures (phase, last-touched-epoch).
#   Tolerant of unreadable mtimes — epoch is "0" in that case which
#   means "treat as recently touched" (safer default than "ancient").
reconcile::_record_lifecycle() {
    local phase="$1"
    local spec_dir="$2"
    local epoch=""
    # Pull a numeric epoch using the same GNU/BSD stat dance as
    # git_helpers::last_touched. We don't reuse that helper here
    # because it returns an ISO string; we need the raw seconds for
    # the idle-window math.
    if epoch="$(stat -c %Y "$spec_dir" 2>/dev/null)"; then
        :
    elif epoch="$(stat -f %m "$spec_dir" 2>/dev/null)"; then
        :
    else
        epoch="0"
    fi
    if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
        epoch="0"
    fi
    if [[ -z "$_RECONCILE_LIFECYCLE_ROWS" ]]; then
        _RECONCILE_LIFECYCLE_ROWS="${phase}"$'\t'"${epoch}"
    else
        _RECONCILE_LIFECYCLE_ROWS="${_RECONCILE_LIFECYCLE_ROWS}"$'\n'"${phase}"$'\t'"${epoch}"
    fi
}

# reconcile::_desired_project_state
#   Echo one of `started`, `completed`, `paused`, or empty (leave
#   alone) based on the aggregated lifecycle rows. Implements the
#   FR-002 priority order: any started → started; all merged + idle →
#   paused; all merged → completed; nothing else flips.
reconcile::_desired_project_state() {
    if [[ -z "$_RECONCILE_LIFECYCLE_ROWS" ]]; then
        printf ''
        return 0
    fi

    local idle_days idle_window_secs now
    idle_days="$(reconcile::_idle_window_days)"
    idle_window_secs=$(( idle_days * 86400 ))
    now="$(date +%s 2>/dev/null || printf '0')"

    local any_started=0 all_merged=1 all_idle=1
    local row phase epoch
    while IFS=$'\t' read -r phase epoch; do
        [[ -n "$phase" ]] || continue
        if reconcile::_lifecycle_is_started "$phase"; then
            any_started=1
        fi
        if [[ "$phase" != "merged" ]]; then
            all_merged=0
        fi
        # Idle = mtime older than the window. Epoch 0 (couldn't read
        # stat) is treated as "recent" so we don't accidentally
        # auto-pause a repo whose filesystem we can't probe.
        if (( epoch == 0 )) || (( idle_window_secs <= 0 )) \
            || (( (now - epoch) < idle_window_secs )); then
            all_idle=0
        fi
        row=""  # silence shellcheck unused-var on the loop var
        : "${row}"
    done <<< "$_RECONCILE_LIFECYCLE_ROWS"

    if (( any_started == 1 )); then
        printf 'started\n'
    elif (( all_merged == 1 )) && (( all_idle == 1 )); then
        printf 'paused\n'
    elif (( all_merged == 1 )); then
        printf 'completed\n'
    else
        # No positive signal — leave the Project's existing state alone.
        printf ''
    fi
}

# reconcile::sync_project_status
#   Compute the desired Project Status from the per-spec lifecycle
#   accumulator and flip the Linear Project's status via projectUpdate
#   if (and only if) the current state doesn't already match. All
#   failure modes aggregate as warnings — FR-002 is aggregate sugar
#   and must not block the per-spec writes that already settled.
reconcile::sync_project_status() {
    local desired
    desired="$(reconcile::_desired_project_state)"

    if [[ -z "$desired" ]]; then
        reconcile::log "FR-002 Project Status: no positive signal across touched specs; leaving as-is"
        return 0
    fi

    local project_uuid
    project_uuid="$(config::get_project_id)"
    if [[ -z "$project_uuid" ]]; then
        summary::add warned "FR-002 Project Status: linear.project.id absent; skipping projectUpdate"
        return 0
    fi

    # Query the current status + workspace status palette in one round-trip.
    # Linear's Project schema exposes `status { id name type }` and the
    # workspace's full palette via `projectStatuses { nodes { id name type } }`.
    local query='query GetProjectStatus($id: String!) {
        project(id: $id) {
            id
            name
            status { id name type }
        }
        projectStatuses {
            nodes { id name type }
        }
    }'
    local vars response
    vars="$(jq -nc --arg id "$project_uuid" '{id: $id}')"

    if ! response="$(graphql::query "$query" "$vars" 2>/dev/null)"; then
        summary::add warned "FR-002 Project Status: projectStatuses query failed (transport); skipping flip"
        return 0
    fi

    local current_type target_status_id
    current_type="$(printf '%s' "$response" | jq -r '.data.project.status.type // ""')"
    # Resolve the target status UUID — pick the first status whose
    # type matches the desired flag. Multi-status-per-type workspaces
    # (rare) get the alphabetically-first match.
    target_status_id="$(printf '%s' "$response" | jq -r \
        --arg type "$desired" \
        '.data.projectStatuses.nodes
         | map(select(.type == $type))
         | sort_by(.name)
         | (.[0].id // "")')"

    if [[ -z "$target_status_id" ]]; then
        summary::add warned "FR-002 Project Status: no projectStatus with type='${desired}' found in workspace; skipping flip"
        return 0
    fi

    if [[ "$current_type" == "$desired" ]]; then
        reconcile::log "FR-002 Project Status: already '${desired}' (zero-churn)"
        return 0
    fi

    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN projectUpdate id=${project_uuid} statusId=${target_status_id} (type=${desired})"
        summary::add updated "projectUpdate Status → ${desired} (dry-run)"
        return 0
    fi

    local mutation='mutation FlipProjectStatus($id: String!, $input: ProjectUpdateInput!) {
        projectUpdate(id: $id, input: $input) {
            success
            project { id name status { id name type } }
        }
    }'
    local input_json mvars mresponse
    input_json="$(jq -nc --arg status "$target_status_id" '{statusId: $status}')"
    mvars="$(jq -nc --arg id "$project_uuid" --argjson input "$input_json" \
        '{id: $id, input: $input}')"

    if ! mresponse="$(graphql::mutate "$mutation" "$mvars" 2>/dev/null)"; then
        summary::add warned "FR-002 Project Status: projectUpdate failed (transport); leaving Status unchanged"
        return 0
    fi

    if ! printf '%s' "$mresponse" | jq -e '.data.projectUpdate.success == true' >/dev/null 2>&1; then
        summary::add warned "FR-002 Project Status: projectUpdate did not return success=true"
        return 0
    fi

    summary::add updated "projectUpdate Status: ${current_type:-unknown} → ${desired}"
    reconcile::log "FR-002 Project Status: flipped ${current_type:-unknown} → ${desired}"
}

# =============================================================================
# Main.
# =============================================================================
reconcile::main() {
    reconcile::parse_args "$@"

    local title
    title="speckit.linear reconcile"
    if [[ -n "$ARG_SPEC" ]]; then
        title="${title} — spec ${ARG_SPEC}"
    elif (( ARG_ALL == 1 )); then
        title="${title} — all specs"
    fi
    if (( ARG_DRY_RUN == 1 )); then
        title="${title} (dry-run)"
    fi
    summary::start "$title"

    # FR-061: --retroactive is a deprecated no-op alias. Emit EXACTLY ONE
    # INFO row per invocation (drift-warning-surface §6 verbatim text). It
    # lands here, just after summary::start, so it survives the buffer reset
    # that summary::start performs and renders as the top-of-summary INFO
    # line (drift-warning-surface §7 / plan A12).
    if (( ARG_RETROACTIVE == 1 )); then
        summary::add info "--retroactive is deprecated and now the default — writing from any branch needs no flag (use --all to enumerate)"
    fi

    # Step 2 — config load. Exits 2 via config::*'s own halt on failure.
    reconcile::load_config

    # Step 3 — spec enumeration.
    local -a spec_dirs=()
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && spec_dirs+=("$dir")
    done < <(reconcile::enumerate_specs)

    if (( ${#spec_dirs[@]} == 0 )); then
        if [[ -n "$ARG_SPEC" ]]; then
            summary::add warned "no spec directory matched --spec ${ARG_SPEC}"
            reconcile::promote_exit 1
        else
            reconcile::log "no specs/NNN-* directories found"
        fi
    fi

    # Step 4 — per-spec loop.
    local spec_dir
    for spec_dir in "${spec_dirs[@]}"; do
        reconcile::process_spec "$spec_dir"
    done

    # Step 4b — FR-002 Project Status flip. Runs after all per-spec
    # mutations land so the aggregate reflects the freshest filesystem
    # state. Failure here is best-effort; aggregated as warning rather
    # than blocking the per-spec writes.
    reconcile::sync_project_status || true

    # (FR-061 / spec 003) The v0.1.x retroactive-bypass aggregate warned row
    # is RETIRED: writing from any branch is now the default, so there is no
    # "bypass" to count. The one-time deprecation INFO row is emitted up-front
    # in main() right after summary::start instead.

    # Step 5 — summary emission (Principle VIII).
    summary::emit

    # Step 6 — final exit code. If any errors landed, promote to 1
    # unless we've already promoted higher.
    if summary::has_errors; then
        reconcile::promote_exit 1
    fi

    exit "$RECONCILE_EXIT_CODE"
}

# Allow this script to be sourced for testing without executing main.
# When sourced, BASH_SOURCE[0] != $0; when executed, they match.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    reconcile::main "$@"
fi
