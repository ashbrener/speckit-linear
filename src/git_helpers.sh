#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/git_helpers.sh
#
# Git / worktree / PR-state primitives used by the reconciler and by the
# write-authority gate (Principle IV: "Write-Authority Follows The Worktree").
#
# Public functions are namespaced under git_helpers:: and never print to
# stderr unless something has actually gone wrong. They are designed to be
# safe to call repeatedly (idempotent, no side effects) so the reconciler
# can ask the same question from multiple call sites without surprise.
#
# Responsibilities (in spec terms):
#   * Surface the current branch and the worktree → branch map (FR-026)
#   * Implement the write-authority gate for a given spec (FR-025, Principle IV)
#   * Enumerate spec feature branches by their NNN- prefix
#   * Detect a branch's PR state, preferring `gh` when present and falling
#     back to git-only branch-reachability (FR-030)
#   * Produce a cross-platform ISO 8601 mtime for "last touched on disk"
#     surfaces in the spec Issue's memory block (FR-004)
#
# Non-responsibilities: this module does NOT mutate git state (no checkouts,
# no resets, no commits) and does NOT make network calls of its own. The
# only external program it may shell out to is `gh`, and only when `gh` is
# already present and authenticated.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Cache the absolute path to `git` at module-source time. The test harness in
# tests/unit/git_helpers.bats forces the git-only fallback path of pr_state by
# stripping every PATH entry that contains a `gh` binary — on most Linux
# distros (and the CI runner) git and gh both live in /usr/bin, so the strip
# also evicts git from PATH. Resolving git here, BEFORE any test manipulates
# PATH, lets pr_state invoke it via the absolute path and keeps the fallback
# working even when PATH has been narrowed. The shell variable falls back to
# the bare `git` token when resolution fails, so non-test consumers see no
# behavioural change.
# ---------------------------------------------------------------------------
_GIT_HELPERS_GIT_BIN="$(command -v git 2>/dev/null || printf 'git')"

# ---------------------------------------------------------------------------
# git_helpers::current_branch
#
# Echoes the name of the currently checked-out branch, or empty string when
# the working tree is in a detached-HEAD state. Never errors out — callers
# treat empty output as "no branch" and gate accordingly.
#
# Implementation note: `git rev-parse --abbrev-ref HEAD` returns the literal
# string "HEAD" when detached. We translate that to empty so callers don't
# have to special-case the sentinel.
# ---------------------------------------------------------------------------
git_helpers::current_branch() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    return 0
  fi
  printf '%s\n' "$branch"
}

