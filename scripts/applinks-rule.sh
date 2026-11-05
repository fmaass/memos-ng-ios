#!/usr/bin/env bash
#
# The applinks rule: the app claims exactly the trip door as its universal-link host set, and the
# share extension claims no universal-link host at all.
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
# a machine that has no `plutil`. XML comments are removed first, a multiline one included, so a
# commented-out line is never an entry (MEMNG-1178). An entry is a line DIRECTLY inside the
# associated-domains array, not inside an array or dict nested in it, and the app must hold both
# `<string>applinks:trip.discomarder.live</string>` and its `?mode=developer` twin as entries,
# each matched exactly once its surrounding whitespace is trimmed: the twin alone, a longer host,
# a commented-out entry, an entry one level too deep, or the string under another key does not
# satisfy it. That pair is the app's WHOLE applinks set (MEMNG-1177): any other line of the list
# that holds `applinks:`, at any depth, is refused, because the home domain never serves universal
# links and the custom URL scheme is its deep-link lane. Entries of another type
# (`webcredentials:`) are neither required nor forbidden.
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
twin="$trip?mode=developer"
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
# key's array, a comment) is text, not an entitlement. Comments go first, `<!-- ... -->` across any
# number of lines. The block is the lines after the key, opened by an `<array>` on the very next
# non-blank line and closed by the `</array>` that matches it: a nested `<array>` or `<dict>` raises
# the depth and its own closing tag lowers it again, so it neither ends the list early nor passes
# for a direct entry. A key whose value is anything else (`<array/>`, a string) yields no block,
# which reads as no claim. Each line of the block is printed as `<depth> <line>`, depth 1 being a
# direct entry. Every line is trimmed, because XcodeGen's indentation is not this script's
# business, the entry is.
domains="$(awk '
  {
    raw = $0; line = ""
    while (raw != "") {
      if (incomment) {
        i = index(raw, "-->"); if (i == 0) { raw = ""; break }
        raw = substr(raw, i + 3); incomment = 0
      } else {
        i = index(raw, "<!--"); if (i == 0) { line = line raw; raw = ""; break }
        line = line substr(raw, 1, i - 1); raw = substr(raw, i + 4); incomment = 1
      }
    }
    sub(/^[ \t\r]+/, "", line); sub(/[ \t\r]+$/, "", line)
  }
  state == 0 && line == "<key>com.apple.developer.associated-domains</key>" { state = 1; next }
  state == 1 { if (line == "") next; if (line == "<array>") { state = 2; depth = 1; next } state = 3; next }
  state == 2 {
    if (line == "") next
    if (line == "<array>" || line == "<dict>") { depth++; next }
    if (line == "</array>" || line == "</dict>") { depth--; if (depth == 0) state = 3; next }
    print depth " " line
  }
' "$dir/$app")"
awk_rc=$?
if [ "$awk_rc" -ne 0 ]; then
  echo "APPLINKS FAIL: reading the associated-domains list of $dir/$app ended with exit $awk_rc,"
  echo "              so the trip entry was never checked"
  exit 2
fi
for want in "$trip" "$twin"; do
  if printf '%s\n' "$domains" | grep -qxF "1 <string>$want</string>"; then
    echo "APPLINKS ok: $app claims $want"
  else
    echo "APPLINKS FAIL: $app does not claim $want"
    echo "              a pass link from the trip door would no longer open the app (MEMNG-1012)"
    rc=1
  fi
done

# Every other line of the block that names applinks, at any depth, is a claim outside the set.
outside=0
while IFS= read -r entry; do
  case "$entry" in
    "1 <string>$trip</string>" | "1 <string>$twin</string>") continue ;;
    *applinks:*) ;;
    *) continue ;;
  esac
  echo "APPLINKS FAIL: $app claims an applinks entry outside the trip-door set: ${entry#* }"
  outside=1
done <<< "$domains"
if [ "$outside" -eq 0 ]; then
  echo "APPLINKS ok: $app claims exactly the trip-door applinks set"
else
  echo "              the home domain never serves universal links; its lane is the custom URL scheme"
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
