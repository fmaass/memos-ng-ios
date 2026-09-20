#!/usr/bin/env bash
#
# The text-selection rule: SwiftUI's text-selection modifier appears in none of the token
# management screen's files.
#
# A personal access token's plaintext is on screen exactly once, in the sheet that follows a mint
# (MEMNG-138). The one way it may leave that sheet is the Copy button, which writes a pasteboard
# item that expires a few minutes out, so a secret cannot sit on the general pasteboard until the
# next paste. The modifier undoes all of it: it offers the system's own Copy over the same Text,
# a second path to the general pasteboard that never passes the expiring write, and it hands over
# whatever was dragged over — a token is copied whole or not at all.
#
# What makes the absence UNCATCHABLE by a test is that SwiftUI exposes no view tree: no drawn-
# screen test can ask whether a Text is selectable, and the accessibility probe reads the same
# label either way. So the class is pinned the way this repo pins the absence of the share-link
# control — a literal text grep with a positive control in the same run.
#
# The scope is these files, not the package: memo text keeps its selection, because memo text is
# not a credential. It is a LITERAL grep and comments are not exempt: a check a comment can defeat
# is not a check. Prose that needs to explain why the screen is not selectable says so in words,
# which is also why this script lives in scripts/ — its own text carries the literal, and the
# files it checks may not.
#
# The positive control is the other half. A grep that finds nothing proves nothing on its own: it
# reads the same whether the rule holds or the screen was renamed, the directory moved, or the
# mirror arrived empty. So the same run also requires the EXACT file the rule is about, under the
# same root it was handed, to name the Copy action it leaves as the only way out.
#
# Usage: textselection-rule.sh [<repo-root>]   (default: the current directory)
# Exit:  0 = the rule holds and the control was found
#        1 = the rule was broken, or the control was missing
#        2 = the inputs were not usable (no such tree, nothing in scope, or the grep could not
#            read it), which is never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "TEXTSELECTION FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

scope="$root/Packages/MemosFeatures/Sources/MemosFeatures/Settings"
control="$scope/ManageTokensScreen.swift"

if [ ! -d "$scope" ]; then
  echo "TEXTSELECTION FAIL: $scope does not exist — the rule has no scope to check and this proves"
  echo "                    nothing"
  exit 2
fi
if [ ! -f "$control" ]; then
  echo "TEXTSELECTION FAIL: $control does not exist — the positive control has nothing to read, so"
  echo "                    a clean grep below would only mean the screen moved"
  exit 2
fi

# The scope is walked rather than globbed: a file moved one directory down would leave a bare
# ManageTokens*.swift glob matching nothing and reporting a pass.
files="$(find "$scope" -type f -name 'ManageTokens*.swift' 2>/dev/null | sort)"
if [ -z "$files" ]; then
  echo "TEXTSELECTION FAIL: no ManageTokens*.swift file under $scope, so the rule read nothing"
  exit 2
fi

rc=0
count=0
hits=""

# -a so a file git thinks is binary still answers with file:line rather than "Binary file matches":
# a hit is a failure whatever the file is, and a hit nobody can locate is not evidence. -H because
# one file in scope would otherwise answer without naming itself.
while IFS= read -r file; do
  count=$((count + 1))
  file_hits="$(grep -naHF 'textSelection' "$file" 2>/dev/null)"
  grep_rc=$?
  if [ "$grep_rc" -ge 2 ]; then
    echo "TEXTSELECTION FAIL: the grep over $file ended with exit $grep_rc, so the rule was never"
    echo "                    checked"
    exit 2
  fi
  [ -z "$file_hits" ] || hits="$hits$file_hits
"
done <<EOF
$files
EOF

if [ -n "$hits" ]; then
  echo "TEXTSELECTION FAIL: the text-selection modifier is named by the token management screen. It"
  echo "                    puts a second Copy on the minted secret — the system's own, over the"
  echo "                    general pasteboard, past the expiring write the Copy button makes, and"
  echo "                    over a fragment of a token at that (MEMNG-138). Comments count: reword"
  echo "                    the explanation, do not silence the check."
  printf '%s' "$hits"
  rc=1
else
  echo "TEXTSELECTION ok: no textSelection literal in the $count ManageTokens*.swift file(s) under"
  echo "                  Packages/MemosFeatures/Sources/MemosFeatures/Settings"
fi

if grep -qaF 'copySecret' "$control"; then
  echo "TEXTSELECTION ok (positive control): $control names copySecret, so the walk read the file"
  echo "                                     the rule is about"
else
  echo "TEXTSELECTION FAIL: positive control missing — $control does not name copySecret, so the"
  echo "                    grep above found nothing because it read the wrong file"
  rc=1
fi

exit $rc
