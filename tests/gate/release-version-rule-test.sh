#!/usr/bin/env bash
# release-version-rule-test.sh — proves scripts/release-version-rule.sh, the gate's release-version
# authority, on throwaway git repositories this suite builds itself, each tagged the way a release
# is: `git tag -a v<version> -m "<name> <version> (TestFlight build <n>): ..."`.
#
# A tree whose project.yml is byte-identical to the tag's is ordinary work between a tag and the
# next cut, and passes with its own named line (MEMNG-878: the build number is assigned only at cut
# time, so main cannot be bumped ahead of it). A tree that changed project.yml is a release
# candidate and meets the strict checks unchanged. The identity is judged on the WORKING TREE file —
# the one the gate rsyncs — never on HEAD's.
#
# Never touches this checkout: every fixture lives in this run's own temporary directory, so a
# second run is harmless. The gate runs it in its catch-all selftest loop (bin/mac-gate.sh, step
# selftest).
#
# Exit: 0 = every case as expected; 1 otherwise.
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
rule="$repo_root/scripts/release-version-rule.sh"
gate="$repo_root/bin/mac-gate.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-relver-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "${tmp:?}"' EXIT
fails=0
passes=0
pass() { echo "PASS $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
check_eq() { # NAME WANT GOT
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}
[ -x "$rule" ] || { echo "FAIL rule/present: missing or not executable: $rule"; echo "RELEASE-VERSION-RULE-TEST FAIL"; exit 1; }

# The app's shape: both targets carry the pair, and a comment names the build key.
write_project() { # DIR VERSION BUILD
  cat > "$1/project.yml" <<YML
targets:
  MemosNG:
    settings:
      base:
        # CURRENT_PROJECT_VERSION from \$CI_BUILD_NUMBER, so that no hand edit is needed here.
        MARKETING_VERSION: "$2"
        CURRENT_PROJECT_VERSION: "$3"
  MemosShare:
    settings:
      base:
        MARKETING_VERSION: "$2"
        CURRENT_PROJECT_VERSION: "$3"
YML
}

# A repository at VERSION/BUILD, committed, and tagged v<VERSION> as build BUILD unless TAG is "-".
fixture() { # NAME VERSION BUILD [TAG]
  local r="$tmp/$1"
  mkdir -p "$r"
  git init -q "$r"
  git -C "$r" config user.name test
  git -C "$r" config user.email test@example.invalid
  git -C "$r" config commit.gpgsign false
  git -C "$r" config tag.gpgsign false
  write_project "$r" "$2" "$3"
  echo src > "$r/Source.swift"
  git -C "$r" add -A && git -C "$r" commit -q -m fixture
  if [ "${4:-}" != "-" ]; then
    git -C "$r" tag -a "v$2" -m "memos-ng-ios $2 (TestFlight build $3): a release; uploaded 2026-10-19."
  fi
  echo "$r"
}

run_rule() { # DIR → sets out, rc
  out="$("$rule" "$1" 2>&1)"
  rc=$?
}

# 1. project.yml unchanged since the tag, feature work committed on top: not a release candidate.
r="$(fixture unchanged 2.4.0 53)"
echo feature >> "$r/Source.swift"; git -C "$r" commit -q -am "feature work"
run_rule "$r"
check_eq unchanged/rc 0 "$rc"
check_eq unchanged/line "release     : 2.4.0 (build 53) unchanged since v2.4.0 — project.yml is byte-identical to the tag's, not a release candidate" "$out"

# 2. project.yml changed (a dependency line), build still the tagged one: today's refusal.
r="$(fixture changed-equal 2.4.0 53)"
printf 'packages:\n  Extra:\n    url: https://example.invalid/extra\n' >> "$r/project.yml"; git -C "$r" commit -q -am "add a package"
run_rule "$r"
check_eq changed-equal/rc 1 "$rc"
check_eq changed-equal/line "release check: build 53 does not advance past the shipped build 53 (v2.4.0)" "$out"

# 2b. project.yml changed and the build moved BACKWARDS: refused the same way.
r="$(fixture changed-below 2.4.0 53)"
write_project "$r" 2.4.0 52; git -C "$r" commit -q -am "build backwards"
run_rule "$r"
check_eq changed-below/rc 1 "$rc"
check_eq changed-below/line "release check: build 52 does not advance past the shipped build 53 (v2.4.0)" "$out"

# 2c. project.yml changed and the marketing version is below the tag's: refused, version first.
r="$(fixture changed-version-below 2.4.0 53)"
write_project "$r" 2.3.9 54; git -C "$r" commit -q -am "version backwards"
run_rule "$r"
check_eq changed-version-below/rc 1 "$rc"
check_eq changed-version-below/line "release check: MARKETING_VERSION 2.3.9 is below the shipped tag v2.4.0" "$out"

# 3. project.yml changed and the build is greater: a release candidate that advances, passes.
r="$(fixture changed-greater 2.4.0 53)"
write_project "$r" 2.4.0 54; git -C "$r" commit -q -am "bump build to 54"
run_rule "$r"
check_eq changed-greater/rc 0 "$rc"
check_eq changed-greater/line "release     : 2.4.0 (build 54) advances past v2.4.0 (build 53)" "$out"

# 4. No v* tag at all: the bootstrap line, as before.
r="$(fixture no-tag 2.4.0 53 -)"
run_rule "$r"
check_eq no-tag/rc 0 "$rc"
check_eq no-tag/line "release     : no v* tag yet — bootstrap, nothing to advance past" "$out"

# 5. The WORKING TREE is what is judged: HEAD's project.yml is the tag's, but an uncommitted edit
#    (the tree the gate rsyncs) changed it — a candidate, so the strict check refuses build 53.
r="$(fixture dirty-tree 2.4.0 53)"
echo "# uncommitted" >> "$r/project.yml"
run_rule "$r"
check_eq dirty-tree/rc 1 "$rc"
check_eq dirty-tree/line "release check: build 53 does not advance past the shipped build 53 (v2.4.0)" "$out"

# 5b. And the converse: HEAD changed project.yml, the working tree put it back byte for byte.
r="$(fixture restored-tree 2.4.0 53)"
cp "$r/project.yml" "$tmp/restored.yml"
echo "# committed" >> "$r/project.yml"; git -C "$r" commit -q -am "comment"
cp "$tmp/restored.yml" "$r/project.yml"
run_rule "$r"
check_eq restored-tree/rc 0 "$rc"
check_eq restored-tree/unchanged-line 1 "$(printf '%s\n' "$out" | grep -c 'unchanged since v2.4.0')"

# 6. Byte-identical means bytes: a lone trailing newline is a change (a $(...) comparison would
#    strip it and call the trees equal).
r="$(fixture trailing-newline 2.4.0 53)"
echo >> "$r/project.yml"
run_rule "$r"
check_eq trailing-newline/rc 1 "$rc"

# 7. The tag's tree has no project.yml (git show fails): never read as "unchanged".
r="$tmp/no-yml-at-tag"
mkdir -p "$r"; git init -q "$r"
git -C "$r" config user.name test; git -C "$r" config user.email test@example.invalid
git -C "$r" config commit.gpgsign false; git -C "$r" config tag.gpgsign false
echo src > "$r/Source.swift"; git -C "$r" add -A; git -C "$r" commit -q -m first
git -C "$r" tag -a v2.4.0 -m "memos-ng-ios 2.4.0 (TestFlight build 53): before project.yml."
write_project "$r" 2.4.0 53; git -C "$r" add -A; git -C "$r" commit -q -m "add project.yml"
run_rule "$r"
check_eq no-yml-at-tag/rc 1 "$rc"

# 8. The gate runs THIS script from its private copy and refuses on its verdict.
check_eq static/gate-helper 1 "$(grep -c '^GATE_RUN_HELPERS=.*release-version-rule\.sh' "$gate")"
check_eq static/gate-calls 1 "$(grep -c '"\$GATE_RUN_COPY/scripts/release-version-rule\.sh" "\$repo_root"' "$gate")"
check_eq static/parses 0 "$(bash -n "$rule" > /dev/null 2>&1; echo "$?")"

echo "release-version-rule-test: $passes passed, $fails failed"
[ "$fails" -eq 0 ] || { echo "RELEASE-VERSION-RULE-TEST FAIL"; exit 1; }
echo "RELEASE-VERSION-RULE-TEST ok"
