#!/usr/bin/env bash
#
# The build host's mount guard — scripts/gate-mount-guard.sh — driven against a throwaway build
# root and fake readers that serve REAL plists captured from the host (tests/gate/fixtures/
# mount-guard/, read 2026-10-01: the image attached-unmounted, detached, mounted at a preparation
# path, the data volume, and a plain directory's Error answer). A healthy mount at the root is the
# preparation capture with its mount path rewritten to the root: the same volume, the same
# devices, mounted elsewhere. Every case reads the helper's own verdict and exit code.
#
# The root is a literal in the helper (no environment may move it), so the helper under test is a
# copy whose one GATE_MG_ROOT line is rewritten to the throwaway root; the suite refuses to run if
# that line is not found exactly once. GATE_MOUNT_GUARD_SCRIPT points it at another copy (the
# mutation proofs). Exit: 0 = every case behaved as expected; 1 = at least one did not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GUARD="${GATE_MOUNT_GUARD_SCRIPT:-$repo_root/scripts/gate-mount-guard.sh}"
FIX="$here/fixtures/mount-guard"
[ -r "$GUARD" ] || { echo "FAIL: $GUARD is not readable"; exit 1; }
export LC_ALL=C

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mount-guard-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

fails=0; cases=0
ok()  { cases=$((cases + 1)); echo "ok   $1"; }
bad() { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }

M="$tmp/build"; H="$tmp/home"; F="$tmp/fake"; PREP=/Users/fabian/.merkur_build_prep
UUID=EE4304C8-021C-489D-B57B-6D846E76B1CF
HOST_UUID=ABED54FD-4031-53B1-9951-E8FF4DE51F69
mkdir -p "$F" "$tmp/bin" "$H"

# --- the helper under test, its root moved to the throwaway one ----------------------------------
n="$(grep -c '^GATE_MG_ROOT=/Users/fabian/build$' "$GUARD")"
[ "$n" = 1 ] || { echo "FAIL: VOID — the GATE_MG_ROOT literal is present $n times in $GUARD, not once"; exit 1; }
sed "s|^GATE_MG_ROOT=/Users/fabian/build\$|GATE_MG_ROOT=$M|" "$GUARD" > "$tmp/guard.sh"

# --- the fakes -----------------------------------------------------------------------------------
# plutil -extract <keypath> raw|xml1 -o - <file|->: macOS plutil's formats (raw: strings bare,
# booleans true/false, arrays and dictionaries their count; xml1: the value as a plist), a missing
# path real plutil's text and exit 1. $F/plutil-hang (a keypath suffix) hangs that extraction;
# $F/plutil-fail ("<keypath suffix> <rc>") fails it with that same text, as real plutil does for
# a missing key, a bad index and unparsable input alike.
cat > "$tmp/bin/plutil" <<'EOF'
#!/usr/bin/env python3
import os, plistlib, sys, time
a = sys.argv[1:]
if len(a) != 6 or a[0] != '-extract' or a[2] not in ('raw', 'xml1') or a[3] != '-o' or a[4] != '-':
    sys.stderr.write('fake plutil: unsupported %r\n' % a); sys.exit(2)
fake = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), '..', 'fake')
def hook(name):
    try: return open(os.path.join(fake, name)).read().split()
    except OSError: return None
miss = '<stdin>: Could not extract value, error: No value at that key path or invalid key path: %s\n' % a[1]
h = hook('plutil-hang')
if h and a[1].endswith(h[0]): time.sleep(30)
f = hook('plutil-fail')
if f and a[1].endswith(f[0]): sys.stderr.write(miss); sys.exit(int(f[1]))
try:
    d = plistlib.loads(sys.stdin.buffer.read() if a[5] == '-' else open(a[5], 'rb').read())
    for k in a[1].split('.'):
        d = d[int(k)] if isinstance(d, list) else d[k]
except Exception:
    sys.stderr.write(miss); sys.exit(1)
if a[2] == 'xml1': sys.stdout.buffer.write(plistlib.dumps(d, fmt=plistlib.FMT_XML)); sys.exit(0)
if isinstance(d, bool): print('true' if d else 'false')
elif isinstance(d, (list, dict)): print(len(d))
else: print(d)
EOF
# diskutil info -plist <path> / hdiutil info -plist: the plist in $F/<tool>.plist; $F/<tool>-rc
# exits with that code after printing it; $F/<tool>-sleep hangs first.
for tool in diskutil hdiutil; do
  cat > "$tmp/bin/$tool" <<EOF
