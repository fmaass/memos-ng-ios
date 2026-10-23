#!/usr/bin/env bash
#
# The shared build host's admission — scripts/gate-admission.sh — driven against a throwaway slot
# root, fake readers and a fake simctl, with real processes standing in for holders.
#
# Every predicate the simulator admission reads, every way a reading can fail, the slot claim, the
# release, the recovery of a dead holder and both interleavings the plan's reviewers forced
# (two recoverers on one stale holder; a recoverer paused while another waiter polls) are here, as
# is the check that this project's copy of the helper is the one scripts/GATE_ADMISSION_SOURCE
# records. Each assertion reads what the helper did to the slot root, the fake devices or the
# processes — never text this test wrote itself.
#
# Every process that runs gate_sim_release is started in a process group of its own: the release
# stops the rest of its caller's group, and in this shell's group that would be the gate running it.
#
# GATE_ADMISSION_SCRIPT points it at another copy (the mutation proofs).
# Exit: 0 = every case behaved as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
ADMISSION="${GATE_ADMISSION_SCRIPT:-$repo_root/scripts/gate-admission.sh}"
SOURCE_RECORD="$repo_root/scripts/GATE_ADMISSION_SOURCE"
[ -r "$ADMISSION" ] || { echo "FAIL: $ADMISSION is not readable"; exit 1; }
export LC_ALL=C

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-admission-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
bg_pids=""
cleanup() {
  for p in $bg_pids; do kill -KILL "$p" 2>/dev/null; kill -KILL -- "-$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

# --- the fakes -------------------------------------------------------------------------------------
F="$tmp/fake"          # readings: one file per reading; <name>-fail = plausible output, exit 1
SIM="$tmp/sim"         # devices: one file per UDID, "STATE|NAME"; undeletable-<udid> refuses delete
mkdir -p "$F" "$SIM" "$tmp/bin"
cat > "$tmp/bin/df" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$F/df-args"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3 239362496 1 %s 45%% /\n' "\$(cat "$F/free")"
[ ! -e "$F/df-fail" ] || exit 1
EOF
cat > "$tmp/bin/du" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$(cat "$F/du")" "\$2"
[ ! -e "$F/du-fail" ] || exit 1
EOF
cat > "$tmp/bin/sysctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *vm.swapusage*) printf 'total = 8192.00M  used = %s  free = 1.00M  (encrypted)\n' "\$(cat "$F/swap")"
                  [ ! -e "$F/swap-fail" ] || exit 1 ;;
  *vm.loadavg*)   printf '{ %s 1.00 1.00 }\n' "\$(cat "$F/load")"
                  [ ! -e "$F/load-fail" ] || exit 1 ;;
  *) exit 1 ;;
esac
EOF
cat > "$tmp/bin/memory_pressure" <<EOF
#!/usr/bin/env bash
printf 'The system has 17179869184 (1048576 pages with a page size of 16384).\nSystem-wide memory free percentage: %s%%\n' "\$(cat "$F/mem")"
[ ! -e "$F/mem-fail" ] || exit 1
EOF
cat > "$tmp/bin/simctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  list)
    # simctl's JSON shape; a third field "unavailable" writes the record a missing runtime leaves.
    [ "\$2 \$3" = "devices -j" ] || exit 64
    if [ -e "$F/sim-garbage" ]; then echo '{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [ {"udid": '; exit 0; fi
    printf '{\n  "devices" : {\n    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : ['
    sep=""
    for f in "$SIM"/*-*-*-*-*; do
      [ -e "\$f" ] || continue
      case "\${f##*/}" in undeletable-*|stuck-*) continue ;; esac
      IFS='|' read -r state name extra < "\$f"
      if [ "\$extra" = unavailable ]; then
        avail='"availabilityError" : "runtime profile not found using \\"System\\" match policy", "isAvailable" : false'
      else avail='"isAvailable" : true'; fi
      printf '%s\n      { "dataPath" : "/x", "logPath" : "/y", "udid" : "%s", %s, "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "state" : "%s", "name" : "%s" }' \\
        "\$sep" "\${f##*/}" "\$avail" "\$state" "\$name"
      sep=","
    done
    if [ -e "$F/sim-malformed" ]; then printf '%s\n      { "state" : "Booted", "name" : "gate-no-udid", "isAvailable" : true }' "\$sep"; fi
    printf '\n    ]\n  }\n}\n'
    [ ! -e "$F/simctl-fail" ] || exit 1 ;;
  shutdown)
    [ -e "$SIM/\$2" ] || exit 149
    [ ! -e "$SIM/stuck-\$2" ] || exit 1
    IFS='|' read -r state name < "$SIM/\$2"; printf 'Shutdown|%s\n' "\$name" > "$SIM/\$2" ;;
  delete)
    [ -e "$SIM/\$2" ] || exit 1
    [ ! -e "$SIM/undeletable-\$2" ] || exit 1
    rm -f "$SIM/\$2" ;;
  *) exit 1 ;;
esac
EOF
cat > "$tmp/bin/ps-fail" <<'EOF'
#!/usr/bin/env bash
ps "$@"
exit 1
EOF
chmod +x "$tmp/bin/"*

export GATE_DU="$tmp/bin/du" GATE_DF="$tmp/bin/df" GATE_SYSCTL="$tmp/bin/sysctl" GATE_MEMORY_PRESSURE="$tmp/bin/memory_pressure"
export GATE_SIMCTL="$tmp/bin/simctl" GATE_PS=ps
export GATE_SLOT_ROOT="$tmp/slots" GATE_POLL_S=60 GATE_CEILING_S=600 GATE_UNMEASURED_MAX=3
export GATE_SLEEP="$tmp/bin/fake-sleep"
# The fake sleep counts, and runs $tmp/on-sleep with the count if a case put one there.
cat > "$GATE_SLEEP" <<EOF
#!/usr/bin/env bash
n=\$((\$(cat "$tmp/sleeps" 2>/dev/null || echo 0) + 1)); echo "\$n" > "$tmp/sleeps"
[ ! -x "$tmp/on-sleep" ] || "$tmp/on-sleep" "\$n"
exit 0
EOF
chmod +x "$GATE_SLEEP"
sleeps() { cat "$tmp/sleeps" 2>/dev/null || echo 0; }

