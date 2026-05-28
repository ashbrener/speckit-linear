#!/usr/bin/env bats
# =============================================================================
# tests/unit/git_helpers.bats
#
# Unit tests for src/git_helpers.sh.
#
# Strategy: every test runs inside a temp directory holding a freshly-
# initialised throwaway git repo (plus a separate temp dir for the bare
# "origin" remote when we need an origin/main ref or extra worktrees).
# The `gh` CLI is mocked via a per-test shim directory prepended to PATH,
# so we never make real GitHub API calls and never need the operator's
# `gh auth` state to test the rich-state path.
#
# Pinned tooling per plan.md §Testing: bats-core 1.11.0. The tests use
# only features available in that version (`setup`, `teardown`, `run`,
# `${lines[@]}`, `BATS_TEST_TMPDIR`).
#
# Targets covered:
#   - git_helpers::current_branch on main, on 001-feature, on detached HEAD
#   - git_helpers::list_worktrees with 2 worktrees
#   - git_helpers::worktree_for_branch hit + miss
#   - git_helpers::is_authoritative_for_spec yes/no cases
#   - git_helpers::feature_branches filter behaviour
#   - git_helpers::feature_number_for_branch extraction + non-feature input
#   - git_helpers::pr_state via mocked gh -> merged
#   - git_helpers::pr_state with gh absent + branch reachable -> merged
#   - git_helpers::pr_state with gh absent + branch ahead -> open
#   - git_helpers::last_touched returns parseable ISO 8601
# =============================================================================

# -----------------------------------------------------------------------------
# Resolve the source module's absolute path once at file load time, BEFORE
# any test changes directory. Doing this here (rather than inside setup())
# means `setup` is free to `cd` around without losing track of where the
# implementation lives.
# -----------------------------------------------------------------------------
GIT_HELPERS_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/src/git_helpers.sh"

# -----------------------------------------------------------------------------
# setup(): build a hermetic playground for each test.
#
#   $BATS_TEST_TMPDIR/repo       — the working repo most tests operate on
#   $BATS_TEST_TMPDIR/origin.git — bare remote used when we need origin/main
#   $BATS_TEST_TMPDIR/shims      — per-test PATH directory for the gh mock
#
# We deliberately set GIT_AUTHOR_* and GIT_COMMITTER_* env vars so commits
# work without depending on the operator's global git config. Likewise we
# clear HOME-derived gh config to avoid the host gh installation answering
# `gh auth status` accidentally — when we want gh present we drop a shim;
# when we want gh absent we strip /opt/homebrew/bin and friends from PATH.
# -----------------------------------------------------------------------------
setup() {
  # Source the module under test. `set +u` around the source is defensive
  # in case any helper relies on a variable that's only set later; the
  # module currently uses set -euo pipefail itself, but tests run with the
  # default bats environment which is more permissive.
  # shellcheck source=../../src/git_helpers.sh
  source "$GIT_HELPERS_SH"

  export GIT_AUTHOR_NAME='Test Author'
  export GIT_AUTHOR_EMAIL='test@example.com'
  export GIT_COMMITTER_NAME='Test Author'
  export GIT_COMMITTER_EMAIL='test@example.com'
  # Prevent the host's gpg-signing config from interfering with commits.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  REPO="$BATS_TEST_TMPDIR/repo"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  SHIMS="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$REPO" "$SHIMS"

  # Initialise the working repo with `main` as the explicit default branch
  # (older git versions default to `master`; pinning makes assertions stable).
  git -C "$REPO" init --initial-branch=main --quiet
  printf 'hello\n' > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m 'initial commit'
}

# -----------------------------------------------------------------------------
# Helper: create a feature branch from main and switch the working repo to it.
# -----------------------------------------------------------------------------
_make_feature_branch() {
  local branch="$1"
  git -C "$REPO" checkout --quiet -b "$branch"
  printf 'work on %s\n' "$branch" >> "$REPO/README.md"
  git -C "$REPO" commit --quiet -am "work on $branch"
}

# -----------------------------------------------------------------------------
# Helper: install a `gh` shim into $SHIMS that prints the supplied JSON and
# always claims authenticated. Prepends $SHIMS to PATH for the current test.
# -----------------------------------------------------------------------------
_install_gh_shim() {
  # $1 is the JSON ARRAY git_helpers::pr_state expects back from
  # `gh pr list --head <branch> --state all --json ...`. The implementation
  # extracts `.[0]` from this array, so callers pass an array literal (e.g.
  # '[{"state":"MERGED",...}]') — or '[]' to simulate "no PR for this
  # branch", which forces the git-only fallback.
  local json="$1"
  cat > "$SHIMS/gh" <<EOF
#!/usr/bin/env bash
# Minimal gh shim used by git_helpers.bats. Recognises only the two
# subcommands git_helpers::pr_state calls: \`auth status\` (must succeed)
# and \`pr list --head <branch> --state all --json ...\` (echo a JSON array).
case "\$1" in
  auth)
    # \`gh auth status\` — always healthy in this shim.
    exit 0
    ;;
  pr)
    # \`gh pr list --head <branch> --json ...\` — echo the canned JSON
    # array. This is queried by HEAD ref, so it resolves regardless of
    # which branch is currently checked out (the from-main case).
    cat <<'JSON'
