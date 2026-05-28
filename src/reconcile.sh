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
# Principle IV (write-authority-follows-worktree) — gated per-spec
#   via `git_helpers::is_authoritative_for_spec`; non-authoritative
#   worktrees enter read-only display per FR-026.
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

# The fenced markers around the human-readable Overview block in spec
# Issue descriptions. This block is sourced from spec.md's `## Overview`
# section verbatim (truncated to the first paragraph when long) so a
# developer scanning the Linear Issue sees what the spec actually does
# without opening spec.md on GitHub. Owned by the bridge — everything
# between BEGIN and END is rewritten on every reconcile.
readonly RECONCILE_OVERVIEW_BEGIN="<!-- spec-kit-linear:overview:begin -->"
readonly RECONCILE_OVERVIEW_END="<!-- spec-kit-linear:overview:end -->"

# Cap on the verbatim Overview body before we truncate to the first
# paragraph (split on `\n\n`) + ellipsis. Linear descriptions are
# already long with the memory + diagrams blocks; keeping this under
# 1500 chars preserves the at-a-glance value the block is meant to add.
readonly RECONCILE_OVERVIEW_MAX_CHARS=1500

# The fenced markers around the memory block in spec Issue descriptions
# (FR-004). Bridge rewrites everything between BEGIN and END on every
# reconcile; operator-added prose ABOVE or BELOW the fences survives.
readonly RECONCILE_MEMORY_BEGIN="<!-- spec-kit-linear:memory:begin -->"
readonly RECONCILE_MEMORY_END="<!-- spec-kit-linear:memory:end -->"

# The fenced markers around the diagrams pointer block in spec Issue
# descriptions. Separate fence family from memory block so each can be
# independently rewritten without disturbing the other. The diagrams
# block is best-effort: when the consumer repo's git remote isn't a
# GitHub URL we omit the block entirely rather than emit broken links.
readonly RECONCILE_DIAGRAMS_BEGIN="<!-- spec-kit-linear:diagrams:begin -->"
readonly RECONCILE_DIAGRAMS_END="<!-- spec-kit-linear:diagrams:end -->"

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

# Module-level cache: label name → UUID. Populated lazily by
# reconcile::_resolve_label_id so the same name resolved across N
# specs in a single --all sweep hits Linear at most once.
declare -gA _RECONCILE_LABEL_ID_CACHE=()

# FR-034 graceful-degradation flag — set to 1 the first time
# reconcile::_resolve_operator_assignee_id sees an empty
# linear.operator.user_id so the missing-operator warning fires
# exactly once per reconcile run rather than once per Issue created.
declare -g _RECONCILE_OPERATOR_WARNED=0

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
declare -g ARG_RETROACTIVE=0    # 0|1 — extra-quiet, suppresses non-authoritative warnings

# Aggregate exit-code tracker. We start at 0 and monotonically promote
# to higher severities as failures accumulate.
declare -g RECONCILE_EXIT_CODE=0

# -----------------------------------------------------------------------------
# reconcile::usage
#   Print operator-facing usage to stderr.
# -----------------------------------------------------------------------------
reconcile::usage() {
    cat >&2 <<'EOF'
Usage: reconcile.sh [--spec NNN | --all] [--dry-run] [--retroactive] [--quiet]
                    [--config PATH] [--help]

Reconcile filesystem spec state into Linear (Layer D). Idempotent.

Options:
  --spec NNN       Reconcile only the spec whose feature number matches NNN.
  --all            Reconcile every specs/NNN-feature/ in the repo.
                   (Exactly one of --spec or --all is required.)
  --dry-run        Log every mutation that WOULD fire; issue none.
  --retroactive    First-time-adoption mode. Suppresses "skipped because
                   non-authoritative" warnings. Implies --all if --spec
                   is not given.
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
            --retroactive)
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

    # --retroactive without an explicit --spec implies --all.
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

    # Title-case the lifecycle phase for human display.
    local phase_display
    case "$lifecycle_phase" in
        ready_to_merge) phase_display="Ready-to-merge" ;;
        red_team)       phase_display="Red-team" ;;
        *)              phase_display="$(printf '%s' "$lifecycle_phase" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" ;;
    esac

    # Markdown table — fixed column order (Field / Value). Begin/end
    # fence markers are added by the caller (compose_issue_description).
    cat <<EOF
