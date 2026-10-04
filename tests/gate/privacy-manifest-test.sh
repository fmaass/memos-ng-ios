#!/usr/bin/env bash
#
# The privacy manifests are held to their declared reasons, per bundle, and a manifest that drops
# one is refused naming the bundle and the difference.
#
# The full gate reads each BUILT bundle's PrivacyInfo.xcprivacy back through
# scripts/privacy-manifest-verdict.py. Until that verdict held the user-defaults category, a change
# that dropped the entry, or one of its reasons, passed the gate and would first have been heard of
# in an App Store Connect rejection. The cases here feed the verdict the tracked manifests (which
# must pass: the control) and edited copies of them, derived from the tracked files so the test
# follows the manifests rather than a second copy of their reason codes. The last part runs the
# gate's own read-back script, cut out of bin/mac-gate.sh, over two fake bundles, so a verdict the
# gate had stopped calling would fail here too.
#
# Run locally or through the gate's selftest; no build host is needed, only python3.
# PRIVACY_VERDICT and MAC_GATE_SCRIPT point the test at other copies (used to prove it red).
#
# Exit: 0 = every case behaved as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
VERDICT="${PRIVACY_VERDICT:-$repo_root/scripts/privacy-manifest-verdict.py}"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
APP_MANIFEST="$repo_root/Support/MemosNG/PrivacyInfo.xcprivacy"
EXT_MANIFEST="$repo_root/Support/MemosShare/PrivacyInfo.xcprivacy"
UD=NSPrivacyAccessedAPICategoryUserDefaults
FT=NSPrivacyAccessedAPICategoryFileTimestamp

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is not on PATH"; exit 1; }
for f in "$VERDICT" "$GATE" "$APP_MANIFEST" "$EXT_MANIFEST"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; exit 1; }
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-privacy-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
ok()  { cases=$((cases + 1)); echo "ok   $1"; }
bad() { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

# Writes an edited copy of a manifest. $1 = source, $2 = destination, $3 = a python expression over
# `p` (the parsed manifest) that edits it in place.
edited() {
  python3 - "$1" "$2" "$3" <<'PY'
import plistlib, sys
src, dst, edit = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "rb") as handle:
    p = plistlib.load(handle)
def entry(category):
    for e in p.get("NSPrivacyAccessedAPITypes", []):
        if e.get("NSPrivacyAccessedAPIType") == category:
            return e
    raise SystemExit("no %s entry in %s" % (category, src))
exec(edit)
with open(dst, "wb") as handle:
    plistlib.dump(p, handle)
PY
}
reasons_of() { # $1 = manifest, $2 = category: the declared reasons, one per line
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    p = plistlib.load(handle)
for e in p.get("NSPrivacyAccessedAPITypes", []):
    if e.get("NSPrivacyAccessedAPIType") == sys.argv[2]:
        print("\n".join(e.get("NSPrivacyAccessedAPITypeReasons", [])))
PY
}

accepts() { # $1 = case label, $2 = bundle label, $3 = manifest
  local out rc
  out="$(python3 "$VERDICT" "$2" "$3" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'BUNDLE FAIL'; then ok "$1: accepted"
  else bad "$1: expected exit 0 and no BUNDLE FAIL, got exit $rc"; show "$out"; fi
}
refuses() { # $1 = case label, $2 = bundle label, $3 = manifest, $4... = strings the refusal must name
  local label="$1" bundle="$2" manifest="$3" out rc needle; shift 3
  out="$(python3 "$VERDICT" "$bundle" "$manifest" 2>&1)"; rc=$?
  if [ "$rc" -ne 1 ]; then bad "$label: expected exit 1, got $rc"; show "$out"; return; fi
  for needle in "BUNDLE FAIL: $bundle " "$@"; do
    if ! printf '%s\n' "$out" | grep 'BUNDLE FAIL' | grep -qF -- "$needle"; then
      bad "$label: exit 1, but no BUNDLE FAIL line names '$needle'"; show "$out"; return
    fi
  done
  ok "$label: refused, naming the bundle and $*"
}

# --- the control: the manifests as tracked hold ---------------------------------------------------
app_reasons="$(reasons_of "$APP_MANIFEST" "$UD")"
ext_reasons="$(reasons_of "$EXT_MANIFEST" "$UD")"
if [ -n "$app_reasons" ] && [ -n "$ext_reasons" ]; then
  ok "control: both tracked manifests declare user-defaults reasons ($(echo $app_reasons) / $(echo $ext_reasons))"
else
  bad "control: a tracked manifest declares no user-defaults reasons — the cases below prove nothing"
fi
accepts "the tracked app manifest" app "$APP_MANIFEST"
accepts "the tracked extension manifest" extension "$EXT_MANIFEST"

