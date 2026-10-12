#!/usr/bin/env bash
#
# The gate's release-notes rule, checked against trees this script builds for the purpose.
#
# `scripts/release-notes-rule.sh` holds the one notes file — the TestFlight "What to Test" text and
# the app's What's new screen alike — to the version and build project.yml declares: a version bump
# that forgot its notes would upload nothing (the cut refuses a missing section) and would open a
# What's new screen headed by an older build's words. A rule that cannot go red holds nothing, so
# the cases below are the ways it is supposed to bite — a section for another build, a heading that
# is only text inside a code fence, a heading that merely starts or ends the same, two sections for
# one build, a file with no sections at all — and the inputs it must refuse rather than judge.
#
# The last cases are the real repository itself, once alone and four times at once. Nothing here
# writes into that tree — every scratch tree lands in a temporary directory — and every temporary
# tree is removed on exit.
#
# Run it directly (`tests/gate/release-notes-rule-test.sh`) or let the gate run it: it is one of
# the selftests bin/mac-gate.sh names, so a run without it fails.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/release-notes-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-notes-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "${tmp:?}"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

NOTES="Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md"

# project.yml in the shape the rule reads: a comment naming the build key before its first real
# line (the real file has one), the pair on the app target, and the same pair further down.
project_yml() { # $1 version, $2 build
  cat <<YML
targets:
  MemosNG:
    settings:
      base:
        # CURRENT_PROJECT_VERSION from \$CI_BUILD_NUMBER, so that no hand edit is needed here.
        MARKETING_VERSION: "$1"
        CURRENT_PROJECT_VERSION: "$2"
  MemosNGShare:
    settings:
      base:
        MARKETING_VERSION: "$1"
        CURRENT_PROJECT_VERSION: "$2"
YML
}

notes_md() { # the notes, headed for 2.2.3 (45) with an older section below
  cat <<'MD'
# TestFlight notes

A preamble that is not a section.

## 2.2.3 (45)

- A footer on the account sheet opens What's new.

## 2.2.2 (44)

- Trips.
MD
}

new_tree() { # $1 name, $2 version, $3 build
  local work="$tmp/trees/$1"
  mkdir -p "$work/$(dirname "$NOTES")" || return 1
  project_yml "$2" "$3" > "$work/project.yml" || return 1
  notes_md > "$work/$NOTES" || return 1
  printf '%s' "$work"
}

# Replaces a scratch file with what a filter made of it, and refuses a filter that changed nothing:
# a mutant whose edit matched nothing would be the clean tree under another name.
rewrite() { # $1 file, then the filter command
  local file="$1" before after
  shift
  before="$(cksum < "$file")"
  "$@" < "$file" > "$file.new" || true
  mv "$file.new" "$file" || { echo "FAIL: cannot rewrite $file"; exit 1; }
  after="$(cksum < "$file")"
  [ "$before" != "$after" ] || { echo "FAIL: the rewrite '$*' changed nothing in $file"; exit 1; }
}

