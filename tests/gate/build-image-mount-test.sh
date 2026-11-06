#!/usr/bin/env bash
#
# The mount wrapper the LaunchAgent runs — scripts/merkur/build-image-mount.sh — driven against a
# throwaway root, volume and bundle, with fake hdiutil/diskutil/stat that keep one state (detached,
# attached, mounted) and answer with the REAL plists captured from the build host
# (tests/gate/fixtures/mount-guard/). A fake attach mounts by moving the root's directory aside
# and putting a fresh one in its place, so what the wrapper sees underneath and on top is real.
# Every case reads the wrapper's exit code, the hdiutil calls it made and the state it left.
#
# The paths are literals in the helper's two host profiles (merkur, mars), so the wrapper and the
# helper are copied side by side (the wrapper sources the helper beside itself) with each literal
# rewritten — the root in both profiles, each bundle in its own; the suite refuses to run if a
# literal is not found the expected number of times. The wrapper derives the bundle's volume and
# its log from the profile, so nothing in it is rewritten. A fake scutil names the host ($F/host,
# merkur unless a case says otherwise). GATE_MG_WRAPPER_SCRIPT points it at another copy of
# the wrapper (the mutation proofs W1-W3). Exit: 0 = every case behaved as expected; 1 otherwise.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
WRAPPER="${GATE_MG_WRAPPER_SCRIPT:-$repo_root/scripts/merkur/build-image-mount.sh}"
GUARD="$repo_root/scripts/gate-mount-guard.sh"
PLIST="$repo_root/scripts/merkur/live.discomarder.merkur-build-image.plist"
MARS_PLIST="$repo_root/scripts/mars/live.discomarder.mars-build-image.plist"
FIX="$here/fixtures/mount-guard"
for f in "$WRAPPER" "$GUARD" "$PLIST" "$MARS_PLIST"; do [ -r "$f" ] || { echo "FAIL: $f is not readable"; exit 1; }; done
export LC_ALL=C

tmp="$(mktemp -d "${TMPDIR:-/tmp}/build-image-mount-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

fails=0; cases=0; OUT=""
ok()  { cases=$((cases + 1)); echo "ok   $1"; }
bad() { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }

M="$tmp/build"; H="$tmp/home"; F="$tmp/fake"; VOL="$tmp/lexosaurus"
BUNDLE="$VOL/caches/merkur_build.sparsebundle"; REAL_BUNDLE=/Volumes/lexosaurus/caches/merkur_build.sparsebundle
PREP=/Users/fabian/.merkur_build_prep; SENT=.NOT-MOUNTED-merkur_build
UUID=EE4304C8-021C-489D-B57B-6D846E76B1CF; MARS_UUID=4FBC8F45-0C6B-45C4-AF86-411A2B7B2789
MERKUR_HW=ABED54FD-4031-53B1-9951-E8FF4DE51F69; MARS_HW=639B86D9-17FA-5EBE-8A66-530B948476BE
MVOL="$tmp/flexosaurus"; MBUNDLE="$MVOL/caches/mars_build.sparsebundle"
MARS_REAL_BUNDLE=/Volumes/flexosaurus/caches/mars_build.sparsebundle; MSENT=.NOT-MOUNTED-mars_build
mkdir -p "$tmp/bin" "$tmp/inst"

