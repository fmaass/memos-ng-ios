#!/usr/bin/env bash
#
# Source this file. Admission to the SHARED Mac build host: room for a run, then ONE simulator phase
# at a time across every project whose gate uses it.
#
# The host is one 16 GiB Mac with one data volume, and three projects gate on it. Each gate orders
# only its own runs, so two projects' simulator phases used to run at once; measured three times
# (2026-09-28, -29, -30): two booted simulators and two test runs push swap to 10-12 GiB, the load
# to 330-760, and fill the disk mid-run (swap and simulator data share the volume's container).
# The wait that stood in front of that was a timer that proceeded anyway. This file replaces it
# with conditions, and with a slot that covers the simulator phase and nothing else: compiling and
# linting may overlap across runs, booting a simulator and testing on it may not.
#
# The file is vendored BYTE-IDENTICAL into every project that gates on the host; each records the
# reference commit and this file's sha256 in scripts/GATE_ADMISSION_SOURCE and its selftest refuses
# a copy that differs. So nothing in here names a project, a path of one, or a device of one: the
# caller passes its project, branch, run token and device names. It runs under the build host's
# /bin/bash 3.2 (no flock, no associative arrays, no mapfile, no case-changing expansions) and under
# whatever bash the controller has.
#
# --- the protocol --------------------------------------------------------------------------------
# Run admission (controller, before anything is copied, no slot): gate_run_admission waits until
#   the caller's reader reports free space plus what the run's own trees already hold >= one run's
#   peak + a reserve. Refuses 12 at the ceiling, 13 after GATE_UNMEASURED_MAX unmeasured polls.
# Simulator admission (build host, after the compile, before the device exists):
#   gate_slot_wait_claim polls every GATE_POLL_S until ALL of: free >= GATE_SIM_FREE_FLOOR_KB,
#   memory_pressure free >= GATE_MEMFREE_MIN_PCT, 1-minute load <= GATE_LOAD_MAX, no booted device matching GATE_DEVICE_PATTERNS that is not this run's, and the
#   slot free — then claims the slot. Returns 0 (taken), 11 (ceiling), 12 (ceiling, free space the
#   one failing term), 13 (GATE_UNMEASURED_MAX consecutive polls with a reader unmeasured), 14
#   (the controller's ssh went away before the claim — see gate_on_broken_pipe).
#   Residuals of 14, stated rather than closed: (a) it detects a BROKEN OUTPUT CONNECTION, not a
#   dead controller — an orphaned ssh client that keeps draining the output is not caught; (b) a
#   drop is noticed only at the remote's next write, so a waiter can claim the slot (its
#   "slot-claimed" line is that write) before its first failed write. Neither can make two holders
#   or release live work: the claim is still the one rename, the release still the holder's own.
#   Swap used is read on every poll and logged on every wait line, but it is not a term: on the
#   host it stays at ~6 GiB while idle (memory free 69 %, nothing booted, 2026-09-30), held by
#   long-lived desktop applications, so a swap bound would hold every run to its ceiling. An
#   unreadable swap still counts as unmeasured.
# The slot is $GATE_SLOT_ROOT/sim, a directory that appears together with its owner record: the
#   claimant writes claim.<token>/owner and renames that directory onto sim with rename(2), which
#   fails while sim exists (mv is never used: onto an existing directory it moves INTO it).
# Release (gate_sim_release) is a checked step the caller runs BEFORE its verdict, and again from
#   its EXIT/INT/TERM/HUP traps, where it is a no-op once done: stop what is left of the run's
#   process group, delete every private device by the names recorded (or shut a shared one down),
#   confirm by re-listing, and only then rename sim away. A cleanup that cannot be confirmed keeps
#   the slot, marks it state=cleanup-failed and returns 1 (the caller's simrelease=1).
# A holder is stale only when its pid is gone (or started at another time), no process of its
#   process group is alive, and — under the reap mutex, with sim still in place — every device it
#   named is confirmed deleted (a shared one shut down). The reap mutex has no expiry: a live
#   recoverer that is stuck logs REAP-STUCK, a dead one logs REAP-DEAD with the human step, and
#   recovery stays blocked either way (fail closed). An unmeasured reading is never a proof.
#
# --- the numbers (env seams; the defaults are the host's) ----------------------------------------
# One run's peak from a cold lane — mirror, DerivedData, warnings rebuilds and a booted device:
# measured 2026-09-27 on the reference project at 11.2 GiB at most, so 12 GiB; the reserve is what
# the host writes outside any lane meanwhile (caches, logs, swap).
GATE_RUN_PEAK_KB="${GATE_RUN_PEAK_KB:-12582912}"
GATE_RESERVE_KB="${GATE_RESERVE_KB:-3145728}"
# What the simulator phase needs BEYOND the trees the run already holds (they are on disk already
# and are not counted twice): the device's data, its caches, the result bundle, and swap growth.
# 8 GiB until measured; the measurements are recorded here as they are taken:
#   reference project, 2026-09-30, 5 s df samples over two spans on a shared host: -1.83, -3.05 GiB
GATE_SIM_FREE_FLOOR_KB="${GATE_SIM_FREE_FLOOR_KB:-8388608}"
GATE_MEMFREE_MIN_PCT="${GATE_MEMFREE_MIN_PCT:-20}"
GATE_LOAD_MAX="${GATE_LOAD_MAX:-24}"
GATE_POLL_S="${GATE_POLL_S:-60}"
# The ceiling ends a wait with a refusal, never with admission.
GATE_CEILING_S="${GATE_CEILING_S:-21600}"
GATE_UNMEASURED_MAX="${GATE_UNMEASURED_MAX:-3}"
GATE_SLOT_ROOT="${GATE_SLOT_ROOT:-$HOME/build/.gate-slots}"
# The private-device names of every project's gate, old and new: gate-<branch>-<pid|token> (the
# two SwiftPM/Xcode projects) and mac-gate-iphone-<pid> / mac-gate-ipad-<pid> (the third). A booted
# device matching one of these that no slot holder names is a gate running without the slot.
GATE_DEVICE_PATTERNS="${GATE_DEVICE_PATTERNS:-gate-* mac-gate-iphone-* mac-gate-ipad-*}"
# The commands every reading goes through, so a test can make each one fail with plausible output.
GATE_SIMCTL="${GATE_SIMCTL:-xcrun simctl}"
GATE_PS="${GATE_PS:-ps}"
GATE_DF="${GATE_DF:-df}"
GATE_DU="${GATE_DU:-du}"
GATE_SYSCTL="${GATE_SYSCTL:-sysctl}"
GATE_MEMORY_PRESSURE="${GATE_MEMORY_PRESSURE:-memory_pressure}"
GATE_SLEEP="${GATE_SLEEP:-sleep}"
GATE_TEST_HOOK="${GATE_TEST_HOOK:-}"

