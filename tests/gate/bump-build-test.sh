#!/usr/bin/env bash
# bump-build-test.sh — proves bin/bump-build.sh on throwaway git repositories this suite builds
# itself: every refusal leaves project.yml, ReleaseNotes.md and the history exactly as they were;
# a good run sets BOTH build key lines (a comment naming the key is not one), leaves every
# MARKETING_VERSION line byte-identical, inserts the section the release-notes rule asks for and
# commits it; the 4000-character ceiling is the cut's loader's, counted as it counts.
#
# The rule itself is the control: scripts/release-notes-rule.sh passes the bumped tree and fails it
# again once the inserted section is taken out.
#
# Never touches this checkout: the script and the rule are copied into each fixture, every fixture
# lives in this run's own temporary directory, so a second run (the gate's catch-all loop) is
# harmless. It is one of the gate's NAMED selftests (bin/mac-gate.sh, step selftest).
#
# Exit: 0 = every case as expected; 1 otherwise.
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
bump="$repo_root/bin/bump-build.sh"
rule="$repo_root/scripts/release-notes-rule.sh"
NOTES=Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-bump-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "${tmp:?}"' EXIT
fails=0
passes=0
pass() { echo "PASS $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
check_eq() { # NAME WANT GOT
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}
[ -f "$bump" ] || fail bump/present "missing $bump"

# The app's shape: a comment that names the build key at the start of its text, a commented-out
# key line, and the share extension's pair as the second key site.
write_project() { # DIR BUILD [SECOND_BUILD]
  cat > "$1/project.yml" <<YML
targets:
  MemosNG:
    settings:
      base:
        # CURRENT_PROJECT_VERSION from \$CI_BUILD_NUMBER, so that no hand edit is needed here.
        # CURRENT_PROJECT_VERSION: "1"
        MARKETING_VERSION: "2.4.0"
        CURRENT_PROJECT_VERSION: "$2"
  MemosShare:
    settings:
      base:
        MARKETING_VERSION: "2.4.0"
        CURRENT_PROJECT_VERSION: "${3:-$2}"
YML
}
write_notes() { # DIR
  mkdir -p "$1/$(dirname "$NOTES")"
  cat > "$1/$NOTES" <<'MD'
# TestFlight notes

The intro paragraph, which stays above every section.

## 2.4.0 (49)

- An older build's line.
MD
}
# mkrepo NAME [BUILD [SECOND_BUILD]]: a committed fixture on a work branch; its path in $r.
mkrepo() {
  r="$tmp/$1"
  mkdir -p "$r/bin" "$r/scripts"
  [ -f "$bump" ] && cp "$bump" "$r/bin/bump-build.sh"
  cp "$rule" "$r/scripts/release-notes-rule.sh"
  write_project "$r" "${2:-49}" "${3:-}"
  write_notes "$r"
  git init -q "$r"
  git -C "$r" config user.name test
  git -C "$r" config user.email test@example.invalid
  git -C "$r" checkout -q -b fix/build-50-version
  git -C "$r" add -A && git -C "$r" commit -q -m fixture
}
body() { # NAME TEXT — a notes file outside every fixture; its path in $nf
  nf="$tmp/notes-$1.txt"
  printf '%s' "$2" > "$nf"
}
# run_bump [args…]: from the fixture $r; output in $tmp/out, exit in $rc
run_bump() {
  (cd "$r" && bash bin/bump-build.sh "$@") > "$tmp/out" 2>&1
  rc=$?
}
state() { # what a refusal must leave untouched: both files, HEAD, the status
  printf '%s %s %s [%s]' "$(sha256sum < "$r/project.yml" | cut -c1-16)" "$(sha256sum < "$r/$NOTES" | cut -c1-16)" \
    "$(git -C "$r" rev-parse HEAD)" "$(git -C "$r" status --porcelain | paste -sd ',' -)"
}
refused() { # NAME TOKEN BEFORE — exit 2, the token named, nothing written
  check_eq "$1/exit" 2 "$rc"
  check_eq "$1/token" 1 "$(grep -c "^bump-build: REFUSED($2): " "$tmp/out")"
  check_eq "$1/nothing-written" "$3" "$(state)"
}
key_lines() { # the anchored reading of the build key, as release-notes-rule.sh reads it
  sed -n -E 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]#]+)"?[[:space:]]*(#.*)?$/\1/p' "$1"
}
GOOD='- A memo with pictures is created right away; the user sees it in the house timeline.
- Please create a memo with two pictures and check that it shows at once.
'
body good "$GOOD"