GIB=1048576
healthy() { # every reading passes, nothing is booted, no slot, no hook
  echo 1048576 > "$F/du"; echo $((20 * GIB)) > "$F/free"; echo 1024.00M > "$F/swap"; echo 40 > "$F/mem"; echo 3.50 > "$F/load"
  rm -f "$F"/*-fail "$F/sim-garbage" "$F/sim-malformed" "$tmp/sleeps" "$tmp/on-sleep" "$SIM"/*
  rm -rf "$GATE_SLOT_ROOT"; mkdir -p "$GATE_SLOT_ROOT"
  unset GATE_TEST_HOOK
}
add_device() { printf '%s|%s\n' "$3" "$2" > "$SIM/$1"; } # UDID NAME STATE
has_device() { [ -e "$SIM/$1" ]; }
dev_state() { cut -d'|' -f1 "$SIM/$1" 2>/dev/null; }
U1=11111111-1111-1111-1111-111111111111
U2=22222222-2222-2222-2222-222222222222
U3=33333333-3333-3333-3333-333333333333

# shellcheck source=scripts/gate-admission.sh
. "$ADMISSION"
HOSTNAME_S="$(hostname -s)"

dead_pid() { ( exit 0 ) & local p=$!; wait "$p"; printf '%s' "$p"; }
# A process in a group of its own, alive until killed: its pid is its pgid.
live_group() { perl -e 'setpgrp(0, 0); exec "sleep", "300"' & LIVE=$!; bg_pids="$bg_pids $LIVE"; sleep 0.2; }
lstart_of() { ps -o lstart= -p "$1" | sed -e 's/^ *//' -e 's/ *$//'; }
# Plants a holder of sim: TOKEN PID LSTART PGID [DEVICE_NAME [UDID]] [SHARED]
plant() {
  mkdir -p "$GATE_SLOT_ROOT/sim"
  {
    printf 'project=other-project\nbranch=fix/other\ntoken=%s\nhost=%s\n' "$1" "$HOSTNAME_S"
    printf 'pid=%s\nlstart=%s\npgid=%s\nshared=%s\nstate=held\nclaimed=2026-09-30T09:00:00Z\n' "$2" "$3" "$4" "${7:-0}"
    [ -z "${5:-}" ] || printf 'device=%s\n' "$5"
    [ -z "${6:-}" ] || printf 'udid=%s\n' "$6"
  } > "$GATE_SLOT_ROOT/sim/owner"
}
slot_token() { gate_owner_get "$GATE_SLOT_ROOT/sim/owner" token; }
# A background run is never waited for without a bound: past it, it is killed and the case fails.
bounded_wait() { local n=0; while kill -0 "$1" 2>/dev/null; do n=$((n + 1)); [ "$n" -le 300 ] || { kill -KILL "$1" 2>/dev/null; break; }; sleep 0.1; done; wait "$1" 2>/dev/null; }
wait_for() { local n=0; while [ ! -e "$1" ]; do n=$((n + 1)); [ "$n" -le 300 ] || return 1; sleep 0.1; done; }

# A run of the helper in a process group of its own: claims, names a device, creates it (fake),
# optionally starts test work in its group, then does what $2 says. Writes $1.rc / .ready / .log.
own_group_run() { # PREFIX ACTION TOKEN [SHARED_UDID [START_FILE]]
  cat > "$1.sh" <<EOF
[ -z "${5:-}" ] || while [ ! -e "${5:-}" ]; do sleep 0.1; done
. "$ADMISSION"
trap 'gate_sim_release; echo \$? > "$1.release"' EXIT
trap 'gate_sim_release; echo \$? > "$1.release"; trap - EXIT; exit 130' INT
trap 'gate_sim_release; echo \$? > "$1.release"; trap - EXIT; exit 143' TERM
trap 'gate_sim_release; echo \$? > "$1.release"; trap - EXIT; exit 129' HUP
trap 'gate_on_broken_pipe "$1.after-pipe"' PIPE
if [ -n "${4:-}" ]; then
  gate_slot_wait_claim proj fix/branch "$3" 1 "${4:-}" || { echo claim-failed > "$1.rc"; exit 9; }
else
  gate_slot_wait_claim proj fix/branch "$3" 0 "" || { echo claim-failed > "$1.rc"; exit 9; }
  gate_slot_note_device "gate-fix-branch-$3"
  printf 'Booted|gate-fix-branch-%s\n' "$3" > "$SIM/\$(printf '%08d-0000-0000-0000-000000000000' \$\$)"
  gate_slot_note_udid "\$(printf '%08d-0000-0000-0000-000000000000' \$\$)" "gate-fix-branch-$3"
fi
sleep 300 & echo \$! > "$1.worker"
: > "$1.ready"
case "$2" in
  exit) exit 0 ;;
  release) kill \$(cat "$1.worker"); gate_sim_release; echo \$? > "$1.rc"; exit 0 ;;
  hold) while [ ! -e "$1.go" ]; do sleep 0.1; done; kill \$(cat "$1.worker"); gate_sim_release; echo \$? > "$1.rc"; exit 0 ;;
  pipe) while [ ! -e "$1.go" ]; do sleep 0.1; done; kill \$(cat "$1.worker"); for i in 1 2 3 4 5; do echo "line \$i" || true; done; gate_sim_release; echo \$? > "$1.rc"; exit 0 ;;
  wait) wait ;;
esac
EOF
  # The build host's script starts from sshd with every signal at its default; a caller under nohup
  # (HUP ignored) or a job shell (INT ignored) would otherwise hand the worker a signal bash may not trap.
  if [ "$2" = pipe ]; then
    ( perl -e '$SIG{$_} = "DEFAULT" for qw(INT QUIT HUP TERM PIPE); setpgrp(0, 0); exec @ARGV' bash "$1.sh" 2>"$1.err" | head -c 1 >/dev/null ) &
  else
    perl -e '$SIG{$_} = "DEFAULT" for qw(INT QUIT HUP TERM PIPE); setpgrp(0, 0); exec @ARGV' bash "$1.sh" > "$1.log" 2>&1 &
  fi
  RUN_PID=$!; bg_pids="$bg_pids $RUN_PID"
}

# --- the helper this project runs is the one recorded ------------------------------------------------
if [ -r "$SOURCE_RECORD" ] && [ "$(wc -l < "$SOURCE_RECORD" | tr -d ' ')" -eq 1 ]; then
  recorded="$(sed -n 's/.*sha256=\([0-9a-f]\{64\}\).*/\1/p' "$SOURCE_RECORD")"
  actual="$(gate_sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }; gate_sha256_of "$repo_root/scripts/gate-admission.sh")"
  if [ -n "$recorded" ] && [ "$recorded" = "$actual" ]; then
    ok "scripts/gate-admission.sh is the copy scripts/GATE_ADMISSION_SOURCE records (sha256 $actual)"
  else
    bad "scripts/gate-admission.sh has sha256 $actual, scripts/GATE_ADMISSION_SOURCE records '${recorded:-nothing}'"
  fi
else
  bad "scripts/GATE_ADMISSION_SOURCE is missing or is not exactly one line"
fi

# --- the slot, free and busy -----------------------------------------------------------------------------
healthy
out="$(gate_slot_wait_claim proj fix/a tokA 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(slot_token)" = tokA ] && [ "$(sleeps)" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'token=tokA slot-claimed'; then
  ok "a free slot is taken at once, and the claim is logged with the run token"
else bad "a free slot: rc $rc, slot token '$(slot_token)', $(sleeps) sleeps"; show "$out"; fi

healthy
own_group_run "$tmp/holder" hold tokH
wait_for "$tmp/holder.ready"
cat > "$tmp/on-sleep" <<EOF
#!/usr/bin/env bash
[ "\$1" -eq 2 ] || exit 0
: > "$tmp/holder.go"
n=0; while [ ! -e "$tmp/holder.rc" ] && [ \$n -lt 100 ]; do sleep 0.1; n=\$((n + 1)); done
EOF
chmod +x "$tmp/on-sleep"
out="$(gate_slot_wait_claim proj fix/b tokB 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sleeps)" -eq 2 ] && [ "$(slot_token)" = tokB ] \
   && [ "$(cat "$tmp/holder.rc" 2>/dev/null)" = 0 ] \
   && printf '%s' "$out" | grep -q 'waiting: slot held by proj fix/branch since'; then
  ok "a busy slot is waited for (naming its holder) and taken once the holder released it"
else bad "busy slot: rc $rc after $(sleeps) sleeps, slot '$(slot_token)', holder release '$(cat "$tmp/holder.rc" 2>/dev/null)'"; show "$out"; fi
rm -rf "$GATE_SLOT_ROOT/sim"

# Two claimants that both found the slot free: the first rename wins, the second waits.
healthy
cat > "$tmp/race-hook" <<EOF
#!/usr/bin/env bash
[ "\$1" = before-claim-rename ] || exit 0
[ ! -e "$tmp/raced" ] || exit 0
: > "$tmp/raced"
GATE_TEST_HOOK= bash -c '. "$ADMISSION"; gate_slot_claim other fix/other tokR 0' >/dev/null 2>&1
EOF
chmod +x "$tmp/race-hook"
export GATE_TEST_HOOK="$tmp/race-hook"
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/c tokC 0 "" 2>&1)"; rc=$?
unset GATE_TEST_HOOK
if [ "$rc" -ne 0 ] && [ "$(slot_token)" = tokR ] && [ ! -e "$GATE_SLOT_ROOT/claim.tokC" ]; then
  ok "of two claimants that both saw the slot free, the one that renamed second does not hold it"
else bad "claim race: rc $rc, the slot names '$(slot_token)' (expected tokR, and tokC refused)"; show "$out"; fi
rm -f "$tmp/raced"

# A branch whose NAME carries the record's own key text must not be read back as the holder's token.
healthy
out="$(gate_slot_wait_claim proj 'fix/token=tokEVIL' tokL 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(slot_token)" = tokL ] \
   && [ "$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" branch)" = 'fix/token=tokEVIL' ]; then
  ok "a branch named 'fix/token=tokEVIL' leaves the record's token tokL (keys match at the line start)"