# The slot this shell holds, if any. Only gate_slot_claim sets these.
GATE_SLOT_HELD=0
GATE_SLOT_TOKEN=""
GATE_SLOT_SHARED=0
GATE_SLOT_WAITED=0
GATE_SIMRELEASE=0
GATE_ADMIT_WAITED=0
GATE_ADMIT_FIRST_FREE=""

gate_say() { printf '%s\n' "$*"; }
gate_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# Host-timestamped: the contention probe reads two gates' orders from these lines alone.
gate_log() { printf 'GATE_SLOT %s %s\n' "$(gate_now)" "$*"; }
gate_is_count() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
gate_kb_h() { awk -v k="$1" 'BEGIN { printf "%.1fG", k / 1048576 }'; }
gate_hook() { [ -z "${GATE_TEST_HOOK:-}" ] || "$GATE_TEST_HOOK" "$@"; }

# rename(2) of a directory, refusing an existing destination. rename(2) itself refuses a non-empty
# one; the -e test covers the empty directory it would replace, which the protocol never leaves.
gate_rename_dir() { perl -e 'exit 3 if -e $ARGV[1] || -l $ARGV[1]; rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2" 2>/dev/null; }
# rename(2) of a file onto a file: the atomic replace every owner-record update goes through.
gate_replace_file() { perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2" 2>/dev/null; }

# --- the readers: each returns 0 with a value of the expected form, or 1 (unmeasured) -----------
gate_read_free_kb() { # PATH
  local out v
  out="$($GATE_DF -Pk "$1" 2>/dev/null)" || return 1
  v="$(printf '%s\n' "$out" | awk 'NR == 2 { print $4 }')"
  gate_is_count "$v" || return 1
  printf '%s\n' "$v"
}
# One line "<KiB> <path>", its status and its number both checked: a du that could not read part of
# the tree exits nonzero with a plausible total, and that total is not a reading.
gate_read_tree_kb() { # PATH
  local out v
  out="$($GATE_DU -sk "$1" 2>/dev/null)" || return 1
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || return 1
  v="$(printf '%s\n' "$out" | awk '{ print $1 }')"
  gate_is_count "$v" || return 1
  printf '%s\n' "$v"
}
# The build host's half of the run admission: "FREE_KB <n> OWN_KB <n>" for the lane's mirror and
# work trees, or status 1 when any reading is unmeasured. It runs over `ssh bash -s`, where no
# pipefail reaches, so every reading goes through a checked reader rather than a pipe.
gate_lane_space() { # TARGET WORK
  local free own=0 kb tree
  free="$(gate_read_free_kb "$1")" || return 1
  for tree in "$1" "$2"; do
    [ -e "$tree" ] || continue
    kb="$(gate_read_tree_kb "$tree")" || return 1
    own=$((own + kb))
  done
  echo "FREE_KB $free OWN_KB $own"
}
# vm.swapusage: "total = 8192.00M  used = 6655.25M  free = 1536.75M  (encrypted)" -> MiB used,
# rounded up, so 4.01G is not read as 4G.
gate_read_swap_mb() {
  local out v
  out="$($GATE_SYSCTL -n vm.swapusage 2>/dev/null)" || return 1
  v="$(printf '%s\n' "$out" | sed -n -E 's/.*used = ([0-9]+(\.[0-9]+)?)([MG]).*/\1 \3/p' | head -1)"
  [ -n "$v" ] || return 1
  v="$(printf '%s\n' "$v" | awk '{ m = ($2 == "G") ? $1 * 1024 : $1; i = int(m); if (i < m) i++; print i }')"
  gate_is_count "$v" || return 1
  printf '%s\n' "$v"
}
gate_read_memfree_pct() {
  local out v
  out="$($GATE_MEMORY_PRESSURE -Q 2>/dev/null)" || return 1
  v="$(printf '%s\n' "$out" | sed -n -E 's/^System-wide memory free percentage: ([0-9]+)%.*/\1/p' | head -1)"
  gate_is_count "$v" || return 1
  printf '%s\n' "$v"
}
# vm.loadavg: "{ 223.82 96.47 70.88 }" -> "223.82", compared as a number, not truncated.
gate_read_load1() {
  local out v
  out="$($GATE_SYSCTL -n vm.loadavg 2>/dev/null)" || return 1
  v="$(printf '%s\n' "$out" | sed -n -E 's/^\{ ([0-9]+(\.[0-9]+)?) [0-9.]+ [0-9.]+ \}.*/\1/p' | head -1)"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}
# Every device the host knows, one "UDID<TAB>STATE<TAB>NAME" line each, from simctl's JSON listing,
# unavailable runtimes included. Every record must be accounted for: a record without a UDID, a
# state or a name, or a document of any other shape, makes the whole reading unmeasured — a
# device the reader cannot see must never read as a device that is gone.
gate_read_devices() {
  local out
  out="$($GATE_SIMCTL list devices -j 2>/dev/null)" || return 1
  printf '%s' "$out" | perl -MJSON::PP -e '
    local $/; my $d = eval { JSON::PP->new->decode(<STDIN>) } or exit 1;
    ref $d eq "HASH" && ref $d->{devices} eq "HASH" or exit 1;
    my $uuid = qr/\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/;
    my @rows;
    for my $runtime (sort keys %{$d->{devices}}) {
      my $list = $d->{devices}{$runtime};
      ref $list eq "ARRAY" or exit 1;
      for my $e (@$list) {
        ref $e eq "HASH" or exit 1;
        my ($u, $s, $n) = @$e{qw(udid state name)};
        defined $u && !ref $u && $u =~ $uuid or exit 1;
        defined $s && !ref $s && $s =~ /\A[A-Za-z][A-Za-z ]*\z/ or exit 1;
        defined $n && !ref $n && length $n && $n !~ /[\t\r\n]/ or exit 1;
        push @rows, "$u\t$s\t$n\n";
      }
    }
    print @rows; exit 0;' 2>/dev/null
}
# "PID PGID PPID" for every process, taken by a ps that has left this shell's process group first,
# so the listing never shows the lister as a member of the group it is asked about. Its own shell
# must be in it: a listing that cannot see the one process known to exist proves nothing.
gate_read_procs() { # OUTFILE
  perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' $GATE_PS -axo pid=,pgid=,ppid= > "$1" 2>/dev/null || return 1
  awk 'NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' "$1" \
    || return 1
  awk -v p="$$" '$1 == p { found = 1 } END { exit !found }' "$1" || return 1
  return 0
}
gate_read_lstart() { # PID
  local out
  out="$($GATE_PS -o lstart= -p "$1" 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -1)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
gate_read_pgid() { # PID
  local out
  out="$($GATE_PS -o pgid= -p "$1" 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  gate_is_count "$out" || return 1
  printf '%s\n' "$out"
}

# --- the owner record: key=value lines, the first of a key wins; device lines repeat ------------
gate_owner_get() { # FILE KEY
  awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1" 2>/dev/null
}
gate_owner_all() { # FILE KEY
  awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$1" 2>/dev/null
}
gate_owner_describe() { # FILE
  printf 'project=%s branch=%s token=%s pid=%s since=%s state=%s shared=%s' \
    "$(gate_owner_get "$1" project)" "$(gate_owner_get "$1" branch)" "$(gate_owner_get "$1" token)" \
    "$(gate_owner_get "$1" pid)" "$(gate_owner_get "$1" claimed)" "$(gate_owner_get "$1" state)" \
    "$(gate_owner_get "$1" shared)"
}
# Rewrites this run's own record with LINE appended (or state replaced), atomically, and only
# while the slot still names this run.
gate_slot_update() { # KEY VALUE
  local own="$GATE_SLOT_ROOT/sim/owner" tmp
  [ "$GATE_SLOT_HELD" = 1 ] || return 1
  [ "$(gate_owner_get "$own" token)" = "$GATE_SLOT_TOKEN" ] || return 1
  tmp="$GATE_SLOT_ROOT/sim/owner.tmp.$GATE_SLOT_TOKEN"
  if [ "$1" = state ]; then
    awk -v v="$2" 'index($0, "state=") == 1 { print "state=" v; next } { print }' "$own" > "$tmp" || return 1
  else
    { cat "$own" && printf '%s=%s\n' "$1" "$2"; } > "$tmp" || return 1
  fi
  gate_replace_file "$tmp" "$own"
}

# --- judging a holder (the slot's, or the reap mutex's) ------------------------------------------
# Prints live | orphan | stale | unmeasured. stale needs BOTH: its pid gone (or a different process
# under that number), and no process of its process group alive. Devices are the recoverer's.
gate_judge() { # OWNERFILE
  local file="$1" pid lstart pgid host procs now_lstart pid_gone=0
  pid="$(gate_owner_get "$file" pid)"; lstart="$(gate_owner_get "$file" lstart)"
  pgid="$(gate_owner_get "$file" pgid)"; host="$(gate_owner_get "$file" host)"
  gate_is_count "$pid" && gate_is_count "$pgid" && [ -n "$lstart" ] || { echo unmeasured; return; }
  # Another machine's pids cannot be asked about here: its holder is taken at its word.
  [ "$host" = "$(hostname -s 2>/dev/null)" ] || { echo live; return; }
  procs="$(mktemp "${TMPDIR:-/tmp}/gate-procs.XXXXXX")" || { echo unmeasured; return; }
  if ! gate_read_procs "$procs"; then rm -f "$procs"; echo unmeasured; return; fi
  if awk -v p="$pid" '$1 == p { found = 1 } END { exit !found }' "$procs"; then
    if ! now_lstart="$(gate_read_lstart "$pid")"; then
      rm -f "$procs"; echo unmeasured; return
    fi
    [ "$now_lstart" = "$lstart" ] || pid_gone=1
  else
    pid_gone=1
  fi
  if [ "$pid_gone" -eq 0 ]; then rm -f "$procs"; echo live; return; fi
  if awk -v g="$pgid" '$2 == g { found = 1 } END { exit !found }' "$procs"; then
    rm -f "$procs"; echo orphan; return
  fi
  rm -f "$procs"
  echo stale
}

# --- devices -------------------------------------------------------------------------------------
# Deletes every device carrying NAME (a name this run or a dead run wrote down), never any other,
# and confirms by re-listing that none of that name remains. 0 confirmed, 1 stuck, 2 unmeasured.
gate_delete_named() { # NAME TOKEN
  local name="$1" token="$2" attempt=1 list udids udid
  while :; do
    list="$(gate_read_devices)" || return 2
    udids="$(printf '%s\n' "$list" | awk -F '\t' -v n="$name" '$3 == n { print $1 }')"
    if [ -z "$udids" ]; then
      gate_log "token=$token device-deletion-confirmed name=$name"
      return 0
    fi
    [ "$attempt" -le 3 ] || break
    for udid in $udids; do
      $GATE_SIMCTL shutdown "$udid" >/dev/null 2>&1
      $GATE_SIMCTL delete "$udid" >/dev/null 2>&1
    done
    list="$(gate_read_devices)" || return 2
    if [ -z "$(printf '%s\n' "$list" | awk -F '\t' -v n="$name" '$3 == n { print $1 }')" ]; then
      for udid in $udids; do gate_log "token=$token device-deletion-confirmed udid=$udid name=$name"; done
      return 0
    fi
    attempt=$((attempt + 1))
    "$GATE_SLEEP" 3
  done
  for udid in $udids; do
    gate_log "token=$token DEVICE-STUCK udid=$udid name=$name (the slot stays fenced; once nothing of that run is alive: xcrun simctl delete $udid)"
  done
  return 1
}
# A shared device is never deleted: shut down, and confirmed Shutdown by re-reading its state.
gate_shutdown_confirm() { # UDID TOKEN
  local udid="$1" token="$2" attempt=1 list state
  while [ "$attempt" -le 3 ]; do
    $GATE_SIMCTL shutdown "$udid" >/dev/null 2>&1
    list="$(gate_read_devices)" || return 2
    state="$(printf '%s\n' "$list" | awk -F '\t' -v u="$udid" '$1 == u { print $2; exit }')"
    if [ -z "$state" ] || [ "$state" = Shutdown ]; then
      gate_log "token=$token device-shutdown-confirmed udid=$udid state=${state:-absent}"
      return 0
    fi
    attempt=$((attempt + 1))
    "$GATE_SLEEP" 3
  done
  gate_log "token=$token DEVICE-STUCK udid=$udid state=$state (a shared device that will not shut down)"
  return 1
}
# Every device a record names goes: private ones by name (the UDID may never have been written),
# the recorded UDIDs too; a shared one is shut down.
gate_clear_devices() { # OWNERFILE TOKEN
  local file="$1" token="$2" ok=0 name udid
  if [ "$(gate_owner_get "$file" shared)" = 1 ]; then
    # A shared record that names no device cannot be proved clean: fenced, never released.
    if [ -z "$(gate_owner_all "$file" udid)" ]; then
      gate_log "token=$token a shared hold names no device: its cleanup cannot be confirmed, the slot stays fenced"
      return 1
    fi
    for udid in $(gate_owner_all "$file" udid); do gate_shutdown_confirm "$udid" "$token" || ok=1; done
    return $ok
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    gate_delete_named "$name" "$token" || ok=1
  done <<GATE_NAMES_EOF
$(gate_owner_all "$file" device)
GATE_NAMES_EOF
  return $ok
}

# --- the process group -----------------------------------------------------------------------------
# The members of PGID other than SELF and SELF's ancestors: an ancestor is a shell waiting on this
# run, not test work.
gate_group_others() { # PGID SELF PROCSFILE
  awk -v g="$1" -v s="$2" '
    { pg[$1] = $2; pp[$1] = $3; if ($2 == g) members[$1] = 1 }
    END {
      keep[s] = 1; p = s; n = 0
      while ((p in pp) && pp[p] != 0 && n < 64) { p = pp[p]; keep[p] = 1; n++ }
      for (m in members) if (!(m in keep)) print m
    }' "$3"
}
# Stops what is left of this run's group: TERM, a bounded wait, KILL, and a re-listing that has to
# come back empty. 0 quiet, 1 not quiet, 2 unmeasured.
gate_group_stop() { # PGID SELF
  local pgid="$1" self="$2" procs others round=0
  procs="$(mktemp "${TMPDIR:-/tmp}/gate-procs.XXXXXX")" || return 2
  while :; do
    gate_read_procs "$procs" || { rm -f "$procs"; return 2; }
    others="$(gate_group_others "$pgid" "$self" "$procs")"
    [ -n "$others" ] || { rm -f "$procs"; return 0; }
    case "$round" in
      0) gate_log "token=$GATE_SLOT_TOKEN stopping the run's remaining processes: $(echo $others)"
         kill -TERM $others 2>/dev/null ;;
      5) kill -KILL $others 2>/dev/null ;;
      8) rm -f "$procs"; gate_log "token=$GATE_SLOT_TOKEN processes of the run still alive: $(echo $others)"; return 1 ;;
    esac
    round=$((round + 1))
    sleep 1
  done
}