$json
JSON
    exit 0
    ;;
  *)
    echo "gh shim: unsupported subcommand \$1" >&2
    exit 64
    ;;
esac
EOF
  chmod +x "$SHIMS/gh"
  export PATH="$SHIMS:$PATH"
}

# -----------------------------------------------------------------------------
# Helper: hide `gh` from PATH so the fallback path in git_helpers::pr_state
# is forced. We do this by prepending a SHIMS directory containing a `gh`
# stub that always reports "command not found"-equivalent behaviour, rather
# than stripping the directory itself — stripping /usr/bin (where gh
# typically lives on ubuntu-latest) would also evict `rm`, `stat`, etc.,
# which bats's own internal cleanup needs (and which would fail the whole
# test run with `rm: command not found` even though every individual test
# passed). The shim approach keeps PATH otherwise intact.
# -----------------------------------------------------------------------------
_strip_gh_from_path() {
  cat > "$SHIMS/gh" <<'EOF'
#!/usr/bin/env bash
# Stub `gh` that pretends not to exist. We exit non-zero so any caller
# treats it as a hard failure; git_helpers::pr_state specifically tests
# `command -v gh` first which will succeed (the stub IS executable and
# on PATH), but its own logic falls through to the git fallback when the
# `gh auth status` probe fails — which this stub guarantees by exiting 127.
exit 127
EOF
  chmod +x "$SHIMS/gh"
  export PATH="$SHIMS:$PATH"
}

# =============================================================================
# git_helpers::current_branch
# =============================================================================

@test "current_branch echoes 'main' on a fresh repo" {
  cd "$REPO"
  run git_helpers::current_branch
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "current_branch echoes the feature branch name when checked out" {
  cd "$REPO"
  _make_feature_branch '001-feature'
  run git_helpers::current_branch
  [ "$status" -eq 0 ]
  [ "$output" = "001-feature" ]
}

@test "current_branch echoes empty on detached HEAD" {
  cd "$REPO"
  # Make a second commit so we have something to detach onto without
  # losing the only ref.
  printf 'second\n' >> "$REPO/README.md"
  git -C "$REPO" commit --quiet -am 'second'
  local first_sha
  first_sha=$(git -C "$REPO" rev-parse HEAD~1)
  git -C "$REPO" checkout --quiet --detach "$first_sha"

  run git_helpers::current_branch
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# git_helpers::list_worktrees
# =============================================================================

@test "list_worktrees emits one tab-separated <path>\\t<branch> line per worktree" {
  cd "$REPO"
  # Create a second worktree on a new feature branch. `git worktree add -b`
  # creates the branch and checks it out into the worktree in one step.
  local other_wt="$BATS_TEST_TMPDIR/wt-001"
  git -C "$REPO" worktree add -b '001-feature' "$other_wt" >/dev/null

  run git_helpers::list_worktrees
  [ "$status" -eq 0 ]
  # We expect at least two lines (primary + the added worktree). Some git
  # versions emit additional informational records (e.g. for prune state);
  # we assert on content presence rather than exact line count.
  [ "${#lines[@]}" -ge 2 ]

  # macOS /tmp realpath gotcha (see CI run 26572145531): `git worktree list
  # --porcelain` resolves paths to their physical form, so on Darwin a worktree
  # under /var/folders/... is emitted as /private/var/folders/... — match both
  # the raw $REPO/$other_wt prefix AND the /private-rewritten form so the same
  # assertion passes on Linux and macOS.
  local saw_main=0 saw_feature=0
  for line in "${lines[@]}"; do
    case "$line" in
      "$REPO"*$'\t'main) saw_main=1 ;;
      "/private$REPO"*$'\t'main) saw_main=1 ;;
      "$other_wt"*$'\t'001-feature) saw_feature=1 ;;
      "/private$other_wt"*$'\t'001-feature) saw_feature=1 ;;
    esac
  done
  [ "$saw_main" -eq 1 ]
  [ "$saw_feature" -eq 1 ]
}

# =============================================================================
# git_helpers::worktree_for_branch
# =============================================================================