else bad "key text in a value: rc $rc, token '$(slot_token)'"; show "$out"; fi

# --- conditions ---------------------------------------------------------------------------------------------
term_case() { # NAME SETUP EXPECTED_RC EXPECTED_TERM
  healthy
  eval "$2"
  out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/t tokT 0 "" 2>&1)"; rc=$?
  if [ "$rc" -eq "$3" ] && [ ! -d "$GATE_SLOT_ROOT/sim" ] && [ "$(sleeps)" -eq 2 ] \
     && printf '%s' "$out" | grep -q -- "$4"; then
    ok "$1 alone keeps the wait, logs '$4', and the ceiling refuses with $3"
  else bad "$1: rc $rc (want $3), $(sleeps) sleeps, slot $([ -d "$GATE_SLOT_ROOT/sim" ] && echo taken || echo free)"; show "$out"; fi
}
term_case "free space below the floor" "echo $((7 * GIB)) > '$F/free'" 12 'free=7.0G<8.0G'
term_case "memory free below 20%" "echo 19 > '$F/mem'" 11 'memfree=19%<20%'

# The edges themselves admit: a memory-free of exactly the floor, a load of exactly the ceiling and free
# space of exactly the floor are within bounds, so the comparisons are <= and >=.
healthy
echo 20 > "$F/mem"; echo 24.00 > "$F/load"; echo $((8 * GIB)) > "$F/free"
out="$(gate_slot_wait_claim proj fix/t tokT 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sleeps)" -eq 0 ] && [ "$(slot_token)" = tokT ]; then
  ok "memory free 20%, load 24.00 and free space of exactly the floor admit at once (edges)"
else bad "edges: rc $rc, $(sleeps) sleeps, slot '$(slot_token)'"; show "$out"; fi
term_case "a load of 24.01" "echo 24.01 > '$F/load'" 11 'load=24.01>24'
term_case "an unowned booted gate device" "add_device $U1 gate-fix-old-4242 Booted" 11 "unowned-gate-device=gate-fix-old-4242($U1)"
term_case "an unowned booted device of the third project's gate" "add_device $U1 mac-gate-ipad-77 Booted" 11 'unowned-gate-device=mac-gate-ipad-77'

healthy
add_device "$U1" "wp369-REPASO-1422b" Booted; add_device "$U2" "gate-fix-old-1" Shutdown
out="$(gate_slot_wait_claim proj fix/t tokT 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sleeps)" -eq 0 ]; then
  ok "a booted device outside the gate patterns, and a gate device that is shut down, do not block (control)"
else bad "a non-gate booted device blocked: rc $rc"; show "$out"; fi

healthy
echo 99.10 > "$F/load"
cat > "$tmp/on-sleep" <<EOF
#!/usr/bin/env bash
[ "\$1" -ne 2 ] || echo 5.00 > "$F/load"
EOF
chmod +x "$tmp/on-sleep"
out="$(gate_slot_wait_claim proj fix/t tokT 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sleeps)" -eq 2 ] && [ "$(slot_token)" = tokT ]; then
  ok "a wait ends in ADMISSION once the pressure clears (after 2 polls)"
else bad "pressure clearing: rc $rc after $(sleeps) sleeps"; show "$out"; fi

# Swap used is logged on every wait line and blocks nothing: the host idles at ~6 GiB of it. The wait
# here is the load's, and the admission after it comes with 9 GiB of swap still in use.
healthy
echo 9.00G > "$F/swap"; echo 99.10 > "$F/load"
cat > "$tmp/on-sleep" <<EOF
#!/usr/bin/env bash
[ "\$1" -ne 1 ] || echo 5.00 > "$F/load"
EOF
chmod +x "$tmp/on-sleep"
out="$(gate_slot_wait_claim proj fix/t tokT 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sleeps)" -eq 1 ] && [ "$(slot_token)" = tokT ] \
   && printf '%s' "$out" | grep -q 'load=99.10>24 swap_used=9216M (waited 0s)' \
   && ! printf '%s' "$out" | grep -q 'swap=9216M>'; then
  ok "swap used 9 GiB is logged on the wait line (swap_used=9216M) and does not block the admission after it"
else bad "swap logged, not a term: rc $rc after $(sleeps) sleeps, slot '$(slot_token)'"; show "$out"; fi

# --- readers: a nonzero exit with plausible output is unmeasured, never a reading ------------------------
unmeasured_case() { # NAME SETUP
  healthy
  eval "$2"
  out="$(gate_slot_wait_claim proj fix/u tokU 0 "" 2>&1)"; rc=$?
  if [ "$rc" -eq 13 ] && [ "$(slot_token)" != tokU ] && printf '%s' "$out" | grep -q 'REFUSED slot=13'; then
    ok "$1 exiting nonzero with plausible output is unmeasured, and three such polls refuse with 13"
  else bad "$1 failing: rc $rc (want 13), slot '$(slot_token)'"; show "$out"; fi
}
unmeasured_case "df" ": > '$F/df-fail'"
unmeasured_case "sysctl vm.swapusage" ": > '$F/swap-fail'"
unmeasured_case "memory_pressure" ": > '$F/mem-fail'"
unmeasured_case "sysctl vm.loadavg" ": > '$F/load-fail'"
unmeasured_case "simctl list devices" ": > '$F/simctl-fail'"
unmeasured_case "a device listing cut off mid-record" ": > '$F/sim-garbage'"
unmeasured_case "a device record without a UDID" ": > '$F/sim-malformed'"

# A record a missing runtime leaves is still a device: its deletion is attempted and confirmed only
# once it is really gone, and one that cannot be deleted is stuck, never "confirmed".
healthy
printf '%s|%s|unavailable\n' Shutdown gate-fix-gone-tokV > "$SIM/$U1"
out="$(gate_delete_named gate-fix-gone-tokV tokV 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! has_device "$U1" && printf '%s' "$out" | grep -q "device-deletion-confirmed udid=$U1"; then
  ok "a device whose runtime is missing is listed, deleted, and only then confirmed"
else bad "unavailable-runtime device: rc $rc, device $(has_device "$U1" && echo present || echo gone)"; show "$out"; fi
healthy
printf '%s|%s|unavailable\n' Shutdown gate-fix-gone-tokV > "$SIM/$U1"; : > "$SIM/undeletable-$U1"
out="$(gate_delete_named gate-fix-gone-tokV tokV 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && has_device "$U1" && ! printf '%s' "$out" | grep -q 'device-deletion-confirmed' \
   && printf '%s' "$out" | grep -q "DEVICE-STUCK udid=$U1"; then
  ok "an undeletable device whose runtime is missing is DEVICE-STUCK, never confirmed deleted"
else bad "unavailable-runtime undeletable device: rc $rc (want 1)"; show "$out"; fi
healthy
add_device "$U1" gate-fix-x-tokM Booted; : > "$F/sim-malformed"
out="$(gate_delete_named gate-fix-x-tokM tokM 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q 'device-deletion-confirmed'; then
  ok "a listing with a record it cannot account for leaves a deletion unmeasured (2), never confirmed"
else bad "malformed listing during deletion: rc $rc (want 2)"; show "$out"; fi
live_group; plant tokL "$LIVE" "$(lstart_of "$LIVE")" "$LIVE"
unmeasured_case "ps (judging a holder)" "live_group; plant tokL \"\$LIVE\" \"\$(lstart_of \"\$LIVE\")\" \"\$LIVE\"; export GATE_PS='$tmp/bin/ps-fail'"
export GATE_PS=ps
unmeasured_case "a load line of the wrong form" "echo 'n/a' > '$F/load'"

# --- holders: who is stale, who is not ----------------------------------------------------------------------
healthy
live_group; plant tokL "$LIVE" "$(lstart_of "$LIVE")" "$LIVE" gate-live-dev "$U1"; add_device "$U1" gate-live-dev Booted
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && [ "$(slot_token)" = tokL ] && has_device "$U1"; then
  ok "a live holder is never stolen: its slot and its device stay, the waiter refuses at the ceiling (11)"
else bad "live holder: rc $rc, slot '$(slot_token)'"; show "$out"; fi