# --- the wrapper and its helper, side by side, their literals moved into the throwaway tree --------
subst() {   # subst <file> <literal line, indentation aside> <replacement> <times>: indentation kept
  local n; n="$(sed 's/^[[:space:]]*//' "$1" | grep -cxF "$2")"
  [ "$n" = "$4" ] || { echo "FAIL: VOID — '$2' is present $n times in $1, not $4"; exit 1; }
  python3 - "$1" "$2" "$3" <<'EOF'
import sys
p, a, b = sys.argv[1:]
t = open(p).read().split('\n')
open(p, 'w').write('\n'.join(l[:len(l) - len(l.lstrip())] + b if l.strip() == a else l for l in t))
EOF
}
cp "$WRAPPER" "$tmp/inst/build-image-mount.sh"; cp "$GUARD" "$tmp/inst/gate-mount-guard.sh"
subst "$tmp/inst/gate-mount-guard.sh" "GATE_MG_ROOT=/Users/fabian/build" "GATE_MG_ROOT=$M" 2
subst "$tmp/inst/gate-mount-guard.sh" "GATE_MG_BUNDLE=$REAL_BUNDLE" "GATE_MG_BUNDLE=$BUNDLE" 1
subst "$tmp/inst/gate-mount-guard.sh" "GATE_MG_BUNDLE=$MARS_REAL_BUNDLE" "GATE_MG_BUNDLE=$MBUNDLE" 1

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
# State in $F/state: detached | attached | mounted (at the root) | prep (mounted at $PREP, the
# captured state of someone inspecting the volume; $F/prep-at names another mount point). $F/attach-mode: ok | noop (rc 0, mounts
# nothing: the old agent's failure) | owners-off | fail | symlink (mounts an image whose
# memos-ng-ios is a symlink off the volume). $F/detach-busy refuses a detach.
# The captures are merkur's; while $F/host is mars they answer with mars's bundle and UUID.
cat > "$tmp/bin/hdiutil" <<EOF
#!/usr/bin/env bash
echo "hdiutil \$*" >> "$F/calls"
st="\$(cat "$F/state")"
if [ "\$(cat "$F/host" 2>/dev/null)" = mars ]; then BUNDLE="$MBUNDLE"; else BUNDLE="$BUNDLE"; fi
case "\$1" in
  info)
    [ ! -e "$F/hdiutil-garbage" ] || { echo garbage; exit 0; }
    case "\$st" in
      detached) cat "$FIX/hdiutil-info-detached.plist" ;;
      attached) sed "s|$REAL_BUNDLE|\$BUNDLE|" "$FIX/hdiutil-info-attached-unmounted.plist" ;;
      mounted)  sed -e "s|$REAL_BUNDLE|\$BUNDLE|" -e "s|<string>$PREP</string>|<string>$M</string>|" "$FIX/hdiutil-info-mounted-prep.plist" ;;
      prep)     at="\$(cat "$F/prep-at" 2>/dev/null || echo "$PREP")"
                sed -e "s|$REAL_BUNDLE|\$BUNDLE|" -e "s|<string>$PREP</string>|<string>\$at</string>|" "$FIX/hdiutil-info-mounted-prep.plist" ;;
    esac ;;
  attach)
    mode="\$(cat "$F/attach-mode" 2>/dev/null || echo ok)"
    case "\$mode" in
      fail) echo "hdiutil: attach failed - no such file" >&2; exit 1 ;;
      noop) echo attached > "$F/state"; exit 0 ;;
    esac
    [ "\$mode" != owners-off ] || touch "$F/owners-off"
    mv "$M" "$M.under" && mkdir "$M" && mkdir -p "$M/quarantine-pre602" "$M/CoreSimulator/Devices" && echo mounted > "$F/state"
    [ "\$mode" != symlink ] || { mkdir -p "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$M/memos-ng-ios"; } ;;
  detach)
    [ ! -e "$F/detach-busy" ] || { echo 'hdiutil: couldn'"'"'t unmount "disk7" - Resource busy' >&2; exit 16; }
    if [ "\$st" = mounted ]; then rm -rf "$M" && mv "$M.under" "$M"; fi
    echo detached > "$F/state" ;;
  *) exit 2 ;;
esac
EOF
cat > "$tmp/bin/diskutil" <<EOF
#!/usr/bin/env bash
if [ "\$(cat "$F/state")" = mounted ] && [ "\$3" = "$M" ]; then
  u="$UUID"; [ "\$(cat "$F/host" 2>/dev/null)" != mars ] || u="$MARS_UUID"
  sed -e "s|<string>$PREP</string>|<string>$M</string>|" -e "s|$UUID|\$u|" "$FIX/diskutil-info-prep-mount.plist" > "$F/du.plist"
  [ ! -e "$F/owners-off" ] || python3 -c 'import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,"rb")); d["GlobalPermissionsEnabled"]=False; plistlib.dump(d,open(p,"wb"))' "$F/du.plist"
  cat "$F/du.plist"; exit 0