#!/usr/bin/env bash
[ ! -e "$F/$tool-sleep" ] || sleep "\$(cat "$F/$tool-sleep")"
[ ! -e "$F/$tool.plist" ] || cat "$F/$tool.plist"
[ ! -e "$F/$tool-rc" ] || exit "\$(cat "$F/$tool-rc")"
exit 0
EOF
done
# stat -f %d <path>: the device of the path itself (BSD stat does not follow the last symlink).
# $F/dev/<path with / as _> overrides one path; under the root while $F/mounted exists the image's
# device; otherwise the internal volume's. $F/stat-fail fails every call; $F/stat-fail-path fails
# the one path it names, after printing that path's plausible device.
cat > "$tmp/bin/stat" <<EOF
#!/usr/bin/env bash
[ "\$1" = -f ] && [ "\$2" = %d ] || { echo "fake stat: unsupported \$*" >&2; exit 2; }
[ ! -e "$F/stat-fail" ] || { echo 16777234; exit 1; }
p="\$3"
[ ! -e "$F/stat-fail-path" ] || [ "\$p" != "\$(cat "$F/stat-fail-path")" ] || { echo 16777247; exit 1; }
[ -e "\$p" ] || [ -L "\$p" ] || { echo "stat: \$p: stat: No such file or directory" >&2; exit 1; }
o="$F/dev/\$(printf '%s' "\$p" | tr / _)"
if [ -e "\$o" ]; then cat "\$o"
elif [ -e "$F/mounted" ] && { [ "\$p" = "$M" ] || [ "\${p#$M/}" != "\$p" ]; }; then echo 16777247
else echo 16777234
fi
EOF
cat > "$tmp/bin/ioreg" <<EOF
#!/usr/bin/env bash
[ ! -e "$F/ioreg-fail" ] || exit 1
printf '+-o J414sAP  <class IOPlatformExpertDevice, id 0x100000237, registered, matched, active, busy 0 (0 ms), retain 39>\n  {\n'
printf '    "IOPlatformUUID" = "%s"\n  }\n' "\$(cat "$F/host-uuid")"
EOF
chmod +x "$tmp/bin/"*

# --- scenario builders ----------------------------------------------------------------------------
reset() {
  rm -rf "$F" "$M" "$H/.config"; mkdir -p "$F" "$M"
  echo "$HOST_UUID" > "$F/host-uuid"
}
healthy() {   # the image mounted at the root, populated
  reset
  sed "s|<string>$PREP</string>|<string>$M</string>|" "$FIX/diskutil-info-prep-mount.plist" > "$F/diskutil.plist"
  sed "s|<string>$PREP</string>|<string>$M</string>|" "$FIX/hdiutil-info-mounted-prep.plist" > "$F/hdiutil.plist"
  touch "$F/mounted"; mkdir -p "$M/memos-ng-ios/gate" "$M/img-manager-ios/gate" "$M/quarantine-pre602"
}
plain() {     # today: the plain directory, the image detached, its sentinel visible
  reset
  cp "$FIX/diskutil-info-home-dir.plist" "$F/diskutil.plist"; echo 1 > "$F/diskutil-rc"
  cp "$FIX/hdiutil-info-detached.plist" "$F/hdiutil.plist"
  touch "$M/.NOT-MOUNTED-merkur_build"
}
edit() { sed -i "$2" "$F/$1.plist"; }
marker() {    # marker <host> <created offset s> <expires offset s> [extra line]
  local now; now="$(date -u +%s)"
  mkdir -p "$H/.config/build-mount-guard"
  printf 'host=%s\ncreated=%s\nexpires=%s\n' "$1" "$((now + $2))" "$((now + $3))" > "$H/.config/build-mount-guard/pending"
  [ -z "${4:-}" ] || printf '%s\n' "$4" >> "$H/.config/build-mount-guard/pending"
}
OUT=""; RC=""
# The helper holds no inventory; the build host's mount wrapper hands it this one
# (scripts/merkur/build-image-mount.sh, BUILD_IMAGE_SUBTREES), so the cases below prove it too.
INV="memos-ng-ios/gate memos-ng-ios/work img-manager-ios/gate repaso-es-ios/gate.noindex repaso-es-ios/work.noindex repaso-es-ios/scratch.noindex mardermusic-ios/gate"
raw() {       # raw <arguments…>: the helper run with exactly these arguments
  OUT="$(env HOME="$H" GATE_MG_STAT="$tmp/bin/stat" GATE_MG_DISKUTIL="$tmp/bin/diskutil" \
    GATE_MG_HDIUTIL="$tmp/bin/hdiutil" GATE_MG_IOREG="$tmp/bin/ioreg" GATE_MG_PLUTIL="$tmp/bin/plutil" \
    GATE_MG_READ_S="${READ_S:-10}" bash "$tmp/guard.sh" "$@" 2>&1)"; RC=$?
}
run() {       # run <mode> [subtree…]: a mode alone is handed $INV, as the wrapper hands it
  # shellcheck disable=SC2086
  if [ "$#" -eq 1 ]; then raw "$1" $INV; else raw "$@"; fi
}
line() { printf '%s\n' "$OUT" | sed -n "${1}p"; }
expect() {    # expect <name> <rc> <line-1 glob> <line-2 glob>
  # shellcheck disable=SC2053
  if [ "$RC" = "$2" ] && [[ "$(line 1)" == $3 ]] && [[ "$(line 2)" == $4 ]] && [ -z "$(line 3)" ]; then ok "$1"; else bad "$1 (rc $RC)"; fi
}
REF="MOUNT REFUSE *recovery*launchctl kickstart -k gui/*/live.discomarder.merkur-build-image"