healthy
p="$(dead_pid)"; plant tokD "$p" "Thu Jan  1 00:00:00 2026" "$p" gate-dead-dev "$U1"; add_device "$U1" gate-dead-dev Booted
add_device "$U2" gate-dead-dev Shutdown
out="$(gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(slot_token)" = tokS ] && ! has_device "$U1" && ! has_device "$U2" \
   && ls "$GATE_SLOT_ROOT" | grep -q '^reaped\..*\.tokD\.by\.tokS$' && [ ! -e "$GATE_SLOT_ROOT/reap" ]; then
  ok "a dead holder (pid gone, no group) is reclaimed: every device of its recorded name deleted first, then the slot"
else bad "dead holder: rc $rc, slot '$(slot_token)', devices $(ls "$SIM" | tr '\n' ' ')"; show "$out"; fi

healthy
live_group; plant tokP "$LIVE" "Thu Jan  1 00:00:00 2026" "$(dead_pid)"
out="$(gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(slot_token)" = tokS ]; then
  ok "a holder whose pid now belongs to another process (other start time) is reclaimed"
else bad "pid reuse: rc $rc, slot '$(slot_token)'"; show "$out"; fi

healthy
live_group; plant tokG "$(dead_pid)" "Thu Jan  1 00:00:00 2026" "$LIVE"
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && [ "$(slot_token)" = tokG ] && printf '%s' "$out" | grep -q 'ORPHAN-HOLDER'; then
  ok "a dead pid whose process group still lives is NOT reclaimed (ORPHAN-HOLDER on every poll)"
else bad "orphan group: rc $rc, slot '$(slot_token)'"; show "$out"; fi
kill -KILL "$LIVE" 2>/dev/null

healthy
p="$(dead_pid)"; plant tokU "$p" "x" "$p" gate-stuck-dev "$U1"; add_device "$U1" gate-stuck-dev Booted; : > "$SIM/undeletable-$U1"
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && [ "$(slot_token)" = tokU ] && has_device "$U1" && [ ! -e "$GATE_SLOT_ROOT/reap" ] \
   && printf '%s' "$out" | grep -q "DEVICE-STUCK udid=$U1"; then
  ok "a dead holder whose device will not delete is NOT reclaimed: the slot stays fenced, DEVICE-STUCK logged, reap released"
else bad "undeletable device: rc $rc, slot '$(slot_token)', reap $([ -e "$GATE_SLOT_ROOT/reap" ] && echo held || echo free)"; show "$out"; fi

# --- the reap mutex ------------------------------------------------------------------------------------------
healthy
p="$(dead_pid)"; plant tokX "$p" "x" "$p" gate-x-dev "$U1"; add_device "$U1" gate-x-dev Shutdown
q="$(dead_pid)"; mkdir -p "$GATE_SLOT_ROOT/reap"
printf 'token=tokZ\nhost=%s\npid=%s\nlstart=x\npgid=%s\n' "$HOSTNAME_S" "$q" "$q" > "$GATE_SLOT_ROOT/reap/owner"
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && [ "$(slot_token)" = tokX ] && has_device "$U1" && [ -e "$GATE_SLOT_ROOT/reap" ] \
   && printf '%s' "$out" | grep -q 'REAP-DEAD .*rm -rf'; then
  ok "a DEAD reap holder is not replaced: REAP-DEAD with the human step, recovery blocked, nothing admitted"
else bad "dead reap holder: rc $rc, slot '$(slot_token)'"; show "$out"; fi

# Interleaving 1: two recoverers judge one holder stale. A recovers it and claims the slot; B, which
# judged the same holder, must back off on the token under reap and leave A's slot and device alone.
healthy
p="$(dead_pid)"; plant tokX "$p" "x" "$p" gate-x-dev "$U1"; add_device "$U1" gate-x-dev Shutdown
# A is a whole run in a group of its own; it starts only once B has judged the holder stale, and
# holds its slot until told to go.
own_group_run "$tmp/a" hold tokA "" "$tmp/a.start"
cat > "$tmp/b-hook" <<EOF
#!/usr/bin/env bash
[ "\$1" = after-judge ] || exit 0
[ ! -e "$tmp/b-hooked" ] || exit 0
: > "$tmp/b-hooked"
: > "$tmp/a.start"
n=0; while [ ! -e "$tmp/a.ready" ] && [ \$n -lt 300 ]; do sleep 0.1; n=\$((n + 1)); done
EOF
chmod +x "$tmp/b-hook"
cat > "$tmp/on-sleep" <<EOF
#!/usr/bin/env bash
[ "\$1" -eq 1 ] || exit 0
[ "\$(awk -F= '\$1 == "token" { print \$2; exit }' "$GATE_SLOT_ROOT/sim/owner")" = tokA ] && echo intact > "$tmp/a.seen"
: > "$tmp/a.go"
n=0; while [ ! -e "$tmp/a.rc" ] && [ \$n -lt 100 ]; do sleep 0.1; n=\$((n + 1)); done
EOF
chmod +x "$tmp/on-sleep"
export GATE_TEST_HOOK="$tmp/b-hook"
out="$(gate_slot_wait_claim proj fix/b tokB 0 "" 2>&1)"; rc=$?
unset GATE_TEST_HOOK
: > "$tmp/a.go"; bounded_wait "$RUN_PID"
a_dev_deleted_by="$(grep -h 'device-deletion-confirmed.*gate-fix-branch-tokA' "$tmp/a.log" /dev/null | sed -n 's/.*token=\([^ ]*\) .*/\1/p' | head -1)"
if [ "$rc" -eq 0 ] && [ "$(cat "$tmp/a.seen" 2>/dev/null)" = intact ] && [ "$(cat "$tmp/a.rc" 2>/dev/null)" = 0 ] \
   && [ "$a_dev_deleted_by" = tokA ] && printf '%s' "$out" | grep -q 'recovery backed off' \
   && ! printf '%s' "$out" | grep -q 'token=tokB device-deletion-confirmed.*name=gate-fix-branch-tokA' \
   && ! printf '%s' "$out" | grep -q 'reaped the slot of tokA'; then
  ok "two recoverers on one stale holder: the second backs off on the token under reap; the first's run keeps its slot and device until it releases them itself"
else
  bad "two recoverers: B rc $rc, A saw '$(cat "$tmp/a.seen" 2>/dev/null)', A release '$(cat "$tmp/a.rc" 2>/dev/null)', A's device deleted by '${a_dev_deleted_by:-nobody}'"
  show "$out"; show "$(cat "$tmp/a.log" 2>/dev/null)"
fi
rm -f "$tmp/a."* "$tmp/b-hooked"

# Interleaving 2: a recoverer paused inside reap, past any interval, while another waiter polls.
healthy
p="$(dead_pid)"; plant tokX "$p" "x" "$p" gate-x-dev "$U1"; add_device "$U1" gate-x-dev Shutdown
cat > "$tmp/pause-hook" <<EOF
#!/usr/bin/env bash
[ "\$1" = after-reap-claim ] || exit 0
: > "$tmp/r.inreap"
while [ ! -e "$tmp/r.go" ]; do sleep 0.1; done
EOF
chmod +x "$tmp/pause-hook"
cat > "$tmp/r.sh" <<EOF
. "$ADMISSION"
gate_slot_wait_claim proj fix/r tokR 0 ""; echo \$? > "$tmp/r.rc"
EOF
GATE_TEST_HOOK="$tmp/pause-hook" GATE_SLEEP=true perl -e '$SIG{$_} = "DEFAULT" for qw(INT QUIT HUP TERM PIPE); setpgrp(0, 0); exec @ARGV' bash "$tmp/r.sh" > "$tmp/r.log" 2>&1 &
RUN_PID=$!; bg_pids="$bg_pids $RUN_PID"
wait_for "$tmp/r.inreap"
out="$(GATE_CEILING_S=180 gate_slot_wait_claim proj fix/w tokW 0 "" 2>&1)"; rc=$?
w_slot="$(slot_token)"
: > "$tmp/r.go"; bounded_wait "$RUN_PID"
if [ "$rc" -eq 11 ] && [ "$w_slot" = tokX ] && printf '%s' "$out" | grep -q 'REAP-STUCK' \
   && [ "$(cat "$tmp/r.rc" 2>/dev/null)" = 0 ] && [ "$(slot_token)" = tokR ]; then
  ok "a recoverer paused inside reap: the other waiter logs REAP-STUCK and is not admitted; the paused one finishes and is the only run admitted"