fi
cat "$FIX/diskutil-info-home-dir.plist"; exit 1
EOF
cat > "$tmp/bin/stat" <<EOF
#!/usr/bin/env bash
[ "\$1" = -f ] && [ "\$2" = %d ] || exit 2
[ -e "\$3" ] || [ -L "\$3" ] || exit 1
if [ "\$(cat "$F/state")" = mounted ] && { [ "\$3" = "$M" ] || [ "\${3#$M/}" != "\$3" ]; }; then echo 16777247; else echo 16777234; fi
EOF
cat > "$tmp/bin/scutil" <<EOF
#!/usr/bin/env bash
[ "\$1" = --get ] && [ "\$2" = LocalHostName ] && [ "\$#" = 2 ] || exit 2
[ ! -e "$F/host" ] || cat "$F/host"
[ ! -e "$F/scutil-rc" ] || exit "\$(cat "$F/scutil-rc")"
exit 0
EOF
# ioreg -rd1 -c IOPlatformExpertDevice: the hardware UUID of the host the case names ($F/hw).
cat > "$tmp/bin/ioreg" <<EOF
#!/usr/bin/env bash
printf '+-o J414sAP  <class IOPlatformExpertDevice>\\n  {\\n    "IOPlatformUUID" = "%s"\\n  }\\n' "\$(cat "$F/hw")"
EOF
chmod +x "$tmp/bin/"*

# --- scenarios -------------------------------------------------------------------------------------
reset() {   # reset <state> <root: sentinel|populated|empty|sentinel+extra>
  chmod -R u+rwx "$M" "$M.under" 2>/dev/null; rm -rf "$F" "$M" "$M.under" "$H" "$VOL"
  rm -rf "${MVOL:?}"; mkdir -p "$F" "$M" "$H" "$BUNDLE" "$MBUNDLE"; echo "$1" > "$F/state"; echo merkur > "$F/host"; echo "$MERKUR_HW" > "$F/hw"
  # The moved device root: a link onto the image, dangling while the image is not mounted.
  mkdir -p "$H/Library/Developer/CoreSimulator"; ln -s "$M/CoreSimulator/Devices" "$H/Library/Developer/CoreSimulator/Devices"
  case "$2" in
    sentinel) touch "$M/$SENT" ;;
    populated) mkdir -p "$M/memos-ng-ios/gate" "$M/img-manager-ios/gate"; echo x > "$M/run.log" ;;
    sentinel+extra) touch "$M/$SENT" "$M/stray.log" ;;
    empty) ;;
  esac
  if [ "$1" = mounted ]; then   # the populated tree is underneath; on top, the image's content
    mv "$M" "$M.under"; mkdir -p "$M/memos-ng-ios/gate" "$M/quarantine-pre602" "$M/CoreSimulator/Devices"
  fi
}
RC=""
run() {
  OUT="$(env HOME="$H" GATE_MG_STAT="$tmp/bin/stat" GATE_MG_DISKUTIL="$tmp/bin/diskutil" GATE_MG_HDIUTIL="$tmp/bin/hdiutil" \
    GATE_MG_PLUTIL="$tmp/bin/plutil" GATE_MG_SCUTIL="$tmp/bin/scutil" GATE_MG_IOREG="$tmp/bin/ioreg" GATE_MG_READ_S="${READ_S:-10}" bash "$tmp/inst/build-image-mount.sh" 2>&1)"; RC=$?
  OUT="$OUT
--- calls: $(grep -v '^hdiutil info' "$F/calls" 2>/dev/null | tr '\n' ';')
--- log: $(tail -1 "$H/Library/Logs/$(cat "$F/host" 2>/dev/null)-build-image.log" 2>/dev/null)"
}
calls() { grep -v '^hdiutil info' "$F/calls" 2>/dev/null | tr '\n' ';'; }
state() { cat "$F/state"; }