# ---------------------------------------------------------------------------
# git_helpers::list_worktrees
#
# Emits one line per worktree in the form:   <path>\t<branch>
#
# A worktree on a detached HEAD is emitted with an empty branch field
# (i.e. the line ends with a literal trailing tab) so callers can still
# count it without parsing porcelain output.
#
# This wraps `git worktree list --porcelain`, whose record format is:
#   worktree <path>
#   HEAD <sha>
#   branch refs/heads/<name>      (only when not detached)
#   <blank line separating records>
#
# We accumulate path + branch across the record and emit the pair when the
# record terminates (either by a blank line OR end of input — the last
# record has no trailing blank line).
# ---------------------------------------------------------------------------
git_helpers::list_worktrees() {
  local path='' branch='' line
  # The trailing `|| true` on read handles the no-final-newline case so
  # the loop body still runs for the last record.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == worktree\ * ]]; then
      path="${line#worktree }"
      branch=''
    elif [[ "$line" == branch\ refs/heads/* ]]; then
      branch="${line#branch refs/heads/}"
    elif [[ -z "$line" ]]; then
      if [[ -n "$path" ]]; then
        printf '%s\t%s\n' "$path" "$branch"
        path=''
        branch=''
      fi
    fi
  done < <(git worktree list --porcelain 2>/dev/null)

  # Flush the final record (porcelain output has no trailing blank line).
  if [[ -n "$path" ]]; then
    printf '%s\t%s\n' "$path" "$branch"
  fi
}

# ---------------------------------------------------------------------------
# git_helpers::worktree_for_branch <branch>
#
# Echoes the worktree path that currently has <branch> checked out, or
# empty string if no worktree holds that branch.
#
# Exactly one worktree can hold a given branch at a time (git enforces
# this), so the first match is also the only match.
# ---------------------------------------------------------------------------
git_helpers::worktree_for_branch() {
  local target_branch="${1:-}"
  if [[ -z "$target_branch" ]]; then
    return 0
  fi

  local line path branch
  while IFS=$'\t' read -r path branch; do
    if [[ "$branch" == "$target_branch" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(git_helpers::list_worktrees)

  # No worktree currently holds the branch — emit nothing, succeed.
  # Touch the unused locals so shellcheck doesn't complain when this code
  # path falls through with all-empty bindings.
  : "${line:-}"
}

# ---------------------------------------------------------------------------
# git_helpers::is_authoritative_for_spec <NNN>
#
# Returns 0 (true) iff the current branch matches the spec's authoritative
# feature-branch pattern ^<NNN>-.+$ — i.e. the worktree this is called
# from is the one allowed to WRITE to Linear for that spec.
#
# Implements the gate in spec FR-025 and constitution Principle IV.
# Any worktree on `main`, on an unrelated feature branch, or on detached
# HEAD returns 1 — the reconciler then enters read-only mode for that
# spec per FR-026.
#
# <NNN> is the feature number as it appears on disk (typically three
# digits, but the regex allows any non-zero-padded numeric run for
# future-proofing). A non-numeric or empty argument always returns 1.
# ---------------------------------------------------------------------------
git_helpers::is_authoritative_for_spec() {
  local feature_number="${1:-}"
  if [[ -z "$feature_number" || ! "$feature_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local branch
  branch=$(git_helpers::current_branch)
  if [[ -z "$branch" ]]; then
    return 1
  fi

  # Anchor on the feature-number prefix plus a `-` separator and at least
  # one slug character. Matches "001-foo", "001-foo-bar"; rejects "001",
  # "0010-foo" (different number), and "main".
  if [[ "$branch" =~ ^${feature_number}-.+$ ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# git_helpers::feature_branches
#
# Emits every local branch whose name starts with the canonical spec
# feature-branch pattern: ^[0-9]{3,}-.+$ (three or more leading digits,
# a dash, then a non-empty slug).
#
# Used by the reconciler when it needs to enumerate "which specs has an
# operator started branches for". The three-digit minimum matches the
# canonical `specs/NNN-feature/` layout while still allowing four-digit
# expansion if the project ever exceeds 999 specs.
# ---------------------------------------------------------------------------
git_helpers::feature_branches() {
  local branch
  while IFS= read -r branch; do
    # `git branch --format='%(refname:short)'` returns plain branch names
    # with no leading marker character. Trim defensively in case the git
    # version on the runner ever prepends whitespace.
    branch="${branch#"${branch%%[![:space:]]*}"}"
    branch="${branch%"${branch##*[![:space:]]}"}"
    if [[ "$branch" =~ ^[0-9]{3,}-.+$ ]]; then
      printf '%s\n' "$branch"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
}

# ---------------------------------------------------------------------------
# git_helpers::feature_number_for_branch <branch>
#
# Extracts the leading numeric NNN prefix from a feature branch name.
# Echoes the empty string for any input that doesn't match the canonical
# pattern (e.g. `main`, `release/foo`, a branch with no dash separator).
#
# This is the inverse of git_helpers::is_authoritative_for_spec — callers
# use it to derive "which spec does this branch belong to" without
# committing to a specific zero-padding width.
# ---------------------------------------------------------------------------
git_helpers::feature_number_for_branch() {
  local branch="${1:-}"
  if [[ -z "$branch" ]]; then
    return 0
  fi
  if [[ "$branch" =~ ^([0-9]+)-.+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# ---------------------------------------------------------------------------
# git_helpers::pr_state <branch>
#
# Implements FR-030's two-tier PR detection contract:
#
#   1. If `gh` is in PATH AND the operator is authenticated to GitHub via
#      `gh`, return a rich JSON object describing the PR whose HEAD is
#      <branch> (fields: state, isDraft, mergedAt, url). The reconciler
#      decodes whichever fields it needs; "merged" is derived from
#      `state == "MERGED"` (a non-null `mergedAt` corroborates it).
#
#      We query via `gh pr list --head <branch> --state all` rather than
#      `gh pr view <branch>` for two reasons:
#        (a) `gh pr view` requires <branch> to be the *current* branch or
#            otherwise resolvable from local checkout/upstream context;
#            `gh pr list --head` queries the GitHub API directly for ANY
#            branch name, so detection works when reconciling a spec's
#            feature branch (`NNN-...`) from `main` or any other worktree
#            (FR-013 / FR-030 merge detection from any branch).
#        (b) `gh pr list` returns an empty array (exit 0) when no PR
#            exists, vs `gh pr view` which exits non-zero — cleaner to
#            branch on. We take the first (most-recent) matching PR.
#
#      NOTE: there is intentionally NO `merged` field in the --json set —
#      `merged` is not a valid `gh pr {view,list}` JSON field (it errors
#      `Unknown JSON field: "merged"` and aborts the whole query). The
#      original code requested it, so the gh path ALWAYS failed and fell
#      through to the git fallback below; from `main` (where the feature
#      branch has no local ref) that fallback returns indeterminate, so a
#      merged spec was mis-detected as still implementing. Merge state is
#      now read from `state`/`mergedAt`, the real fields.
#
#   2. Otherwise (no `gh` binary, or `gh auth status` failing) fall back to
#      a git-only branch-reachability probe:
#        - "merged" if the branch tip is an ancestor of origin/main (or, if
#          no `origin/main` ref exists, of the upstream of HEAD).
#        - "open" otherwise.
#
#      In the fallback path we have no signal on draft state or even on
#      "does a PR exist at all" — git alone cannot answer those questions.
#      We emit the bare word `merged` or `open` so the reconciler can still
#      branch on the most operationally important distinction (has the
#      change landed yet?) without conflating it with the richer JSON form.
#
# Empty stdout (and exit 0) means "could not determine" — this happens
# when neither `gh` nor any usable git base ref is available; callers
# treat that as a soft warning per Principle VIII rather than an abort.
# ---------------------------------------------------------------------------
git_helpers::pr_state() {
  local branch="${1:-}"
  if [[ -z "$branch" ]]; then
    return 0
  fi

  # ----- Path 1: gh CLI is present and authenticated --------------------
  # `command -v gh` returns success iff gh is on PATH. `gh auth status`
  # is the canonical "are we logged in" check; we redirect its noisy
  # output to /dev/null and rely solely on its exit code.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local rich first
    # `gh pr list --head <branch> --state all` queries the GitHub API for
    # the PR(s) whose head ref is <branch>, independent of which branch is
    # checked out locally — this is what makes merge detection work when
    # reconciling spec NNN from `main`. Returns a JSON array (possibly
    # empty). We extract the first element (most-recent PR) as the rich
    # object the reconciler expects. Only the valid fields are requested
    # (no `merged` — that field does not exist and would abort the query).
    if rich=$(gh pr list --head "$branch" --state all \
        --json state,isDraft,mergedAt,url 2>/dev/null); then
      if [[ -n "$rich" ]]; then
        # `jq -e .[0]` exits non-zero (and prints nothing usable) when the
        # array is empty, so a no-PR branch falls through to the git probe.
        if first=$(printf '%s' "$rich" | jq -ce '.[0]' 2>/dev/null) \
            && [[ -n "$first" && "$first" != "null" ]]; then
          printf '%s\n' "$first"
          return 0
        fi
      fi
    fi
    # No PR found for this branch (empty array or query failed). Fall
    # through to the git-only probe so we still answer the merged-or-not
    # question that callers actually care about.
  fi

  # ----- Path 2: git-only branch-reachability fallback ------------------
  # Try the conventional `origin/main` first because that's where 99% of
  # PRs land. If that ref doesn't exist (fresh clone, non-standard
  # default branch, no remote), fall back to the current branch's
  # upstream as a best-effort base.
  #
  # NOTE: we invoke git via the absolute path captured at module-source
  # time (see _GIT_HELPERS_GIT_BIN above) so the fallback works even when
  # the test harness has stripped /usr/bin from PATH to evict the `gh`
  # binary alongside it.
  local git_bin="${_GIT_HELPERS_GIT_BIN:-git}"
  local base=''
  if "$git_bin" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then
    base='refs/remotes/origin/main'
  elif "$git_bin" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1; then
    base=$("$git_bin" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || printf '')
  fi

  if [[ -z "$base" ]]; then
    # No usable base ref — caller should treat this as "indeterminate"
    # and surface a warning rather than aborting.
    return 0
  fi

  # The branch must actually exist locally for `git merge-base` to work
  # in either direction. If it doesn't, we can't answer, so emit nothing.
  if ! "$git_bin" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
    && ! "$git_bin" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
    return 0
  fi

  # `git merge-base --is-ancestor A B` returns 0 iff A is reachable from B.
  # A branch is "merged" iff its tip commit is reachable from the base.
  if "$git_bin" merge-base --is-ancestor "$branch" "$base" >/dev/null 2>&1; then
    printf 'merged\n'
  else
    printf 'open\n'
  fi
}

# ---------------------------------------------------------------------------
# git_helpers::last_touched <path>
#
# Echoes the modification time of <path> in ISO 8601 (UTC, second
# precision: YYYY-MM-DDTHH:MM:SSZ). Used by the spec Issue's memory
# block (FR-004) so operators can see "when did this spec last change
# on disk" without leaving Linear.
#
# Cross-platform: GNU coreutils `stat` and BSD `stat` (macOS) use
# incompatible flag sets. We try the GNU form first (`stat -c %Y`) and
# fall back to the BSD form (`stat -f %m`). Both emit the mtime as a
# Unix epoch integer, which we then format via `date -u`. macOS `date`
# uses `-r <epoch>` to interpret the integer; GNU `date` uses
# `-d @<epoch>`. We try both.
#
# Empty stdout means we couldn't read the file — caller should treat it
# as "unknown" rather than aborting.
# ---------------------------------------------------------------------------
git_helpers::last_touched() {
  local target="${1:-}"
  if [[ -z "$target" || ! -e "$target" ]]; then
    return 0
  fi

  local epoch=''
  if epoch=$(stat -c %Y "$target" 2>/dev/null); then
    : # GNU stat succeeded
  elif epoch=$(stat -f %m "$target" 2>/dev/null); then
    : # BSD stat succeeded
  else
    return 0
  fi

  if [[ -z "$epoch" || ! "$epoch" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  local formatted=''
  if formatted=$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
    printf '%s\n' "$formatted"
  elif formatted=$(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
    printf '%s\n' "$formatted"
  fi
}

# ---------------------------------------------------------------------------
# git_helpers::iso_to_epoch <iso-8601>          (spec 003 — recency-comparison §2)
#
# Converts a strict ISO-8601 timestamp (e.g. the `%cI` committer date
# `2026-05-20T14:02:11+00:00`, or a `Z`-suffixed UTC form) to a Unix epoch
# integer on stdout. Mirrors the dual GNU/BSD `date` pattern that
# git_helpers::last_touched already relies on, but in the parse direction:
#
#   * GNU coreutils: `date -d "<iso>" +%s` accepts ISO-8601 directly.
#   * BSD/macOS:     `date -j -f "<fmt>" "<iso>" +%s` needs an explicit
#                    input format. ISO-8601 admits two zone spellings —
#                    a literal `Z` and a numeric `±HH:MM` offset — so we try
#                    both BSD format strings. macOS `date` rejects the colon
#                    in `%z`, so we normalise `+00:00` → `+0000` first.
#
# Empty stdout (exit 0) means the string could not be parsed — the caller
# treats recency as `unavailable` and falls back to phase-ordering alone
# (recency-comparison §2: "do not fabricate a comparison"). MUST NOT use
# mtime; this is a pure string→epoch transform with no filesystem access.
# ---------------------------------------------------------------------------
git_helpers::iso_to_epoch() {
  local iso="${1:-}"
  if [[ -z "$iso" ]]; then
    return 0
  fi

  local epoch=''
  # GNU first: a single permissive parser handles every ISO-8601 spelling.
  if epoch=$(date -d "$iso" +%s 2>/dev/null) && [[ -n "$epoch" ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi

  # BSD/macOS fallback. macOS `strptime` cannot read the colon in a numeric
  # zone offset, so collapse `+00:00` → `+0000` before handing it over.
  local normalised="${iso/Z/+0000}"
  # Strip the colon from a trailing ±HH:MM offset only (last 6 chars shape).
  if [[ "$normalised" =~ ^(.*T[0-9:]+)([+-][0-9]{2}):([0-9]{2})$ ]]; then
    normalised="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  fi
  if epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$normalised" +%s 2>/dev/null) \
      && [[ -n "$epoch" ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  # Last resort: a zone-less ISO form (no offset at all).
  if epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso%Z}" +%s 2>/dev/null) \
      && [[ -n "$epoch" ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  # Unparseable — recency unavailable.
  return 0
}

# ---------------------------------------------------------------------------
# git_helpers::spec_dir_last_commit <spec_dir>   (spec 003 — recency-comparison §1)
#
# Echoes the ISO-8601 committer date (`%cI`, e.g.
# `2026-05-20T14:02:11+00:00`) of the most recent commit that TOUCHED
# <spec_dir>, or the empty string when no commit in this worktree's history
# touches the directory (Edge Case 1 → recency signal `unavailable`).
#
# This is the recency comparator's disk key (FR-053). It MUST use the git
# committer date — NEVER `stat`/mtime — because the committer date is
# clone/checkout-stable and reflects when the change landed in THIS
# worktree's history. The mtime-based git_helpers::last_touched (above) is
# RETAINED only for the FR-004 memory-block human display and MUST NOT be
# used as the recency comparator.
#
# Runs `git -C <worktree-or-cwd>` implicitly via the captured git binary so
# the lookup works from any worktree; the pathspec `-- <spec_dir>` restricts
# the log to commits affecting the spec directory.
# ---------------------------------------------------------------------------
git_helpers::spec_dir_last_commit() {
  local spec_dir="${1:-}"
  if [[ -z "$spec_dir" ]]; then
    return 0
  fi

  local git_bin="${_GIT_HELPERS_GIT_BIN:-git}"
  local iso=''
  # `git log -1 --format=%cI -- <dir>` echoes a single ISO-8601 line, or
  # nothing (exit 0) when no commit touches the pathspec. The `|| true`
  # guards against a non-zero exit on a brand-new repo with no commits.
  iso=$("$git_bin" log -1 --format=%cI -- "$spec_dir" 2>/dev/null || true)
  if [[ -n "$iso" ]]; then
    printf '%s\n' "$iso"
  fi
}

# ---------------------------------------------------------------------------
# git_helpers::worktrees_touching_spec <feature_number>
#                                          (spec 003 — recency-comparison §4)
#
# Emits one line per worktree whose checkout contains a `specs/<NNN>-*/`
# directory, in the form:
#
#     <commit_epoch>\t<worktree_path>\t<branch>
#
# where <commit_epoch> is the Unix-epoch conversion of that worktree's
# spec-dir last-commit ISO date (§1), <worktree_path> is the absolute
# worktree root, and <branch> is the checked-out branch (empty for detached
# HEAD). Worktrees that do NOT contain the spec dir are omitted entirely.
#
# Ranking contract (FR-058 / FR-059): the canonical worktree is the line
# with the MAXIMUM commit_epoch — the most recent spec-dir commit, NEVER the
# branch name or filesystem mtime. Ties (identical epochs) resolve to the
# invoking worktree as canonical; both tied worktrees still appear in the
# emitted touching set. This function only enumerates + ranks; the caller
# (reconcile::compute_drift / the WARNING emitter) selects the max.
#
# A worktree whose spec-dir commit is unavailable (dir present but no commit
# touches it — uncommitted spec) is emitted with a `0` epoch so it sorts
# below any real commit but still appears in the touching set.
# ---------------------------------------------------------------------------
git_helpers::worktrees_touching_spec() {
  local feature_number="${1:-}"
  if [[ -z "$feature_number" || ! "$feature_number" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  local git_bin="${_GIT_HELPERS_GIT_BIN:-git}"
  local invoking_root=''
  invoking_root=$("$git_bin" rev-parse --show-toplevel 2>/dev/null || printf '')

  local path branch
  while IFS=$'\t' read -r path branch; do
    [[ -n "$path" ]] || continue

    # Find a specs/<NNN>-*/ dir inside this worktree. `compgen -G` globs
    # without nullglob side effects; the first match is sufficient because a
    # well-formed repo carries exactly one spec dir per feature number.
    local matches match spec_dir=''
    matches=$(compgen -G "${path%/}/specs/${feature_number}-*" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      while IFS= read -r match; do
        if [[ -d "$match" ]]; then
          spec_dir="$match"
          break
        fi
      done <<< "$matches"
    fi
    [[ -n "$spec_dir" ]] || continue

    # The spec-dir last commit must be read from THIS worktree's history.
    # `git -C <path> log` scopes the query to the worktree's own refs.
    local iso epoch
    iso=$("$git_bin" -C "$path" log -1 --format=%cI -- "$spec_dir" 2>/dev/null || true)
    if [[ -n "$iso" ]]; then
      epoch=$(git_helpers::iso_to_epoch "$iso")
    fi
    [[ -n "${epoch:-}" ]] || epoch=0

    printf '%s\t%s\t%s\n' "$epoch" "$path" "$branch"
  done < <(git_helpers::list_worktrees)

  # Touch invoking_root so shellcheck does not flag it unused; it documents
  # the tie-break rule (the caller resolves epoch ties to this path).
  : "${invoking_root:-}"
}
