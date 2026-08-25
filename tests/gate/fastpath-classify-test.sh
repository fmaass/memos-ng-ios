#!/usr/bin/env bash
#
# The gate's own integrity check: what `bin/mac-gate.sh --classify-only` calls a docs-only change.
#
# The fast path is the one place where the gate is allowed to say PASS without building anything,
# so the classifier that decides it is the one piece of the gate that cannot be checked by the
# gate's own build. It is checked here instead, against throwaway repositories this script builds:
# each case is a repository whose whole history and working tree exist to ask the classifier one
# question. A case that expects `full` is not decoration — every one of them is a way the fast
# path could have shipped an unbuilt change (a rename out of a source file, a symlink wearing a
# .md name, an edit sitting unstaged in the tree).
#
# Run it directly (`tests/gate/fastpath-classify-test.sh`) or let the gate run it: it is the
# gate's first step, on every run, fast path or not.
#
# Exit: 0 = every case classified as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="$repo_root/bin/mac-gate.sh"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-fastpath-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
fastpath_seen=0

# A repository with an origin whose main holds the baseline the classifier measures against.
# Everything the classifier can look at is here: a docs tree, a couple of markdown files at the
# root, the version file, and source under both of the layouts this repo builds from.
new_repo() {
  local name="$1" work="$tmp/$1" origin="$tmp/$1.git"
  git init --quiet --bare "$origin" || return 1
  git init --quiet -b main "$work" || return 1
  git -C "$work" config user.email gate-test@example.invalid
  git -C "$work" config user.name "gate test"
  git -C "$work" config commit.gpgsign false
  git -C "$work" config core.hooksPath "$tmp/no-hooks"
  mkdir -p "$work/docs" "$work/Sources" "$work/Packages/MemosCore/Sources/MemosCore"
  printf 'a guide\n' > "$work/docs/guide.md"
  printf 'the readme\n' > "$work/README.md"
  printf 'MARKETING_VERSION: "1.0.0"\n' > "$work/project.yml"
  printf 'let app = 1\n' > "$work/Sources/App.swift"
  printf 'let old = 1\n' > "$work/Sources/Foo.swift"
  printf 'let core = 1\n' > "$work/Packages/MemosCore/Sources/MemosCore/Core.swift"
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  printf '%s' "$work"
}

# The classifier is asked the way the gate asks it, from inside the repository under test and with
# no build host in the environment: a classification that needed a Mac to answer would not be a
# classification, it would be the gate.
classify() {
  local work="$1"
  OUT="$(cd "$work" && env -u MAC_GATE_HOST -u MAC_GATE_BRANCH "$GATE" --classify-only 2>&1)"
  RC=$?
}

# 0 = fast path, 10 = full gate. The exit code and the printed verdict have to agree: the gate
# reads the code, a human reads the line, and a disagreement between them is how a fast path
# gets taken for a reason nobody can see afterwards.
check() {
  local label="$1" expected="$2" work="$3"
  cases=$((cases + 1))
  classify "$work"
  local verdict="" expected_rc
  verdict="$(printf '%s\n' "$OUT" | sed -n 's/^CLASSIFY verdict=//p' | head -1)"
  case "$expected" in
    fastpath) expected_rc=0 ;;
    full) expected_rc=10 ;;
    *) echo "FAIL: the test asked for an unknown expectation '$expected'"; fails=$((fails + 1)); return ;;
  esac
  if [ "$RC" = "$expected_rc" ] && [ "$verdict" = "$expected" ]; then
    [ "$expected" != fastpath ] || fastpath_seen=1
    echo "ok   $label -> $expected"
  else
    fails=$((fails + 1))
    echo "FAIL $label: expected $expected (exit $expected_rc), got verdict='${verdict:-none}' exit=$RC"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi
}

# --- the cases ----------------------------------------------------------------------------------

# Documentation only, which is the whole point of the fast path.
w="$(new_repo docs-only)" || { echo "FAIL: cannot build the docs-only fixture"; exit 1; }
git -C "$w" checkout --quiet -b fix/docs
printf 'more guide\n' >> "$w/docs/guide.md"
printf 'more readme\n' >> "$w/README.md"
git -C "$w" commit --quiet -am "docs"
check "docs and a root markdown file" fastpath "$w"

# One Swift file in the same commit range is enough to owe a build.
w="$(new_repo docs-plus-swift)" || exit 1
git -C "$w" checkout --quiet -b fix/mixed
printf 'more guide\n' >> "$w/docs/guide.md"
printf 'let two = 2\n' >> "$w/Sources/App.swift"
git -C "$w" commit --quiet -am "docs and code"
check "docs plus one Swift file" full "$w"

# The version file is the release-number authority; it never fast-paths.
w="$(new_repo project-yml)" || exit 1
git -C "$w" checkout --quiet -b fix/bump
printf 'CURRENT_PROJECT_VERSION: "6"\n' >> "$w/project.yml"
git -C "$w" commit --quiet -am "bump"
check "project.yml alone" full "$w"

# A markdown NAME over a source file: the allowlist reads names, so the mode has to be read too.
w="$(new_repo md-symlink)" || exit 1
git -C "$w" checkout --quiet -b fix/symlink
ln -s Sources/App.swift "$w/NOTES.md"
git -C "$w" add -A
git -C "$w" commit --quiet -m "a link that reads as documentation"
check "a .md symlink pointing at source" full "$w"

# A rename out of a source file removes Swift from the tree; with renames turned off both names
# are in the change set, and the old one is not allowlisted.
w="$(new_repo rename-swift-to-md)" || exit 1
git -C "$w" checkout --quiet -b fix/rename
git -C "$w" mv Sources/Foo.swift Foo.md
git -C "$w" commit --quiet -m "rename a source file to markdown"
check "Foo.swift renamed to Foo.md" full "$w"

# The gate builds the WORKING TREE, not the commits: an unstaged source edit is in the build.
w="$(new_repo dirty-tree)" || exit 1
git -C "$w" checkout --quiet -b fix/dirty
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
printf 'let three = 3\n' >> "$w/Sources/App.swift"
check "a docs-only branch with an unstaged source edit" full "$w"

# Same, staged rather than unstaged.
w="$(new_repo dirty-tree-staged)" || exit 1
git -C "$w" checkout --quiet -b fix/staged
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs"
printf 'let four = 4\n' >> "$w/Packages/MemosCore/Sources/MemosCore/Core.swift"
git -C "$w" add -A
check "a docs-only branch with a staged source edit" full "$w"

# main is measured against nothing here; it is where the full gate belongs.
w="$(new_repo on-main)" || exit 1
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "docs on main"
check "the branch is main" full "$w"

# Nothing to skip is not something to skip: an empty change set gets the full gate.
w="$(new_repo empty-diff)" || exit 1
git -C "$w" checkout --quiet -b fix/empty
check "no change against origin/main" full "$w"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite: a run where every case came back `full` would pass a
# classifier that had simply stopped saying fastpath, which is not the thing under test.
if [ "$fastpath_seen" -ne 1 ]; then
  echo "FAIL: no case reached the fast path — the suite proves nothing about a classifier that never takes it"
  fails=$((fails + 1))
fi

echo "gate fastpath classifier: $((cases - fails)) of $cases cases as expected"
[ "$fails" -eq 0 ] || { echo "FASTPATH-TEST FAIL: $fails case(s) misclassified"; exit 1; }
echo "FASTPATH-TEST ok"
