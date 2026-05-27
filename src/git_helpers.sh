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
#      `gh`, return the rich JSON object `gh pr view` emits, exactly as
#      received (fields: state, isDraft, merged, mergedAt, url). The
#      reconciler decodes whichever fields it needs.
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
    local rich
    if rich=$(gh pr view "$branch" --json state,isDraft,merged,mergedAt,url 2>/dev/null); then
      if [[ -n "$rich" ]]; then
        printf '%s\n' "$rich"
        return 0
      fi
    fi
    # `gh pr view` exits non-zero when no PR exists for the branch. Fall
    # through to the git-only probe so we still answer the merged-or-not
    # question that callers actually care about.
  fi

  # ----- Path 2: git-only branch-reachability fallback ------------------
  # Try the conventional `origin/main` first because that's where 99% of
  # PRs land. If that ref doesn't exist (fresh clone, non-standard
  # default branch, no remote), fall back to the current branch's
  # upstream as a best-effort base.
  local base=''
  if git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then
    base='refs/remotes/origin/main'
  elif git rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1; then
    base=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || printf '')
  fi

  if [[ -z "$base" ]]; then
    # No usable base ref — caller should treat this as "indeterminate"
    # and surface a warning rather than aborting.
    return 0
  fi

  # The branch must actually exist locally for `git merge-base` to work
  # in either direction. If it doesn't, we can't answer, so emit nothing.
  if ! git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
    && ! git rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
    return 0
  fi

  # `git merge-base --is-ancestor A B` returns 0 iff A is reachable from B.
  # A branch is "merged" iff its tip commit is reachable from the base.
  if git merge-base --is-ancestor "$branch" "$base" >/dev/null 2>&1; then
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
