#!/bin/bash
#
# The LaunchAgent program that mounts the build host's image AT the build root at login, and the
# manual recovery after an unmount (`launchctl kickstart -k gui/501/<label>`). One file serves every
# build host: the guard's profile for the host it runs on (gate_mg_select_profile, keyed on its
# LocalHostName AND IOPlatformUUID as one pair) names the root, bundle, sentinel and label — merkur_build and
# live.discomarder.merkur-build-image on merkur, mars_build and live.discomarder.mars-build-image on
# mars — and a host without a profile exits 1 before anything is read or attached.
#
# The agent it replaces ran `hdiutil attach` directly; on an image that was already attached but
# not mounted that returns 0 and mounts nothing, and launchd then never ran it again: every gate
# built on the internal disk with nobody told. So this program counts as success only what it
# has PROVED with the mount guard's predicate, and it refuses to mount over anything but the
# sentinel directory, so it never hides a populated tree underneath the image.
#
#   (1) the guard's predicate passes in enforce mode -> exit 0 at once (a healthy, populated mount
#       is success: nothing is attached or detached);
#   (2) exit 1 while the volume holding the bundle, or the bundle, is absent;
#   (3) the bundle attached and mounted nowhere -> `hdiutil detach` of that attachment, never
#       forced; busy -> exit 1; mounted anywhere (the root included) -> exit 1, nothing detached;
#   (4) exit 1 unless `ls -A` of the root prints exactly the sentinel;
#   (5) `hdiutil attach -owners on -mountpoint <root> -nobrowse <bundle>`;
#   (6) exit 0 only if the predicate now passes, else exit 1.
# launchd retries a non-zero exit after ThrottleInterval (KeepAlive SuccessfulExit=false) and
# gives an exit 0 no further trigger. Installed beside its copy of scripts/gate-mount-guard.sh in
# ~/Library/Application Support/<host>-build-image/; logs to ~/Library/Logs/<host>-build-image.log
# (the label without its live.discomarder. prefix), the file the host's plist also sends stdout
# and stderr to (scripts/<host>/live.discomarder.<host>-build-image.plist).

here="$(cd "$(dirname "$0")" && pwd -P)" || exit 1
# Empty until the profile is known: a line before that goes to stderr, which launchd sends to the
# same per-host log through the plist's StandardErrorPath.
WRAPPER_LOG=""
GATE_MG_LS="${GATE_MG_LS:-ls}"
# Every project's subtrees on the build root, the one inventory of them: the shared helper names no
# project, so this host's wrapper hands it the list it proves. A root added on the host is added here.
BUILD_IMAGE_SUBTREES="memos-ng-ios/gate memos-ng-ios/work img-manager-ios/gate repaso-es-ios/gate.noindex repaso-es-ios/work.noindex repaso-es-ios/scratch.noindex mardermusic-ios/gate"

wlog() {
  [ -n "$WRAPPER_LOG" ] || { printf '%s pid=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*" >&2; return; }
  mkdir -p "${WRAPPER_LOG%/*}" 2>/dev/null
  printf '%s pid=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*" >> "$WRAPPER_LOG"
}
finish() { wlog "exit $1: $2"; exit "$1"; }

[ -r "$here/gate-mount-guard.sh" ] || finish 1 "the guard helper $here/gate-mount-guard.sh is not readable"
# shellcheck source=../gate-mount-guard.sh
. "$here/gate-mount-guard.sh"
gate_mg_select_profile || finish 1 "$GATE_MG_WHY"
# Both hosts keep the bundle at <volume>/caches/<name>.sparsebundle, so the volume is its grandparent.
WRAPPER_VOLUME="${GATE_MG_BUNDLE%/*/*}"
WRAPPER_LOG="$HOME/Library/Logs/${GATE_MG_LABEL#live.discomarder.}.log"
M="$GATE_MG_ROOT"

# (1) Proof first: a healthy mount is left alone, whatever it holds. The proof is the gates' own
# predicate, every project's subtrees included (BUILD_IMAGE_SUBTREES): a repo root symlinked off
# the volume is no mount the gates could use.
# shellcheck disable=SC2086
verdict="$(gate_mount_guard enforce $BUILD_IMAGE_SUBTREES)" && finish 0 "already mounted and proved: $(printf '%s' "$verdict" | head -1)"
wlog "not proved: $(printf '%s' "$verdict" | head -1)"

# (2) Nothing to mount from.
[ -d "$WRAPPER_VOLUME" ] || finish 1 "$WRAPPER_VOLUME is absent"
[ -d "$GATE_MG_BUNDLE" ] || finish 1 "$GATE_MG_BUNDLE is absent"

# (3) Attached and mounted nowhere (the state that hid the failure): detach it, never forced. A
# mount anywhere is someone's — at the root it is one the predicate refused, and attaching again
# would return 0 and mount nothing; elsewhere it is a volume opened to be looked at — so it is
# left in place and the run stops.
rc=0; gate_mg_bundle_entities || rc=$?
[ "$rc" -ne 2 ] || finish 1 "image attachment unmeasured: $GATE_MG_WHY"
if [ "$rc" -eq 0 ]; then
  if printf '%s' "$GATE_MG_ENTS" | awk -F '\t' -v m="$M" '$2 == m { f = 1 } END { exit !f }'; then
    finish 1 "the bundle is mounted at $M but the predicate failed; not detaching a mount at the root"
  fi
  elsewhere="$(printf '%s' "$GATE_MG_ENTS" | awk -F '\t' '$2 != "" { print $2; exit }')" \
    || finish 1 "the bundle's mount points could not be read (awk rc $?)"
  if [ -n "$elsewhere" ]; then
    finish 1 "the bundle is mounted at $elsewhere, not at $M; not detaching a mounted volume"
  else
    whole="$(printf '%s' "$GATE_MG_ENTS" | awk -F '\t' '$1 ~ /^\/dev\/disk[0-9]+$/ { print $1; exit }')"
    [ -n "$whole" ] || finish 1 "the bundle is attached but no whole-disk entity was found"
    out="$(GATE_MG_READ_S=180 gate_mg_run $GATE_MG_HDIUTIL detach "$whole" 2>&1)" || finish 1 "hdiutil detach $whole refused (busy?): $out"
    wlog "detached $whole (attached, mounted nowhere)"
  fi
fi

# (4) Mount only over the sentinel directory, never over a populated tree.
listing="$(gate_mg_run $GATE_MG_LS -A "$M")" || finish 1 "ls -A $M failed"
[ "$listing" = "$GATE_MG_SENTINEL" ] || finish 1 "$M is not the bare sentinel directory (ls -A: $(printf '%s' "$listing" | tr '\n' ' ' | cut -c1-200))"

# (5) Attach and mount at the root with ownership on (an attach may take longer than a reader).
out="$(GATE_MG_READ_S=180 gate_mg_run $GATE_MG_HDIUTIL attach -owners on -mountpoint "$M" -nobrowse "$GATE_MG_BUNDLE" 2>&1)" \
  || finish 1 "hdiutil attach failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"

# (6) An attach that returned 0 is not a mount: only the predicate is.
# shellcheck disable=SC2086
verdict="$(gate_mount_guard enforce $BUILD_IMAGE_SUBTREES)" || finish 1 "attach returned 0 but the predicate fails: $(printf '%s' "$verdict" | head -1)"
finish 0 "mounted and proved: $(printf '%s' "$verdict" | head -1)"
