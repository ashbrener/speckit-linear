#!/usr/bin/env bash
# shellcheck shell=bash
#
# parser.sh — markdown parser for spec-kit artifacts.
#
# Public functions (all prefixed `parser::`):
#   parser::feature_number <spec_dir>
#   parser::short_name <spec_dir>
#   parser::lifecycle_phase <spec_dir> [pr_state]
#   parser::task_phases <tasks_md_path>
#   parser::tasks_in_phase <tasks_md_path> <phase_index>
#   parser::malformed_task_lines <tasks_md_path>
#   parser::clarify_sessions <spec_md_path>
#   parser::clarify_session_bullets <spec_md_path> <date>
#
# Implements the filesystem-side parser invariants documented in
# specs/001-spec-kit-linear-bridge/data-model.md §2.3-2.4 and the
# phase-inference ladder in spec FR-012 / FR-013 / FR-014.
#
# Vocabulary follows constitution Principle VIII: canonical spec-kit
# terms only (`## Phase N: <Name>` for task groupings, lifecycle phase
# identifiers from data-model.md `workflow_state_uuids` keys).
#
# This file is a library: it does NOT enable `set -euo pipefail` on
# the calling shell. Each top-level entry-point script in `src/` is
# responsible for setting its own shell options before sourcing this
# module (Principle VIII Rule 1: observable failure surfaces stay at
# the entry point, not in every library).

