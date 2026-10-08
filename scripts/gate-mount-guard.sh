#!/bin/bash
#
# The mount guard of the SHARED Mac build host: a gate may write under the build root only when
# that root is the designated merkur_build APFS image, mounted there, owned, and attached from its
# one sparse bundle. Every other state — the image unmounted (macOS leaves the plain directory, and
# builds land silently on the internal disk), another volume named merkur_build, the image mounted
# without ownership, a repo root symlinked off the volume — refuses before the first remote write.
#
# Source this file and call gate_mount_guard, or run it: `bash gate-mount-guard.sh <mode> <sub…|->`.
# Vendored BYTE-IDENTICAL into every project that gates on the host; each records the reference
# commit and this file's sha256 in scripts/GATE_MOUNT_GUARD_SOURCE. It runs under the build host's
# /bin/bash 3.2 (no associative arrays, no mapfile, no case-changing expansions).
#
# gate_mount_guard <mode> <subtree…|->
#   mode enforce  the predicate decides: OK -> 0, anything else -> 16.
#   mode report   the predicate is evaluated the same way, but while a valid pending marker exists
#                 a refusal is REPORTED (rc 0) instead of enforced; without a valid marker, report
#                 behaves exactly like enforce. The marker is $HOME/.config/build-mount-guard/pending,
#                 exactly three lines host=<IOPlatformUUID>, created=<UTC epoch>, expires=<UTC epoch>,
#                 valid only when this host's UUID, created <= now < expires and the window is at
#                 most 72 h. Missing, unreadable, malformed, another host's or expired = enforce.
#   subtree…      repo subtrees under the root whose EXISTING components must stay on the volume
#                 (relative paths), at least one; a single "-" = the volume identity only. The
#                 helper holds no inventory: each caller names what it proves, and a mode with
#                 neither is refused as a usage error (16, never softened by a marker).
# Output: exactly one verdict line, `MOUNT OK uuid=<uuid> dev=<device>` or `MOUNT REFUSE <reason>`,
# then one state line `mountguard=<enforced|pending:OK|pending:REFUSE> marker=<state>`.
#
# The predicate (plan MEMNG-602, Decision 2), every term required:
#   (a) diskutil info -plist <root>: VolumeUUID literally the recorded one, FilesystemType apfs,
#       MountPoint exactly the root, GlobalPermissionsEnabled true (owners on);
#   (b) its DeviceNode is the dev-entry of one of the system-entities of the hdiutil image whose
#       image-path is exactly the designated bundle (a second volume of that name is not attached
#       from it);
#   (c) the root's device differs from $HOME's (a mount boundary, not the plain directory);
#   (d) the sentinel the unmounted directory carries is not visible;
#   (e) every existing component of each subtree is not a symlink, is on the root's device and
#       resolves physically under the root.
# A reader that fails, times out (GATE_MG_READ_S) or prints an unparsable value refuses; there is
# no fallback reader. Recovery after an unmount is manual (launchd gives the wrapper no trigger
# after it exited 0), and the refusal names the command.

# The designated root, image and volume. Literals by design: no environment can move them.
GATE_MG_ROOT=/Users/fabian/build
GATE_MG_UUID=EE4304C8-021C-489D-B57B-6D846E76B1CF
GATE_MG_BUNDLE=/Volumes/lexosaurus/caches/merkur_build.sparsebundle
GATE_MG_SENTINEL=.NOT-MOUNTED-merkur_build
GATE_MG_LABEL=live.discomarder.merkur-build-image
GATE_MG_MAX_PENDING_S=259200
# The readers, so a test can make each one fail, hang or lie with plausible output.
GATE_MG_STAT="${GATE_MG_STAT:-stat}"
GATE_MG_DISKUTIL="${GATE_MG_DISKUTIL:-diskutil}"
GATE_MG_HDIUTIL="${GATE_MG_HDIUTIL:-hdiutil}"
GATE_MG_IOREG="${GATE_MG_IOREG:-ioreg}"
GATE_MG_PLUTIL="${GATE_MG_PLUTIL:-plutil}"
# Seconds one reader may take (diskutil info measured 0.024 s idle on the host, 2026-10-01).
GATE_MG_READ_S="${GATE_MG_READ_S:-20}"

# Run a reader under a deadline. macOS has no timeout(1); perl is in the base system. The reader
# gets a process group of its own so a hung one is killed with its children (an orphan holding the
# output pipe would keep $(…) waiting past the deadline). 142 = the deadline fired.
gate_mg_run() {
  perl -e '
    my $t = shift; my $pid = fork; defined $pid or exit 126;
    if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 }
    $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid $pid, 0; exit 142 };
    alarm $t; waitpid $pid, 0; alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
  ' "$GATE_MG_READ_S" "$@"
}