# Healthy populated mount: proved at once, nothing attached or detached (W2 removes this step).
reset mounted populated; run
if [ "$RC" = 0 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && [ -d "$M/quarantine-pre602" ]; then ok "a healthy populated mount -> exit 0, no attach, no detach"; else bad "healthy populated mount (rc $RC)"; fi
if grep -q 'exit 0: already mounted and proved: MOUNT OK host=merkur uuid=EE4304C8-021C-489D-B57B-6D846E76B1CF dev=/dev/disk8s1' "$H/Library/Logs/merkur-build-image.log" 2>/dev/null; then ok "the log names the proof"; else bad "log line for the healthy mount"; fi

# Today's state after P0: detached, the sentinel directory at the root -> mount and prove.
reset detached sentinel; run
if [ "$RC" = 0 ] && [ "$(calls)" = "hdiutil attach -owners on -mountpoint $M -nobrowse $BUNDLE;" ] && [ "$(state)" = mounted ] && [ ! -e "$M/$SENT" ] && [ -e "$M.under/$SENT" ]; then ok "detached + sentinel -> attach -owners on at the root, proved, exit 0"; else bad "detached + sentinel (rc $RC)"; fi

# The state that hid the failure: attached, not mounted -> detach (never forced), then mount.
reset attached sentinel; run
if [ "$RC" = 0 ] && [ "$(calls)" = "hdiutil detach /dev/disk7;hdiutil attach -owners on -mountpoint $M -nobrowse $BUNDLE;" ] && [ "$(state)" = mounted ]; then ok "attached-not-mounted -> detach /dev/disk7 without -force, attach, exit 0"; else bad "attached-not-mounted (rc $RC)"; fi
reset attached sentinel; touch "$F/detach-busy"; run
if [ "$RC" = 1 ] && [ "$(calls)" = "hdiutil detach /dev/disk7;" ] && [ "$(state)" = attached ]; then ok "detach busy -> exit 1, no attach"; else bad "detach busy (rc $RC)"; fi

# Nothing to mount from.
reset detached sentinel; rm -rf "$VOL"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "the external volume absent -> exit 1, nothing attached"; else bad "volume absent (rc $RC)"; fi
reset detached sentinel; rm -rf "$BUNDLE"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "the bundle absent -> exit 1, nothing attached"; else bad "bundle absent (rc $RC)"; fi

# Never mount over anything but the bare sentinel directory (W3 accepts any content).
reset detached populated; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ -f "$M/run.log" ]; then ok "a populated plain directory at the root -> exit 1, nothing attached over it"; else bad "populated plain dir (rc $RC)"; fi
reset detached sentinel+extra; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "the sentinel plus one stray file -> exit 1, nothing attached"; else bad "sentinel + stray (rc $RC)"; fi
reset detached empty; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "an empty directory without the sentinel -> exit 1, nothing attached"; else bad "empty dir (rc $RC)"; fi

# An attach that returned 0 is not a mount (W1 exits 0 here).
reset detached sentinel; echo noop > "$F/attach-mode"; run
if [ "$RC" = 1 ] && [ "$(state)" = attached ]; then ok "attach rc 0 without a mount (the old agent's failure) -> exit 1"; else bad "attach noop (rc $RC)"; fi
reset detached sentinel; echo owners-off > "$F/attach-mode"; run
if [ "$RC" = 1 ] && [ "$(state)" = mounted ]; then ok "attach mounted without ownership -> exit 1"; else bad "attach owners-off (rc $RC)"; fi
reset detached sentinel; echo fail > "$F/attach-mode"; run
if [ "$RC" = 1 ] && [ "$(state)" = detached ]; then ok "attach fails -> exit 1"; else bad "attach fails (rc $RC)"; fi

# Mounted at the root but not proved: no detach of a mount at the root, no attach over it.
reset mounted populated; touch "$F/owners-off"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && tail -1 "$H/Library/Logs/merkur-build-image.log" | grep -qF "exit 1: the bundle is mounted at $M but the predicate failed; not detaching a mount at the root"; then ok "mounted at the root without proof -> exit 1 at step 3, neither detached nor re-attached"; else bad "mounted unproved (rc $RC)"; fi

