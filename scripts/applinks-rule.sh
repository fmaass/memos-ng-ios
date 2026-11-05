#!/usr/bin/env bash
#
# The applinks rule: the app claims the trip door as a universal-link host, and the share extension
# claims no universal-link host at all.
#
# The trip door is the one host whose association is publicly fetchable, and the line that claims
# it is what lets a pass link opened from the Camera or Messages open the app on that pass. Deleting
# it breaks nothing a build or a unit test can see: the app still builds, signs and launches, and
# the link simply falls back to the door's landing page. Before MEMNG-1084 no gate step read the
# associated-domains list, so that deletion passed every gate. The extension is the other half: a
# share sheet that claimed a universal-link host would be offered links the app is meant to open.
#
# It reads the GENERATED plists as text, the artefact that ships, rather than project.yml. Text and
# not `plutil`, so the same code runs on the build host and in tests/gate/applinks-rule-test.sh on
# a machine that has no `plutil`. The app's entry must be a line INSIDE the associated-domains
# array that is, once its surrounding whitespace is trimmed, exactly
# `<string>applinks:trip.discomarder.live</string>`: the `?mode=developer` twin alone, a longer
# host, a commented-out entry, or the string under another key does not satisfy it. The rule
# neither requires nor forbids any other entry in the app's list.
#
# The positive control is the other half. The extension's grep passes by finding nothing, and
# nothing reads the same whether the file was clean or the wrong file was read. So the same run
# requires the app group in both files and the associated-domains key in the app's.
#
# Usage: applinks-rule.sh [<dir>]     (default: the current directory; it holds both plists)
# Exit:  0 = the rule holds and the control was found
#        1 = the rule was broken, or the control was missing
#        2 = the inputs were not usable (no such directory, a plist absent or unreadable, or a read
#            that failed), which is never a pass
set -uo pipefail

dir="${1:-.}"
app="MemosNG.entitlements"
ext="MemosShare.entitlements"
trip="applinks:trip.discomarder.live"
group="group.live.discomarder.memosng"

if [ ! -d "$dir" ]; then
  echo "APPLINKS FAIL: '$dir' is not a directory, so nothing was checked"
  exit 2
fi
for f in "$app" "$ext"; do
  if [ ! -f "$dir/$f" ] || [ ! -r "$dir/$f" ]; then
    echo "APPLINKS FAIL: $dir/$f is absent or unreadable, so nothing was checked"
    exit 2
  fi
done

rc=0

# Only the associated-domains array counts: the same string anywhere else in the plist (another
# key's array, a comment) is text, not an entitlement. The block is the lines after the key, opened
# by an `<array>` on the very next non-blank line and closed by the first `</array>`; a key whose
# value is anything else (`<array/>`, a string) yields no block, which reads as no claim. Every
# line is trimmed, because XcodeGen's indentation is not this script's business, the entry is.
domains="$(awk '
  { line = $0; sub(/^[ \t\r]+/, "", line); sub(/[ \t\r]+$/, "", line) }
  state == 0 && line == "<key>com.apple.developer.associated-domains</key>" { state = 1; next }
  state == 1 { if (line == "") next; if (line == "<array>") { state = 2; next } state = 3; next }
  state == 2 { if (line == "</array>") { state = 3; next } print line }
' "$dir/$app")"
awk_rc=$?
if [ "$awk_rc" -ne 0 ]; then
  echo "APPLINKS FAIL: reading the associated-domains list of $dir/$app ended with exit $awk_rc,"
  echo "              so the trip entry was never checked"
  exit 2
fi
if printf '%s\n' "$domains" | grep -qxF "<string>$trip</string>"; then
  echo "APPLINKS ok: $app claims $trip"
else
  echo "APPLINKS FAIL: $app does not claim $trip"
  echo "              a pass link from the trip door would no longer open the app (MEMNG-1012)"
  rc=1
fi

# grep answers 1 for "no line" and 2 or more for "could not read": only the first is a pass, and
# an empty capture alone cannot tell the two apart.
raw="$(grep -F 'applinks:' "$dir/$ext")"
grep_rc=$?
if [ "$grep_rc" -ge 2 ]; then
  echo "APPLINKS FAIL: the grep over $dir/$ext ended with exit $grep_rc, so the extension was"
  echo "              never checked"
  exit 2
fi
if [ "$grep_rc" -eq 0 ]; then
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    echo "APPLINKS FAIL: $ext claims applinks: $line"
  done <<< "$raw"
  rc=1
else
  echo "APPLINKS ok: $ext claims no applinks host"
fi

if grep -qF "$group" "$dir/$app" && grep -qF "$group" "$dir/$ext" \
  && grep -qF 'com.apple.developer.associated-domains' "$dir/$app"; then
  echo "APPLINKS ok (positive control): both files declare $group and $app declares"
  echo "              com.apple.developer.associated-domains, so the greps read the real files"
else
  echo "APPLINKS FAIL: positive control missing — $group is not in both files, or $app has no"
  echo "              com.apple.developer.associated-domains key, so the greps above prove nothing"
  rc=1
fi

exit $rc
