#!/usr/bin/env bash
#
# The gate's picture-list forwarding rule, checked against trees this script builds for the purpose.
#
# `scripts/picturelist-forwarding-rule.sh` stands in for the tests neither host can have: both save
# call sites sit behind a sheet that does not present under test. So the rule is the only thing
# holding the forwarding, and a rule that cannot go red holds nothing. The cases below are the ways
# it is supposed to bite — a host that lost the line, a host that grew a second one, a line that is
# only a comment, and a control that stopped answering — each on a scratch tree built here.
#
# The last case is the real repository this test ships in: the rule must hold on the tree as it
# stands. Nothing here writes into that tree — every scratch host only ever lands in a temporary
# copy — and every temporary tree is removed on exit.
#
# Run it directly (`tests/gate/picturelist-forwarding-rule-test.sh`) or let the gate run it: it is
# picked up by the controller-side selftest step in bin/mac-gate.sh, which runs every
# tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/picturelist-forwarding-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-picturelist-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

# A Features layer with the shape the rule reads: the two hosts, each saving an edit the way they
# really do — the upload forwarding (the control) and the stated picture list beside it.
host_body() {
  cat <<'SWIFT'
import SwiftUI

struct Host: View {
    var body: some View { Text("x") }

    private func save(_ submission: ComposeSubmission) async {
        _ = try? await store.edit(
            uid: uid,
            content: submission.content,
            attaching: submission.attachments.map(\.stagedSource),
            listing: submission.pictures,
            using: session,
            baseURL: url)
    }
}
SWIFT
}

new_tree() { # $1 name
  local work="$tmp/$1" sources
  sources="$work/Packages/MemosFeatures/Sources/MemosFeatures"
  mkdir -p "$sources" || return 1
  host_body > "$sources/TimelineView.swift"
  host_body > "$sources/MemoDetailView.swift"
  printf '%s' "$work"
}

check() { # $1 label, $2 expected exit, $3 tree root
  local label="$1" expected="$2" root="$3" out rc
  cases=$((cases + 1))
  out="$("$RULE" "$root" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ]; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    if [ "$first_fail" -eq 0 ]; then
      # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# Both hosts as they are supposed to be.
w="$(new_tree clean)" || exit 1
check "both hosts forwarding the stated list" 0 "$w"

# THE case this rule exists for: one host quietly stops stating the list, and the save it sends
# leaves the memo holding the picture somebody took off it.
w="$(new_tree dropped-in-one-host)" || exit 1
sed -i.bak '/listing: submission.pictures,/d' \
  "$w/Packages/MemosFeatures/Sources/MemosFeatures/MemoDetailView.swift" || exit 1
check "one host that no longer states the list" 1 "$w"

# The other direction: a second save path grown beside the first, where one of the two is bound to
# fall behind the other.
w="$(new_tree doubled)" || exit 1
printf 'func saveAgain() { resend(listing: submission.pictures) }\n' \
  >> "$w/Packages/MemosFeatures/Sources/MemosFeatures/TimelineView.swift"
check "one host forwarding the list twice" 1 "$w"

# A comment is not a forwarding. The line is counted only where it can execute, so an explanation
# of the rule written into a host cannot stand in for the host obeying it.
w="$(new_tree only-in-a-comment)" || exit 1
sed -i.bak 's|^            listing: submission.pictures,$|            // listing: submission.pictures,|' \
  "$w/Packages/MemosFeatures/Sources/MemosFeatures/TimelineView.swift" || exit 1
check "a host whose only mention is commented out" 1 "$w"

# The positive control, checked by removing its subject: a host that no longer names the upload
# forwarding is not a host that saves an edit, so the count beside it proves nothing.
w="$(new_tree no-control)" || exit 1
sed -i.bak '/attaching:/d' \
  "$w/Packages/MemosFeatures/Sources/MemosFeatures/MemoDetailView.swift" || exit 1
check "a host that no longer names the upload forwarding" 1 "$w"

# A host that is not there reads exactly like a host that is clean. It is refused instead: a mirror
# that arrived empty, or a screen that was renamed, must never come back as a pass.
w="$(new_tree missing-host)" || exit 1
rm "$w/Packages/MemosFeatures/Sources/MemosFeatures/MemoDetailView.swift" || exit 1
check "a tree with one host missing" 2 "$w"

# And the repository this suite ships in, which is the point of the whole exercise.
check "the real repository tree" 0 "$repo_root"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no tree was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no tree was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate picture-list forwarding rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || { echo "PICTURELIST-TEST FAIL: $fails tree(s) misjudged"; exit "$first_fail"; }
echo "PICTURELIST-TEST ok"