# --- the predicate, enforce mode ---------------------------------------------------------------------
healthy; run enforce
expect "healthy mount at the root -> MOUNT OK, rc 0" 0 "MOUNT OK uuid=$UUID dev=/dev/disk8s1" "mountguard=enforced marker=not-read"
plain; run enforce
expect "(a) today's plain folder (diskutil: Could not find disk) -> refuse 16" 16 "$REF" "mountguard=enforced marker=not-read"
healthy; edit diskutil "s|$UUID|E61B4BEF-3A44-41C5-B945-41A37E2504D2|"; run enforce
expect "(b) right name, wrong UUID -> refuse" 16 "MOUNT REFUSE volume UUID*E61B4BEF*" "mountguard=enforced*"
healthy; edit diskutil "s|$UUID|${UUID}X|"; run enforce
expect "(i) UUID with a suffix -> refuse (literal match only)" 16 "MOUNT REFUSE volume UUID*" "mountguard=enforced*"
healthy; edit diskutil "s|$UUID|${UUID%?}|"; run enforce
expect "(i) UUID prefix -> refuse" 16 "MOUNT REFUSE volume UUID*" "mountguard=enforced*"
healthy; sed "s|<string>/System/Volumes/Data</string>|<string>$M</string>|" "$FIX/diskutil-info-data-volume.plist" > "$F/diskutil.plist"; run enforce
expect "the internal data volume mounted at the root (captured) -> refuse" 16 "MOUNT REFUSE volume UUID*" "mountguard=enforced*"
healthy; edit diskutil "s|<string>apfs</string>|<string>hfs</string>|"; run enforce
expect "(c) right UUID, not apfs -> refuse" 16 "MOUNT REFUSE filesystem*hfs*" "mountguard=enforced*"
healthy; cp "$FIX/diskutil-info-prep-mount.plist" "$F/diskutil.plist"; run enforce
expect "the volume mounted at another path -> refuse" 16 "MOUNT REFUSE the volume is mounted at*merkur_build_prep*" "mountguard=enforced*"
healthy; python3 - "$F/diskutil.plist" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb')); d['GlobalPermissionsEnabled'] = False
plistlib.dump(d, open(sys.argv[1], 'wb'))
EOF
run enforce
expect "(e) ownership disabled -> refuse" 16 "MOUNT REFUSE ownership is not enabled*false*" "mountguard=enforced*"
healthy; edit diskutil "/<key>GlobalPermissionsEnabled<\/key>/{N;d}"; run enforce
expect "ownership field missing -> refuse" 16 "MOUNT REFUSE *no GlobalPermissionsEnabled*" "mountguard=enforced*"
healthy; edit hdiutil "s|merkur_build.sparsebundle|merkur_build-copy.sparsebundle|"; run enforce
expect "(d) the volume attached from another image-path -> refuse" 16 "MOUNT REFUSE *is not attached*" "mountguard=enforced*"
healthy; cp "$FIX/hdiutil-info-detached.plist" "$F/hdiutil.plist"; run enforce
expect "the bundle not attached at all -> refuse" 16 "MOUNT REFUSE *is not attached*" "mountguard=enforced*"
healthy; edit diskutil "s|<string>/dev/disk8s1</string>|<string>/dev/disk8s10</string>|"; run enforce
expect "DeviceNode /dev/disk8s10 vs entity /dev/disk8s1 -> refuse (complete dev-entry, no prefix)" 16 "MOUNT REFUSE /dev/disk8s10 is not an entity*" "mountguard=enforced*"
healthy; edit diskutil "s|<string>/dev/disk8s1</string>|<string>/dev/disk5s1</string>|"; run enforce
expect "DeviceNode of the OTHER attached image (simulator runtime) -> refuse" 16 "MOUNT REFUSE /dev/disk5s1 is not an entity*" "mountguard=enforced*"
healthy; rm "$F/mounted"; run enforce
expect "(a) same device as \$HOME -> refuse" 16 "MOUNT REFUSE *same device as*" "mountguard=enforced*"
healthy; touch "$M/.NOT-MOUNTED-merkur_build"; run enforce
expect "(f) sentinel visible -> refuse" 16 "MOUNT REFUSE *.NOT-MOUNTED-merkur_build is visible*" "mountguard=enforced*"
healthy; ln -s "$tmp/elsewhere" "$M/.NOT-MOUNTED-merkur_build"; run enforce
expect "(f) sentinel as a dangling symlink still counts as visible -> refuse" 16 "MOUNT REFUSE *is visible*" "mountguard=enforced*"