# --- each bundle, each way of losing the entry ----------------------------------------------------
for pair in "app:$APP_MANIFEST" "extension:$EXT_MANIFEST"; do
  bundle="${pair%%:*}"; manifest="${pair#*:}"
  edited "$manifest" "$tmp/$bundle-no-ud.plist" \
    "p['NSPrivacyAccessedAPITypes'] = [e for e in p['NSPrivacyAccessedAPITypes'] if e.get('NSPrivacyAccessedAPIType') != '$UD']"
  refuses "$bundle without the user-defaults entry" "$bundle" "$tmp/$bundle-no-ud.plist" "no user-defaults entry" "$UD"
  while IFS= read -r reason; do
    [ -n "$reason" ] || continue
    edited "$manifest" "$tmp/$bundle-no-$reason.plist" \
      "entry('$UD')['NSPrivacyAccessedAPITypeReasons'].remove('$reason')"
    refuses "$bundle without user-defaults reason $reason" "$bundle" "$tmp/$bundle-no-$reason.plist" "missing $reason"
  done <<< "$(reasons_of "$manifest" "$UD")"
  edited "$manifest" "$tmp/$bundle-extra.plist" "entry('$UD')['NSPrivacyAccessedAPITypeReasons'].append('AC6B.1')"
  refuses "$bundle with an undeclared user-defaults reason" "$bundle" "$tmp/$bundle-extra.plist" "not expected AC6B.1"
  edited "$manifest" "$tmp/$bundle-twice.plist" "p['NSPrivacyAccessedAPITypes'].append(dict(entry('$UD')))"
  refuses "$bundle declaring user-defaults twice" "$bundle" "$tmp/$bundle-twice.plist" "user-defaults category 2 times"
  edited "$manifest" "$tmp/$bundle-reordered.plist" "entry('$UD')['NSPrivacyAccessedAPITypeReasons'].reverse()"
  accepts "$bundle with its user-defaults reasons in another order" "$bundle" "$tmp/$bundle-reordered.plist"
  # What the step held before this verdict still holds.
  edited "$manifest" "$tmp/$bundle-no-ft.plist" \
    "p['NSPrivacyAccessedAPITypes'] = [e for e in p['NSPrivacyAccessedAPITypes'] if e.get('NSPrivacyAccessedAPIType') != '$FT']"
  refuses "$bundle without the file-timestamp entry" "$bundle" "$tmp/$bundle-no-ft.plist" "no file-timestamp entry"
  edited "$manifest" "$tmp/$bundle-tracking.plist" "p['NSPrivacyTracking'] = True"
  refuses "$bundle claiming tracking" "$bundle" "$tmp/$bundle-tracking.plist" "NSPrivacyTracking is True"
done

refuses "a bundle with no manifest" app "$tmp/absent.plist" "has no PrivacyInfo.xcprivacy"
printf 'not a plist\n' > "$tmp/garbage.plist"
refuses "a manifest that does not parse" extension "$tmp/garbage.plist" "does not parse"
out="$(python3 "$VERDICT" watch "$APP_MANIFEST" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "a bundle label the gate does not read back is a usage error (exit 2)"
else bad "an unknown bundle label: expected exit 2, got $rc"; show "$out"; fi

# --- the gate calls it ----------------------------------------------------------------------------
# The read-back script is cut out of the gate's own text and run over two fake bundles holding the
# tracked manifests, then again with the app's user-defaults entry gone: a gate that had stopped
# handing the manifest to the verdict would pass the second run.
step_py="$tmp/bundlecheck.py"
awk '/<<.PY.$/ && /"\$privacy_verdict"/ { f = 1; next } f && /^PY$/ { exit } f { print }' "$GATE" > "$step_py"
if [ -s "$step_py" ] && grep -q 'PRIVACY_VERDICT' "$step_py"; then
  ok "control: the read-back script was cut out of the gate ($(wc -l < "$step_py" | tr -d ' ') lines)"
else
  bad "cannot find the read-back script that hands \$privacy_verdict to python in $GATE"
fi
fake_bundle() { # $1 = dir, $2 = bundle id, $3 = manifest
  mkdir -p "$1"
  cp "$3" "$1/PrivacyInfo.xcprivacy"
  python3 - "$1/Info.plist" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as handle:
    plistlib.dump({"CFBundleIdentifier": sys.argv[2], "CFBundleShortVersionString": "9.9.9",
                   "CFBundleVersion": "999", "ITSAppUsesNonExemptEncryption": False}, handle)
PY
}
app_dir="$tmp/good/MemosNG.app"
fake_bundle "$app_dir" live.discomarder.memosng "$APP_MANIFEST"
fake_bundle "$app_dir/PlugIns/MemosShare.appex" live.discomarder.memosng.share "$EXT_MANIFEST"
out="$(python3 "$step_py" "$app_dir" "$app_dir/PlugIns/MemosShare.appex" 9.9.9 "$VERDICT" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'BUNDLE FAIL'; then
  ok "the gate's read-back passes two bundles carrying the tracked manifests"
else
  bad "the gate's read-back refused the tracked manifests (exit $rc)"; show "$out"
fi
bad_dir="$tmp/bad/MemosNG.app"
fake_bundle "$bad_dir" live.discomarder.memosng "$tmp/app-no-ud.plist"
fake_bundle "$bad_dir/PlugIns/MemosShare.appex" live.discomarder.memosng.share "$EXT_MANIFEST"
out="$(python3 "$step_py" "$bad_dir" "$bad_dir/PlugIns/MemosShare.appex" 9.9.9 "$VERDICT" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "BUNDLE FAIL: app declares no user-defaults entry"; then
  ok "the gate's read-back fails an app bundle without the user-defaults entry, naming it"
else
  bad "the gate's read-back let an app bundle without the user-defaults entry through (exit $rc)"; show "$out"
fi
ext_bad_dir="$tmp/bad-ext/MemosNG.app"
fake_bundle "$ext_bad_dir" live.discomarder.memosng "$APP_MANIFEST"
fake_bundle "$ext_bad_dir/PlugIns/MemosShare.appex" live.discomarder.memosng.share "$tmp/extension-no-ud.plist"
out="$(python3 "$step_py" "$ext_bad_dir" "$ext_bad_dir/PlugIns/MemosShare.appex" 9.9.9 "$VERDICT" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "BUNDLE FAIL: extension declares no user-defaults entry"; then
  ok "the gate's read-back fails an extension bundle without the user-defaults entry, naming it"
else
  bad "the gate's read-back let an extension bundle without the user-defaults entry through (exit $rc)"; show "$out"
fi

echo "gate privacy manifest: $((cases - fails)) of $cases checks passed"
[ "$fails" -eq 0 ]
