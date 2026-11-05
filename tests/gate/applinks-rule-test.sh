#!/usr/bin/env bash
#
# The gate's applinks rule, checked against entitlement pairs this script writes for the purpose.
#
# `scripts/applinks-rule.sh` is a text check over two generated plists, and a text check is exactly
# as trustworthy as the evidence that it still bites. The case that matters is the second one: the
# app's plain trip-door entry is removed from a pair that was accepted a moment ago, and the rule
# must go red on it (MEMNG-1084, the follow-up to MEMNG-1012 — before it, deleting that entry
# passed every gate). The others pin the edges the matcher is built around: the developer twin
# alone is not the entry, a commented-out entry is not the entry, the share extension may claim no
# universal-link host at all, and a pair without the app group proves nothing.
#
# The generated files are not in the tree (XcodeGen writes them on the build host), so there is no
# real-repository case here; the full gate runs the same script on the real files.
#
# Run it directly (`tests/gate/applinks-rule-test.sh`) or let the gate run it: it is picked up by
# the controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/applinks-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-applinks-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "${tmp:?}"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

TRIP='applinks:trip.discomarder.live'
GROUP='group.live.discomarder.memosng'

# Apple's XML plist form, tab-indented the way PropertyListSerialization writes it. $1 is the
# file, $2 the dict body (already indented).
plist() {
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '%s\n' "$2"
    printf '</dict>\n</plist>\n'
  } > "$1"
}

# $1 = the associated-domains <string> lines, one per line, without indentation.
app_body() {
  local domains="" line
  while IFS= read -r line; do
    [ -n "$line" ] && domains="$domains"$'\t\t'"$line"$'\n'
  done <<< "$1"
  printf '\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n%s\t</array>\n' "$domains"
  printf '\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>%s</string>\n\t</array>\n' "$GROUP"
  printf '\t<key>keychain-access-groups</key>\n\t<array>\n\t\t<string>%s</string>\n\t</array>' \
    '$(AppIdentifierPrefix)live.discomarder.memosng.credentials'
}

# The app's list as project.yml generates it today: the home entries stay, and the rule neither
# requires nor forbids them.
APP_DOMAINS="<string>applinks:memos.discomarder.live</string>
<string>applinks:memos.discomarder.live?mode=developer</string>
<string>webcredentials:memos.discomarder.live</string>
<string>webcredentials:memos.discomarder.live?mode=developer</string>
<string>$TRIP</string>
<string>$TRIP?mode=developer</string>"

EXT_GROUP_ONLY="$(printf '\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>%s</string>\n\t</array>' "$GROUP")"

# $1 = the <string> line the extension's associated-domains list carries.
ext_with_domain() {
  printf '%s\n\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t%s\n\t</array>' \
    "$EXT_GROUP_ONLY" "$1"
}

# $1 name, $2 app associated-domains lines, $3 extension dict body
new_pair() {
  local work="$tmp/pairs/$1"
  mkdir -p "$work" || return 1
  plist "$work/MemosNG.entitlements" "$(app_body "$2")"
  plist "$work/MemosShare.entitlements" "$3"
  printf '%s' "$work"
}

# A case may run the rule with a PATH of its own (CASE_PATH), to put a failing tool in front of it.
CASE_PATH=""