# gate_mg_plist_get <plist text> <keypath>: the raw value, or rc != 0. An array or dictionary
# answers its element count (plutil's raw format).
gate_mg_plist_get() {
  printf '%s\n' "$1" | gate_mg_run $GATE_MG_PLUTIL -extract "$2" raw -o - - 2>/dev/null
}

# A canonical decimal only: `[ -gt ]` reads 010 as ten but `$((…))` reads it as octal eight, so a
# leading zero would let the marker's window be judged on two different numbers.
gate_mg_is_count() { case "${1:-}" in ''|*[!0-9]*|0?*) return 1 ;; esac; return 0; }

# gate_mg_bundle_entities: GATE_MG_ENTS gets, for the designated bundle's image, one
# "dev-entry<TAB>mount-point" line per system entity (mount-point empty when none). rc 0 =
# attached, 1 = not attached, 2 = unmeasured (a reader failed or printed something unparsable),
# GATE_MG_WHY says why. Call it directly, never in $(…): its answers are these two variables.
gate_mg_bundle_entities() {
  local info n i path m j dev ent mp found=0 nl='
'
  GATE_MG_WHY=""; GATE_MG_ENTS=""
  info="$(gate_mg_run $GATE_MG_HDIUTIL info -plist 2>/dev/null)" || { GATE_MG_WHY="hdiutil info failed (rc $?)"; return 2; }
  [ -n "$info" ] || { GATE_MG_WHY="hdiutil info printed nothing"; return 2; }
  n="$(gate_mg_plist_get "$info" images)" || { GATE_MG_WHY="hdiutil info has no images array"; return 2; }
  gate_mg_is_count "$n" || { GATE_MG_WHY="hdiutil images count unparsable: $n"; return 2; }
  i=0
  while [ "$i" -lt "$n" ]; do
    path="$(gate_mg_plist_get "$info" "images.$i.image-path")" || { GATE_MG_WHY="image $i has no image-path"; return 2; }
    if [ "$path" = "$GATE_MG_BUNDLE" ]; then
      found=$((found + 1))
      m="$(gate_mg_plist_get "$info" "images.$i.system-entities")" || { GATE_MG_WHY="image $i has no system-entities"; return 2; }
      gate_mg_is_count "$m" || { GATE_MG_WHY="image $i entity count unparsable: $m"; return 2; }
      j=0
      while [ "$j" -lt "$m" ]; do
        dev="$(gate_mg_plist_get "$info" "images.$i.system-entities.$j.dev-entry")" || { GATE_MG_WHY="image $i entity $j has no dev-entry"; return 2; }
        case "$dev" in /dev/disk[0-9]*) ;; *) GATE_MG_WHY="image $i entity $j dev-entry unparsable: $dev"; return 2 ;; esac
        # An entity without a mount-point key is not mounted; that absence is the normal answer, and
        # the only one. plutil answers a missing key, a bad index and unparsable input with the same
        # text and exit code, so presence is read from the entity's own XML (a value spelling the key
        # is escaped there), and every failed read is unmeasured: a mount-point read as blank would
        # make a mounted image look detachable.
        ent="$(printf '%s\n' "$info" | gate_mg_run $GATE_MG_PLUTIL -extract "images.$i.system-entities.$j" xml1 -o - - 2>/dev/null)" \
          || { GATE_MG_WHY="image $i entity $j unreadable (rc $?)"; return 2; }
        case "$ent" in *'<dict>'*|*'<dict/>'*) ;; *) GATE_MG_WHY="image $i entity $j is not a dictionary"; return 2 ;; esac
        mp=""
        case "$ent" in
          *'<key>mount-point</key>'*)
            mp="$(gate_mg_plist_get "$info" "images.$i.system-entities.$j.mount-point")" \
              || { GATE_MG_WHY="image $i entity $j mount-point unreadable (rc $?)"; return 2; }
            [ -n "$mp" ] || { GATE_MG_WHY="image $i entity $j mount-point is empty"; return 2; } ;;
        esac
        GATE_MG_ENTS="$GATE_MG_ENTS$dev	$mp$nl"
        j=$((j + 1))
      done
    fi
    i=$((i + 1))
  done
  [ "$found" -le 1 ] || { GATE_MG_WHY="the bundle is listed $found times"; return 2; }
  [ "$found" -eq 1 ] || return 1
  return 0
}

gate_mg_dev_of() {
  local d
  d="$(gate_mg_run $GATE_MG_STAT -f %d "$1" 2>/dev/null)" || return 1
  gate_mg_is_count "$d" || return 1
  printf '%s\n' "$d"
}