else bad "paused recoverer: waiter rc $rc, slot while paused '$w_slot', recoverer rc '$(cat "$tmp/r.rc" 2>/dev/null)', slot after '$(slot_token)'"; show "$out"; fi

# --- release ------------------------------------------------------------------------------------------------
for how in exit INT TERM HUP; do
  healthy
  own_group_run "$tmp/t-$how" "$( [ "$how" = exit ] && echo exit || echo wait )" "tok$how"
  wait_for "$tmp/t-$how.ready"
  worker="$(cat "$tmp/t-$how.worker")"
  [ "$how" = exit ] || kill -"$how" "$RUN_PID"
  bounded_wait "$RUN_PID"
  if [ "$(cat "$tmp/t-$how.release" 2>/dev/null)" = 0 ] && [ ! -d "$GATE_SLOT_ROOT/sim" ] \
     && [ -z "$(ls "$SIM")" ] && ! kill -0 "$worker" 2>/dev/null; then
    ok "release on $how: the run's remaining work is stopped, its device deleted and confirmed, the slot handed back"
  else bad "release on $how: release '$(cat "$tmp/t-$how.release" 2>/dev/null)', slot $([ -d "$GATE_SLOT_ROOT/sim" ] && echo kept || echo free), devices '$(ls "$SIM" | tr '\n' ' ')', worker $(kill -0 "$worker" 2>/dev/null && echo alive || echo gone)"; show "$(cat "$tmp/t-$how.log")"; fi
done

healthy
own_group_run "$tmp/pp" pipe tokPipe
wait_for "$tmp/pp.ready"
: > "$tmp/pp.go"; bounded_wait "$RUN_PID"; n=0
while [ ! -e "$tmp/pp.rc" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
if [ "$(cat "$tmp/pp.rc" 2>/dev/null)" = 0 ] && [ ! -d "$GATE_SLOT_ROOT/sim" ] && [ -z "$(ls "$SIM")" ]; then
  ok "a run whose output reader went away (an ssh drop) carries on to its own release"
else bad "broken pipe: release '$(cat "$tmp/pp.rc" 2>/dev/null)', slot $([ -d "$GATE_SLOT_ROOT/sim" ] && echo kept || echo free)"; fi

healthy
own_group_run "$tmp/cf" hold tokCF
wait_for "$tmp/cf.ready"
cf_udid="$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" udid)"
: > "$SIM/undeletable-$cf_udid"
: > "$tmp/cf.go"; bounded_wait "$RUN_PID"
if [ "$(cat "$tmp/cf.rc" 2>/dev/null)" = 1 ] && [ "$(slot_token)" = tokCF ] \
   && [ "$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" state)" = cleanup-failed ] \
   && [ "$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" udid)" = "$cf_udid" ] && has_device "$cf_udid"; then
  ok "a cleanup that fails keeps the slot, marks it cleanup-failed with the UDID recorded, and the release returns nonzero"
else bad "cleanup failure: release '$(cat "$tmp/cf.rc" 2>/dev/null)', slot '$(slot_token)', state '$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" state)'"; show "$(cat "$tmp/cf.log")"; fi
rm -f "$SIM/undeletable-$cf_udid"
out="$(gate_slot_wait_claim proj fix/n tokN 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(slot_token)" = tokN ] && ! has_device "$cf_udid"; then
  ok "the next waiter retries a cleanup-failed holder's device once its run is gone, then takes the slot"
else bad "cleanup-failed recovery: rc $rc, slot '$(slot_token)'"; show "$out"; fi

healthy
add_device "$U3" "Shared Phone" Booted
own_group_run "$tmp/sh" release tokSH "$U3"
bounded_wait "$RUN_PID"
if [ "$(cat "$tmp/sh.rc" 2>/dev/null)" = 0 ] && has_device "$U3" && [ "$(dev_state "$U3")" = Shutdown ] \
   && [ ! -d "$GATE_SLOT_ROOT/sim" ] && grep -q 'token=tokSH slot-claimed' "$tmp/sh.log"; then
  ok "shared-device mode takes the slot, shuts the device down (confirmed) and never deletes it"
else bad "shared device: release '$(cat "$tmp/sh.rc" 2>/dev/null)', device $(has_device "$U3" && echo "$(dev_state "$U3")" || echo DELETED)"; show "$(cat "$tmp/sh.log")"; fi

# A shared hold exists only with its device's identity in the record: a claim without a valid UDID
# is never attempted, and three such polls refuse the run before any test.
for bad_udid in "" "not-a-udid"; do
  healthy
  out="$(gate_slot_wait_claim proj fix/t tokE 1 "$bad_udid" 2>&1)"; rc=$?
  if [ "$rc" -eq 13 ] && [ ! -d "$GATE_SLOT_ROOT/sim" ]; then
    ok "a shared claim with UDID '$bad_udid' takes no slot and refuses with 13"
  else bad "shared claim with UDID '$bad_udid': rc $rc (want 13), slot '$(slot_token)'"; show "$out"; fi
done
healthy
out="$(gate_slot_wait_claim proj fix/t tokI 1 "$U3" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" udid)" = "$U3" ]; then
  ok "a shared claim's record names its device from the moment the slot exists"
else bad "shared claim record: rc $rc, udid '$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" udid)'"; show "$out"; fi

# A shared hold whose record lost its device cannot be proved clean: the release keeps the slot
# fenced, and a recoverer finding such a dead holder leaves it in place.
healthy
add_device "$U3" "Shared Phone" Booted
own_group_run "$tmp/sn" hold tokSN "$U3"
until [ -e "$tmp/sn.ready" ] || ! kill -0 "$RUN_PID" 2>/dev/null; do sleep 0.1; done
grep -v '^udid=' "$GATE_SLOT_ROOT/sim/owner" > "$tmp/sn.owner"; cat "$tmp/sn.owner" > "$GATE_SLOT_ROOT/sim/owner"
: > "$tmp/sn.go"
bounded_wait "$RUN_PID"
if [ "$(cat "$tmp/sn.rc" 2>/dev/null)" = 1 ] && [ "$(slot_token)" = tokSN ] \
   && [ "$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" state)" = cleanup-failed ] \
   && grep -q 'a shared hold names no device' "$tmp/sn.log"; then
  ok "a shared hold whose record names no device keeps the slot fenced (cleanup-failed, release 1)"
else bad "identity-less shared release: release '$(cat "$tmp/sn.rc" 2>/dev/null)', slot '$(slot_token)', state '$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" state)'"; show "$(cat "$tmp/sn.log")"; fi
healthy
p="$(dead_pid)"; plant tokDS "$p" "Thu Jan  1 00:00:00 2026" "$p" "" "" 1
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/r tokR2 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && [ "$(slot_token)" = tokDS ] && printf '%s' "$out" | grep -q 'a shared hold names no device'; then
  ok "a dead shared holder whose record names no device is never recovered"
else bad "identity-less shared recovery: rc $rc (want 11), slot '$(slot_token)'"; show "$out"; fi