# --- refusals ---
mkrepo plain
before="$(state)"
run_bump --build 50; refused no-notes-arg usage "$before"
run_bump --notes-file "$nf"; refused no-build-arg usage "$before"
run_bump --build 50 --notes-file "$nf" --bogus; refused unknown-arg usage "$before"
run_bump --build abc --notes-file "$nf"; refused build-text bad-build "$before"
run_bump --build "" --notes-file "$nf"; refused build-empty bad-build "$before"
run_bump --build 050 --notes-file "$nf"; refused build-leading-zero bad-build "$before"
run_bump --build -5 --notes-file "$nf"; refused build-negative bad-build "$before"
run_bump --build 49 --notes-file "$nf"; refused build-equal build-not-greater "$before"
run_bump --build 48 --notes-file "$nf"; refused build-lower build-not-greater "$before"
run_bump --build 50 --notes-file "$tmp/no-such-notes.txt"; refused notes-missing notes-missing "$before"
run_bump --build 50 --notes-file "$tmp"; refused notes-directory notes-missing "$before"
body empty ''; run_bump --build 50 --notes-file "$nf"; refused notes-empty notes-empty "$before"
body blank $'  \n\t\n\n'; run_bump --build 50 --notes-file "$nf"; refused notes-blank notes-empty "$before"
body key $'- The memo is created at once (MEMNG-831).\n'; run_bump --build 50 --notes-file "$nf"
refused tracker-key tracker-key "$before"
for word in we We US our; do
  body "voice-$word" "- Now $word fixed the upload."$'\n'; run_bump --build 50 --notes-file "$nf"
  refused "voice-$word" voice "$before"
done
# a heading inside the body ends the section the loader sends: one after content is refused as
# such, one that opens it would leave the section empty, which the re-read refuses first
body heading-after $'- a\n## x\n- b\n'; run_bump --build 50 --notes-file "$nf"; refused body-heading-after body-heading "$before"
body heading-one $'- a\n# x\n'; run_bump --build 50 --notes-file "$nf"; refused body-heading-level-1 body-heading "$before"
body heading-bare $'- a\n##\n'; run_bump --build 50 --notes-file "$nf"; refused body-heading-bare body-heading "$before"
body heading-open $'## x\n- b\n'; run_bump --build 50 --notes-file "$nf"; refused body-opens-with-heading empty-section "$before"
body unclosed $'- a\n```\n- b\n'; run_bump --build 50 --notes-file "$nf"; refused body-unclosed-fence unclosed-fence "$before"
# the loader's ceiling: 4001 characters of section text, multi-byte characters counted once
body over "$(printf 'x%.0s' $(seq 1 4001))"$'\n'; run_bump --build 50 --notes-file "$nf"; refused over-4000 too-long "$before"
body over-utf8 "$(printf '\303\251%.0s' $(seq 1 4001))"$'\n'; run_bump --build 50 --notes-file "$nf"; refused over-4000-utf8 too-long "$before"
# U+2028 is one character inside a line for the loader (Ruby's each_line splits on "\n" only)
body over-u2028 "$(printf 'x%.0s' $(seq 1 2000))"$'\342\200\250'"$(printf 'x%.0s' $(seq 1 2000))"$'\n'
run_bump --build 50 --notes-file "$nf"; refused over-4000-u2028 too-long "$before"
printf '\377\376 not UTF-8\n' > "$tmp/notes-latin.txt"; run_bump --build 50 --notes-file "$tmp/notes-latin.txt"
refused notes-not-utf8 notes-check "$before"
body good "$GOOD"
git -C "$r" checkout -q -b main; run_bump --build 50 --notes-file "$nf"; refused on-main on-main "$before"
git -C "$r" checkout -q fix/build-50-version; git -C "$r" branch -q -D main
git -C "$r" checkout -q --detach HEAD; run_bump --build 50 --notes-file "$nf"; refused detached detached "$before"
git -C "$r" checkout -q fix/build-50-version
printf 'stray\n' > "$r/stray.txt"; run_bump --build 50 --notes-file "$nf"
check_eq dirty-untracked/exit 2 "$rc"
check_eq dirty-untracked/stray-survived stray "$(cat "$r/stray.txt")"
check_eq dirty-untracked/token 1 "$(grep -c '^bump-build: REFUSED(dirty): ' "$tmp/out")"
rm -f "$r/stray.txt"
printf '\n' >> "$r/$NOTES"; dirty_sum="$(sha256sum < "$r/$NOTES")"; run_bump --build 50 --notes-file "$nf"
check_eq dirty-tracked/exit 2 "$rc"
check_eq dirty-tracked/edit-survived "$dirty_sum" "$(sha256sum < "$r/$NOTES")"
check_eq dirty-tracked/token 1 "$(grep -c '^bump-build: REFUSED(dirty): ' "$tmp/out")"
git -C "$r" checkout -q -- "$NOTES"
check_eq refusals/tree-as-built "$before" "$(state)"
# the key sites disagree: no number to bump from
mkrepo split 49 48
before="$(state)"
run_bump --build 50 --notes-file "$nf"; refused keys-disagree bad-project "$before"
# a section for the new pair already in the file: the re-read finds two and refuses
mkrepo dup
printf '\n## 2.4.0 (50)\n\n- A stale section.\n' >> "$r/$NOTES"; git -C "$r" commit -q -am stale
before="$(state)"
run_bump --build 50 --notes-file "$nf"; refused duplicate duplicate-section "$before"
# a notes file with no section to insert above
mkrepo noanchor
printf '# TestFlight notes\n\nOnly an intro.\n' > "$r/$NOTES"; git -C "$r" commit -q -am intro
before="$(state)"
run_bump --build 50 --notes-file "$nf"; refused no-anchor no-section-anchor "$before"
# a third target carrying the pair (the Live Activity's extension): every key line moves together
third_target() { # BUILD — appended to $r/project.yml and committed
  printf '  MemosActivity:\n    settings:\n      base:\n        MARKETING_VERSION: "2.4.0"\n        CURRENT_PROJECT_VERSION: "%s"\n' "$1" >> "$r/project.yml"
  git -C "$r" commit -q -am third
}
mkrepo three
third_target 49
run_bump --build 50 --notes-file "$nf"
check_eq three/exit 0 "$rc"
check_eq three/every-key-line "50 50 50" "$(key_lines "$r/project.yml" | paste -sd ' ' -)"
# the third site disagreeing is the same refusal as two disagreeing
mkrepo three-split
third_target 48
before="$(state)"
run_bump --build 50 --notes-file "$nf"; refused three-disagree bad-project "$before"
# one key line is no app-and-extension pair at all
mkrepo one
sed -i '/MemosShare:/,$d' "$r/project.yml"; git -C "$r" commit -q -am one
before="$(state)"
run_bump --build 50 --notes-file "$nf"; refused one-key-line bad-project "$before"