@test "worktree_for_branch returns the worktree path when the branch is checked out somewhere" {
  cd "$REPO"
  local other_wt="$BATS_TEST_TMPDIR/wt-002"
  git -C "$REPO" worktree add -b '002-other' "$other_wt" >/dev/null

  run git_helpers::worktree_for_branch '002-other'
  [ "$status" -eq 0 ]
  # `git worktree list` may report the path with a /private prefix on
  # macOS (because /tmp -> /private/tmp). Accept either form.
  [[ "$output" == "$other_wt" || "$output" == "/private$other_wt" ]]
}

@test "worktree_for_branch returns empty when no worktree holds the branch" {
  cd "$REPO"
  run git_helpers::worktree_for_branch 'nonexistent-branch'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# git_helpers::is_authoritative_for_spec
# =============================================================================

@test "is_authoritative_for_spec returns 0 on the matching feature branch" {
  cd "$REPO"
  _make_feature_branch '001-spec-kit-linear-bridge'
  run git_helpers::is_authoritative_for_spec '001'
  [ "$status" -eq 0 ]
}

@test "is_authoritative_for_spec returns 1 on main" {
  cd "$REPO"
  run git_helpers::is_authoritative_for_spec '001'
  [ "$status" -eq 1 ]
}

@test "is_authoritative_for_spec returns 1 on an unrelated feature branch" {
  cd "$REPO"
  _make_feature_branch '002-other-feature'
  run git_helpers::is_authoritative_for_spec '001'
  [ "$status" -eq 1 ]
}

@test "is_authoritative_for_spec returns 1 on detached HEAD" {
  cd "$REPO"
  printf 'second\n' >> "$REPO/README.md"
  git -C "$REPO" commit --quiet -am 'second'
  git -C "$REPO" checkout --quiet --detach HEAD~1
  run git_helpers::is_authoritative_for_spec '001'
  [ "$status" -eq 1 ]
}

@test "is_authoritative_for_spec returns 1 for a non-numeric argument" {
  cd "$REPO"
  _make_feature_branch '001-feature'
  run git_helpers::is_authoritative_for_spec 'abc'
  [ "$status" -eq 1 ]
}

# =============================================================================
# git_helpers::feature_branches
# =============================================================================

@test "feature_branches lists only branches matching NNN- prefix" {
  cd "$REPO"
  # Create one canonical feature branch, one non-feature branch, and one
  # branch with only two digits (should NOT match the 3+-digit pattern).
  git -C "$REPO" branch '001-spec-kit-linear-bridge'
  git -C "$REPO" branch '002-other-spec'
  git -C "$REPO" branch 'release/foo'
  git -C "$REPO" branch '12-too-short'

  run git_helpers::feature_branches
  [ "$status" -eq 0 ]

  # Build a quick set membership check from the output lines.
  local has_001=0 has_002=0 has_release=0 has_short=0 has_main=0
  for line in "${lines[@]}"; do
    case "$line" in
      '001-spec-kit-linear-bridge') has_001=1 ;;
      '002-other-spec') has_002=1 ;;
      'release/foo') has_release=1 ;;
      '12-too-short') has_short=1 ;;
      'main') has_main=1 ;;
    esac
  done
  [ "$has_001" -eq 1 ]
  [ "$has_002" -eq 1 ]
  [ "$has_release" -eq 0 ]
  [ "$has_short" -eq 0 ]
  [ "$has_main" -eq 0 ]
}

# =============================================================================
# git_helpers::feature_number_for_branch
# =============================================================================

@test "feature_number_for_branch extracts the leading NNN from a feature branch" {
  run git_helpers::feature_number_for_branch '001-spec-kit-linear-bridge'
  [ "$status" -eq 0 ]
  [ "$output" = "001" ]
}

