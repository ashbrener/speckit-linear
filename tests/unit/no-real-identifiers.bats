#!/usr/bin/env bats
# shellcheck shell=bats
# =============================================================================
# tests/unit/no-real-identifiers.bats
#
# Privacy guard. spec-kit-linear is a PUBLIC repo; example configs, test
# fixtures, specs and docs must use neutral placeholder coordinates, never
# the operator's real Linear workspace/team/project/user UUIDs or identity.
#
# This test fails CI if any real identifier reappears anywhere in the
# tracked tree. The forbidden patterns are RECONSTRUCTED from fragments at
# runtime so this guard file does not itself contain (and thus self-match)
# the very strings it forbids.
#
# Bootstrap: the resolved `linear-config.yml` (which legitimately holds the
# real values for local dogfooding) is gitignored, so `git ls-files` never
# sees it — only the committed `config-template.yml` placeholder ships.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# Reassemble each forbidden literal from pieces. Concatenation keeps the full
# string out of this file's bytes, so the guard can scan the tree (including
# itself) without a false positive.
_forbidden_patterns() {
  printf '%s\n' \
    "6ab43461""-6d22-4f02-bb1e-0be9859c7997" \
    "dc2e7503""-4b65-42ac-bed8-d2aa2d817f60" \
    "9f411c68""-640a-4f80-a803-c8716caff3f0" \
    "star""logik" \
    "OSH""-INFRA" \
    "osh""-infra" \
    "OSH""-[0-9]"
}

@test "no real Linear identifiers leak into the tracked tree (privacy guard)" {
  cd "$REPO_ROOT"
  local pattern hits all_hits=""
  while IFS= read -r pattern; do
    # -I skips binaries; -E for the OSH-<N> char class. NUL-safe file list.
    hits="$(git ls-files -z | xargs -0 grep -nIE "$pattern" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      all_hits+="--- pattern: ${pattern} ---"$'\n'"${hits}"$'\n'
    fi
  done < <(_forbidden_patterns)

  if [ -n "$all_hits" ]; then
    printf 'Real identifier(s) found in tracked files:\n%s\n' "$all_hits" >&2
    printf 'Replace with neutral placeholders (see config-template.yml).\n' >&2
    return 1
  fi
}