# --- a good run ---
mkrepo good
mv_before="$(grep -n 'MARKETING_VERSION' "$r/project.yml")"
head_before="$(git -C "$r" rev-parse HEAD)"
run_bump --build 50 --notes-file "$nf"
check_eq good/exit 0 "$rc"
check_eq good/answer 1 "$(grep -cE "^BUMPED version=2\.4\.0 build=50 commit=[0-9a-f]{40}\$" "$tmp/out")"
check_eq good/both-key-lines "50 50" "$(key_lines "$r/project.yml" | paste -sd ' ' -)"
check_eq good/key-lines-exactly-two 2 "$(key_lines "$r/project.yml" | grep -c .)"
check_eq good/comment-untouched 1 "$(grep -cxF '        # CURRENT_PROJECT_VERSION from $CI_BUILD_NUMBER, so that no hand edit is needed here.' "$r/project.yml")"
check_eq good/commented-key-untouched 1 "$(grep -cxF '        # CURRENT_PROJECT_VERSION: "1"' "$r/project.yml")"
check_eq good/marketing-version-identical "$mv_before" "$(grep -n 'MARKETING_VERSION' "$r/project.yml")"
check_eq good/diff-names-no-marketing-version 0 "$(git -C "$r" diff -U0 "$head_before" HEAD | grep -c '^[-+].*MARKETING_VERSION')"
check_eq good/project-diff-two-lines "2 2" "$(git -C "$r" diff --numstat "$head_before" HEAD -- project.yml | cut -f1,2 | tr '\t' ' ')"
check_eq good/one-commit 1 "$(git -C "$r" rev-list --count "$head_before..HEAD")"
check_eq good/commit-files "$NOTES|project.yml" "$(git -C "$r" diff --name-only "$head_before" HEAD | sort | paste -sd '|' -)"
check_eq good/commit-names-pair 1 "$(git -C "$r" log -1 --format=%s | grep -cF '2.4.0 (50)')"
check_eq good/tree-clean "" "$(git -C "$r" status --porcelain)"
check_eq good/branch-kept fix/build-50-version "$(git -C "$r" symbolic-ref --short HEAD)"
check_eq good/section-under-intro "## 2.4.0 (50)||- A memo with pictures is created right away; the user sees it in the house timeline." \
  "$(sed -n '5,7p' "$r/$NOTES" | paste -sd '|' -)"