# --- (e) root containment ---------------------------------------------------------------------------
healthy; rm -rf "$M/memos-ng-ios"; mkdir -p "$tmp/elsewhere/memos-ng-ios"; ln -s "$tmp/elsewhere/memos-ng-ios" "$M/memos-ng-ios"; run enforce
expect "(n) M/memos-ng-ios a symlink to a directory elsewhere -> refuse" 16 "MOUNT REFUSE $M/memos-ng-ios is a symlink*" "mountguard=enforced*"
healthy; mkdir -p "$tmp/elsewhere/work"; ln -s "$tmp/elsewhere/work" "$M/memos-ng-ios/work"; run enforce
expect "(o) M/memos-ng-ios/work a symlink -> refuse" 16 "MOUNT REFUSE $M/memos-ng-ios/work is a symlink*" "mountguard=enforced*"
healthy; mkdir -p "$tmp/m2"; ln -s ../build/memos-ng-ios "$tmp/m2/link"; rm -rf "$M/repaso-es-ios"; ln -s "../m2/link" "$M/repaso-es-ios"; run enforce
expect "(r) a relative, chained link that resolves back under M is still a symlink -> refuse" 16 "MOUNT REFUSE $M/repaso-es-ios is a symlink*" "mountguard=enforced*"
healthy; mkdir -p "$F/dev"; echo 16777234 > "$F/dev/$(printf '%s' "$M/memos-ng-ios/gate" | tr / _)"; run enforce
expect "(p) an existing component on another device -> refuse" 16 "MOUNT REFUSE $M/memos-ng-ios/gate is on device 16777234*" "mountguard=enforced*"
healthy; rm -rf "$M/memos-ng-ios" "$M/img-manager-ios"; run enforce
expect "(q) components missing below a verified ancestor -> OK" 0 "MOUNT OK *" "mountguard=enforced*"
healthy; rm -rf "$M/memos-ng-ios/gate"; touch "$M/memos-ng-ios/gate"; run enforce
expect "a component that is a file, not a directory -> refuse" 16 "MOUNT REFUSE $M/memos-ng-ios/gate does not resolve*" "mountguard=enforced*"
healthy; mkdir -p "$tmp/elsewhere/r"; ln -s "$tmp/elsewhere/r" "$M/repaso-es-ios"; run enforce -
expect "'-' checks the volume identity only -> OK despite a symlinked repo root" 0 "MOUNT OK *" "mountguard=enforced*"
healthy; mkdir -p "$tmp/elsewhere/r"; ln -s "$tmp/elsewhere/r" "$M/repaso-es-ios"; run enforce memos-ng-ios/gate memos-ng-ios/work
expect "named subtrees only: memos's subtree is checked, repaso's link is not its business -> OK" 0 "MOUNT OK *" "mountguard=enforced*"
healthy; run enforce memos-ng-ios/../..
expect "a subtree with .. -> refuse" 16 "MOUNT REFUSE subtree*not a plain relative path*" "mountguard=enforced*"
healthy; run enforce /etc
expect "an absolute subtree -> refuse" 16 "MOUNT REFUSE subtree*not a plain relative path*" "mountguard=enforced*"
healthy; mv "$M" "$tmp/build.real"; ln -s "$tmp/build.real" "$M"; run enforce
expect "the root itself a symlink -> refuse" 16 "MOUNT REFUSE $M is a symlink*" "mountguard=enforced*"
rm -f "$M"