# --- the slot ------------------------------------------------------------------------------------
# Claims sim for this shell. 0 claimed, 1 held by someone else, 2 could not even try.
# A shared claim carries its device's UDID in the record it renames into place, so the slot never
# exists, even for an instant, as a shared hold whose device nobody could shut down.
gate_slot_claim() { # PROJECT BRANCH TOKEN SHARED [SHARED_UDID]
  local root="$GATE_SLOT_ROOT" claim lstart pgid
  if [ "$4" = 1 ]; then
    printf '%s\n' "${5:-}" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' \
      || return 2
  fi
  mkdir -p "$root" 2>/dev/null || return 2
  claim="$root/claim.$3"
  rm -rf "$claim"
  mkdir "$claim" 2>/dev/null || return 2
  lstart="$(gate_read_lstart "$$")" || { rm -rf "$claim"; return 2; }
  pgid="$(gate_read_pgid "$$")" || { rm -rf "$claim"; return 2; }
  {
    printf 'project=%s\nbranch=%s\ntoken=%s\nhost=%s\n' "$1" "$2" "$3" "$(hostname -s)"
    printf 'pid=%s\nlstart=%s\npgid=%s\nshared=%s\nstate=held\nclaimed=%s\n' \
      "$$" "$lstart" "$pgid" "$4" "$(gate_now)"
    [ "$4" != 1 ] || printf 'udid=%s\n' "$5"
  } > "$claim/owner" || { rm -rf "$claim"; return 2; }
  [ "$(gate_owner_get "$claim/owner" token)" = "$3" ] || { rm -rf "$claim"; return 2; }
  [ "$4" != 1 ] || [ "$(gate_owner_get "$claim/owner" udid)" = "$5" ] || { rm -rf "$claim"; return 2; }
  gate_hook before-claim-rename
  if ! gate_rename_dir "$claim" "$root/sim"; then
    rm -rf "$claim"
    return 1
  fi
  [ "$(gate_owner_get "$root/sim/owner" token)" = "$3" ] || return 1
  GATE_SLOT_HELD=1; GATE_SLOT_TOKEN="$3"; GATE_SLOT_SHARED="$4"; GATE_SIMRELEASE=0
  gate_log "token=$3 slot-claimed project=$1 branch=$2 pid=$$ pgid=$pgid"
  return 0
}
# Names a device before it exists, so a recoverer finds it by name even if its UDID is never written.
gate_slot_note_device() { # NAME
  gate_slot_update device "$1"
}
gate_slot_note_udid() { # UDID NAME
  gate_slot_update udid "$1" || return 1
  gate_slot_update created "$1 $(gate_now)" || return 1
  gate_log "token=$GATE_SLOT_TOKEN device-created udid=$1 name=$2"
}
# Hands the slot back: only this run's, only as a rename, confirmed gone or another run's after.
gate_slot_give_up() {
  local root="$GATE_SLOT_ROOT" aside
  [ "$(gate_owner_get "$root/sim/owner" token)" = "$GATE_SLOT_TOKEN" ] || return 1
  aside="$root/released.$GATE_SLOT_TOKEN"
  rm -rf "$aside"
  gate_rename_dir "$root/sim" "$aside" || return 1
  rm -rf "$aside"
  if [ -d "$root/sim" ] && [ "$(gate_owner_get "$root/sim/owner" token)" = "$GATE_SLOT_TOKEN" ]; then
    return 1
  fi
  GATE_SLOT_HELD=0
  gate_log "token=$GATE_SLOT_TOKEN slot-released"
  return 0
}
# The checked release. Sets GATE_SIMRELEASE (0 released or never held, 1 cleanup not confirmed).
gate_sim_release() {
  local own="$GATE_SLOT_ROOT/sim/owner" ok=0 pgid
  [ "$GATE_SLOT_HELD" = 1 ] || return "$GATE_SIMRELEASE"
  if [ "$(gate_owner_get "$own" token)" != "$GATE_SLOT_TOKEN" ]; then
    gate_log "token=$GATE_SLOT_TOKEN the slot no longer names this run: $(gate_owner_describe "$own")"
    GATE_SLOT_HELD=0; GATE_SIMRELEASE=1
    return 1
  fi
  pgid="$(gate_owner_get "$own" pgid)"
  gate_group_stop "$pgid" "$$" || ok=1
  gate_clear_devices "$own" "$GATE_SLOT_TOKEN" || ok=1
  if [ "$ok" -eq 0 ] && gate_slot_give_up; then
    GATE_SIMRELEASE=0
    return 0
  fi
  gate_slot_update state cleanup-failed
  gate_log "token=$GATE_SLOT_TOKEN slot KEPT, state=cleanup-failed: the run's processes or devices could not be confirmed gone"
  GATE_SLOT_HELD=0
  GATE_SIMRELEASE=1
  return 1
}