check_eq good/older-section-kept 1 "$(grep -cx '## 2.4.0 (49)' "$r/$NOTES")"
check_eq good/intro-kept "# TestFlight notes||The intro paragraph, which stays above every section.|" "$(sed -n '1,4p' "$r/$NOTES" | paste -sd '|' -)"
(cd "$r" && bash scripts/release-notes-rule.sh .) > "$tmp/rule.out" 2>&1
check_eq good/notes-rule-passes 0 "$?"
# the retry: the same number again is a refusal, never a second section
before="$(state)"
run_bump --build 50 --notes-file "$nf"; refused retry-same-number build-not-greater "$before"
check_eq retry/one-section 1 "$(grep -cx '## 2.4.0 (50)' "$r/$NOTES")"
# mutation control: without the inserted section the rule fails the tree
awk 'BEGIN{skip=0} /^## 2\.4\.0 \(50\)$/{skip=1; next} /^## /{skip=0} !skip' "$r/$NOTES" > "$tmp/cut.md" && cp "$tmp/cut.md" "$r/$NOTES"
check_eq mutant/section-gone 0 "$(grep -c '## 2.4.0 (50)' "$r/$NOTES")"
(cd "$r" && bash scripts/release-notes-rule.sh .) > "$tmp/rule.out" 2>&1
check_eq mutant/notes-rule-fails 1 "$?"

# --- the ceiling exactly: 4000 characters pass, in ASCII and in two-byte characters ---
mkrepo at4000
body at4000 "$(printf 'x%.0s' $(seq 1 4000))"$'\n\n'
run_bump --build 50 --notes-file "$nf"
check_eq at-4000/exit 0 "$rc"
mkrepo at4000utf8
body at4000utf8 "$(printf '\303\251%.0s' $(seq 1 4000))"$'\n'
run_bump --build 50 --notes-file "$nf"
check_eq at-4000-utf8/exit 0 "$rc"
(cd "$r" && bash scripts/release-notes-rule.sh .) > "$tmp/rule.out" 2>&1
check_eq at-4000-utf8/notes-rule-passes 0 "$?"
mkrepo at4000u2028
body at4000u2028 "$(printf 'x%.0s' $(seq 1 2000))"$'\342\200\250'"$(printf 'x%.0s' $(seq 1 1999))"$'\n'
run_bump --build 50 --notes-file "$nf"
check_eq at-4000-u2028/exit 0 "$rc"
check_eq at-4000-u2028/one-body-line 1 "$(grep -c "$(printf '\342\200\250')" "$r/$NOTES")"
# Ruby's \s is ASCII: "#" before a no-break space starts no heading for the loader, so it is text
mkrepo nbsp
body nbsp $'- a\n#\302\240not a heading\n'
run_bump --build 50 --notes-file "$nf"
check_eq nbsp-hash-not-heading/exit 0 "$rc"
# a heading inside a fenced block is text, so it neither ends the section nor refuses
mkrepo fenced
body fenced $'- a\n```\n## not a heading\n```\n- b\n'
run_bump --build 51 --notes-file "$nf"
check_eq fenced-heading/exit 0 "$rc"
check_eq fenced-heading/both-key-lines "51 51" "$(key_lines "$r/project.yml" | paste -sd ' ' -)"

# --- the tracked files themselves: the app's project.yml and notes, bumped by one ---
# No case may depend on which builds the LIVE notes already head (a branch can carry a section
# prepared by hand for a later build). So the live notes are normalised first: every section whose
# build is above the project's is taken out, and each expected number is derived from that fixture.
live_build="$(key_lines "$repo_root/project.yml" | head -n 1)"
live_version="$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]#]+)"?.*$/\1/p' "$repo_root/project.yml" | head -n 1)"
normalise_notes() { # BUILD SOURCE — the notes without any section for a build above BUILD
  awk -v max="$1" '
    /^## / {
      skip = 0
      if (match($0, /\([0-9]+\)[ \t\r]*$/)) {
        n = substr($0, RSTART + 1, RLENGTH - 1); sub(/\).*/, "", n)
        if (n + 0 > max + 0) skip = 1
      }
    }
    !skip' "$2"
}
normalise_notes "$live_build" "$repo_root/$NOTES" > "$tmp/notes-normal.md"
highest_heading() { sed -n -E 's/^## [^ ]+ \(([0-9]+)\)[[:space:]]*$/\1/p' "$1" | sort -n | tail -n 1; }
check_eq normalised/no-heading-above-build 1 \
  "$(h="$(highest_heading "$tmp/notes-normal.md")"; [ -n "$h" ] && [ "$h" -le "$live_build" ] && echo 1 || echo 0)"