# --- holder-less gate devices (MEMNG-880) ---------------------------------------------------------------------
# A run cut off with its build host can leave its device Booted while no slot record names it. The run
# leaves a record of itself beside the slot, run.<token>, written when it names its device and kept past
# its release; a device is recovered only through that record, judged as strictly as a holder.
H1=670b0364f41928f2; H2=9f2796c808a999ad; H3=4c1d2e3f5a6b7c8d
# Plants the record a run leaves: TOKEN PID LSTART PGID DEVICE_NAME [SHARED [HOST]]
plant_run() {
  {
    printf 'project=other-project\nbranch=fix/old\ntoken=%s\nhost=%s\n' "$1" "${7:-$HOSTNAME_S}"
    printf 'pid=%s\nlstart=%s\npgid=%s\nshared=%s\nstate=held\nclaimed=2026-10-19T19:40:00Z\n' "$2" "$3" "$4" "${6:-0}"
    printf 'device=%s\n' "$5"
  } > "$GATE_SLOT_ROOT/run.$1"
}
untouched_case() { # NAME UDID — the device stays, the wait keeps its term, the ceiling refuses (11)
  out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
  if [ "$rc" -eq 11 ] && has_device "$2" && [ "$(dev_state "$2")" = Booted ] \
     && printf '%s' "$out" | grep -q "unowned-gate-device=.*($2)" && ! printf '%s' "$out" | grep -q 'HOLDERLESS-DEVICE' \
     && [ ! -e "$GATE_SLOT_ROOT/reap" ]; then
    ok "$1"
  else bad "$1: rc $rc, device $(has_device "$2" && dev_state "$2" || echo deleted)"; show "$out"; fi
}

# The incident, through the run's own code: the run names and creates its device, then dies with no trap
# (its build host cut off); the slot record is gone, the device stays Booted.
healthy
own_group_run "$tmp/cut" hold "$H1"
wait_for "$tmp/cut.ready"
cut_udid="$(gate_owner_get "$GATE_SLOT_ROOT/sim/owner" udid)"
kill -KILL -- "-$RUN_PID" 2>/dev/null; bounded_wait "$RUN_PID"
rm -rf "${GATE_SLOT_ROOT:?}/sim"; printf 'token=x\n' > "$GATE_SLOT_ROOT/snapshot.$H1"
out="$(gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sleeps)" -eq 0 ] && [ "$(slot_token)" = tokS ] && [ -n "$cut_udid" ] && ! has_device "$cut_udid" \
   && printf '%s' "$out" | grep -q "HOLDERLESS-DEVICE udid=$cut_udid name=gate-fix-branch-$H1" \
   && printf '%s' "$out" | grep -q "token=tokS device-deletion-confirmed udid=$cut_udid" \
   && [ ! -e "$GATE_SLOT_ROOT/reap" ] && [ ! -e "$GATE_SLOT_ROOT/run.$H1" ]; then
  ok "a Booted gate device of a run cut off without a trap, named by no slot record: its one udid deleted under the reap mutex, HOLDERLESS-DEVICE logged, admitted at once"
else bad "holder-less device of a cut-off run: rc $rc, $(sleeps) sleeps, udid '$cut_udid' $(has_device "$cut_udid" && echo kept || echo deleted), record $([ -e "$GATE_SLOT_ROOT/run.$H1" ] && echo kept || echo gone)"; show "$out"; fi

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "Thu Jan  1 00:00:00 2026" "$p" "gate-fix-old-$H1"
add_device "$U1" "gate-fix-old-$H1" Booted; add_device "$U2" "gate-fix-old-$H1" Shutdown; add_device "$U3" "gate-fix-other-$H2" Booted
p2="$(dead_pid)"; plant_run "$H2" "$p2" "x" "$p2" "gate-fix-other-$H2"
out="$(gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! has_device "$U1" && ! has_device "$U3" && has_device "$U2" && [ "$(dev_state "$U2")" = Shutdown ]; then
  ok "only the Booted udid of a dead run is deleted: a shut-down device of the same name is not touched (one udid per recovery)"
else bad "one udid: rc $rc, devices '$(ls "$SIM" | tr '\n' ' ')'"; show "$out"; fi

healthy
live_group; plant_run "$H1" "$LIVE" "$(lstart_of "$LIVE")" "$LIVE" "gate-fix-live-$H1"; add_device "$U1" "gate-fix-live-$H1" Booted
untouched_case "a holder-less device of a LIVE run is never deleted (its record's pid lives)" "$U1"
kill -KILL "$LIVE" 2>/dev/null

healthy
live_group; plant_run "$H1" "$(dead_pid)" "Thu Jan  1 00:00:00 2026" "$LIVE" "gate-fix-orph-$H1"; add_device "$U1" "gate-fix-orph-$H1" Booted
untouched_case "a holder-less device whose run's pid is gone but whose process group lives is never deleted" "$U1"
kill -KILL "$LIVE" 2>/dev/null

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-far-$H1" 0 some-other-mac; add_device "$U1" "gate-fix-far-$H1" Booted
untouched_case "a holder-less device whose run record names another host is never deleted (its pids cannot be asked about here)" "$U1"

healthy
add_device "$U1" "gate-fix-norec-$H1" Booted
untouched_case "a holder-less device with no run record is left alone: its liveness is unmeasured, not stale" "$U1"

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "" "$p" "gate-fix-nolstart-$H1"; add_device "$U1" "gate-fix-nolstart-$H1" Booted
untouched_case "a run record that cannot be judged (no start time) is unmeasured: the device is left alone" "$U1"

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-sh-$H1" 1; add_device "$U1" "gate-fix-sh-$H1" Booted
untouched_case "a dead run's record that marks its device shared never deletes that device" "$U1"

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-mine-$H1"; add_device "$U1" "gate-fix-mine-$H1" Booted
out="$(gate_slot_wait_claim proj fix/s tokS 1 "$U1" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && has_device "$U1" && [ "$(dev_state "$U1")" = Booted ] && ! printf '%s' "$out" | grep -q 'HOLDERLESS-DEVICE'; then
  ok "the waiter's own shared device is never recovered, even when a dead run's record names it"
else bad "own shared device: rc $rc, device $(has_device "$U1" && dev_state "$U1" || echo deleted)"; show "$out"; fi

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "mac-gate-ipad-77"; add_device "$U1" "mac-gate-ipad-77" Booted
untouched_case "another project's device (mac-gate-ipad-*) is never deleted, even with a dead run record naming it" "$U1"
healthy
p="$(dead_pid)"; plant_run 77 "$p" "x" "$p" "mac-gate-ipad-77"; add_device "$U1" "mac-gate-ipad-77" Booted
untouched_case "another project's device whose name ends in its record's token is never deleted (not gate-*-<token>)" "$U1"

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-x-$H2"; add_device "$U1" "gate-fix-x-$H2" Booted
untouched_case "a record naming a device that carries ANOTHER run's token never deletes it" "$U1"
healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-a-$H1"; add_device "$U1" "gate-fix-b-$H1" Booted; add_device "$U2" "gate-fix-a-$H1" Shutdown
untouched_case "a device carrying a dead run's token under a name its record never wrote is not deleted" "$U1"

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-held-$H1"
live_group; plant tokL "$LIVE" "$(lstart_of "$LIVE")" "$LIVE" "gate-fix-held-$H1"; add_device "$U1" "gate-fix-held-$H1" Booted
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && has_device "$U1" && [ "$(slot_token)" = tokL ] && ! printf '%s' "$out" | grep -q 'HOLDERLESS-DEVICE'; then
  ok "a device the slot's live holder names is the holder's, never a holder-less recovery's"
else bad "held device: rc $rc, device $(has_device "$U1" && echo kept || echo deleted)"; show "$out"; fi
kill -KILL "$LIVE" 2>/dev/null

# Under the reap mutex everything is read again: a run record that reads live there, or a slot that names
# the device there, stops the delete; a device another recoverer already deleted is not an error.
healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-rj-$H1"; add_device "$U1" "gate-fix-rj-$H1" Booted
live_group
cat > "$tmp/rj-hook" <<EOF
#!/usr/bin/env bash
[ "\$1" = after-device-judge ] || exit 0
printf 'token=$H1\nhost=$HOSTNAME_S\npid=$LIVE\nlstart=$(lstart_of "$LIVE")\npgid=$LIVE\nshared=0\ndevice=gate-fix-rj-$H1\n' > "$GATE_SLOT_ROOT/run.$H1"
EOF
chmod +x "$tmp/rj-hook"
out="$(GATE_TEST_HOOK="$tmp/rj-hook" GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && has_device "$U1" && [ ! -e "$GATE_SLOT_ROOT/reap" ] && printf '%s' "$out" | grep -q 'holder-less recovery backed off'; then
  ok "a run record re-judged live under the reap mutex stops the delete (the judgment is taken again where the effect is)"