check() { # $1 label, $2 expected exit, $3 tree root, $4 (optional) a fragment the output must carry
  local label="$1" expected="$2" root="$3" needle="${4:-}" out rc
  cases=$((cases + 1))
  out="$("$RULE" "$root" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ] && { [ -z "$needle" ] || printf '%s\n' "$out" | grep -qF -- "$needle"; }; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    if [ "$first_fail" -eq 0 ]; then
      # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected${needle:+ naming '$needle'}, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# The matching version: project.yml's pair has its section.
w="$(new_tree matching 2.2.3 45)" || exit 1
check "a version whose section is there" 0 "$w" "## 2.2.3 (45)"

# THE case this rule exists for: the build moved and the notes did not.
w="$(new_tree not-matching 2.2.3 46)" || exit 1
check "a build with no section of its own" 1 "$w" "## 2.2.3 (46)"

# The marketing version moved alone.
w="$(new_tree version-moved 2.3.0 45)" || exit 1
check "a version with no section of its own" 1 "$w" "## 2.3.0 (45)"

# A heading that only STARTS or ENDS the same is another build's: 4 is not 45, 2.2 is not 2.2.3.
w="$(new_tree prefix-build 2.2.3 4)" || exit 1
check "a build that a heading only starts like" 1 "$w"
w="$(new_tree prefix-version 2.2 45)" || exit 1
check "a version that a heading only ends like" 1 "$w"
w="$(new_tree trailing-text 2.2.3 45)" || exit 1
rewrite "$w/$NOTES" sed 's/^## 2\.2\.3 (45)$/## 2.2.3 (45) and more/'
check "a heading with text after the build" 1 "$w"

# A heading inside a code fence is text: the cut would not find it, so neither does the rule.
w="$(new_tree fenced 2.4.0 50)" || exit 1
printf '\n```\n## 2.4.0 (50)\n```\n' >> "$w/$NOTES" || exit 1
check "a section heading written only inside a code fence" 1 "$w"
w="$(new_tree tilde-fenced 2.4.0 50)" || exit 1
printf '\n~~~ markdown\n## 2.4.0 (50)\n~~~\n' >> "$w/$NOTES" || exit 1
check "a section heading written only inside a tilde fence" 1 "$w"
# The control for the two above: after the fence closes, a heading counts again.
w="$(new_tree after-fence 2.4.0 50)" || exit 1
printf '\n```\n## 2.4.0 (50)\n```\n\n## 2.4.0 (50)\n\n- Real.\n' >> "$w/$NOTES" || exit 1
check "a section heading after a closed fence" 0 "$w"

# CommonMark: a fence closes only on its own character, at least as long as the run that opened
# it. Inside a four-backtick fence a three-backtick line is text, so the heading after it is too,
# and the heading after the real close counts.
long_fence() { printf '\n## 2.0 (2)\n````\n```\n## 9.9 (99)\n````\n## 1.0 (1)\n- One.\n'; }
w="$(new_tree long-fence-inside 9.9 99)" || exit 1
long_fence >> "$w/$NOTES" || exit 1
check "a heading after a shorter fence line, still inside the longer fence" 1 "$w"
w="$(new_tree long-fence-after 1.0 1)" || exit 1
long_fence >> "$w/$NOTES" || exit 1
check "a heading after the longer fence really closes" 0 "$w"
w="$(new_tree other-char-fence 9.9 99)" || exit 1
printf '\n## 2.0 (2)\n~~~\n```\n## 9.9 (99)\n~~~\n' >> "$w/$NOTES" || exit 1
check "a heading after a backtick line inside a tilde fence" 1 "$w"

# Two sections for one build: the cut refuses to choose, so the rule does too.
w="$(new_tree doubled 2.2.3 45)" || exit 1
printf '\n## 2.2.3 (45)\n\n- Again.\n' >> "$w/$NOTES" || exit 1
check "two sections for the same build" 1 "$w"

# The FIRST pair is read: a later, differing pair and a commented-out pair above the first change
# nothing.
w="$(new_tree first-pair 2.2.3 45)" || exit 1
printf 'more:\n  settings:\n    MARKETING_VERSION: "9.9.9"\n    CURRENT_PROJECT_VERSION: "99"\n' \
  >> "$w/project.yml" || exit 1
check "a later, differing pair is not the one read" 0 "$w" "## 2.2.3 (45)"
w="$(new_tree commented-pair 2.2.3 45)" || exit 1
{ printf '# MARKETING_VERSION: "9.9.9"\n#   CURRENT_PROJECT_VERSION: "99"\n'; cat "$w/project.yml"; } \
  > "$w/project.yml.new" && mv "$w/project.yml.new" "$w/project.yml" || exit 1
check "a commented-out pair above the first is not read" 0 "$w" "## 2.2.3 (45)"

# The positive control: a file with no section at all read nothing, whatever it says.
w="$(new_tree no-sections 2.2.3 45)" || exit 1
printf '# TestFlight notes\n\nNothing yet.\n' > "$w/$NOTES" || exit 1
check "a notes file with no section headings" 1 "$w" "read 0"
w="$(new_tree empty-notes 2.2.3 45)" || exit 1
: > "$w/$NOTES" || exit 1
check "an empty notes file" 1 "$w" "read 0"

# Inputs that cannot be judged are refused, never passed.
w="$(new_tree missing-notes 2.2.3 45)" || exit 1
rm -f "${w:?}/$NOTES" || exit 1
check "a tree without the notes file" 2 "$w"
w="$(new_tree missing-project 2.2.3 45)" || exit 1
rm -f "${w:?}/project.yml" || exit 1
check "a tree without project.yml" 2 "$w"
w="$(new_tree no-build-key 2.2.3 45)" || exit 1
rewrite "$w/project.yml" grep -v 'CURRENT_PROJECT_VERSION: "'
check "a project.yml that names no build" 2 "$w"
w="$(new_tree no-version-key 2.2.3 45)" || exit 1
rewrite "$w/project.yml" grep -v 'MARKETING_VERSION: "'
check "a project.yml that names no version" 2 "$w"
check "a root that is not a directory" 2 "$tmp/no-such-tree"

# And the repository this suite ships in, alone and four times at once: the rule only reads, so
# concurrent runs must all answer the same.
check "the real repository tree" 0 "$repo_root"
pids=()
for n in 1 2 3 4; do
  ( "$RULE" "$repo_root" > "$tmp/parallel-$n.out" 2>&1; echo $? > "$tmp/parallel-$n.rc" ) &
  pids+=($!)
done
wait "${pids[@]}"
for n in 1 2 3 4; do
  cases=$((cases + 1))
  if [ "$(cat "$tmp/parallel-$n.rc" 2>/dev/null)" = 0 ]; then
    echo "ok   the real repository tree, run $n of 4 at once -> exit 0"
  else
    fails=$((fails + 1))
    [ "$first_fail" -ne 0 ] || first_fail=1
    echo "FAIL the real repository tree, run $n of 4 at once: exit $(cat "$tmp/parallel-$n.rc" 2>/dev/null)"
    sed 's/^/     | /' "$tmp/parallel-$n.out"
  fi
done

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no tree was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no tree was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate release-notes rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || { echo "NOTES-TEST FAIL: $fails tree(s) misjudged"; exit "$first_fail"; }
echo "NOTES-TEST ok"