@test "feature_number_for_branch echoes empty for 'main'" {
  run git_helpers::feature_number_for_branch 'main'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "feature_number_for_branch echoes empty for a branch with no numeric prefix" {
  run git_helpers::feature_number_for_branch 'release/foo'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "feature_number_for_branch echoes empty for an empty argument" {
  run git_helpers::feature_number_for_branch ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# git_helpers::pr_state — gh present (mocked)
# =============================================================================

@test "pr_state returns the first PR's rich JSON when gh reports a merged PR" {
  cd "$REPO"
  _make_feature_branch '001-feature'

  # gh pr list --head returns a JSON ARRAY; the canned blob uses the REAL
  # gh JSON fields (state/mergedAt) — there is no `merged` field (the bug:
  # requesting it aborted the gh query and lost merge detection entirely).
  _install_gh_shim '[{"state":"MERGED","isDraft":false,"mergedAt":"2026-05-27T10:00:00Z","url":"https://github.com/example/repo/pull/1"}]'

  run git_helpers::pr_state '001-feature'
  [ "$status" -eq 0 ]
  # The function unwraps the array's first element and passes it through.
  # Assert on the distinctive fields rather than the whole string so
  # whitespace quirks in the shim don't trip the test.
  [[ "$output" == *'"state":"MERGED"'* ]]
  [[ "$output" == *'"mergedAt":"2026-05-27T10:00:00Z"'* ]]
  # Regression guard: the unwrapped value is a JSON OBJECT, not the array.
  [[ "$output" != \[* ]]
}

# Regression test for the v0.1.1 dogfood bug (OSH-5 stuck "Implementing"
# despite PR #1 merged): reconciling a spec's feature branch from `main`
# — where the feature branch has NO local ref — must still detect MERGED
# via `gh pr list --head`. Previously the gh query requested an invalid
# `merged` field, always failed, and fell through to the git probe, which
# returned indeterminate from main (no local feature ref) → mis-detected
# as not-merged. Here we stay on `main` and never create a local
# `001-from-main` branch; the gh shim answers by HEAD ref regardless.
@test "pr_state detects a merged PR from main when the feature branch has no local ref" {
  cd "$REPO"
  # Stay on main — do NOT create a local 001-from-main branch.
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ]

  _install_gh_shim '[{"state":"MERGED","isDraft":false,"mergedAt":"2026-05-28T12:49:57Z","url":"https://github.com/example/repo/pull/1"}]'

  run git_helpers::pr_state '001-from-main'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"MERGED"'* ]]
}

# Negative pin: an OPEN, non-draft PR must NOT report as merged. The
# reconciler maps this to ready_to_merge (FR-028), never merged.
@test "pr_state returns an open non-draft PR's JSON (not merged) for the from-main case" {
  cd "$REPO"
  [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ]

  _install_gh_shim '[{"state":"OPEN","isDraft":false,"mergedAt":null,"url":"https://github.com/example/repo/pull/2"}]'

  run git_helpers::pr_state '002-open-pr'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state":"OPEN"'* ]]
  [[ "$output" != *'"state":"MERGED"'* ]]
}

# When gh reports NO PR for the branch (empty array), pr_state must fall
# through to the git-only reachability probe rather than treating the
# empty array as a merged/open signal.
@test "pr_state falls through to the git probe when gh returns an empty array" {
  cd "$REPO"
  git -C "$REPO" init --bare --quiet "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push --quiet origin main
  # Feature branch ahead of origin/main → git probe says "open".
  _make_feature_branch '001-no-pr'

  _install_gh_shim '[]'

  run git_helpers::pr_state '001-no-pr'
  [ "$status" -eq 0 ]
  [ "$output" = "open" ]
}

# =============================================================================
# git_helpers::pr_state — gh absent, git-only fallback
# =============================================================================

@test "pr_state falls back to git and returns 'merged' when branch is reachable from origin/main" {
  cd "$REPO"
  # Set up a bare origin and push main, so origin/main exists. Then make
  # the feature branch FROM main without any extra commits, push it, and
  # advance main past it so the feature branch's tip is reachable from
  # origin/main (i.e. effectively merged).
  git -C "$REPO" init --bare --quiet "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push --quiet origin main

  # Create the feature branch at the current HEAD.
  git -C "$REPO" branch '001-already-merged' main

  # Advance main with a follow-up commit, then push so origin/main moves
  # past the feature branch tip. The feature branch is now an ancestor.
  printf 'mainline progress\n' >> "$REPO/README.md"
  git -C "$REPO" commit --quiet -am 'mainline progress'
  git -C "$REPO" push --quiet origin main

  _strip_gh_from_path

  run git_helpers::pr_state '001-already-merged'
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
}

@test "pr_state falls back to git and returns 'open' when branch is ahead of origin/main" {
  cd "$REPO"
  git -C "$REPO" init --bare --quiet "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push --quiet origin main

  # Create the feature branch and add an extra commit so its tip is NOT
  # reachable from origin/main.
  _make_feature_branch '001-in-flight'

  _strip_gh_from_path

  run git_helpers::pr_state '001-in-flight'
  [ "$status" -eq 0 ]
  [ "$output" = "open" ]
}

# =============================================================================
# git_helpers::last_touched
# =============================================================================

@test "last_touched returns an ISO 8601 UTC timestamp for an existing file" {
  cd "$REPO"
  local file="$REPO/README.md"
  run git_helpers::last_touched "$file"
  [ "$status" -eq 0 ]
  # Match YYYY-MM-DDTHH:MM:SSZ exactly. Anchored so trailing chatter
  # would fail the test.
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "last_touched echoes empty for a missing file" {
  run git_helpers::last_touched "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