# gate_mg_predicate <subtree…>: rc 0 and GATE_MG_DEVNODE set when every term holds; rc 1 with the
# reason in GATE_MG_WHY otherwise.
gate_mg_predicate() {
  local M="$GATE_MG_ROOT" info v devnode rc mdev hdev sub rel comp p r
  GATE_MG_WHY=""; GATE_MG_DEVNODE=""
  # (a) the volume's identity, from the volume itself.
  info="$(gate_mg_run $GATE_MG_DISKUTIL info -plist "$M" 2>/dev/null)" || { GATE_MG_WHY="diskutil info $M failed (rc $?): not a mounted volume"; return 1; }
  [ -n "$info" ] || { GATE_MG_WHY="diskutil info $M printed nothing"; return 1; }
  v="$(gate_mg_plist_get "$info" VolumeUUID)" || { GATE_MG_WHY="diskutil info $M has no VolumeUUID"; return 1; }
  [ "$v" = "$GATE_MG_UUID" ] || { GATE_MG_WHY="volume UUID at $M is '$v', not $GATE_MG_UUID"; return 1; }
  v="$(gate_mg_plist_get "$info" FilesystemType)" || { GATE_MG_WHY="diskutil info $M has no FilesystemType"; return 1; }
  [ "$v" = apfs ] || { GATE_MG_WHY="filesystem at $M is '$v', not apfs"; return 1; }
  v="$(gate_mg_plist_get "$info" MountPoint)" || { GATE_MG_WHY="diskutil info $M has no MountPoint"; return 1; }
  [ "$v" = "$M" ] || { GATE_MG_WHY="the volume is mounted at '$v', not $M"; return 1; }
  v="$(gate_mg_plist_get "$info" GlobalPermissionsEnabled)" || { GATE_MG_WHY="diskutil info $M has no GlobalPermissionsEnabled"; return 1; }
  [ "$v" = true ] || { GATE_MG_WHY="ownership is not enabled on $M (GlobalPermissionsEnabled '$v')"; return 1; }
  devnode="$(gate_mg_plist_get "$info" DeviceNode)" || { GATE_MG_WHY="diskutil info $M has no DeviceNode"; return 1; }
  case "$devnode" in /dev/disk[0-9]*) ;; *) GATE_MG_WHY="DeviceNode unparsable: '$devnode'"; return 1 ;; esac
  # (b) attached from the designated bundle: the complete dev-entry, never a prefix.
  rc=0; gate_mg_bundle_entities || rc=$?
  [ "$rc" -ne 2 ] || { GATE_MG_WHY="image attachment unmeasured: $GATE_MG_WHY"; return 1; }
  [ "$rc" -eq 0 ] || { GATE_MG_WHY="$GATE_MG_BUNDLE is not attached"; return 1; }
  printf '%s' "$GATE_MG_ENTS" | awk -F '\t' -v d="$devnode" '$1 == d { f = 1 } END { exit !f }' \
    || { GATE_MG_WHY="$devnode is not an entity of $GATE_MG_BUNDLE"; return 1; } # ALLOWANCE: awk exits only in END, so the pipe's status is awk's own
  # (c) a mount boundary between the root and the home directory.
  mdev="$(gate_mg_dev_of "$M")" || { GATE_MG_WHY="stat of $M failed"; return 1; }
  hdev="$(gate_mg_dev_of "$HOME")" || { GATE_MG_WHY="stat of $HOME failed"; return 1; }
  [ "$mdev" != "$hdev" ] || { GATE_MG_WHY="$M is on the same device as $HOME ($mdev): the image is not mounted there"; return 1; }
  # (d) the unmounted directory's sentinel must be hidden by the mount.
  if [ -e "$M/$GATE_MG_SENTINEL" ] || [ -L "$M/$GATE_MG_SENTINEL" ]; then
    GATE_MG_WHY="$M/$GATE_MG_SENTINEL is visible: that is the unmounted directory"; return 1
  fi
  # (e) the repos' own subtrees stay on the volume, checked read-only before anything is created.
  [ ! -L "$M" ] || { GATE_MG_WHY="$M is a symlink"; return 1; }
  for sub in "$@"; do
    case "/$sub/" in
      //|*/../*|*/./*|//*) GATE_MG_WHY="subtree '$sub' is not a plain relative path"; return 1 ;;
    esac
    p="$M"; rel="$sub"
    while [ -n "$rel" ]; do
      comp="${rel%%/*}"
      if [ "$comp" = "$rel" ]; then rel=""; else rel="${rel#*/}"; fi
      [ -n "$comp" ] || continue
      p="$p/$comp"
      # A missing component is fine: it will be created under a verified ancestor.
      if [ ! -e "$p" ] && [ ! -L "$p" ]; then break; fi
      [ ! -L "$p" ] || { GATE_MG_WHY="$p is a symlink"; return 1; }
      v="$(gate_mg_dev_of "$p")" || { GATE_MG_WHY="stat of $p failed"; return 1; }
      [ "$v" = "$mdev" ] || { GATE_MG_WHY="$p is on device $v, not the volume's $mdev"; return 1; }
      r="$(cd -P "$p" 2>/dev/null && pwd -P)" || { GATE_MG_WHY="$p does not resolve as a directory"; return 1; }
      case "$r/" in
        "$M"/?*) ;;
        *) GATE_MG_WHY="$p resolves to $r, outside $M"; return 1 ;;
      esac
    done
  done
  GATE_MG_DEVNODE="$devnode"
  return 0
}