# --- recovery under the reap mutex -------------------------------------------------------------------
# Recovers a holder judged stale, whose token was JUDGED. Prints what happened; 0 when sim was
# carried away, 1 otherwise. Never claims sim itself.
gate_reap_release() { # TOKEN
  local root="$GATE_SLOT_ROOT" aside="$GATE_SLOT_ROOT/reap-released.$1"
  [ "$(gate_owner_get "$root/reap/owner" token)" = "$1" ] || return 1
  rm -rf "$aside"
  gate_rename_dir "$root/reap" "$aside" && rm -rf "$aside"
}
gate_slot_recover() { # JUDGED_TOKEN MY_TOKEN
  local root="$GATE_SLOT_ROOT" judged="$1" me="$2" claim verdict lstart pgid
  claim="$root/claim.$me.reap"
  rm -rf "$claim"
  mkdir "$claim" 2>/dev/null || return 1
  lstart="$(gate_read_lstart "$$")" && pgid="$(gate_read_pgid "$$")" || { rm -rf "$claim"; return 1; }
  printf 'token=%s\nhost=%s\npid=%s\nlstart=%s\npgid=%s\nsince=%s\n' \
    "$me" "$(hostname -s)" "$$" "$lstart" "$pgid" "$(gate_now)" > "$claim/owner" || { rm -rf "$claim"; return 1; }
  if ! gate_rename_dir "$claim" "$root/reap"; then
    rm -rf "$claim"
    verdict="$(gate_judge "$root/reap/owner")"
    case "$verdict" in
      stale) gate_log "token=$me REAP-DEAD $(gate_owner_describe "$root/reap/owner") — recovery stays blocked; once its pid is confirmed gone: ssh <build host> rm -rf $root/reap" ;;
      unmeasured) gate_log "token=$me the reap mutex's holder could not be judged: $(gate_owner_describe "$root/reap/owner")" ;;
      *) gate_log "token=$me REAP-STUCK $(gate_owner_describe "$root/reap/owner") ($verdict) — recovery waits for it" ;;
    esac
    return 1
  fi
  gate_hook after-reap-claim
  if [ "$(gate_owner_get "$root/sim/owner" token)" != "$judged" ]; then
    gate_log "token=$me recovery backed off: the slot no longer names $judged"
    gate_reap_release "$me"
    return 1
  fi
  if ! gate_clear_devices "$root/sim/owner" "$me"; then
    gate_log "token=$me recovery of $judged stopped: its devices are not confirmed gone, the slot stays"
    gate_reap_release "$me"
    return 1
  fi
  gate_hook before-reap-rename
  if [ "$(gate_owner_get "$root/sim/owner" token)" != "$judged" ]; then
    gate_log "token=$me recovery backed off: the slot no longer names $judged"
    gate_reap_release "$me"
    return 1
  fi
  if ! gate_rename_dir "$root/sim" "$root/reaped.$(date -u +%Y%m%dT%H%M%SZ).$judged.by.$me"; then
    gate_reap_release "$me"
    return 1
  fi
  gate_log "token=$me reaped the slot of $judged (pid and process group gone, devices confirmed gone)"
  gate_reap_release "$me"
  return 0
}