# --- readers that fail, hang, or print nothing ------------------------------------------------------
healthy; echo 1 > "$F/diskutil-rc"; run enforce
expect "(g) diskutil exits 1 after plausible output -> refuse" 16 "MOUNT REFUSE diskutil info*failed*" "mountguard=enforced*"
healthy; echo 5 > "$F/diskutil-sleep"; t0=$(date +%s); READ_S=1 run enforce; el=$(( $(date +%s) - t0 ))
if [ "$el" -lt 4 ]; then expect "(g) diskutil hangs past the deadline -> refuse within it (${el}s)" 16 "MOUNT REFUSE diskutil info*rc 142*" "mountguard=enforced*"; else bad "(g) diskutil hang took ${el}s, the deadline was 1s"; fi
healthy; : > "$F/diskutil.plist"; run enforce
expect "(g) diskutil prints nothing -> refuse" 16 "MOUNT REFUSE diskutil info*printed nothing*" "mountguard=enforced*"
healthy; echo 1 > "$F/hdiutil-rc"; run enforce
expect "(g) hdiutil exits 1 after plausible output -> refuse" 16 "MOUNT REFUSE image attachment unmeasured: hdiutil info failed*" "mountguard=enforced*"
healthy; echo 5 > "$F/hdiutil-sleep"; t0=$(date +%s); READ_S=1 run enforce; el=$(( $(date +%s) - t0 ))
if [ "$el" -lt 4 ]; then expect "(g) hdiutil hangs past the deadline -> refuse within it (${el}s)" 16 "MOUNT REFUSE image attachment unmeasured*rc 142*" "mountguard=enforced*"; else bad "(g) hdiutil hang took ${el}s"; fi
healthy; printf 'not a plist\n' > "$F/hdiutil.plist"; run enforce
expect "(g) hdiutil prints garbage -> refuse" 16 "MOUNT REFUSE image attachment unmeasured*" "mountguard=enforced*"
healthy; touch "$F/stat-fail"; run enforce
expect "(g) stat fails -> refuse" 16 "MOUNT REFUSE stat of*failed*" "mountguard=enforced*"
healthy; printf '%s' "$M" > "$F/stat-fail-path"; run enforce -
expect "(g) the stat of the root alone fails, volume identity only ('-') -> refuse" 16 "MOUNT REFUSE stat of $M failed*" "mountguard=enforced*"
healthy; printf '%s' "$M" > "$F/stat-fail-path"; run enforce
expect "(g) the stat of the root alone fails, the inventory named -> refuse at the root's stat" 16 "MOUNT REFUSE stat of $M failed*" "mountguard=enforced*"
healthy; OUT="$(env HOME="$H" GATE_MG_STAT="$tmp/bin/stat" GATE_MG_DISKUTIL="$tmp/bin/diskutil" GATE_MG_HDIUTIL="$tmp/bin/hdiutil" \
  GATE_MG_PLUTIL="$tmp/no-such-plutil" bash "$tmp/guard.sh" enforce $INV 2>&1)"; RC=$?
expect "(g) the plist reader missing -> refuse" 16 "MOUNT REFUSE *no VolumeUUID*" "mountguard=enforced*"