# Mounted somewhere else (the captured fixture: at $PREP): a volume someone opened is not taken
# from under them -- no detach, no attach, the state and the root as they were.
reset prep sentinel; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = prep ] && [ "$(ls -A "$M")" = "$SENT" ] && tail -1 "$H/Library/Logs/merkur-build-image.log" | grep -qF "exit 1: the bundle is mounted at $PREP, not at $M; not detaching a mounted volume"; then ok "mounted at another path ($PREP) -> exit 1, no detach, no attach, state unchanged"; else bad "mounted elsewhere (rc $RC)"; fi
# A mount point that merely starts with the root's path is elsewhere, not at the root.
reset prep sentinel; echo "$M.inspect" > "$F/prep-at"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = prep ] && tail -1 "$H/Library/Logs/merkur-build-image.log" | grep -qF "exit 1: the bundle is mounted at $M.inspect, not at $M; not detaching a mounted volume"; then ok "mounted at the root's path plus a suffix ($M.inspect) -> exit 1 as elsewhere, nothing detached"; else bad "mounted at root-prefixed path (rc $RC)"; fi
# The reading of where it is mounted fails: never read as "mounted nowhere".
mkdir -p "$tmp/awkbin"; real_awk="$(command -v awk)"
printf '#!/usr/bin/env bash\ncase "$*" in *%s*) exit 2 ;; esac\nexec %q "$@"\n' "'\$2 != \"\"'" "$real_awk" > "$tmp/awkbin/awk"
chmod +x "$tmp/awkbin/awk"
reset prep sentinel; PATH="$tmp/awkbin:$PATH" run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = prep ] && tail -1 "$H/Library/Logs/merkur-build-image.log" | grep -qF "exit 1: the bundle's mount points could not be read (awk rc 2)"; then ok "the mount-point reading fails -> exit 1, nothing detached"; else bad "mount-point reading fails (rc $RC)"; fi

# The device root (term (f), @devroot): the wrapper declares success only with the device root on
# the image. Detached + bare sentinel + the correct link, dangling until the mount: attach, then (f)
# passes — the dangling link never blocks the mount it is waiting for.
reset detached sentinel; run
if [ "$RC" = 0 ] && [ "$(calls)" = "hdiutil attach -owners on -mountpoint $M -nobrowse $BUNDLE;" ] && [ -d "$H/Library/Developer/CoreSimulator/Devices/" ] \
   && tail -1 "$H/Library/Logs/merkur-build-image.log" | grep -qF "exit 0: mounted and proved: MOUNT OK host=merkur"; then ok "(f) a dangling device-root link over a bare sentinel -> attach, then (f) passes, exit 0 (no mount deadlock)"; else bad "(f) dangling link before attach (rc $RC)"; fi
reset mounted populated; rm "$H/Library/Developer/CoreSimulator/Devices"; mkdir "$H/Library/Developer/CoreSimulator/Devices"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && grep -qF "not proved: MOUNT REFUSE host=merkur device root $H/Library/Developer/CoreSimulator/Devices is not a symlink" "$H/Library/Logs/merkur-build-image.log"; then ok "(f) step 1: a healthy image but a real device-root directory -> not proved, exit 1, neither detached nor re-attached"; else bad "(f) step 1 real device-root directory (rc $RC)"; fi
reset detached sentinel; rm "$H/Library/Developer/CoreSimulator/Devices"; ln -s "$tmp/elsewhere-devices" "$H/Library/Developer/CoreSimulator/Devices"; mkdir -p "$tmp/elsewhere-devices"; run
if [ "$RC" = 1 ] && [ "$(state)" = mounted ] && tail -1 "$H/Library/Logs/merkur-build-image.log" | grep -qF "exit 1: attach returned 0 but the predicate fails: MOUNT REFUSE host=merkur device root $H/Library/Developer/CoreSimulator/Devices resolves to $tmp/elsewhere-devices"; then ok "(f) step 6: a fresh mount but the device root linked elsewhere -> exit 1"; else bad "(f) step 6 device root elsewhere (rc $RC)"; fi
# The inventory the wrapper hands the predicate: every project's subtrees, the device root's target,
# and the @devroot request, on both of its calls.
n="$(grep -c '^BUILD_IMAGE_SUBTREES="memos-ng-ios/gate memos-ng-ios/work img-manager-ios/gate repaso-es-ios/gate.noindex repaso-es-ios/work.noindex repaso-es-ios/scratch.noindex mardermusic-ios/gate CoreSimulator/Devices"$' "$WRAPPER")"
c="$(grep -c 'gate_mount_guard enforce $BUILD_IMAGE_SUBTREES @devroot)' "$WRAPPER")"
OUT="inventory lines: $n, @devroot predicate calls: $c"
if [ "$n" = 1 ] && [ "$c" = 2 ]; then ok "the wrapper's inventory names CoreSimulator/Devices and both predicate calls ask for @devroot"; else bad "the wrapper's inventory or its @devroot calls"; fi

