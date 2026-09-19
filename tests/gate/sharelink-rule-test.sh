#!/usr/bin/env bash
#
# The gate's share-link rule, checked against trees this script builds for the purpose.
#
# `scripts/sharelink-rule.sh` is a text grep, and a text grep is exactly as trustworthy as the
# evidence that it still bites. The case that matters is the second one below: a scratch view using
# SwiftUI's share-link control is dropped into a Features layer that was clean a moment ago, and
# the rule must go red on it. That is the ticket's demonstration (MEMNG-211), and putting it here
# rather than in a one-off session means it is re-proved on every gate run instead of once.
#
# The last case is the real repository this test ships in: the rule must hold on the tree as it
# stands. Nothing here writes into that tree — the scratch control only ever lands in a temporary
# copy — and every temporary tree is removed on exit.
#
# Run it directly (`tests/gate/sharelink-rule-test.sh`) or let the gate run it: it is picked up by
# the controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/sharelink-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-sharelink-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

# A Features layer with the shape the rule reads: a manifest, a source tree that imports SwiftUI
# (the positive control's subject) and a test target. No share-link control anywhere.
new_tree() {
  local name="$1" work="$tmp/$1"
  mkdir -p "$work/Packages/MemosFeatures/Sources/MemosFeatures" \
    "$work/Packages/MemosFeatures/Tests/MemosFeaturesTests" || return 1
  printf '// swift-tools-version: 6.0\nlet package = "MemosFeatures"\n' \
    > "$work/Packages/MemosFeatures/Package.swift"
  printf 'import SwiftUI\n\nstruct X: View {\n    var body: some View { Text("x") }\n}\n' \
    > "$work/Packages/MemosFeatures/Sources/X.swift"
  printf 'import Testing\n\n@Test func x() {}\n' \
    > "$work/Packages/MemosFeatures/Tests/MemosFeaturesTests/XTests.swift"
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

# The shape of a healthy Features layer: no share-link control, and a file that imports SwiftUI.
w="$(new_tree clean)" || exit 1
check "a clean Features layer" 0 "$w"

# THE case this rule exists for. The tree above was accepted; one scratch view using the control is
# added to it, and the same rule must now refuse it. A rule that cannot go red is not a rule.
w="$(new_tree scratch-usage)" || exit 1
cat > "$w/Packages/MemosFeatures/Sources/MemosFeatures/GateShareLinkScratch.swift" <<'SWIFT'
import SwiftUI

struct GateShareLinkScratch: View {
    let url: URL
    var body: some View {
        ShareLink(item: url)
    }
}
SWIFT
check "a scratch share-link view under Sources" 1 "$w"

# A comment is not an exemption. The literal grep is chosen precisely so that the explanation of
# why this app does not use the control cannot be written using the control's own name — otherwise
# a row could be reintroduced under a comment that reads like a warning about it.
w="$(new_tree in-a-comment)" || exit 1
printf '// A row here must never be a ShareLink over a URL.\nlet note = 1\n' \
  >> "$w/Packages/MemosFeatures/Sources/X.swift"
check "the literal inside a comment" 1 "$w"

# The scope is the whole package, not just Sources: a test target that names the control is a test
# that would keep compiling after somebody put one back.
w="$(new_tree in-tests)" || exit 1
printf 'let shared = "ShareLink"\n' \
  >> "$w/Packages/MemosFeatures/Tests/MemosFeaturesTests/XTests.swift"
check "the literal in the test target" 1 "$w"

# The manifest is in scope too.
w="$(new_tree in-manifest)" || exit 1
printf '// no ShareLink here, said the manifest\n' >> "$w/Packages/MemosFeatures/Package.swift"
check "the literal in Package.swift" 1 "$w"

# The positive control, checked by removing its subject. Nothing under Sources imports SwiftUI, so
# the rule grep found nothing for a reason that has nothing to do with the rule holding.
w="$(new_tree no-control)" || exit 1
printf 'import Foundation\n\nlet x = 1\n' > "$w/Packages/MemosFeatures/Sources/X.swift"
check "a Sources tree that never imports SwiftUI" 1 "$w"

# A scope that is not there reads exactly like a scope that is clean. It is refused instead: a
# mirror that arrived empty, or a package that was renamed, must never come back as a pass.
w="$tmp/no-package"
mkdir -p "$w/Packages/MemosCore/Sources" || exit 1
check "a tree with no MemosFeatures package" 2 "$w"

# And the repository this suite ships in, which is the point of the whole exercise: main is clean
# and stays clean.
check "the real repository tree" 0 "$repo_root"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no case was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no tree was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate share-link rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || { echo "SHARELINK-TEST FAIL: $fails tree(s) misjudged"; exit "$first_fail"; }
echo "SHARELINK-TEST ok"