# --- the pending marker (report mode) -----------------------------------------------------------------
plain; marker "$HOST_UUID" -60 86400; run report
expect "(j) valid marker + plain folder -> pending:REFUSE, rc 0" 0 "$REF" "mountguard=pending:REFUSE marker=valid"
healthy; marker "$HOST_UUID" -60 86400; run report
expect "valid marker + healthy mount -> pending:OK, rc 0" 0 "MOUNT OK *" "mountguard=pending:OK marker=valid"
plain; marker "$HOST_UUID" 0 259200; run report
expect "window exactly 72 h -> valid" 0 "$REF" "mountguard=pending:REFUSE marker=valid"
plain; run report
expect "marker missing -> enforce, rc 16" 16 "$REF" "mountguard=enforced marker=missing"
plain; marker "$HOST_UUID" -86400 -1; run report
expect "(k) marker expired -> enforce" 16 "$REF" "mountguard=enforced marker=expired"
plain; marker "$HOST_UUID" -100 0; run report
expect "(k) marker expiring this second (now = expires) -> enforce" 16 "$REF" "mountguard=enforced marker=expired"
plain; marker 00000000-1111-2222-3333-444444444444 -60 86400; run report
expect "(l) marker of another host -> enforce" 16 "$REF" "mountguard=enforced marker=other-host"
plain; marker "$HOST_UUID" -60 259201; run report
expect "(m) window over 72 h -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:window-over-72h"
plain; marker "$HOST_UUID" 600 3600; run report
expect "(m) created in the future -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:created-in-future"
plain; marker "$HOST_UUID" -60 86400 "note=extra"; run report
expect "(m) a fourth line -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:key-note"
plain; marker "$HOST_UUID" -60 86400 "expires=99999999999"; run report
expect "(m) a key twice -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:expires-twice"
plain; marker "$HOST_UUID" -60 86400; sed -i 's/^created=.*/created=yesterday/' "$H/.config/build-mount-guard/pending"; run report
expect "(m) a non-numeric epoch -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:epoch"
# A leading zero is octal to $((…)) and decimal to [ -gt ]: 02000000000 passes '> created' as two
# billion yet makes the window negative, so it would pass the 72 h bound.
plain; marker "$HOST_UUID" -60 86400; sed -i 's/^expires=.*/expires=02000000000/' "$H/.config/build-mount-guard/pending"; run report
expect "(m) an expires with a leading zero (octal to \$((…))) -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:epoch"
plain; marker "$HOST_UUID" -60 86400; sed -i 's/^created=.*/created=01700000000/' "$H/.config/build-mount-guard/pending"; run report
expect "(m) a created with a leading zero -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:epoch"
plain; marker "$HOST_UUID" -60 86400; sed -i -e 's/^created=.*/created=0/' -e 's/^expires=.*/expires=1/' "$H/.config/build-mount-guard/pending"; run report
expect "(m) the single digit 0 is still an epoch (created=0 expires=1 -> expired, not malformed)" 16 "$REF" "mountguard=enforced marker=expired"
plain; marker "host=$HOST_UUID" -60 86400; run report
expect "(m) host value with an embedded 'host=' -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:host"
plain; mkdir -p "$H/.config/build-mount-guard"; : > "$H/.config/build-mount-guard/pending"; run report
expect "(m) empty marker -> enforce" 16 "$REF" "mountguard=enforced marker=malformed:0-lines"
plain; marker "$HOST_UUID" -60 86400; chmod 000 "$H/.config/build-mount-guard/pending"
if [ "$(id -u)" -ne 0 ]; then run report; expect "(m) unreadable marker -> enforce" 16 "$REF" "mountguard=enforced marker=unreadable"; else ok "(m) unreadable marker: skipped as root"; fi
chmod 600 "$H/.config/build-mount-guard/pending"
plain; marker "$HOST_UUID" -60 86400; touch "$F/ioreg-fail"; run report
expect "the host UUID unreadable -> enforce" 16 "$REF" "mountguard=enforced marker=unmeasured:ioreg"
plain; marker "$HOST_UUID" -60 86400; run enforce
expect "enforce mode ignores a valid marker -> rc 16" 16 "$REF" "mountguard=enforced marker=not-read"
plain; run bogus
expect "an unknown mode -> refuse 16" 16 "MOUNT REFUSE usage*" "mountguard=enforced marker=not-read"
plain; run
expect "no mode -> refuse 16" 16 "MOUNT REFUSE usage*" "mountguard=enforced marker=not-read"
USAGE_NONE="MOUNT REFUSE usage: gate_mount_guard <enforce|report> <subtree…|-> (no subtree given)"
healthy; raw enforce
expect "a mode with no subtree and no '-' -> usage refusal 16 even on a healthy mount (no default inventory)" 16 "$USAGE_NONE" "mountguard=enforced marker=not-read"
plain; marker "$HOST_UUID" -60 86400; raw report
expect "report with no subtree and a valid marker -> usage refusal 16, never softened to pending" 16 "$USAGE_NONE" "mountguard=enforced marker=not-read"
healthy; raw enforce ''
expect "an empty subtree argument -> refuse 16 (not read as 'none given', not as the root)" 16 "MOUNT REFUSE subtree '' is not a plain relative path*" "mountguard=enforced*"
n="$(grep -cE 'memos|img-manager|repaso|mardermusic' "$GUARD")"; c="$(grep -c '^GATE_MG_UUID=EE4304C8-021C-489D-B57B-6D846E76B1CF$' "$GUARD")"
OUT="project names: $n, control GATE_MG_UUID lines: $c"
if [ "$n" = 0 ] && [ "$c" = 1 ]; then ok "the helper names no project, so every repo vendors it byte-identical (control: its UUID literal found once)"; else bad "the helper names a project"; fi