# Unmeasured attachment and a missing helper refuse.
reset detached sentinel; touch "$F/hdiutil-garbage"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "hdiutil info unparsable -> exit 1, nothing attached"; else bad "hdiutil garbage (rc $RC)"; fi
reset detached sentinel; mv "$tmp/inst/gate-mount-guard.sh" "$tmp/guard.away"; run; mv "$tmp/guard.away" "$tmp/inst/gate-mount-guard.sh"
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "the helper missing beside the wrapper -> exit 1"; else bad "helper missing (rc $RC)"; fi

# The wrapper proves the gates' own predicate, repo roots included: a repo root symlinked off the
# volume is not a proof, neither for a mount found in place (step 1) nor for a fresh one (step 6).
LOG="$H/Library/Logs/merkur-build-image.log"
reset mounted populated; rm -rf "$M/memos-ng-ios"; ln -s "$M.under/memos-ng-ios" "$M/memos-ng-ios"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && grep -qF "not proved: MOUNT REFUSE host=merkur $M/memos-ng-ios is a symlink" "$LOG"; then ok "step 1: an image mounted at the root whose memos-ng-ios is a symlink onto internal storage -> not proved, exit 1, neither detached nor re-attached"; else bad "step 1 symlinked repo root (rc $RC)"; fi
reset mounted populated; ln -s "$M.under" "$M/repaso-es-ios"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && grep -qF "not proved: MOUNT REFUSE host=merkur $M/repaso-es-ios is a symlink" "$LOG"; then ok "step 1: every project's subtrees are proved, not memos's alone (repaso-es-ios a symlink -> exit 1)"; else bad "step 1 symlinked repaso root (rc $RC)"; fi
reset mounted populated; ln -s "$M.under" "$M/mardermusic-ios"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && grep -qF "not proved: MOUNT REFUSE host=merkur $M/mardermusic-ios is a symlink" "$LOG"; then ok "step 1: the newest root is in the inventory too (mardermusic-ios a symlink -> exit 1)"; else bad "step 1 symlinked mardermusic root (rc $RC)"; fi
# The helper names no project: the wrapper hands it the inventory, the same seven roots, the device
# root's target and the @devroot request at step 1
# and at step 6, each its own argument. A spy wraps the real helper function in the installed copy.
cp "$tmp/inst/gate-mount-guard.sh" "$tmp/guard.unspied"
cat >> "$tmp/inst/gate-mount-guard.sh" <<EOF
eval "unspied_\$(declare -f gate_mount_guard)"
gate_mount_guard() { printf '<%s>' "\$@" >> "$F/guard-args"; echo >> "$F/guard-args"; unspied_gate_mount_guard "\$@"; }
EOF
reset detached sentinel; run; mv "$tmp/guard.unspied" "$tmp/inst/gate-mount-guard.sh"
want='<enforce><memos-ng-ios/gate><memos-ng-ios/work><img-manager-ios/gate><repaso-es-ios/gate.noindex><repaso-es-ios/work.noindex><repaso-es-ios/scratch.noindex><mardermusic-ios/gate><CoreSimulator/Devices><@devroot>'
got="$(cat "$F/guard-args" 2>/dev/null)"
if [ "$RC" = 0 ] && [ "$got" = "$want
$want" ]; then ok "both proofs hand the helper exactly the seven roots, mardermusic-ios/gate included, then CoreSimulator/Devices and @devroot"; else OUT="$OUT
--- guard args: $got"; bad "inventory handed to the helper (rc $RC)"; fi
reset detached sentinel; echo symlink > "$F/attach-mode"; run
if [ "$RC" = 1 ] && [ "$(state)" = mounted ] && tail -1 "$LOG" | grep -qF "exit 1: attach returned 0 but the predicate fails: MOUNT REFUSE host=merkur $M/memos-ng-ios is a symlink"; then ok "step 6: a fresh mount whose memos-ng-ios is a symlink off the volume -> exit 1"; else bad "step 6 symlinked repo root (rc $RC)"; fi

# A mount-point that cannot be read is unmeasured, never "not mounted here": the image IS mounted at
# the root (unproved: ownership off), and reading its mount-point as blank would detach it.
reset mounted populated; touch "$F/owners-off"; echo mount-point > "$F/plutil-hang"; READ_S=1 run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && tail -1 "$LOG" | grep -qF "exit 1: image attachment unmeasured: image 1 entity 4 mount-point unreadable (rc 142)"; then ok "a hung mount-point read -> exit 1 unmeasured, the image mounted at the root is not detached"; else bad "hung mount-point read (rc $RC)"; fi
reset mounted populated; touch "$F/owners-off"; echo 'mount-point 1' > "$F/plutil-fail"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && tail -1 "$LOG" | grep -qF "exit 1: image attachment unmeasured: image 1 entity 4 mount-point unreadable (rc 1)"; then ok "a failed mount-point read (plutil's missing-key text, key present) -> exit 1 unmeasured, nothing detached"; else bad "failed mount-point read (rc $RC)"; fi

# --- one wrapper, two hosts: the profile names the bundle, its volume, the sentinel and the log ----
MLOG="$H/Library/Logs/mars-build-image.log"; KLOG="$H/Library/Logs/merkur-build-image.log"
reset detached empty; touch "$M/$MSENT"; echo mars > "$F/host"; echo "$MARS_HW" > "$F/hw"; run
if [ "$RC" = 0 ] && [ "$(calls)" = "hdiutil attach -owners on -mountpoint $M -nobrowse $MBUNDLE;" ] && [ "$(state)" = mounted ] \
   && grep -qF "exit 0: mounted and proved: MOUNT OK host=mars uuid=$MARS_UUID dev=/dev/disk8s1" "$MLOG" 2>/dev/null && [ ! -e "$KLOG" ]; then
  ok "mars: detached + mars's sentinel -> attach of mars's bundle at the root, proved with mars's UUID, logged to mars-build-image.log only"
else bad "mars detached + sentinel (rc $RC)"; fi
reset mounted populated; echo mars > "$F/host"; echo "$MARS_HW" > "$F/hw"; run
if [ "$RC" = 0 ] && [ -z "$(calls)" ] && grep -qF "exit 0: already mounted and proved: MOUNT OK host=mars uuid=$MARS_UUID" "$MLOG" 2>/dev/null; then ok "mars: its image mounted at the root -> exit 0, nothing attached or detached"; else bad "mars healthy mount (rc $RC)"; fi
reset detached sentinel; echo mars > "$F/host"; echo "$MARS_HW" > "$F/hw"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && tail -1 "$MLOG" 2>/dev/null | grep -qF "exit 1: $M is not the bare sentinel directory (ls -A: $SENT"; then ok "mars: merkur's sentinel at the root is not mars's -> exit 1, nothing attached"; else bad "mars with merkur's sentinel (rc $RC)"; fi
reset detached empty; touch "$M/$MSENT"; echo mars > "$F/host"; echo "$MARS_HW" > "$F/hw"; rm -rf "${MVOL:?}"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && tail -1 "$MLOG" 2>/dev/null | grep -qF "exit 1: $MVOL is absent"; then ok "mars: its volume (the bundle's grandparent) absent, merkur's present -> exit 1 on mars's volume"; else bad "mars volume absent (rc $RC)"; fi
reset detached sentinel; rm -rf "${VOL:?}"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && tail -1 "$KLOG" 2>/dev/null | grep -qF "exit 1: $VOL is absent"; then ok "merkur: its volume absent, mars's present -> exit 1 on merkur's volume"; else bad "merkur volume absent (rc $RC)"; fi
reset detached sentinel; echo venus > "$F/host"; run
if [ "$RC" = 1 ] && [ ! -e "$F/calls" ] && printf '%s\n' "$OUT" | grep -qF "exit 1: no mount profile for host venus" && [ ! -e "$KLOG" ] && [ ! -e "$MLOG" ] && [ "$(ls -A "$M")" = "$SENT" ]; then
  ok "an unknown host (venus) -> exit 1 with the reason on stderr (launchd's log), not one hdiutil call, the root untouched"
else bad "unknown host (rc $RC)"; fi
reset detached empty; touch "$M/$MSENT"; echo mars > "$F/host"; run
if [ "$RC" = 1 ] && [ ! -e "$F/calls" ] && printf '%s\n' "$OUT" | grep -qF "exit 1: no mount profile for host mars ($MERKUR_HW)" && [ ! -e "$MLOG" ] && [ ! -e "$KLOG" ]; then
  ok "merkur renamed mars (mars's name, merkur's hardware) -> exit 1, not one hdiutil call, mars's bundle never attached"
else bad "renamed host (rc $RC)"; fi
reset detached sentinel; echo 1 > "$F/scutil-rc"; run
if [ "$RC" = 1 ] && [ ! -e "$F/calls" ] && printf '%s\n' "$OUT" | grep -qF "exit 1: no mount profile for host unmeasured (scutil rc 1)"; then ok "the host name unreadable (scutil rc 1) -> exit 1, nothing read or attached"; else bad "scutil fails (rc $RC)"; fi
# The derivation against the REAL literals: the tracked wrapper and helper, unmodified, on a host
# without either volume, stop at step 2 naming the host's real volume in the host's own log.
mkdir -p "$tmp/real"; cp "$WRAPPER" "$tmp/real/build-image-mount.sh"; cp "$GUARD" "$tmp/real/gate-mount-guard.sh"
for pair in merkur:/Volumes/lexosaurus:$MERKUR_HW mars:/Volumes/flexosaurus:$MARS_HW; do
  h="${pair%%:*}"; v="${pair#*:}"; hw="${v#*:}"; v="${v%%:*}"
  if [ -e "$v" ]; then ok "real literals, $h: skipped, $v exists on this machine"; continue; fi
  reset detached sentinel; echo "$h" > "$F/host"; echo "$hw" > "$F/hw"
  OUT="$(env HOME="$H" GATE_MG_STAT="$tmp/bin/stat" GATE_MG_DISKUTIL="$tmp/bin/diskutil" GATE_MG_HDIUTIL="$tmp/bin/hdiutil" \
    GATE_MG_PLUTIL="$tmp/bin/plutil" GATE_MG_SCUTIL="$tmp/bin/scutil" GATE_MG_IOREG="$tmp/bin/ioreg" bash "$tmp/real/build-image-mount.sh" 2>&1)"; RC=$?
  if [ "$RC" = 1 ] && [ -z "$(calls)" ] && tail -1 "$H/Library/Logs/$h-build-image.log" 2>/dev/null | grep -qF "exit 1: $v is absent"; then ok "real literals, $h: the volume is $v, the log $h-build-image.log"; else bad "real literals, $h (rc $RC)"; fi
done

# --- the LaunchAgent definition ----------------------------------------------------------------------
for pair in "merkur:$PLIST" "mars:$MARS_PLIST"; do
  h="${pair%%:*}"
  OUT="$(python3 - "${pair#*:}" "$h" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb')); h = sys.argv[2]
log = '/Users/fabian/Library/Logs/%s-build-image.log' % h
want = {
  'Label': 'live.discomarder.%s-build-image' % h,
  'ProgramArguments': ['/bin/bash', '/Users/fabian/Library/Application Support/%s-build-image/build-image-mount.sh' % h],
  'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 60,
  'StandardOutPath': log, 'StandardErrorPath': log,
}
bad = [k for k in want if d.get(k) != want[k]] + [k for k in d if k not in want]
print('mismatch: %s' % bad if bad else 'plist ok')
EOF
)"
  if [ "$OUT" = "plist ok" ]; then ok "$h plist: the label, the installed wrapper, RunAtLoad, KeepAlive SuccessfulExit=false, ThrottleInterval 60, both logs the host's, no other key"; else bad "$h plist"; fi
done

echo "build-image-mount-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
