#!/usr/bin/env bash
#
# Where the build scratch of a gate lane lives, checked against layouts this script builds.
#
# The work tree is the `work/` sibling of the gate root the preflight RESOLVED — the same root the
# refusal check compares the target against — so nothing about the physical path is assumed. It
# used to be a substring rewrite (`/build/memos-ng-ios/gate/` -> `.../work/`) of the physical gate
# path, which is a different claim: it holds only while ~/build/memos-ng-ios resolves under a path
# still spelling that out. Case (2) is where that breaks — a gate root symlinked into a directory
# whose physical path contains no `/build/memos-ng-ios/` at all, the answer to a full build disk
# (MEMNG-160). Case (1) is today's layout, which must derive exactly what it derived before.
#
# Case (3) is the other half of the sibling rule: the reaper compares physical paths and REFUSES a
# root that is a symlink, so a work tree already moved onto another volume — the ordinary way this
# host has bought space — has to reach it resolved, exactly as the code this replaced resolved it.
# The refusal is exercised in the same run, so a passing case cannot be one that could not fail.
#
# The last cases read bin/mac-gate.sh itself: an extracted derivation nothing calls would pass
# every case here and change nothing on the build host, so the remote half must be shown to
# receive the resolved root and to ask these functions for the answer.
#
# Nothing here depends on how the temporary directory is spelled: the relocated fixture is built
# under a base whose physical path is checked for that substring first, and a run that cannot find
# one says so by name instead of failing the derivation.
#
# Run it directly (`tests/gate/gate-work-dir-test.sh`) or let the gate run it: it is picked up by
# the controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case answered as expected; 1 = at least one did not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="$repo_root/bin/mac-gate.sh"
DERIVATION="$repo_root/scripts/gate-work-dir.sh"
REAPER="$repo_root/scripts/reap-gate-lanes.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-work-dir-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
# macOS temp paths traverse /var, and every path this test compares is a physical one.
tmp="$(cd "$tmp" && pwd -P)" || exit 1
moved_tmp=""
cleanup() {
  rm -rf "$tmp"
  [ -z "$moved_tmp" ] || rm -rf "$moved_tmp"
}
trap cleanup EXIT

# With no extracted derivation, exercise the old behaviour: the substring rewrite the gate carried
# inline, so this suite fails on the tree it was written against instead of passing vacuously.
if [ -f "$DERIVATION" ]; then
  . "$DERIVATION"
else
  gate_work_dir() {
    local target="$1/$2" work
    work="$(printf '%s' "$target" | sed 's#/build/memos-ng-ios/gate/#/build/memos-ng-ios/work/#')"
    [ "$work" != "$target" ] || return 2
    printf '%s\n' "$work"
  }
  gate_work_root() { echo "gate_work_root: no derivation is installed" >&2; return 2; }
fi
# And with a derivation that hands the reaper an unresolved sibling, exercise that: it is what the
# first cut of this change did, and case (3) is the reason it could not stand.
if ! command -v gate_work_root_resolved >/dev/null 2>&1; then
  gate_work_root_resolved() { gate_work_root "${1:-}"; }
fi

fails=0
cases=0
refusal_seen=0

fail() { # $1 message
  echo "FAIL $1"
  fails=$((fails + 1))
}

expect_eq() { # $1 label, $2 expected, $3 actual
  cases=$((cases + 1))
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    fail "$1: got ${3:-none}, expected $2"
  fi
}

check() { # $1 label, $2 gate root, $3 branch, $4 expected exit, $5 expected work dir ('' when refused)
  local label="$1" root="$2" branch="$3" expect_rc="$4" expect="$5" out rc
  cases=$((cases + 1))
  out="$(gate_work_dir "$root" "$branch" 2>&1)"
  rc=$?
  if [ "$rc" != "$expect_rc" ]; then
    fail "$label: exit $rc, expected $expect_rc (output: ${out:-none})"
    return
  fi
  if [ "$expect_rc" != 0 ]; then
    refusal_seen=1
    echo "ok   $label -> refused with exit $rc"
    return
  fi
  if [ "$out" != "$expect" ]; then
    fail "$label: derived ${out:-none}, expected $expect"
    return
  fi
  echo "ok   $label -> $out"
}

# (1) Today's layout: a real ~/build/memos-ng-ios/gate. The answer must not move.
home="$tmp/home"
mkdir -p "$home/build/memos-ng-ios/gate" "$home/build/memos-ng-ios/work" || exit 1
today="$(cd "$home/build/memos-ng-ios/gate" && pwd -P)" || exit 1
check "the current layout keeps its work tree" \
  "$today" fix/lane 0 "$home/build/memos-ng-ios/work/fix/lane"
check "a branch with several slashes keeps every segment" \
  "$today" fix/deep/lane 0 "$home/build/memos-ng-ios/work/fix/deep/lane"