# ---------------------------------------------------------------------------
# parser::feature_number <spec_dir>
#
# Extracts the leading 3-digit feature number from the spec directory's
# basename (e.g. `specs/001-foo/` → `001`). Trailing slash tolerated.
# Empty output (and non-zero exit) when the basename does not start
# with `NNN-`.
# ---------------------------------------------------------------------------
parser::feature_number() {
    local spec_dir="$1"
    local base
    base="$(basename "${spec_dir%/}")"
    if [[ "$base" =~ ^([0-9]{3})- ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# parser::short_name <spec_dir>
#
# Extracts the kebab-case slug after `NNN-` from the spec directory's
# basename (e.g. `001-spec-kit-linear-bridge` →
# `spec-kit-linear-bridge`). Empty output (and non-zero exit) when the
# basename does not follow the `NNN-<slug>` shape.
# ---------------------------------------------------------------------------
parser::short_name() {
    local spec_dir="$1"
    local base
    base="$(basename "${spec_dir%/}")"
    if [[ "$base" =~ ^[0-9]{3}-(.+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# parser::_has_clarifications_section <spec_md_path>
#
# Returns 0 iff `spec.md` contains a literal `## Clarifications`
# heading followed (anywhere later in the file) by at least one
# `### Session YYYY-MM-DD` subheading.
# ---------------------------------------------------------------------------
parser::_has_clarifications_section() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 1
    awk '
        /^## Clarifications[[:space:]]*$/ { in_section = 1; next }
        /^## / && in_section { exit }
        in_section && /^### Session [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            found = 1
            exit
        }
        END { exit (found ? 0 : 1) }
    ' "$spec_md"
}

# ---------------------------------------------------------------------------
# parser::_has_checked_tasks <tasks_md_path>
#
# Returns 0 iff at least one `- [x]` checked task line exists in
# `tasks.md`. Case-insensitive on the `x` per common markdown variants.
# ---------------------------------------------------------------------------
parser::_has_checked_tasks() {
    local tasks_md="$1"
    [[ -f "$tasks_md" ]] || return 1
    grep -Eiq '^- \[x\] ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::lifecycle_phase <spec_dir> [pr_state]
#
# Infers the spec's current lifecycle phase from filesystem artifacts
# per spec FR-012 + FR-013 + data-model.md §6.1. Walks the inference
# ladder bottom-up, returning the highest-precedence phase whose
# trigger artifacts are present. Output is one of the canonical
# `workflow_state_uuids` keys:
#
#   specifying | clarifying | planning | tasking | red_team |
#   implementing | analyzing | ready_to_merge | merged
#
# Optional second arg is a caller-supplied PR state hint
# (`open` | `ready` | `merged`) emitted by `git_helpers::pr_state`;
# the parser stays decoupled from `gh`/git and never shells out.
#
# `spec.md` absent / empty → exits non-zero (caller should skip and
# warn per spec edge case §1).
# ---------------------------------------------------------------------------
parser::lifecycle_phase() {
    local spec_dir="$1"
    local pr_state="${2:-}"

    local spec_md="${spec_dir%/}/spec.md"
    local plan_md="${spec_dir%/}/plan.md"
    local tasks_md="${spec_dir%/}/tasks.md"

    if [[ ! -s "$spec_md" ]]; then
        return 1
    fi

    # PR hints short-circuit to terminal states regardless of artifact
    # ladder (FR-013, FR-014: retroactive sync lands directly).
    case "$pr_state" in
        merged)
            printf 'merged\n'
            return 0
            ;;
        open|ready|ready_for_review)
            printf 'ready_to_merge\n'
            return 0
            ;;
    esac

    local has_red_team=0 has_analyze=0
    if compgen -G "${spec_dir%/}/red-team*.md" >/dev/null; then
        has_red_team=1
    fi
    if compgen -G "${spec_dir%/}/analyze*.md" >/dev/null; then
        has_analyze=1
    fi

    if [[ "$has_analyze" -eq 1 ]]; then
        printf 'analyzing\n'
        return 0
    fi

    if [[ -f "$tasks_md" ]] && parser::_has_checked_tasks "$tasks_md"; then
        printf 'implementing\n'
        return 0
    fi

    if [[ "$has_red_team" -eq 1 ]]; then
        printf 'red_team\n'
        return 0
    fi

    if [[ -f "$tasks_md" ]]; then
        printf 'tasking\n'
        return 0
    fi

    if [[ -f "$plan_md" ]]; then
        printf 'planning\n'
        return 0
    fi

    if parser::_has_clarifications_section "$spec_md"; then
        printf 'clarifying\n'
        return 0
    fi

    printf 'specifying\n'
}

# ---------------------------------------------------------------------------
# parser::task_phases <tasks_md_path>
#
# Emits one line per `## Phase N: <Name>` heading found in tasks.md,
# formatted `<N>\t<Name>`. Both `## Phase 1: Setup` and
# `## Phase 10: Polish` are accepted; the name is trimmed of leading
# and trailing whitespace. No output if the file is absent or has no
# matching headings (caller infers "no task phases yet").
# ---------------------------------------------------------------------------
parser::task_phases() {
    local tasks_md="$1"
    [[ -f "$tasks_md" ]] || return 0
    awk '
        /^## Phase [0-9]+:/ {
            line = $0
            # Strip the leading "## Phase " prefix.
            sub(/^## Phase /, "", line)
            # Index of ":" splits "<N>" from "<Name>".
            colon = index(line, ":")
            if (colon == 0) next
            idx = substr(line, 1, colon - 1)
            name = substr(line, colon + 1)
            sub(/^[[:space:]]+/, "", name)
            sub(/[[:space:]]+$/, "", name)
            printf "%s\t%s\n", idx, name
        }
    ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::tasks_in_phase <tasks_md_path> <phase_index>
#
# Emits one line per task belonging to phase `<phase_index>`, formatted
# `<TaskID>\t<checked|unchecked>\t<description>`. Tasks are checklist
# items (`- [ ]` / `- [x]`) appearing between the matching
# `## Phase N:` heading and the next `## ` heading. Task ID is the
# first whitespace-separated token after the checkbox; description is
# the remainder of the line (any trailing whitespace trimmed).
#
# If a checklist line has no recognisable task ID token, the entire
# remainder becomes the description and the ID is empty.
# ---------------------------------------------------------------------------
parser::tasks_in_phase() {
    local tasks_md="$1"
    local phase_index="$2"
    [[ -f "$tasks_md" ]] || return 0
    awk -v want="$phase_index" '
        /^## Phase [0-9]+:/ {
            line = $0
            sub(/^## Phase /, "", line)
            colon = index(line, ":")
            if (colon == 0) { in_phase = 0; next }
            idx = substr(line, 1, colon - 1)
            in_phase = (idx == want) ? 1 : 0
            next
        }
        /^## / { in_phase = 0; next }
        in_phase && /^- \[[ xX]\][[:space:]]/ {
            # Checkbox character is line[4] (1-indexed): "- [X] ".
            box = substr($0, 4, 1)
            state = (tolower(box) == "x") ? "checked" : "unchecked"
            rest = substr($0, 7)
            sub(/^[[:space:]]+/, "", rest)
            sub(/[[:space:]]+$/, "", rest)
            id = ""
            desc = rest
            sp = index(rest, " ")
            tab_idx = index(rest, "\t")
            if (tab_idx > 0 && (sp == 0 || tab_idx < sp)) sp = tab_idx
            if (sp > 0) {
                id = substr(rest, 1, sp - 1)
                desc = substr(rest, sp + 1)
                sub(/^[[:space:]]+/, "", desc)
                sub(/[[:space:]]+$/, "", desc)
            }
            printf "%s\t%s\t%s\n", id, state, desc
        }
    ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::malformed_task_lines <tasks_md_path>
#
# Emits one line per checklist task line (`- [ ]` / `- [x]`) that
# appears OUTSIDE any `## Phase N:` heading. Lines are emitted with
# their 1-indexed source line number first, then a tab, then the
# verbatim line — useful for warning messages per FR-024 and SC-007.
# Empty output when every task line lives under some `## Phase`.
# ---------------------------------------------------------------------------
parser::malformed_task_lines() {
    local tasks_md="$1"
    [[ -f "$tasks_md" ]] || return 0
    awk '
        /^## Phase [0-9]+:/ { in_phase = 1; next }
        /^## / { in_phase = 0; next }
        !in_phase && /^- \[[ xX]\][[:space:]]/ {
            printf "%d\t%s\n", NR, $0
        }
    ' "$tasks_md"
}

# ---------------------------------------------------------------------------
# parser::clarify_sessions <spec_md_path>
#
# Emits one line per `### Session YYYY-MM-DD` subheading found under
# the `## Clarifications` section of spec.md, formatted
# `<date>\t<bullet-count>`. Bullets are counted as `- ` prefixed lines
# between this session's heading and the next `### ` or `## ` heading
# (whichever comes first). FR-008 + FR-015 source-of-truth.
# ---------------------------------------------------------------------------
parser::clarify_sessions() {
    local spec_md="$1"
    [[ -f "$spec_md" ]] || return 0
    awk '
        function flush() {
            if (current_date != "") {
                printf "%s\t%d\n", current_date, bullet_count
            }
            current_date = ""
            bullet_count = 0
        }
        /^## Clarifications[[:space:]]*$/ { in_section = 1; next }
        /^## / {
            if (in_section) { flush(); in_section = 0 }
            next
        }
        in_section && /^### Session [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            flush()
            # Extract the date token (chars 13..22 in "### Session YYYY-MM-DD").
            current_date = substr($0, 13, 10)
            bullet_count = 0
            next
        }
        in_section && current_date != "" && /^- / {
            bullet_count++
        }
        END { if (in_section) flush() }
    ' "$spec_md"
}

# ---------------------------------------------------------------------------
# parser::clarify_session_bullets <spec_md_path> <date>
#
# Emits the verbatim bullet lines (each starting with `- `) belonging
# to the `### Session <date>` subheading. Used by reconcile to build
# the body of the per-session comment posted on the spec Issue
# (FR-015). Empty output if the date heading is not found.
# ---------------------------------------------------------------------------
parser::clarify_session_bullets() {
    local spec_md="$1"
    local date="$2"
    [[ -f "$spec_md" ]] || return 0
    awk -v want="$date" '
        /^## Clarifications[[:space:]]*$/ { in_section = 1; next }
        /^## / { in_section = 0; in_session = 0; next }
        in_section && /^### Session [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            this_date = substr($0, 13, 10)
            in_session = (this_date == want) ? 1 : 0
            next
        }
        in_section && /^### / { in_session = 0; next }
        in_section && in_session && /^- / { print }
    ' "$spec_md"
}