# --- the simulator admission ---------------------------------------------------------------------
# Waits for every condition and a free slot, then claims it. SHARED_UDID is the shared device's UDID
# (MAC_GATE_SIMULATOR), excluded from the unowned-device term; empty for a private device.
gate_slot_wait_claim() { # PROJECT BRANCH TOKEN SHARED SHARED_UDID
  local rc
  gate_slot_wait_claim_polls "$@"; rc=$?
  rm -f "$GATE_SLOT_ROOT/snapshot.$3"
  return $rc
}
gate_slot_wait_claim_polls() {
  local project="$1" branch="$2" token="$3" shared="$4" shared_udid="${5:-}"
  local root="$GATE_SLOT_ROOT" waited=0 unmeasured_run=0 terms unmeasured space_only
  local free swap mem load devices holder_file verdict holder_names holder_udids line udid state name pat
  GATE_SLOT_WAITED=0
  mkdir -p "$root" 2>/dev/null || { gate_log "token=$token cannot create $root"; return 13; }
  while :; do
    # A run whose controller went away before it held the slot gives up waiting: a device and a
    # test run nobody will read are the slot kept from a run somebody will.
    if [ "${GATE_CONTROLLER_GONE:-0}" = 1 ]; then
      GATE_SLOT_WAITED="$waited"
      gate_log "token=$token REFUSED slot=14 after ${waited}s: the controller went away before the slot was claimed"
      return 14
    fi
    terms=""; unmeasured=""; space_only=0
    if free="$(gate_read_free_kb "$HOME")"; then
      [ "$free" -ge "$GATE_SIM_FREE_FLOOR_KB" ] \
        || terms="$terms free=$(gate_kb_h "$free")<$(gate_kb_h "$GATE_SIM_FREE_FLOOR_KB")"
    else unmeasured="$unmeasured free"; fi
    swap="$(gate_read_swap_mb)" || { swap="?"; unmeasured="$unmeasured swap"; }
    if mem="$(gate_read_memfree_pct)"; then
      [ "$mem" -ge "$GATE_MEMFREE_MIN_PCT" ] || terms="$terms memfree=${mem}%<${GATE_MEMFREE_MIN_PCT}%"
    else unmeasured="$unmeasured memfree"; fi
    if load="$(gate_read_load1)"; then
      awk -v l="$load" -v m="$GATE_LOAD_MAX" 'BEGIN { exit !(l <= m) }' || terms="$terms load=$load>$GATE_LOAD_MAX"
    else unmeasured="$unmeasured load"; fi
    case "$terms" in " free="*) case "${terms# free=}" in *" "*) ;; *) space_only=1 ;; esac ;; esac
    # One snapshot of the record is judged, and the token recovery is later held to is the token
    # of THAT snapshot: read afresh, it could already name the next run.
    holder_file="$root/snapshot.$token"
    holder_names=""; holder_udids=""
    rm -f "$holder_file"
    if [ -d "$root/sim" ] && cp "$root/sim/owner" "$holder_file" 2>/dev/null; then
      holder_names="$(gate_owner_all "$holder_file" device)"
      holder_udids="$(gate_owner_all "$holder_file" udid)"
      space_only=0
      verdict="$(gate_judge "$holder_file")"
      case "$verdict" in
        live) terms="$terms waiting: slot held by $(gate_owner_get "$holder_file" project) $(gate_owner_get "$holder_file" branch) since $(gate_owner_get "$holder_file" claimed) (state=$(gate_owner_get "$holder_file" state))" ;;
        orphan) gate_log "token=$token ORPHAN-HOLDER $(gate_owner_describe "$holder_file") — its pid is gone but its process group lives; waiting"
                terms="$terms slot held by an orphan" ;;
        stale)
          gate_hook after-judge
          if gate_slot_recover "$(gate_owner_get "$holder_file" token)" "$token"; then continue; fi
          terms="$terms slot held by a stale holder not yet recovered" ;;
        *) unmeasured="$unmeasured holder" ;;
      esac
    elif [ -d "$root/sim" ]; then
      space_only=0
      unmeasured="$unmeasured holder"
    fi
    if devices="$(gate_read_devices)"; then
      while IFS='	' read -r udid state name; do
        [ "$state" = Booted ] || continue
        [ "$udid" != "$shared_udid" ] || continue
        case "
