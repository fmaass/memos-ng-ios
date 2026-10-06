#!/usr/bin/env bash
#
# The mount wrapper the LaunchAgent runs — scripts/merkur/build-image-mount.sh — driven against a
# throwaway root, volume and bundle, with fake hdiutil/diskutil/stat that keep one state (detached,
# attached, mounted) and answer with the REAL plists captured from the build host
# (tests/gate/fixtures/mount-guard/). A fake attach mounts by moving the root's directory aside
# and putting a fresh one in its place, so what the wrapper sees underneath and on top is real.
# Every case reads the wrapper's exit code, the hdiutil calls it made and the state it left.
#
# The paths are literals in the wrapper and the helper, so both are copied side by side (the
# wrapper sources the helper beside itself) with each literal rewritten once; the suite refuses to
# run if a literal is not found exactly once. GATE_MG_WRAPPER_SCRIPT points it at another copy of
# the wrapper (the mutation proofs W1-W3). Exit: 0 = every case behaved as expected; 1 otherwise.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
WRAPPER="${GATE_MG_WRAPPER_SCRIPT:-$repo_root/scripts/merkur/build-image-mount.sh}"
GUARD="$repo_root/scripts/gate-mount-guard.sh"
PLIST="$repo_root/scripts/merkur/live.discomarder.merkur-build-image.plist"
FIX="$here/fixtures/mount-guard"
for f in "$WRAPPER" "$GUARD" "$PLIST"; do [ -r "$f" ] || { echo "FAIL: $f is not readable"; exit 1; }; done
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
mkdir -p "$tmp/bin" "$tmp/inst"

# --- the wrapper and its helper, side by side, their literals moved into the throwaway tree --------
subst() {   # subst <file> <literal line> <replacement line>
  local n; n="$(grep -cxF "$2" "$1")"
  [ "$n" = 1 ] || { echo "FAIL: VOID — '$2' is present $n times in $1, not once"; exit 1; }
  python3 - "$1" "$2" "$3" <<'EOF'
import sys
p, a, b = sys.argv[1:]
t = open(p).read().split('\n')
open(p, 'w').write('\n'.join(b if l == a else l for l in t))
EOF
}
cp "$WRAPPER" "$tmp/inst/build-image-mount.sh"; cp "$GUARD" "$tmp/inst/gate-mount-guard.sh"
subst "$tmp/inst/gate-mount-guard.sh" "GATE_MG_ROOT=/Users/fabian/build" "GATE_MG_ROOT=$M"
subst "$tmp/inst/gate-mount-guard.sh" "GATE_MG_BUNDLE=$REAL_BUNDLE" "GATE_MG_BUNDLE=$BUNDLE"
subst "$tmp/inst/build-image-mount.sh" "WRAPPER_VOLUME=/Volumes/lexosaurus" "WRAPPER_VOLUME=$VOL"

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
cat > "$tmp/bin/hdiutil" <<EOF
#!/usr/bin/env bash
echo "hdiutil \$*" >> "$F/calls"
st="\$(cat "$F/state")"
case "\$1" in
  info)
    [ ! -e "$F/hdiutil-garbage" ] || { echo garbage; exit 0; }
    case "\$st" in
      detached) cat "$FIX/hdiutil-info-detached.plist" ;;
      attached) sed "s|$REAL_BUNDLE|$BUNDLE|" "$FIX/hdiutil-info-attached-unmounted.plist" ;;
      mounted)  sed -e "s|$REAL_BUNDLE|$BUNDLE|" -e "s|<string>$PREP</string>|<string>$M</string>|" "$FIX/hdiutil-info-mounted-prep.plist" ;;
      prep)     at="\$(cat "$F/prep-at" 2>/dev/null || echo "$PREP")"
                sed -e "s|$REAL_BUNDLE|$BUNDLE|" -e "s|<string>$PREP</string>|<string>\$at</string>|" "$FIX/hdiutil-info-mounted-prep.plist" ;;
    esac ;;
  attach)
    mode="\$(cat "$F/attach-mode" 2>/dev/null || echo ok)"
    case "\$mode" in
      fail) echo "hdiutil: attach failed - no such file" >&2; exit 1 ;;
      noop) echo attached > "$F/state"; exit 0 ;;
    esac
    [ "\$mode" != owners-off ] || touch "$F/owners-off"
    mv "$M" "$M.under" && mkdir "$M" && mkdir "$M/quarantine-pre602" && echo mounted > "$F/state"
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
  sed "s|<string>$PREP</string>|<string>$M</string>|" "$FIX/diskutil-info-prep-mount.plist" > "$F/du.plist"
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
chmod +x "$tmp/bin/"*

# --- scenarios -------------------------------------------------------------------------------------
reset() {   # reset <state> <root: sentinel|populated|empty|sentinel+extra>
  chmod -R u+rwx "$M" "$M.under" 2>/dev/null; rm -rf "$F" "$M" "$M.under" "$H" "$VOL"
  mkdir -p "$F" "$M" "$H" "$BUNDLE"; echo "$1" > "$F/state"
  case "$2" in
    sentinel) touch "$M/$SENT" ;;
    populated) mkdir -p "$M/memos-ng-ios/gate" "$M/img-manager-ios/gate"; echo x > "$M/run.log" ;;
    sentinel+extra) touch "$M/$SENT" "$M/stray.log" ;;
    empty) ;;
  esac
  if [ "$1" = mounted ]; then   # the populated tree is underneath; on top, the image's content
    mv "$M" "$M.under"; mkdir -p "$M/memos-ng-ios/gate" "$M/quarantine-pre602"
  fi
}
RC=""
run() {
  OUT="$(env HOME="$H" GATE_MG_STAT="$tmp/bin/stat" GATE_MG_DISKUTIL="$tmp/bin/diskutil" GATE_MG_HDIUTIL="$tmp/bin/hdiutil" \
    GATE_MG_PLUTIL="$tmp/bin/plutil" GATE_MG_READ_S="${READ_S:-10}" bash "$tmp/inst/build-image-mount.sh" 2>&1)"; RC=$?
  OUT="$OUT
--- calls: $(grep -v '^hdiutil info' "$F/calls" 2>/dev/null | tr '\n' ';')
--- log: $(tail -1 "$H/Library/Logs/merkur-build-image.log" 2>/dev/null)"
}
calls() { grep -v '^hdiutil info' "$F/calls" 2>/dev/null | tr '\n' ';'; }
state() { cat "$F/state"; }