# gate_mg_marker: "valid", or the reason the marker does not allow reporting.
gate_mg_marker() {
  local f="$HOME/.config/build-mount-guard/pending" line k v host="" created="" expires="" lines=0 now me
  [ -e "$f" ] || { echo missing; return; }
  [ -f "$f" ] && [ -r "$f" ] || { echo unreadable; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    k="${line%%=*}"; v="${line#*=}"
    [ "$k" != "$line" ] || { echo "malformed:line-$lines"; return; }
    case "$k" in
      host)    [ -z "$host" ] || { echo malformed:host-twice; return; }; host="$v" ;;
      created) [ -z "$created" ] || { echo malformed:created-twice; return; }; created="$v" ;;
      expires) [ -z "$expires" ] || { echo malformed:expires-twice; return; }; expires="$v" ;;
      *) echo "malformed:key-$k"; return ;;
    esac
  done < "$f" || { echo unreadable; return; }
  [ "$lines" -eq 3 ] || { echo "malformed:$lines-lines"; return; }
  case "$host" in
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]) ;;
    *) echo malformed:host; return ;;
  esac
  gate_mg_is_count "$created" && gate_mg_is_count "$expires" || { echo malformed:epoch; return; }
  [ "$expires" -gt "$created" ] || { echo malformed:window; return; }
  [ $((expires - created)) -le "$GATE_MG_MAX_PENDING_S" ] || { echo malformed:window-over-72h; return; }
  now="$(date -u +%s)"
  gate_mg_is_count "$now" || { echo unmeasured:clock; return; }
  [ "$created" -le "$now" ] || { echo malformed:created-in-future; return; }
  [ "$now" -lt "$expires" ] || { echo expired; return; }
  me="$(gate_mg_run $GATE_MG_IOREG -rd1 -c IOPlatformExpertDevice 2>/dev/null)" || { echo unmeasured:ioreg; return; }
  me="$(printf '%s\n' "$me" | sed -n 's/^[[:space:]]*"IOPlatformUUID" = "\([0-9A-F-]*\)"[[:space:]]*$/\1/p')"
  [ -n "$me" ] || { echo unmeasured:ioreg; return; }
  [ "$host" = "$me" ] || { echo other-host; return; }
  echo valid
}

gate_mount_guard() {
  local mode="${1:-}" marker state pass
  [ "$#" -eq 0 ] || shift
  case "$mode" in
    enforce|report) ;;
    *) echo "MOUNT REFUSE usage: gate_mount_guard <enforce|report> <subtree…|-> (got '$mode')"
       echo "mountguard=enforced marker=not-read"
       return 16 ;;
  esac
  if [ "$#" -eq 0 ]; then
    echo "MOUNT REFUSE usage: gate_mount_guard <enforce|report> <subtree…|-> (no subtree given)"
    echo "mountguard=enforced marker=not-read"
    return 16
  elif [ "$#" -eq 1 ] && [ "$1" = - ]; then
    set --
  fi
  if gate_mg_predicate "$@"; then
    pass=1; echo "MOUNT OK uuid=$GATE_MG_UUID dev=$GATE_MG_DEVNODE"
  else
    pass=0; echo "MOUNT REFUSE $GATE_MG_WHY; recovery once the image is mounted correctly: launchctl kickstart -k gui/$(id -u)/$GATE_MG_LABEL"
  fi
  if [ "$mode" = report ]; then marker="$(gate_mg_marker)"; else marker=not-read; fi
  if [ "$marker" = valid ]; then
    if [ "$pass" -eq 1 ]; then state=pending:OK; else state=pending:REFUSE; fi
    echo "mountguard=$state marker=valid"
    return 0
  fi
  echo "mountguard=enforced marker=$marker"
  [ "$pass" -eq 1 ] && return 0
  return 16
}

# Run directly (not sourced, not piped into `bash -s`): the standalone check.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  gate_mount_guard "$@"
  exit $?
fi