# (2) The ticket: ~/build/memos-ng-ios moved onto another volume, and the physical path of the
# gate root no longer contains /build/memos-ng-ios/ anywhere. The fixture is built under the first
# base whose OWN physical path is free of it, because the temp directory this suite runs in may
# itself be spelled that way and that would say nothing about the derivation.
clean_base=""
tried=""
for candidate in "$tmp" "${TMPDIR:-}" /tmp "${HOME:-}"; do
  [ -n "$candidate" ] || continue
  tried="$tried $candidate"
  [ -d "$candidate" ] && [ -w "$candidate" ] || continue
  candidate_physical="$(cd "$candidate" 2>/dev/null && pwd -P)" || continue
  case "$candidate_physical/" in */build/memos-ng-ios/*) continue ;; esac
  clean_base="$candidate_physical"
  break
done
cases=$((cases + 1))
if [ -z "$clean_base" ]; then
  fail "fixture: no writable base free of /build/memos-ng-ios/ in its physical path (tried:$tried)"
else
  moved_tmp="$(mktemp -d "$clean_base/gate-work-dir-moved-XXXXXX")" || exit 1
  moved_tmp="$(cd "$moved_tmp" && pwd -P)" || exit 1
  mkdir -p "$moved_tmp/volume/ios-lanes/gate" "$moved_tmp/moved-home/build" || exit 1
  ln -s "$moved_tmp/volume/ios-lanes" "$moved_tmp/moved-home/build/memos-ng-ios" || exit 1
  moved="$(cd "$moved_tmp/moved-home/build/memos-ng-ios/gate" && pwd -P)" || exit 1
  case "$moved/" in
    */build/memos-ng-ios/*)
      fail "fixture: $moved still spells out the old substring" ;;
    *)
      echo "ok   fixture: the resolved gate root is $moved"
      check "a gate root resolved outside /build/memos-ng-ios/ still finds its work tree" \
        "$moved" fix/lane 0 "$moved_tmp/volume/ios-lanes/work/fix/lane" ;;
  esac
fi

# (3) A work tree already moved off this disk: ~/build/memos-ng-ios/work is a symlink. The build
# half walks through it, but the reaper compares physical paths and refuses a symlinked root, so
# what the preflight hands it must be resolved.
sym_home="$tmp/symlinked-work"
mkdir -p "$sym_home/build/memos-ng-ios/gate" "$tmp/scratch-volume/ios-work" || exit 1
ln -s "$tmp/scratch-volume/ios-work" "$sym_home/build/memos-ng-ios/work" || exit 1
sym_gate="$(cd "$sym_home/build/memos-ng-ios/gate" && pwd -P)" || exit 1
sym_link="$sym_home/build/memos-ng-ios/work"
sym_physical="$tmp/scratch-volume/ios-work"
expect_eq "the sibling of a symlinked work root is the link itself" \
  "$sym_link" "$(gate_work_root "$sym_gate" 2>&1)"
sym_resolved="$(gate_work_root_resolved "$sym_gate" 2>&1)"
expect_eq "an existing symlinked work root reaches the reaper resolved" \
  "$sym_physical" "$sym_resolved"
cases=$((cases + 1))
if [ -L "$sym_resolved" ]; then
  fail "the resolved work root is still a symlink: $sym_resolved"
else
  echo "ok   the resolved work root is not a symlink"
fi
# A first-ever run has no work tree yet, and must still be told where to make one.
absent_gate="$tmp/absent-home/build/memos-ng-ios/gate"
mkdir -p "$absent_gate" || exit 1
expect_eq "a work root that does not exist yet is still named" \
  "$tmp/absent-home/build/memos-ng-ios/work" \
  "$(gate_work_root_resolved "$(cd "$absent_gate" && pwd -P)" 2>&1)"

# The reaper itself, on the same fixture: the refusal is real, and the resolved root clears it.
cases=$((cases + 1))
if [ ! -f "$REAPER" ]; then
  fail "$REAPER is missing; the reaper cases below cannot run"
else
  echo "ok   the reaper is present"
  . "$REAPER"
  printf 'main\n' > "$tmp/survivors" || exit 1
  reap_gate_lanes "$sym_gate" "$sym_link" fix/current "$tmp/survivors" > "$tmp/reap-link.log" 2>&1
  expect_eq "control: the reaper refuses a symlinked work root" 2 "$?"
  reap_gate_lanes "$sym_gate" "$sym_resolved" fix/current "$tmp/survivors" > "$tmp/reap-phys.log" 2>&1
  expect_eq "the reaper accepts the resolved work root" 0 "$?"
fi

# (4) Inputs that cannot name a work tree are refused rather than guessed at.
check "a relative gate root is refused" "build/memos-ng-ios/gate" fix/lane 2 ''
check "the filesystem root is refused" "/" fix/lane 2 ''
check "an empty branch is refused" "$today" '' 2 ''
check "a branch with a .. segment is refused" "$today" ../escape 2 ''

# (5) The gate must actually use it. Text checks, so each one carries a control that must hit.
[ -x "$GATE" ] || fail "$GATE is missing or not executable"
gate_hits() { grep -c -- "$1" "$GATE" | tr -d ' '; }
control="$(gate_hits 'GATE_TARGET')"
cases=$((cases + 1))
if [ "${control:-0}" -lt 1 ]; then
  fail "the control grep found no GATE_TARGET in $GATE — the text checks below prove nothing"
else
  echo "ok   control: GATE_TARGET appears $control times in bin/mac-gate.sh"
fi
for needle in 'scripts/gate-work-dir.sh' 'gate_work_dir "$GATE_ROOT" "$GATE_BRANCH"' \
  'gate_work_root_resolved "$gate_root"' "GATE_ROOT='%s'"; do
  cases=$((cases + 1))
  if [ "$(gate_hits "$needle")" -lt 1 ]; then
    fail "bin/mac-gate.sh never mentions $needle"
  else
    echo "ok   bin/mac-gate.sh uses $needle"
  fi
done
cases=$((cases + 1))
if [ "$(gate_hits '/build/memos-ng-ios/gate/#')" -gt 0 ]; then
  fail "bin/mac-gate.sh still rewrites a path substring to find the work tree"
else
  echo "ok   bin/mac-gate.sh no longer rewrites a path substring to find the work tree"
fi

[ "$refusal_seen" -eq 1 ] || fail "no refusal was exercised; the suite cannot show it bites"
if [ "$fails" -ne 0 ]; then
  echo "GATE-WORK-DIR-TEST FAIL: $fails of $cases case(s) failed"
  exit 1
fi
echo "GATE-WORK-DIR-TEST ok ($cases cases)"
