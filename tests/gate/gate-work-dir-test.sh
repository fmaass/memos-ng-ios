#!/usr/bin/env bash
#
# Where the build scratch of a gate lane lives, checked against layouts this script builds.
#
# The work tree is the `work/` sibling of the gate root the preflight RESOLVED — the same root the
# refusal check compares the target against — so nothing about the physical path is assumed. It
# used to be a substring rewrite (`/build/memos-ng-ios/gate/` -> `.../work/`) of the physical gate
# path, which is a different claim: it holds only while ~/build/memos-ng-ios resolves under a path
# still spelling that out. The case that matters is the second one below, where the gate root is a
# symlink into a directory whose physical path contains no `/build/memos-ng-ios/` at all — the
# answer to a full build disk (MEMNG-160). The first case is today's layout, which must derive
# exactly what it derived before.
#
# The last two cases read bin/mac-gate.sh itself: an extracted derivation nothing calls would pass
# every case here and change nothing on the build host, so the remote half must be shown to
# receive the resolved root and to ask this function for the answer.
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

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-work-dir-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
# macOS temp paths traverse /var, and every path this test compares is a physical one.
tmp="$(cd "$tmp" && pwd -P)" || exit 1
trap 'rm -rf "$tmp"' EXIT

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
fi

fails=0
cases=0
refusal_seen=0

check() { # $1 label, $2 gate root, $3 branch, $4 expected exit, $5 expected work dir ('' when refused)
  local label="$1" root="$2" branch="$3" expect_rc="$4" expect="$5" out rc
  cases=$((cases + 1))
  out="$(gate_work_dir "$root" "$branch" 2>&1)"
  rc=$?
  if [ "$rc" != "$expect_rc" ]; then
    echo "FAIL $label: exit $rc, expected $expect_rc (output: ${out:-none})"
    fails=$((fails + 1))
    return
  fi
  if [ "$expect_rc" != 0 ]; then
    refusal_seen=1
    echo "ok   $label -> refused with exit $rc"
    return
  fi
  if [ "$out" != "$expect" ]; then
    echo "FAIL $label: derived ${out:-none}"
    echo "     expected $expect"
    fails=$((fails + 1))
    return
  fi
  echo "ok   $label -> ${out#"$tmp/"}"
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
# gate root no longer contains /build/memos-ng-ios/ anywhere.
mkdir -p "$tmp/volume/ios-lanes/gate" || exit 1
mkdir -p "$tmp/moved-home/build" || exit 1
ln -s "$tmp/volume/ios-lanes" "$tmp/moved-home/build/memos-ng-ios" || exit 1
moved="$(cd "$tmp/moved-home/build/memos-ng-ios/gate" && pwd -P)" || exit 1
case "$moved/" in
  */build/memos-ng-ios/*) echo "FAIL fixture: $moved still spells out the old substring"; fails=$((fails + 1)) ;;
  *) echo "ok   fixture: the resolved gate root is $moved" ;;
esac
cases=$((cases + 1))
check "a gate root resolved outside /build/memos-ng-ios/ still finds its work tree" \
  "$moved" fix/lane 0 "$tmp/volume/ios-lanes/work/fix/lane"

# (3) Inputs that cannot name a work tree are refused rather than guessed at.
check "a relative gate root is refused" "build/memos-ng-ios/gate" fix/lane 2 ''
check "the filesystem root is refused" "/" fix/lane 2 ''
check "an empty branch is refused" "$today" '' 2 ''
check "a branch with a .. segment is refused" "$today" ../escape 2 ''

# (4) The gate must actually use it. Text checks, so each one carries a control that must hit.
[ -x "$GATE" ] || { echo "FAIL $GATE is missing or not executable"; fails=$((fails + 1)); }
gate_hits() { grep -c -- "$1" "$GATE" | tr -d ' '; }
control="$(gate_hits 'GATE_TARGET')"
cases=$((cases + 1))
if [ "${control:-0}" -lt 1 ]; then
  echo "FAIL the control grep found no GATE_TARGET in $GATE — the text checks below prove nothing"
  fails=$((fails + 1))
else
  echo "ok   control: GATE_TARGET appears $control times in bin/mac-gate.sh"
fi
for needle in 'scripts/gate-work-dir.sh' 'gate_work_dir "$GATE_ROOT" "$GATE_BRANCH"' "GATE_ROOT='%s'"; do
  cases=$((cases + 1))
  if [ "$(gate_hits "$needle")" -lt 1 ]; then
    echo "FAIL bin/mac-gate.sh never mentions $needle"
    fails=$((fails + 1))
  else
    echo "ok   bin/mac-gate.sh uses $needle"
  fi
done
cases=$((cases + 1))
if [ "$(gate_hits '/build/memos-ng-ios/gate/#')" -gt 0 ]; then
  echo "FAIL bin/mac-gate.sh still rewrites a path substring to find the work tree"
  fails=$((fails + 1))
else
  echo "ok   bin/mac-gate.sh no longer rewrites a path substring to find the work tree"
fi

[ "$refusal_seen" -eq 1 ] || { echo "FAIL no refusal was exercised; the suite cannot show it bites"; fails=$((fails + 1)); }
if [ "$fails" -ne 0 ]; then
  echo "GATE-WORK-DIR-TEST FAIL: $fails of $cases case(s) failed"
  exit 1
fi
echo "GATE-WORK-DIR-TEST ok ($cases cases)"