# Healthy populated mount: proved at once, nothing attached or detached (W2 removes this step).
reset mounted populated; run
if [ "$RC" = 0 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && [ -d "$M/quarantine-pre602" ]; then ok "a healthy populated mount -> exit 0, no attach, no detach"; else bad "healthy populated mount (rc $RC)"; fi
if grep -q 'exit 0: already mounted and proved: MOUNT OK uuid=EE4304C8-021C-489D-B57B-6D846E76B1CF dev=/dev/disk8s1' "$H/Library/Logs/merkur-build-image.log" 2>/dev/null; then ok "the log names the proof"; else bad "log line for the healthy mount"; fi

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

# Unmeasured attachment and a missing helper refuse.
reset detached sentinel; touch "$F/hdiutil-garbage"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "hdiutil info unparsable -> exit 1, nothing attached"; else bad "hdiutil garbage (rc $RC)"; fi
reset detached sentinel; mv "$tmp/inst/gate-mount-guard.sh" "$tmp/guard.away"; run; mv "$tmp/guard.away" "$tmp/inst/gate-mount-guard.sh"
if [ "$RC" = 1 ] && [ -z "$(calls)" ]; then ok "the helper missing beside the wrapper -> exit 1"; else bad "helper missing (rc $RC)"; fi

# The wrapper proves the gates' own predicate, repo roots included: a repo root symlinked off the
# volume is not a proof, neither for a mount found in place (step 1) nor for a fresh one (step 6).
LOG="$H/Library/Logs/merkur-build-image.log"
reset mounted populated; rm -rf "$M/memos-ng-ios"; ln -s "$M.under/memos-ng-ios" "$M/memos-ng-ios"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && grep -qF "not proved: MOUNT REFUSE $M/memos-ng-ios is a symlink" "$LOG"; then ok "step 1: an image mounted at the root whose memos-ng-ios is a symlink onto internal storage -> not proved, exit 1, neither detached nor re-attached"; else bad "step 1 symlinked repo root (rc $RC)"; fi
reset mounted populated; ln -s "$M.under" "$M/repaso-es-ios"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && grep -qF "not proved: MOUNT REFUSE $M/repaso-es-ios is a symlink" "$LOG"; then ok "step 1: every project's subtrees are proved, not memos's alone (repaso-es-ios a symlink -> exit 1)"; else bad "step 1 symlinked repaso root (rc $RC)"; fi
reset detached sentinel; echo symlink > "$F/attach-mode"; run
if [ "$RC" = 1 ] && [ "$(state)" = mounted ] && tail -1 "$LOG" | grep -qF "exit 1: attach returned 0 but the predicate fails: MOUNT REFUSE $M/memos-ng-ios is a symlink"; then ok "step 6: a fresh mount whose memos-ng-ios is a symlink off the volume -> exit 1"; else bad "step 6 symlinked repo root (rc $RC)"; fi

# A mount-point that cannot be read is unmeasured, never "not mounted here": the image IS mounted at
# the root (unproved: ownership off), and reading its mount-point as blank would detach it.
reset mounted populated; touch "$F/owners-off"; echo mount-point > "$F/plutil-hang"; READ_S=1 run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && tail -1 "$LOG" | grep -qF "exit 1: image attachment unmeasured: image 1 entity 4 mount-point unreadable (rc 142)"; then ok "a hung mount-point read -> exit 1 unmeasured, the image mounted at the root is not detached"; else bad "hung mount-point read (rc $RC)"; fi
reset mounted populated; touch "$F/owners-off"; echo 'mount-point 1' > "$F/plutil-fail"; run
if [ "$RC" = 1 ] && [ -z "$(calls)" ] && [ "$(state)" = mounted ] && tail -1 "$LOG" | grep -qF "exit 1: image attachment unmeasured: image 1 entity 4 mount-point unreadable (rc 1)"; then ok "a failed mount-point read (plutil's missing-key text, key present) -> exit 1 unmeasured, nothing detached"; else bad "failed mount-point read (rc $RC)"; fi

# --- the LaunchAgent definition ----------------------------------------------------------------------
OUT="$(python3 - "$PLIST" <<'EOF'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
want = {
  'Label': 'live.discomarder.merkur-build-image',
  'ProgramArguments': ['/bin/bash', '/Users/fabian/Library/Application Support/merkur-build-image/build-image-mount.sh'],
  'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 60,
}
bad = [k for k in want if d.get(k) != want[k]]
print('mismatch: %s' % bad if bad else 'plist ok')
EOF
)"
if [ "$OUT" = "plist ok" ]; then ok "plist: the label, the installed wrapper, RunAtLoad, KeepAlive SuccessfulExit=false, ThrottleInterval 60"; else bad "plist"; fi

echo "build-image-mount-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