else bad "re-judge under reap: rc $rc, device $(has_device "$U1" && echo kept || echo deleted)"; show "$out"; fi
kill -KILL "$LIVE" 2>/dev/null

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-sl-$H1"; add_device "$U1" "gate-fix-sl-$H1" Booted
live_group
cat > "$tmp/sl-hook" <<EOF
#!/usr/bin/env bash
[ "\$1" = after-device-judge ] || exit 0
mkdir -p "$GATE_SLOT_ROOT/sim"
printf 'token=tokL\nhost=$HOSTNAME_S\npid=$LIVE\nlstart=$(lstart_of "$LIVE")\npgid=$LIVE\nshared=0\nstate=held\nudid=$U1\n' > "$GATE_SLOT_ROOT/sim/owner"
EOF
chmod +x "$tmp/sl-hook"
out="$(GATE_TEST_HOOK="$tmp/sl-hook" GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && has_device "$U1" && [ "$(slot_token)" = tokL ] && printf '%s' "$out" | grep -q 'holder-less recovery backed off'; then
  ok "a slot record that names the device by the time the reap mutex is held stops the delete"
else bad "slot names device under reap: rc $rc, device $(has_device "$U1" && echo kept || echo deleted)"; show "$out"; fi
kill -KILL "$LIVE" 2>/dev/null

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-gone-$H1"; add_device "$U1" "gate-fix-gone-$H1" Booted
cat > "$tmp/gone-hook" <<EOF
#!/usr/bin/env bash
[ "\$1" = after-device-judge ] || exit 0
rm -f "${SIM:?}/${U1:?}"
EOF
chmod +x "$tmp/gone-hook"
out="$(GATE_TEST_HOOK="$tmp/gone-hook" gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(slot_token)" = tokS ] && [ ! -e "$GATE_SLOT_ROOT/reap" ] \
   && ! printf '%s' "$out" | grep -q "DEVICE-STUCK"; then
  ok "two recoverers on one holder-less device: the second finds it gone under the reap mutex, deletes nothing, and is admitted"
else bad "second recoverer: rc $rc, reap $([ -e "$GATE_SLOT_ROOT/reap" ] && echo held || echo free)"; show "$out"; fi

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-rs-$H1"; add_device "$U1" "gate-fix-rs-$H1" Booted
live_group; mkdir -p "$GATE_SLOT_ROOT/reap"
printf 'token=tokZ\nhost=%s\npid=%s\nlstart=%s\npgid=%s\n' "$HOSTNAME_S" "$LIVE" "$(lstart_of "$LIVE")" "$LIVE" > "$GATE_SLOT_ROOT/reap/owner"
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && has_device "$U1" && [ "$(gate_owner_get "$GATE_SLOT_ROOT/reap/owner" token)" = tokZ ] \
   && printf '%s' "$out" | grep -q 'REAP-STUCK'; then
  ok "a holder-less recovery waits while another recoverer holds the reap mutex (REAP-STUCK), deleting nothing"
else bad "reap held: rc $rc, device $(has_device "$U1" && echo kept || echo deleted)"; show "$out"; fi
kill -KILL "$LIVE" 2>/dev/null

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-stk-$H1"; add_device "$U1" "gate-fix-stk-$H1" Booted; : > "$SIM/undeletable-$U1"; : > "$SIM/stuck-$U1"
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 11 ] && has_device "$U1" && [ ! -e "$GATE_SLOT_ROOT/reap" ] && [ -e "$GATE_SLOT_ROOT/run.$H1" ] \
   && printf '%s' "$out" | grep -q "DEVICE-STUCK udid=$U1"; then
  ok "a holder-less device that will not delete logs DEVICE-STUCK, keeps its run record, releases the reap mutex and keeps the wait"
else bad "stuck holder-less device: rc $rc, reap $([ -e "$GATE_SLOT_ROOT/reap" ] && echo held || echo free)"; show "$out"; fi

# The records: written by the run when it names its device, kept past its own release, and swept by a
# later admission only once their run is judged stale AND no device of theirs is listed.
healthy
own_group_run "$tmp/rec" release "$H3"
bounded_wait "$RUN_PID"
if [ "$(cat "$tmp/rec.rc" 2>/dev/null)" = 0 ] && [ "$(gate_owner_get "$GATE_SLOT_ROOT/run.$H3" token)" = "$H3" ] \
   && [ "$(gate_owner_get "$GATE_SLOT_ROOT/run.$H3" device)" = "gate-fix-branch-$H3" ] \
   && [ "$(gate_owner_get "$GATE_SLOT_ROOT/run.$H3" pid)" = "$RUN_PID" ] \
   && [ -n "$(gate_owner_get "$GATE_SLOT_ROOT/run.$H3" lstart)" ] && [ -n "$(gate_owner_get "$GATE_SLOT_ROOT/run.$H3" pgid)" ]; then
  ok "a run that names its device leaves run.<token> (token, device, pid, start time, group) and keeps it past its own release"
else bad "run record: release '$(cat "$tmp/rec.rc" 2>/dev/null)', record '$(cat "$GATE_SLOT_ROOT/run.$H3" 2>/dev/null | tr '\n' ' ')'"; show "$(cat "$tmp/rec.log")"; fi

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-a-$H1"
live_group; plant_run "$H2" "$LIVE" "$(lstart_of "$LIVE")" "$LIVE" "gate-fix-b-$H2"
q="$(dead_pid)"; plant_run "$H3" "$q" "x" "$q" "gate-fix-c-$H3"; add_device "$U1" "gate-fix-c-$H3" Shutdown
out="$(gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$GATE_SLOT_ROOT/run.$H1" ] && [ -e "$GATE_SLOT_ROOT/run.$H2" ] && [ -e "$GATE_SLOT_ROOT/run.$H3" ]; then
  ok "admission sweeps a dead run's record with no device left, and keeps a live run's and one whose device still exists"
else bad "record sweep: rc $rc, records '$(ls "$GATE_SLOT_ROOT" | grep '^run\.' | tr '\n' ' ')'"; show "$out"; fi
kill -KILL "$LIVE" 2>/dev/null

healthy
p="$(dead_pid)"; plant_run "$H1" "$p" "x" "$p" "gate-fix-a-$H1"; : > "$F/simctl-fail"
out="$(GATE_CEILING_S=120 gate_slot_wait_claim proj fix/s tokS 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 13 ] && [ -e "$GATE_SLOT_ROOT/run.$H1" ]; then
  ok "an unmeasured device listing sweeps no record (a device the reader cannot see is not a device that is gone)"
else bad "sweep on unmeasured: rc $rc, record $([ -e "$GATE_SLOT_ROOT/run.$H1" ] && echo kept || echo gone)"; show "$out"; fi

# --- the run admission (controller side) -------------------------------------------------------------------
reader_value=""; reader_rc=0
fake_run_reader() { printf '%s\n' "$(cat "$tmp/avail")"; return "$(cat "$tmp/avail-rc")"; }
need=$((15 * GIB))
healthy; echo "$need" > "$tmp/avail"; echo 0 > "$tmp/avail-rc"
out="$(gate_run_admission "$need" fake_run_reader 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(sleeps)" -eq 0 ]; then ok "run admission: exactly the threshold is admitted at once"
else bad "run admission at the threshold: rc $rc"; show "$out"; fi
healthy; echo $((need - 1)) > "$tmp/avail"; echo 0 > "$tmp/avail-rc"
out="$(GATE_CEILING_S=120 gate_run_admission "$need" fake_run_reader 2>&1)"; rc=$?
if [ "$rc" -eq 12 ] && [ "$(sleeps)" -eq 2 ]; then ok "run admission: one KiB short waits, and the ceiling refuses with 12"
else bad "run admission below: rc $rc after $(sleeps) sleeps"; show "$out"; fi
healthy; echo "$need" > "$tmp/avail"; echo 1 > "$tmp/avail-rc"
out="$(gate_run_admission "$need" fake_run_reader 2>&1)"; rc=$?
if [ "$rc" -eq 13 ]; then ok "run admission: a reader exiting 1 with a plausible number is unmeasured, and three refuse with 13"
else bad "run admission with a failing reader: rc $rc (want 13)"; show "$out"; fi

