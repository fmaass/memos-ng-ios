#!/usr/bin/env bash
#
# The share-link rule: SwiftUI's built-in share-link control appears nowhere in the Features layer.
#
# MEMNG-207 was a row that handed a recipient a signed URL into the household server instead of the
# file. What made that possible is that the control which shares is a BUTTON holding a value it
# already has, so it can only ever share something that exists before the tap — and the files this
# app shares do not exist until a download has finished. What makes it UNCATCHABLE by a test is
# that SwiftUI exposes no view tree: a unit test cannot ask whether a row is a button or a share
# control, and the accessibility probe reads the same label either way. So the class is pinned the
# only way the rest of this repo pins such a class — a literal text grep with a positive control in
# the same run, in the idiom of the dependency rule and the keychain rule in bin/mac-gate.sh.
#
# It is a LITERAL grep over the whole package — manifest, sources and tests, every file type — and
# comments are not exempt: a check a comment can defeat is not a check. Prose that needs to explain
# the control says so in words instead, as the comments in MediaSaveFlow, MediaViewerView and
# MediaTileMenu do. This script's own text carries the literal, which is why it lives in scripts/
# and not in the scope it checks.
#
# The positive control is the other half. A grep that finds nothing proves nothing on its own: it
# reads the same whether the rule holds or the path was wrong, the package was renamed, or the
# mirror arrived empty. So the same run also requires `import SwiftUI` somewhere under the
# package's sources — a string that is there today and would only vanish if the walk stopped
# finding real files.
#
# Usage: sharelink-rule.sh [<repo-root>]     (default: the current directory)
# Exit:  0 = the rule holds and the control was found
#        1 = the rule was broken, or the control was missing
#        2 = the inputs were not usable (no such tree, or the grep could not read it), which is
#            never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "SHARELINK FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

scope="$root/Packages/MemosFeatures"
control_scope="$scope/Sources"

if [ ! -d "$scope" ]; then
  echo "SHARELINK FAIL: $scope does not exist — the rule has no scope to check and this proves"
  echo "                nothing"
  exit 2
fi
if [ ! -d "$control_scope" ]; then
  echo "SHARELINK FAIL: $control_scope does not exist — the positive control has nowhere to look"
  exit 2
fi

rc=0

# -a so a file git thinks is binary still answers with file:line rather than "Binary file matches":
# a hit is a failure whatever the file is, and a hit nobody can locate is not evidence.
hits="$(grep -rnaF 'ShareLink' "$scope" 2>/dev/null)"
grep_rc=$?
if [ "$grep_rc" -ge 2 ] && [ -z "$hits" ]; then
  echo "SHARELINK FAIL: the grep over $scope ended with exit $grep_rc and read nothing, so the"
  echo "                rule was never checked"
  exit 2
fi

if [ -n "$hits" ]; then
  echo "SHARELINK FAIL: the share-link control is named under Packages/MemosFeatures. It shares a"
  echo "                value it is already holding, and the files this app shares do not exist"
  echo "                until a download has finished — which is how a signed household URL was"
  echo "                handed to a recipient once already (MEMNG-207). Comments count: reword"
  echo "                the explanation, do not silence the check."
  echo "$hits"
  rc=1
else
  echo "SHARELINK ok: no ShareLink literal under Packages/MemosFeatures"
fi

control="$(grep -rlaF 'import SwiftUI' "$control_scope" 2>/dev/null | head -1)"
if [ -n "$control" ]; then
  echo "SHARELINK ok (positive control): $control imports SwiftUI, so the walk read real files"
else
  echo "SHARELINK FAIL: positive control missing — no file under $control_scope imports SwiftUI,"
  echo "                so the rule grep above found nothing because it read nothing"
  rc=1
fi

exit $rc