$holder_udids
" in *"
$udid
"*) continue ;; esac
        case "
$holder_names
" in *"
$name
"*) continue ;; esac
        for pat in $GATE_DEVICE_PATTERNS; do
          case "$name" in
            $pat) terms="$terms unowned-gate-device=$name($udid)"; space_only=0; break ;;
          esac
        done
      done <<GATE_DEV_EOF
$devices
GATE_DEV_EOF
    else unmeasured="$unmeasured devices"; fi
    if [ -n "$unmeasured" ]; then
      unmeasured_run=$((unmeasured_run + 1))
      gate_log "token=$token unmeasured:$unmeasured (poll $unmeasured_run of $GATE_UNMEASURED_MAX)"
      if [ "$unmeasured_run" -ge "$GATE_UNMEASURED_MAX" ]; then
        GATE_SLOT_WAITED="$waited"
        gate_log "token=$token REFUSED slot=13: $GATE_UNMEASURED_MAX consecutive polls could not measure:$unmeasured"
        return 13
      fi
    elif [ -n "$terms" ]; then
      unmeasured_run=0
    else
      # A claim that cannot even be attempted (no record could be written, or a shared claim
      # without a valid UDID) counts toward the same refusal as an unmeasured reading.
      gate_slot_claim "$project" "$branch" "$token" "$shared" "$shared_udid"
      case $? in
        0) GATE_SLOT_WAITED="$waited"; return 0 ;;
        1) unmeasured_run=0; continue ;;
        *)
          unmeasured_run=$((unmeasured_run + 1))
          gate_log "token=$token the slot claim could not be attempted (poll $unmeasured_run of $GATE_UNMEASURED_MAX)"
          if [ "$unmeasured_run" -ge "$GATE_UNMEASURED_MAX" ]; then
            GATE_SLOT_WAITED="$waited"
            gate_log "token=$token REFUSED slot=13: $GATE_UNMEASURED_MAX consecutive polls could not attempt the claim"
            return 13
          fi ;;
      esac
    fi
    [ -z "$terms" ] || gate_log "token=$token$terms swap_used=${swap}M (waited ${waited}s)"
    if [ "$waited" -ge "$GATE_CEILING_S" ]; then
      GATE_SLOT_WAITED="$waited"
      if [ "$space_only" -eq 1 ] && [ -z "$unmeasured" ]; then
        gate_log "token=$token REFUSED slot=12 after ${waited}s: free space stayed below the floor"
        return 12
      fi
      gate_log "token=$token REFUSED slot=11 after ${waited}s (ceiling ${GATE_CEILING_S}s):$terms"
      return 11
    fi
    "$GATE_SLEEP" "$GATE_POLL_S"
    waited=$((waited + GATE_POLL_S))
  done
}