# --- the run admission (build host side), driven through the gate's OWN remote text ------------------------
# The controller pipes this text to `ssh bash -s`, where no pipefail of its own reaches; it is taken
# from bin/mac-gate.sh as it stands, and only the two lane helpers it relies on are stood in for.
space_text="$(sed -n "/^      cat <<'SPACE_EOF'\$/,/^SPACE_EOF\$/p" "${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}" | sed '1d;$d')"
mkdir -p "$tmp/lane/target" "$tmp/lane/work"
space_run() {
  { cat "$ADMISSION"
    printf 'gate_work_dir() { echo %s; }\ngate_pressure_sweep() { :; }\n' "'$tmp/lane/work'"
    printf "target='%s'\nbranch=fix/s\ngate_root=%s\nneed=1\n" "$tmp/lane/target" "'$tmp/lane'"
    printf '%s\n' "$space_text"; } | bash -s 2>&1
}
if [ "$(printf '%s\n' "$space_text" | grep -c .)" -ge 2 ]; then
  ok "the gate's remote space-reading text was found ($(printf '%s\n' "$space_text" | grep -c .) lines)"
else bad "the gate's remote space-reading text was not found in bin/mac-gate.sh"; fi
healthy
out="$(space_run)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "FREE_KB $((20 * GIB)) OWN_KB 2097152" ]; then
  ok "the gate's remote reader prints free space and both of the lane's trees (control)"
else bad "remote reader control: rc $rc, '$out'"; fi
space_case() { # NAME SETUP
  healthy
  eval "$2"
  out="$(space_run)"; rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^FREE_KB'; then
    ok "the gate's remote reader: $1 is no reading (rc $rc)"
  else bad "the gate's remote reader accepted $1: rc $rc, '$out'"; fi
}
space_case "df exiting nonzero with a plausible line" ": > '$F/df-fail'"
space_case "du exiting nonzero with a plausible total" ": > '$F/du-fail'"
space_case "du printing a total that is not a number" "echo 'n/a' > '$F/du'"

# The build root is meant to be a volume of its own (MEMNG-602), so a reading of `/` measures the
# wrong disk the moment the image is mounted. The run admission's reader is asked about the lane's
# target, never `/`; and so is the gate's own free-space line after the remote sweep.
healthy; rm -f "$F/df-args"
out="$(space_run)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$F/df-args" 2>/dev/null)" = "-Pk $tmp/lane/target" ]; then
  ok "the gate's remote reader asks df about the lane's target and nothing else ($(cat "$F/df-args"))"
else bad "the gate's remote reader asked df about [$(cat "$F/df-args" 2>/dev/null | tr '\n' ',')], rc $rc"; fi
hygiene_text="$(grep -E '^disk_free="\$\(df ' "${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}")"
mkdir -p "$tmp/pathdf"
cat > "$tmp/pathdf/df" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$F/hygiene-df-args"
printf 'Filesystem Size Used Avail Capacity Mounted on\n/dev/disk8s1 466Gi 9Gi 123Gi 8%% /x\n'
EOF
chmod +x "$tmp/pathdf/df"
if [ "$(printf '%s\n' "$hygiene_text" | grep -c .)" -eq 1 ]; then
  ok "the gate's remote free-space line was found exactly once (control)"
  rm -f "$F/hygiene-df-args"
  out="$( { printf "GATE_TARGET='%s'\n" "$tmp/lane/target"; printf '%s\n' "$hygiene_text" 'echo "free=$disk_free"'; } \
    | PATH="$tmp/pathdf:$PATH" bash -s 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "free=123Gi" ] && [ "$(cat "$F/hygiene-df-args" 2>/dev/null)" = "-h $tmp/lane/target" ]; then
    ok "the gate's remote free-space line reads the target's volume, never / ($(cat "$F/hygiene-df-args"))"
  else bad "the gate's remote free-space line asked df about [$(cat "$F/hygiene-df-args" 2>/dev/null | tr '\n' ',')]: rc $rc, '$out'"; fi
else
  bad "the gate's remote free-space line (disk_free=\"\$(df …) was found $(printf '%s\n' "$hygiene_text" | grep -c .) times, not once"
fi

# --- the controller's ssh goes away ---------------------------------------------------------------------------
# Each script starts with SIGPIPE at its default (a trap cannot be set on a signal ignored at entry)
# and writes only after its reader has exited, which is what a dropped ssh looks like from the host.
pipe_run() { # SCRIPT
  perl -e '$SIG{PIPE} = "DEFAULT"; exec @ARGV' bash "$1" | true
}

# The write that failed must not reach a later reading. The value half discriminates only under
# bash 3.2 (the build host's /bin/bash; bash 5 drops the bytes itself); the handler's own line in
# the file is what it must write on any bash. On 3.2 the drained text lands in the file before it.
healthy
printf 'token=tokD\n' > "$tmp/drop.owner"
rm -f "$tmp/drop.log" "$tmp/drop.value"
cat > "$tmp/drop.sh" <<EOF
. "$ADMISSION"
trap 'gate_on_broken_pipe "$tmp/drop.log"' PIPE
sleep 0.5
echo 'written after the reader went away'
v="\$(gate_owner_get "$tmp/drop.owner" token)"
printf '%s' "\$v" > "$tmp/drop.value"
EOF
pipe_run "$tmp/drop.sh" 2>/dev/null
if [ "$(cat "$tmp/drop.value" 2>/dev/null)" = tokD ] \
   && grep -qxF -- "--- the controller's ssh went away; the rest of this run's output lands here" "$tmp/drop.log" 2>/dev/null; then
  ok "after the ssh drop the output goes on in the file, and the next reading is the record's own token"
else bad "ssh drop: value '$(cat "$tmp/drop.value" 2>/dev/null)', file '$(head -2 "$tmp/drop.log" 2>/dev/null | tr '\n' '|')'"; fi

# A run whose controller went away while it waited stops waiting instead of claiming the slot later.
healthy
echo 99.10 > "$F/load"
rm -f "$tmp/gone.log" "$tmp/gone.rc"
cat > "$tmp/gone.sh" <<EOF
. "$ADMISSION"
trap 'gate_on_broken_pipe "$tmp/gone.log"' PIPE
sleep 0.5
gate_slot_wait_claim proj fix/g tokG 0 ""; echo \$? > "$tmp/gone.rc"
EOF
GATE_CEILING_S=600 pipe_run "$tmp/gone.sh" 2>/dev/null
if [ "$(cat "$tmp/gone.rc" 2>/dev/null)" = 14 ] && [ "$(sleeps)" -eq 1 ] && [ ! -d "$GATE_SLOT_ROOT/sim" ] \
   && grep -q 'REFUSED slot=14 after 60s' "$tmp/gone.log"; then
  ok "a waiter whose controller went away refuses with 14 at its next poll and never claims"
else bad "controller gone while waiting: rc '$(cat "$tmp/gone.rc" 2>/dev/null)' (want 14), $(sleeps) sleeps, slot $([ -d "$GATE_SLOT_ROOT/sim" ] && echo taken || echo free)"; show "$(cat "$tmp/gone.log" 2>/dev/null)"; fi

# Gone before the first poll (the compile outlived the ssh): no reading, no claim, even on a free host.
healthy
out="$(GATE_CONTROLLER_GONE=1 gate_slot_wait_claim proj fix/g tokG 0 "" 2>&1)"; rc=$?
if [ "$rc" -eq 14 ] && [ "$(sleeps)" -eq 0 ] && [ ! -d "$GATE_SLOT_ROOT/sim" ]; then
  ok "a run whose controller is already gone refuses with 14 before claiming a free slot"
else bad "controller gone before the wait: rc $rc (want 14), slot '$(slot_token)'"; show "$out"; fi

# --- the gate: no timer admits -------------------------------------------------------------------------------
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
if [ -r "$GATE" ] && ! grep -qi 'proceeding anyway\|proceeding after' "$GATE" \
   && grep -q 'gate_slot_wait_claim' "$GATE"; then
  ok "the gate has no wait that proceeds without its condition, and calls the slot wait (control)"
else bad "the gate still carries a proceed-anyway wait, or no longer calls gate_slot_wait_claim"; fi

echo "admission-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