| Field | Value |
|---|---|
| **Phase** | ${phase_display} |
| **Branch** | \`${feature_branch}\` |
| **Worktree(s)** | ${worktree_cell} |
| **Last touched** | ${last_touched_cell} |
| **Source** | ${source_cell} |
| **Spec** | ${feature_number}-${short_name} |
EOF
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
# spec.md on GitHub. The returned content does NOT include the
# begin/end fences; the caller (compose_issue_description) wraps it.
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
# returned content does NOT include the begin/end fences; the caller
# (compose_issue_description) wraps it.
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
# reconcile::compose_issue_description <body_text> <memory_block> [<diagrams_block>] [<overview_block>]
#
# Merge the bridge's overview + memory + diagrams blocks into the spec
# Issue's description. Strategy: for each fence family, if both markers
# exist in <body_text>, splice between them; otherwise insert a fresh
# fenced block in the canonical position. Operator-added prose outside
# the fences is preserved verbatim (FR-004).
#
# Canonical order (top → bottom of the rendered description):
#   1. overview  (<!-- spec-kit-linear:overview:* -->)  — Fix 7
#   2. memory    (<!-- spec-kit-linear:memory:*   -->)  — FR-004
#   3. diagrams  (<!-- spec-kit-linear:diagrams:* -->)  — Fix 2
#
# <diagrams_block> may be empty — when the consumer repo isn't on
# GitHub, render_diagrams_block returns no content and we omit the
# diagrams fence entirely. <overview_block> may be empty — when
# spec.md has no `## Overview` heading, render_overview_block returns
# no content and we omit the overview fence entirely.
# =============================================================================
reconcile::compose_issue_description() {
    local body="$1"
    local memory_block="$2"
    local diagrams_block="${3:-}"
    local overview_block="${4:-}"

    # The full memory block we want to emit, fences included.
    local memory_fenced
    memory_fenced=$(printf '%s\n%s\n%s' \
        "${RECONCILE_MEMORY_BEGIN}" \
        "${memory_block}" \
        "${RECONCILE_MEMORY_END}")

    local result="$body"

    # ---- memory block splice ------------------------------------------
    # BSD-awk safe: walks $result line by line, replaces everything
    # between the fence markers with the new fenced block. Cannot use
    # `awk -v block=...` because BSD awk on macOS rejects multi-line -v
    # values, silently emptying the output and deleting the block.
    if printf '%s' "$result" | grep -qF "${RECONCILE_MEMORY_BEGIN}" \
        && printf '%s' "$result" | grep -qF "${RECONCILE_MEMORY_END}"; then
        local _mem_out _mem_line _mem_skip=0 _mem_printed=0
        _mem_out=""
        while IFS= read -r _mem_line || [[ -n "$_mem_line" ]]; do
            if [[ "$_mem_skip" -eq 0 && "$_mem_line" == *"${RECONCILE_MEMORY_BEGIN}"* ]]; then
                _mem_skip=1
                if [[ "$_mem_printed" -eq 0 ]]; then
                    _mem_out+="${memory_fenced}"$'\n'
                    _mem_printed=1
                fi
                continue
            fi
            if [[ "$_mem_skip" -eq 1 ]]; then
                if [[ "$_mem_line" == *"${RECONCILE_MEMORY_END}"* ]]; then
                    _mem_skip=0
                fi
                continue
            fi
            _mem_out+="${_mem_line}"$'\n'
        done <<< "$result"
        result="${_mem_out%$'\n'}"
    else
        # No fences yet — prepend.
        result="$(printf '%s\n\n%s' "$memory_fenced" "$result")"
    fi

    # ---- overview block splice (optional) -----------------------------
    # Lands at the TOP of the description so a developer scanning the
    # Linear Issue sees the plain-English summary BEFORE the memory
    # metadata table. If an overview fence already exists, rewrite it
    # in place; otherwise prepend a fresh fenced block to the head.
    if [[ -n "$overview_block" ]]; then
        local overview_fenced
        overview_fenced=$(printf '%s\n%s\n%s' \
            "${RECONCILE_OVERVIEW_BEGIN}" \
            "${overview_block}" \
            "${RECONCILE_OVERVIEW_END}")

        if printf '%s' "$result" | grep -qF "${RECONCILE_OVERVIEW_BEGIN}" \
            && printf '%s' "$result" | grep -qF "${RECONCILE_OVERVIEW_END}"; then
            # BSD-awk safe: bash state machine instead of awk -v block=...
            local _ov_out _ov_line _ov_skip=0 _ov_printed=0
            _ov_out=""
            while IFS= read -r _ov_line || [[ -n "$_ov_line" ]]; do
                if [[ "$_ov_skip" -eq 0 && "$_ov_line" == *"${RECONCILE_OVERVIEW_BEGIN}"* ]]; then
                    _ov_skip=1
                    if [[ "$_ov_printed" -eq 0 ]]; then
                        _ov_out+="${overview_fenced}"$'\n'
                        _ov_printed=1
                    fi
                    continue
                fi
                if [[ "$_ov_skip" -eq 1 ]]; then
                    if [[ "$_ov_line" == *"${RECONCILE_OVERVIEW_END}"* ]]; then
                        _ov_skip=0
                    fi
                    continue
                fi
                _ov_out+="${_ov_line}"$'\n'
            done <<< "$result"
            result="${_ov_out%$'\n'}"
        else
            # No overview fence yet — prepend at the very top so the
            # canonical order is overview → memory → diagrams.
            result="$(printf '%s\n\n%s' "$overview_fenced" "$result")"
        fi
    fi

    # ---- diagrams block splice (optional) -----------------------------
    if [[ -n "$diagrams_block" ]]; then
        local diagrams_fenced
        diagrams_fenced=$(printf '%s\n%s\n%s' \
            "${RECONCILE_DIAGRAMS_BEGIN}" \
            "${diagrams_block}" \
            "${RECONCILE_DIAGRAMS_END}")

        if printf '%s' "$result" | grep -qF "${RECONCILE_DIAGRAMS_BEGIN}" \
            && printf '%s' "$result" | grep -qF "${RECONCILE_DIAGRAMS_END}"; then
            # BSD-awk safe: bash state machine instead of awk -v block=...
            local _dg_out _dg_line _dg_skip=0 _dg_printed=0
            _dg_out=""
            while IFS= read -r _dg_line || [[ -n "$_dg_line" ]]; do
                if [[ "$_dg_skip" -eq 0 && "$_dg_line" == *"${RECONCILE_DIAGRAMS_BEGIN}"* ]]; then
                    _dg_skip=1
                    if [[ "$_dg_printed" -eq 0 ]]; then
                        _dg_out+="${diagrams_fenced}"$'\n'
                        _dg_printed=1
                    fi
                    continue
                fi
                if [[ "$_dg_skip" -eq 1 ]]; then
                    if [[ "$_dg_line" == *"${RECONCILE_DIAGRAMS_END}"* ]]; then
                        _dg_skip=0
                    fi
                    continue
                fi
                _dg_out+="${_dg_line}"$'\n'
            done <<< "$result"
            result="${_dg_out%$'\n'}"
        else
            # Append the diagrams block AFTER the memory block / body
            # so the reader sees: memory fence → operator prose →
            # diagrams pointer. Inserting after the memory end fence
            # keeps the visual order stable across re-runs.
            if printf '%s' "$result" | grep -qF "${RECONCILE_MEMORY_END}"; then
                # BSD-awk safe: bash state machine instead of awk -v block=...
                local _ia_out _ia_line _ia_inserted=0
                _ia_out=""
                while IFS= read -r _ia_line || [[ -n "$_ia_line" ]]; do
                    _ia_out+="${_ia_line}"$'\n'
                    if [[ "$_ia_inserted" -eq 0 && "$_ia_line" == *"${RECONCILE_MEMORY_END}"* ]]; then
                        _ia_out+=$'\n'"${diagrams_fenced}"$'\n'
                        _ia_inserted=1
                    fi
                done <<< "$result"
                if [[ "$_ia_inserted" -eq 0 ]]; then
                    _ia_out+=$'\n'"${diagrams_fenced}"$'\n'
                fi
                result="${_ia_out%$'\n'}"
            else
                result="$(printf '%s\n\n%s' "$result" "$diagrams_fenced")"
            fi
        fi
    fi

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
        local id state desc box
        while IFS=$'\t' read -r id state desc; do
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
    local id state desc
    while IFS=$'\t' read -r id state desc; do
        # Touch unused locals so shellcheck doesn't complain about
        # destructured fields we don't reference.
        : "${id:-}${desc:-}"
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
#   * `phase:*` / `task-phase:*` — MUST already exist (seeded by
#     `speckit.linear.seed`). Missing here is a hard error per FR-022
#     ("unseeded halts"); reconciler aggregates the failure and points
#     at the seed remediation.
#   * Any other label (operator-added) — looked up but never created.
# =============================================================================

# reconcile::_label_create_speckit <name>
#   Create a workspace-scoped (teamId omitted) issue label and echo its
#   UUID. Used only for `speckit-spec:NNN` per the auto-create policy
#   above. Returns non-zero (and records to summary) on transport or
#   GraphQL failure.
reconcile::_label_create_speckit() {
    local name="$1"

    if (( ARG_DRY_RUN == 1 )); then
        reconcile::log "DRY-RUN issueLabelCreate name=${name} color=${RECONCILE_SPECKIT_LABEL_COLOR}"
        summary::add created "issueLabelCreate ${name} (dry-run)"
        # Synthesize a stable placeholder so downstream array-builds work
        # in dry-run. Matches the dry-run pattern used by issueCreate.
        printf 'dry-run-label-id-%s\n' "$name"
        return 0
    fi

    local mutation='mutation CreateSpeckitLabel($input: IssueLabelCreateInput!) {
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
        --arg color "$RECONCILE_SPECKIT_LABEL_COLOR" \
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
        if ! id="$(reconcile::_label_create_speckit "$name")"; then
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

    # phase:* / task-phase:* (or any operator label) missing → FR-022
    # halt-like surface. We don't exit(2) here because one missing
    # label shouldn't kill the whole --all sweep; we record the gap,
    # promote to exit 1, and the per-spec caller drops this label from
    # its set so the mutation can still issue for the labels that DO
    # resolve. The summary names the offending label and points at
    # the seed remediation.
    if [[ "$name" == phase:* || "$name" == task-phase:* ]]; then
        summary::add error "label '${name}' not found in Linear; run \`speckit.linear.seed\` to create phase:* / task-phase:* labels"
    else
        summary::add error "label '${name}' not found in Linear; create it manually or remove it from the spec"
    fi
    reconcile::promote_exit 1
    return 1
}

# reconcile::_resolve_label_ids_array <name1> [<name2> ...]
#   Resolve each label name → UUID and echo a JSON array of UUIDs.
#   `speckit-spec:*` names take the auto-create path; everything else
#   is lookup-only. Names that fail to resolve are SKIPPED from the
#   output (with a summary::add error already recorded by
#   _resolve_label_id) so the caller's mutation still fires for the
#   labels that DID resolve — partial progress beats whole-spec halt
#   (FR-024).
#
#   Empty input → "[]".
reconcile::_resolve_label_ids_array() {
    local -a ids=()
    local name id allow_create
    for name in "$@"; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == speckit-spec:* ]]; then
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
        | jq -c '[.data.issue.relations.nodes[].relatedIssue.id]'
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
#   Implements FR-026 for the non-authoritative case. We still surface
#   the spec's current Linear state to the operator (so "what's done?"
#   is answerable from any worktree) — but without any mutation. The
#   non-authoritative skip is recorded with summary::add UNLESS
#   --retroactive was passed (the post-analyze remediation note on T072).
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
            '[.data.issue.labels.nodes[].name | select(. != $drop)]')"
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

    # Compose the overview + memory + diagrams blocks into a final body.
    local memory_block diagrams_block overview_block existing_body
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
        existing_body=""
        local description
        description="$(reconcile::compose_issue_description \
            "$existing_body" "$memory_block" "$diagrams_block" "$overview_block")"

        # Linear's IssueCreateInput requires `labelIds: [String!]`
        # (UUIDs) — names are rejected on the raw GraphQL path. We
        # resolve every label name to its UUID via
        # reconcile::_resolve_label_ids_array. For speckit-spec:NNN
        # this triggers a workspace-label create on first reconcile;
        # for phase:* we hard-fail (FR-022) if seed hasn't run.
        local labels_json
        labels_json="$(reconcile::_resolve_label_ids_array "$spec_label" "$phase_label")"

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
        }
    }'
    local current_vars current_response
    current_vars="$(jq -nc --arg id "$issue_id" '{id: $id}')"
    if ! current_response="$(graphql::query "$current_query" "$current_vars")"; then
        summary::add error "could not query current state of Issue ${issue_id}"
        return 1
    fi

    local current_title current_description current_state_id
    current_title="$(printf '%s' "$current_response" | jq -r '.data.issue.title // ""')"
    current_description="$(printf '%s' "$current_response" | jq -r '.data.issue.description // ""')"
    current_state_id="$(printf '%s' "$current_response" | jq -r '.data.issue.state.id // ""')"

    local current_labels
    current_labels="$(printf '%s' "$current_response" \
        | jq -c '[.data.issue.labels.nodes[].name]')"

    # Compute the desired description by splicing the new overview +
    # memory + diagrams blocks into whatever the operator has placed
    # around them.
    local desired_description
    desired_description="$(reconcile::compose_issue_description \
        "$current_description" "$memory_block" "$diagrams_block" "$overview_block")"

    # Compute the desired label set: preserve operator-added labels,
    # add (or keep) spec_label + phase_label, remove any stale phase:*
    # label that doesn't match the current lifecycle. Special case for
    # Merged per FR-013: no phase:* label at all.
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

    # Build the diff input. Only include fields that actually changed.
    local update_input='{}'
    if [[ "$current_title" != "$title" ]]; then
        update_input="$(printf '%s' "$update_input" | jq -c \
            --arg title "$title" '. + {title: $title}')"
    fi
    if [[ "$current_description" != "$desired_description" ]]; then
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
        local checklist
        checklist="$(reconcile::compose_subissue_checklist \
            "$feature_number" "$phase_index" "$tasks_md")"
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
            # Create. task-phase:* is seed-owned — if it's missing,
            # _resolve_label_ids_array surfaces an error and we skip
            # this sub-issue (the labels_json comes back as `[]`).
            local labels_json
            labels_json="$(reconcile::_resolve_label_ids_array "$phase_label")"

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
                }
            }'
            local sub_vars sub_response
            sub_vars="$(jq -nc --arg id "$sub_issue_id" '{id: $id}')"
            if ! sub_response="$(graphql::query "$sub_query" "$sub_vars")"; then
                summary::add error "could not query sub-issue ${sub_issue_id}"
                continue
            fi
            local cur_title cur_desc cur_state cur_labels
            cur_title="$(printf '%s' "$sub_response" | jq -r '.data.issue.title // ""')"
            cur_desc="$(printf '%s' "$sub_response" | jq -r '.data.issue.description // ""')"
            cur_state="$(printf '%s' "$sub_response" | jq -r '.data.issue.state.id // ""')"
            cur_labels="$(printf '%s' "$sub_response" | jq -c '[.data.issue.labels.nodes[].name]')"

            # Desired label set: preserve operator labels, ensure
            # task-phase:N is present.
            local desired_labels
            desired_labels="$(printf '%s' "$cur_labels" | jq -c \
                --arg label "$phase_label" \
                '. + ([$label] - .) | unique')"

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

    # Feature branch is the canonical `<NNN>-<short-name>` per FR-025.
    local feature_branch="${feature_number}-${short_name}"

    # --- 4a. Write-authority gate (FR-025 / Principle IV) -------------
    if ! git_helpers::is_authoritative_for_spec "$feature_number"; then
        reconcile::read_only_display "$feature_number" "$spec_dir"
        return 0
    fi

    # --- 4b. Phase inference ------------------------------------------
    # Hand the PR-state hint through to the parser so retroactive sync
    # lands directly on `merged` / `ready_to_merge` without simulating
    # intermediate transitions (FR-014).
    local pr_state_raw lifecycle_phase
    pr_state_raw="$(git_helpers::pr_state "$feature_branch" 2>/dev/null || true)"

    local pr_state_hint=""
    if [[ -n "$pr_state_raw" ]]; then
        # gh path returns JSON; git fallback returns the literal word
        # `merged` or `open`. Detect which and normalise to a token.
        if printf '%s' "$pr_state_raw" | jq -e . >/dev/null 2>&1; then
            local pr_merged pr_draft
            pr_merged="$(printf '%s' "$pr_state_raw" | jq -r '.merged // false')"
            pr_draft="$(printf '%s' "$pr_state_raw" | jq -r '.isDraft // false')"
            if [[ "$pr_merged" == "true" ]]; then
                pr_state_hint="merged"
            elif [[ "$pr_draft" == "false" ]]; then
                pr_state_hint="ready"
            fi
        elif [[ "$pr_state_raw" == "merged" ]]; then
            pr_state_hint="merged"
        fi
    fi

    if ! lifecycle_phase="$(parser::lifecycle_phase "$spec_dir" "$pr_state_hint")"; then
        summary::add warned "spec ${feature_number}: cannot infer lifecycle phase; skipping"
        return 0
    fi

    reconcile::log "spec ${feature_number}: lifecycle=${lifecycle_phase} branch=${feature_branch}"

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
    # We only record for authoritative writers; read-only worktrees
    # take the early-return above and do not influence Project Status
    # decisions (matches Principle IV write-authority semantics).
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
    if (( ARG_RETROACTIVE == 1 )); then
        title="${title} (retroactive)"
    fi
    summary::start "$title"

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