real_case() { # NAME NOTES-SOURCE BUILD — the live project.yml with these notes, bumped to BUILD
  local name="$1" n="$3" key_mentions mv_before
  mkrepo "$name"
  cp "$repo_root/project.yml" "$r/project.yml"
  cp "$2" "$r/$NOTES"
  git -C "$r" commit -q -am "$name"
  key_mentions="$(grep -c 'CURRENT_PROJECT_VERSION' "$r/project.yml")"
  mv_before="$(grep -n 'MARKETING_VERSION' "$r/project.yml")"
  body good "$GOOD"
  run_bump --build "$n" --notes-file "$nf"
  check_eq "$name/exit" 0 "$rc"
  # Every key line the live tree has (the app and each extension carrying the pair) reads n.
  check_eq "$name/every-key-line" "$(key_lines "$repo_root/project.yml" | sed "s/.*/$n/" | paste -sd ' ' -)" \
    "$(key_lines "$r/project.yml" | paste -sd ' ' -)"
  check_eq "$name/live-tree-has-pairs" 1 "$([ "$(key_lines "$repo_root/project.yml" | grep -c .)" -ge 2 ] && echo 1 || echo 0)"
  check_eq "$name/key-mentions-unchanged" "$key_mentions" "$(grep -c 'CURRENT_PROJECT_VERSION' "$r/project.yml")"
  check_eq "$name/marketing-version-identical" "$mv_before" "$(grep -n 'MARKETING_VERSION' "$r/project.yml")"
  check_eq "$name/diff-names-no-marketing-version" 0 "$(git -C "$r" diff -U0 HEAD~1 HEAD | grep -c '^[-+].*MARKETING_VERSION')"
  (cd "$r" && bash scripts/release-notes-rule.sh .) > "$tmp/rule.out" 2>&1
  check_eq "$name/notes-rule-passes" 0 "$?"
}
real_case real "$tmp/notes-normal.md" "$((live_build + 1))"
# the normalised notes with a section prepared by hand for build + 1 above the newest one: that
# number is refused as a duplicate, and the next one is taken with the prepared section kept
prepared="## $live_version ($((live_build + 1)))"
awk -v h="$prepared" '!done && /^## /{print h; print ""; print "- A section prepared by hand."; print ""; done=1} {print}' \
  "$tmp/notes-normal.md" > "$tmp/notes-prepared.md"
check_eq real-prepared/fixture-has-section 1 "$(grep -cxF "$prepared" "$tmp/notes-prepared.md")"
mkrepo real-prepared-dup
cp "$repo_root/project.yml" "$r/project.yml"
cp "$tmp/notes-prepared.md" "$r/$NOTES"
git -C "$r" commit -q -am real-prepared-dup
before="$(state)"
body good "$GOOD"
run_bump --build "$((live_build + 1))" --notes-file "$nf"; refused real-prepared-dup duplicate-section "$before"
real_case real-prepared "$tmp/notes-prepared.md" "$((live_build + 2))"
check_eq real-prepared/prepared-section-kept 1 "$(grep -cxF "$prepared" "$r/$NOTES")"

# --- the script spells the tracker's key in its refusal pattern and nowhere else ---
if [ -f "$bump" ]; then
  check_eq static/key-only-in-refusal 1 "$(grep -cE 'MEMNG|ticket' "$bump")"
  check_eq static/key-is-the-pattern 1 "$(grep -E 'MEMNG|ticket' "$bump" | grep -cF 'MEMNG-[0-9]+')"
  check_eq static/no-xtrace 0 "$(grep -cE 'set -[a-z]*x|bash -x|SHELLOPTS|BASH_XTRACEFD' "$bump")"
  check_eq static/parses 0 "$(bash -n "$bump" > /dev/null 2>&1; echo "$?")"
fi

echo "bump-build-test: $passes passed, $fails failed"
[ "$fails" -eq 0 ] || { echo "BUMP-BUILD-TEST FAIL"; exit 1; }
echo "BUMP-BUILD-TEST ok"
