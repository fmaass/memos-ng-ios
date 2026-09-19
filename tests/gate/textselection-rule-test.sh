#!/usr/bin/env bash
#
# The gate's text-selection rule, checked against trees this script builds for the purpose.
#
# `scripts/textselection-rule.sh` is a text grep, and a text grep is exactly as trustworthy as the
# evidence that it still bites. The case that matters is the second one below: the modifier is put
# back on a token management screen that was clean a moment ago, and the rule must go red on it.
# The other half is the positive control — a screen the rule cannot have read, because it is not
# the file the rule is about, must not come back as a pass (MEMNG-138).
#
# Nothing here writes into the repository this suite ships in: every tree is a temporary one built
# by new_tree(), and all of them are removed on exit. The real tree is judged by the gate step that
# runs the rule against the mirror, which is where a verdict about this repository belongs.
#
# Run it directly (`tests/gate/textselection-rule-test.sh`) or let the gate run it: it is picked up
# by the controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/textselection-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-textselection-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

# A Features layer with the shape the rule reads: the three files of the token management screen
# under Settings, the screen naming its Copy action (the positive control's subject), a sibling
# settings file and a memo view that IS selectable. No text-selection modifier in scope.
new_tree() {
  local name="$1" work="$tmp/$1" settings
  settings="$work/Packages/MemosFeatures/Sources/MemosFeatures/Settings"
  mkdir -p "$settings" || return 1
  printf 'import SwiftUI\n\nstruct ManageTokensScreen: View {\n    let copySecret: () -> Void\n    var body: some View { Text("secret") }\n}\n' \
    > "$settings/ManageTokensScreen.swift"
  printf 'import SwiftUI\n\nstruct ManageTokensView: View {\n    var body: some View { ManageTokensScreen(copySecret: {}) }\n}\n' \
    > "$settings/ManageTokensView.swift"
  printf 'struct ManageTokensPresentation {\n    let rows: [String]\n}\n' \
    > "$settings/ManageTokensPresentation.swift"
  printf 'import SwiftUI\n\nstruct SettingsView: View {\n    var body: some View { Text("settings") }\n}\n' \
    > "$settings/SettingsView.swift"
  printf 'import SwiftUI\n\nstruct MemoMarkdownView: View {\n    var body: some View { Text("memo").textSelection(.enabled) }\n}\n' \
    > "$work/Packages/MemosFeatures/Sources/MemosFeatures/MemoMarkdownView.swift"
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

# The shape of a healthy token management screen, and a memo view that keeps its selection in the
# same tree: memo text is not a credential, and the rule must not reach it.
w="$(new_tree clean)" || exit 1
check "a clean Settings tree, with a selectable memo view beside it" 0 "$w"

# THE case this rule exists for. The tree above was accepted; the modifier goes back on the screen
# that shows the minted secret, and the same rule must now refuse it. A rule that cannot go red is
# not a rule.
w="$(new_tree on-the-screen)" || exit 1
settings="$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings"
printf '\nextension ManageTokensScreen {\n    var selectable: some View { Text("secret").textSelection(.enabled) }\n}\n' \
  >> "$settings/ManageTokensScreen.swift"
check "the modifier back on the token screen" 1 "$w"

# A comment is not an exemption. The literal grep is chosen precisely so that the explanation of
# why this screen is not selectable cannot be written using the modifier's own name — otherwise it
# could be reintroduced under a comment that reads like a warning about it.
w="$(new_tree in-a-comment)" || exit 1
printf '// The secret must never carry textSelection.\n' \
  >> "$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings/ManageTokensScreen.swift"
check "the literal inside a comment" 1 "$w"

# The scope is every file of this screen, not just the one the control reads: the sheet's Text can
# be built in any of them.
w="$(new_tree in-a-sibling)" || exit 1
printf '\nlet selectableRow = Text("x").textSelection(.enabled)\n' \
  >> "$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings/ManageTokensView.swift"
check "the literal in a sibling ManageTokens file" 1 "$w"

# The scope is walked, not globbed one level deep: a screen split into a subdirectory of Settings
# would leave a bare glob matching nothing and reporting a pass.
w="$(new_tree in-a-subdirectory)" || exit 1
mkdir -p "$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings/Sheets" || exit 1
printf 'import SwiftUI\n\nlet sheet = Text("secret").textSelection(.enabled)\n' \
  > "$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings/Sheets/ManageTokensSecretSheet.swift"
check "the literal one directory below Settings" 1 "$w"

# The positive control, checked by removing its subject. The screen is there and clean, but it is
# not the screen this rule is about — so a clean grep says nothing about the secret's Text.
w="$(new_tree no-control)" || exit 1
printf 'import SwiftUI\n\nstruct ManageTokensScreen: View {\n    var body: some View { Text("secret") }\n}\n' \
  > "$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings/ManageTokensScreen.swift"
check "a screen that never names its Copy action" 1 "$w"

# The control is an EXACT path, not a search: the other files of the screen are still there, so the
# rule grep still has something to read, and it must still refuse.
w="$(new_tree control-renamed)" || exit 1
mv "$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings/ManageTokensScreen.swift" \
   "$w/Packages/MemosFeatures/Sources/MemosFeatures/Settings/ManageTokensSecretScreen.swift" || exit 1
check "the screen renamed away from the control's path" 2 "$w"

# A scope that is not there reads exactly like a scope that is clean. It is refused instead: a
# mirror that arrived empty, or a directory that moved, must never come back as a pass.
w="$tmp/no-settings"
mkdir -p "$w/Packages/MemosFeatures/Sources/MemosFeatures" || exit 1
check "a tree with no Settings directory" 2 "$w"

# And a root that is not a tree at all.
check "a root that does not exist" 2 "$tmp/absent"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no case was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no tree was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate text-selection rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || { echo "TEXTSELECTION-TEST FAIL: $fails tree(s) misjudged"; exit "$first_fail"; }
echo "TEXTSELECTION-TEST ok"