check() { # $1 label, $2 expected exit, $3 dir, $4 a fixed string the output must carry (optional)
  local label="$1" expected="$2" dir="$3" want="${4:-}" out rc
  cases=$((cases + 1))
  out="$(PATH="${CASE_PATH:-$PATH}" "$RULE" "$dir" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ] && { [ -z "$want" ] || printf '%s\n' "$out" | grep -qF -- "$want"; }; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    if [ "$first_fail" -eq 0 ]; then
      # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected${want:+ with \"$want\"}, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# The shape the build host generates today: the app claims the trip door (and the home entries),
# the extension declares the app group and nothing else.
w="$(new_pair clean "$APP_DOMAINS" "$EXT_GROUP_ONLY")" || exit 1
check "the pair as generated today" 0 "$w" "APPLINKS ok: MemosNG.entitlements claims $TRIP"

# THE case this rule exists for: the same pair with the plain trip entry deleted.
w="$(new_pair no-trip "$(printf '%s\n' "$APP_DOMAINS" | grep -vxF "<string>$TRIP</string>")" "$EXT_GROUP_ONLY")" || exit 1
check "the app without the plain trip entry" 1 "$w" \
  "APPLINKS FAIL: MemosNG.entitlements does not claim $TRIP"

# The developer twin is a different entry: it only works on a device in developer mode.
w="$(new_pair twin-only "<string>$TRIP?mode=developer</string>" "$EXT_GROUP_ONLY")" || exit 1
check "the app with only the ?mode=developer twin" 1 "$w" \
  "APPLINKS FAIL: MemosNG.entitlements does not claim $TRIP"

# A longer host that starts with the trip host is not the trip host.
w="$(new_pair longer-host "<string>$TRIP.example.com</string>" "$EXT_GROUP_ONLY")" || exit 1
check "the app claiming a host that only starts with the trip host" 1 "$w" \
  "APPLINKS FAIL: MemosNG.entitlements does not claim $TRIP"

# A commented-out entry is text in the file, not an entitlement.
w="$(new_pair commented "<!-- <string>$TRIP</string> -->" "$EXT_GROUP_ONLY")" || exit 1
check "the trip entry inside an XML comment" 1 "$w" \
  "APPLINKS FAIL: MemosNG.entitlements does not claim $TRIP"

# The string in the wrong array: the plain entry under the app group, only the twin under
# associated-domains. The file holds the exact line, and the app still does not claim the door.
w="$tmp/pairs/wrong-array"
mkdir -p "$w" || exit 1
plist "$w/MemosNG.entitlements" "$(printf '\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t<string>%s?mode=developer</string>\n\t</array>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>%s</string>\n\t\t<string>%s</string>\n\t</array>' "$TRIP" "$GROUP" "$TRIP")"
plist "$w/MemosShare.entitlements" "$EXT_GROUP_ONLY"
check "the plain entry in the app-groups array, the twin under associated-domains" 1 "$w" \
  "APPLINKS FAIL: MemosNG.entitlements does not claim $TRIP"

# An empty associated-domains value is not followed by the next key's array: the block ends where
# the key's own value does.
w="$tmp/pairs/empty-domains"
mkdir -p "$w" || exit 1
plist "$w/MemosNG.entitlements" "$(printf '\t<key>com.apple.developer.associated-domains</key>\n\t<array/>\n\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>%s</string>\n\t\t<string>%s</string>\n\t</array>' "$GROUP" "$TRIP")"
plist "$w/MemosShare.entitlements" "$EXT_GROUP_ONLY"
check "an empty associated-domains array before an array holding the entry" 1 "$w" \
  "APPLINKS FAIL: MemosNG.entitlements does not claim $TRIP"

# The share extension claiming the trip door would let a pass link open the sheet, not the app.
w="$(new_pair ext-trip "$APP_DOMAINS" "$(ext_with_domain "<string>$TRIP</string>")")" || exit 1
check "the extension claiming the trip door" 1 "$w" \
  "APPLINKS FAIL: MemosShare.entitlements claims applinks: <string>$TRIP</string>"

# Any applinks entry at all, not only the trip one.
w="$(new_pair ext-home "$APP_DOMAINS" "$(ext_with_domain '<string>applinks:memos.discomarder.live</string>')")" || exit 1
check "the extension claiming another applinks host" 1 "$w" \
  "APPLINKS FAIL: MemosShare.entitlements claims applinks: <string>applinks:memos.discomarder.live</string>"

# The positive control, checked by removing its subject: an extension without the app group is a
# file the 0-hit grep above says nothing about.
w="$(new_pair ext-no-group "$APP_DOMAINS" "$(printf '\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t</array>')")" || exit 1
check "the extension without the app group (control gone)" 1 "$w" "APPLINKS FAIL: positive control"

# The control's app half: no associated-domains list means the trip grep read the wrong file.
w="$tmp/pairs/app-no-domains"
mkdir -p "$w" || exit 1
plist "$w/MemosNG.entitlements" "$(printf '\t<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>%s</string>\n\t\t<string>%s</string>\n\t</array>' "$GROUP" "$TRIP")"
plist "$w/MemosShare.entitlements" "$EXT_GROUP_ONLY"
check "the app without the associated-domains key (control gone)" 1 "$w" "APPLINKS FAIL: positive control"

# A read that failed is not a clean file. A grep that cannot read the extension prints nothing, the
# same as a grep that found nothing; a stand-in grep that fails exactly that call proves the rule
# tells the two apart. The same for the awk that reads the app's list.
real_grep="$(command -v grep)" || { echo "FAIL: no grep on PATH"; exit 1; }
mkdir -p "$tmp/stub-grep" "$tmp/stub-awk" || exit 1
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = applinks: ] && { echo "grep: stand-in read error" >&2; exit 2; }; done\nexec %s "$@"\n' \
  "$real_grep" > "$tmp/stub-grep/grep"
printf '#!/bin/sh\necho "awk: stand-in read error" >&2\nexit 2\n' > "$tmp/stub-awk/awk"
chmod +x "$tmp/stub-grep/grep" "$tmp/stub-awk/awk" || exit 1
w="$(new_pair grep-error "$APP_DOMAINS" "$EXT_GROUP_ONLY")" || exit 1
CASE_PATH="$tmp/stub-grep:$PATH"
check "the extension grep failing to read" 2 "$w" "APPLINKS FAIL: the grep over $w/MemosShare.entitlements ended with exit 2"
CASE_PATH="$tmp/stub-awk:$PATH"
check "the app's list failing to read" 2 "$w" "APPLINKS FAIL: reading the associated-domains list of $w/MemosNG.entitlements ended with exit 2"
CASE_PATH=""

# A file that was never generated is refused, never read as a pass.
w="$(new_pair missing-ext "$APP_DOMAINS" "$EXT_GROUP_ONLY")" || exit 1
rm -f "$w/MemosShare.entitlements"
check "the extension file missing" 2 "$w" "APPLINKS FAIL: $w/MemosShare.entitlements"

w="$(new_pair missing-app "$APP_DOMAINS" "$EXT_GROUP_ONLY")" || exit 1
rm -f "$w/MemosNG.entitlements"
check "the app file missing" 2 "$w" "APPLINKS FAIL: $w/MemosNG.entitlements"

check "a directory that does not exist" 2 "$tmp/nowhere" "APPLINKS FAIL"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no pair was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no pair was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate applinks rule: $((cases - fails)) of $cases pairs as expected"
[ "$fails" -eq 0 ] || { echo "APPLINKS-TEST FAIL: $fails pair(s) misjudged"; exit "$first_fail"; }
echo "APPLINKS-TEST ok"