# --- the mount-point reading: only a key ABSENT from the entity means "not mounted" ---------------
# real plutil answers a missing key, a bad index and unparsable input with one text and exit 1, so a
# failed extraction may never be read as "no mount point": a mounted image would look detachable.
healthy; echo mount-point > "$F/plutil-hang"; READ_S=1 run enforce
expect "a mount-point read that hangs past the deadline -> refuse unmeasured (rc 142), never 'unmounted'" 16 "MOUNT REFUSE image attachment unmeasured: image * entity * mount-point unreadable (rc 142)*" "mountguard=enforced*"
healthy; echo 'mount-point 1' > "$F/plutil-fail"; run enforce
expect "a mount-point read failing with plutil's missing-key text while the key is present -> refuse unmeasured" 16 "MOUNT REFUSE image attachment unmeasured: image * entity * mount-point unreadable (rc 1)*" "mountguard=enforced*"
healthy; echo 'system-entities.4 1' > "$F/plutil-fail"; run enforce
expect "an entity that cannot be extracted -> refuse unmeasured" 16 "MOUNT REFUSE image attachment unmeasured: image * entity 4 unreadable (rc 1)*" "mountguard=enforced*"
healthy; python3 - "$F/hdiutil.plist" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
img = [i for i in d['images'] if i['image-path'].endswith('/merkur_build.sparsebundle')][0]
[e for e in img['system-entities'] if 'mount-point' in e][0]['mount-point'] = ''
plistlib.dump(d, open(sys.argv[1], 'wb'))
EOF
run enforce
expect "a mount-point key with an empty value -> refuse unmeasured, not 'unmounted'" 16 "MOUNT REFUSE image attachment unmeasured: image * entity * mount-point is empty*" "mountguard=enforced*"
ents() {      # the helper sourced into bash -s, gate_mg_bundle_entities called: rc, why, entity lines
  OUT="$( { cat "$tmp/guard.sh"; echo 'rc=0; gate_mg_bundle_entities || rc=$?; echo "rc=$rc why=$GATE_MG_WHY"; printf "%s" "$GATE_MG_ENTS"'; } \
    | env HOME="$H" GATE_MG_HDIUTIL="$tmp/bin/hdiutil" GATE_MG_PLUTIL="$tmp/bin/plutil" GATE_MG_READ_S="${READ_S:-10}" bash -s 2>&1)"
}
healthy; echo mount-point > "$F/plutil-hang"; READ_S=1 ents
if [ "$(line 1)" = "rc=2 why=image 1 entity 4 mount-point unreadable (rc 142)" ]; then ok "gate_mg_bundle_entities: a hung mount-point read returns 2 with its reason"; else bad "bundle entities, hung mount-point"; fi
healthy; ents
if [ "$(line 1)" = "rc=0 why=" ] && printf '%s\n' "$OUT" | grep -qxF "/dev/disk8s1	$M"; then ok "gate_mg_bundle_entities: a present mount-point is read (/dev/disk8s1 at the root)"; else bad "bundle entities, mounted"; fi
reset; cp "$FIX/hdiutil-info-attached-unmounted.plist" "$F/hdiutil.plist"; ents
n="$(printf '%s\n' "$OUT" | sed -n '2,$p' | grep -c .)"; e="$(printf '%s\n' "$OUT" | sed -n '2,$p' | awk -F '\t' 'NF == 2 && $1 ~ /^\/dev\/disk[0-9]/ && $2 == ""' | grep -c .)"
if [ "$(line 1)" = "rc=0 why=" ] && [ "$n" = 5 ] && [ "$e" = 5 ]; then ok "gate_mg_bundle_entities: no mount-point key in any entity -> rc 0, five unmounted entities"; else bad "bundle entities, attached unmounted (lines $n, unmounted $e)"; fi
reset; python3 - "$FIX/hdiutil-info-attached-unmounted.plist" "$F/hdiutil.plist" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
img = [i for i in d['images'] if i['image-path'].endswith('/merkur_build.sparsebundle')][0]
img['system-entities'][0]['content-hint'] = '<key>mount-point</key>'
plistlib.dump(d, open(sys.argv[2], 'wb'))
EOF
ents
if [ "$(line 1)" = "rc=0 why=" ] && ! printf '%s\n' "$OUT" | sed -n '2,$p' | awk -F '\t' '$2 != ""' | grep -q .; then ok "a value spelling <key>mount-point</key> is not the key -> still unmounted, rc 0"; else bad "mount-point literal inside a value"; fi