# --- the run admission (controller side) --------------------------------------------------------------
# READER prints the KiB available to this run (free + its own trees) on one line and exits 0; any
# other answer is unmeasured. 0 admitted, 12 ceiling, 13 unmeasured.
gate_run_admission() { # NEED_KB READER [ARGS...]
  local need="$1" waited=0 unmeasured_run=0 avail rc; shift
  GATE_ADMIT_WAITED=0
  while :; do
    avail="$("$@")"; rc=$?
    if [ "$rc" -eq 0 ] && gate_is_count "$avail"; then
      unmeasured_run=0
      if [ "$avail" -ge "$need" ]; then
        GATE_ADMIT_WAITED="$waited"
        gate_say "admission   : $(gate_kb_h "$avail") available on the build host, threshold $(gate_kb_h "$need") — admitted after ${waited}s"
        return 0
      fi
      gate_say "admission   : $(gate_kb_h "$avail") available, below $(gate_kb_h "$need") — waiting (${waited}s)"
    else
      unmeasured_run=$((unmeasured_run + 1))
      gate_say "admission   : the build host's free space is unmeasured (reader exit $rc, answer '${avail:-}') — poll $unmeasured_run of $GATE_UNMEASURED_MAX"
      if [ "$unmeasured_run" -ge "$GATE_UNMEASURED_MAX" ]; then
        GATE_ADMIT_WAITED="$waited"
        gate_say "admission   : REFUSED admit=13 — nothing was copied"
        return 13
      fi
    fi
    if [ "$waited" -ge "$GATE_CEILING_S" ]; then
      GATE_ADMIT_WAITED="$waited"
      gate_say "admission   : REFUSED admit=12 after ${waited}s below $(gate_kb_h "$need") — nothing was copied"
      return 12
    fi
    "$GATE_SLEEP" "$GATE_POLL_S"
    waited=$((waited + GATE_POLL_S))
  done
}

# An ssh client that goes away is not a signal to the shell on the build host: its next write
# raises SIGPIPE, and a shell killed by that runs no trap, which would leave the slot to a later
# run's recovery. Trapped with this instead, the shell sends the rest of its output to FILE and
# carries on to its own end, where it releases the slot itself.
#
# The line written straight after the redirect is load-bearing. bash 3.2 (the build host's
# /bin/bash) keeps the bytes of the write that failed in its output buffer, and every command
# substitution forked after the redirect would flush them into its own result: the slot's token
# then reads back as "<token>\n<that text>", and the run's own release refuses a slot it holds
# (2026-09-30, merkur). A write here drains them into FILE first; it must not itself fork.
# GATE_CONTROLLER_GONE tells the slot wait that nobody will read this run's result.
gate_on_broken_pipe() { # FILE
  exec >>"$1" 2>&1
  echo "--- the controller's ssh went away; the rest of this run's output lands here"
  GATE_CONTROLLER_GONE=1
}