# --- the forms a gate uses: concatenated into `bash -s`, and sourced ---------------------------------
healthy
OUT="$( { cat "$tmp/guard.sh"; echo 'gate_mount_guard enforce memos-ng-ios/gate memos-ng-ios/work; echo "rc=$?"'; } \
  | env HOME="$H" GATE_MG_STAT="$tmp/bin/stat" GATE_MG_DISKUTIL="$tmp/bin/diskutil" GATE_MG_HDIUTIL="$tmp/bin/hdiutil" \
    GATE_MG_PLUTIL="$tmp/bin/plutil" bash -s 2>&1)"
if [ "$(line 1)" = "MOUNT OK uuid=$UUID dev=/dev/disk8s1" ] && [ "$(line 3)" = "rc=0" ] && [ -z "$(line 4)" ]; then ok "piped into bash -s with the call appended: one verdict, no standalone run"; else bad "bash -s form"; fi
OUT="$(env HOME="$H" bash -c ". '$tmp/guard.sh'; type gate_mount_guard >/dev/null && echo sourced" 2>&1)"
if [ "$OUT" = sourced ]; then ok "sourcing defines the function and runs nothing"; else bad "sourced form"; fi
plain; OUT="$( { cat "$tmp/guard.sh"; echo 'set -e; gate_mount_guard enforce memos-ng-ios/gate; echo "rc=$?"'; } \
  | env HOME="$H" GATE_MG_STAT="$tmp/bin/stat" GATE_MG_DISKUTIL="$tmp/bin/diskutil" GATE_MG_HDIUTIL="$tmp/bin/hdiutil" \
    GATE_MG_PLUTIL="$tmp/bin/plutil" bash -s 2>&1)"; RC=$?
if [ "$RC" = 16 ] && [[ "$(line 1)" == "MOUNT REFUSE"* ]] && [ -z "$(line 3)" ]; then ok "under set -e the refusal still prints both lines and ends the caller with 16"; else bad "set -e form (rc $RC)"; fi

# --- the helper this project runs is the one recorded --------------------------------------------------
SOURCE_RECORD="$repo_root/scripts/GATE_MOUNT_GUARD_SOURCE"
if [ -r "$SOURCE_RECORD" ] && [ "$(wc -l < "$SOURCE_RECORD" | tr -d ' ')" -eq 1 ]; then
  recorded="$(sed -n 's/.*sha256=\([0-9a-f]\{64\}\).*/\1/p' "$SOURCE_RECORD")"
  if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "$repo_root/scripts/gate-mount-guard.sh" | awk '{print $1}')"
  else actual="$(shasum -a 256 "$repo_root/scripts/gate-mount-guard.sh" | awk '{print $1}')"; fi
  if [ -n "$recorded" ] && [ "$recorded" = "$actual" ]; then ok "scripts/gate-mount-guard.sh is the copy scripts/GATE_MOUNT_GUARD_SOURCE records (sha256 $actual)"
  else OUT=""; bad "scripts/gate-mount-guard.sh has sha256 $actual, scripts/GATE_MOUNT_GUARD_SOURCE records '${recorded:-nothing}'"; fi
else
  OUT=""; bad "scripts/GATE_MOUNT_GUARD_SOURCE is missing or is not exactly one line"
fi

echo "mount-guard-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
