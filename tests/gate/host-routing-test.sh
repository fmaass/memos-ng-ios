#!/usr/bin/env bash
#
# MAC_GATE_HOST=auto (MEMNG-824): the gate picks the build host itself from the per-host lock map
# MAC_GATE_ESTATE_LOCKS, and every run of one worktree holds that worktree's run lock
# (<artifacts>/.run.lock, a kernel flock on descriptor 7) from before its estate lock until it exits.
#
# Every case runs the gate itself against local stubs for ssh and rsync — nothing reaches a build
# host — with lock files of its own, held by background `flock` processes standing in for the
# estate's other gates. "Unreachable" is the stub ssh answering 255 to the reachability probe, so a
# held lock and an absent host are told apart exactly as the gate has to tell them apart. Waits are
# on conditions (a marker file, a process blocked in flock, a pid gone), bounded only so that a
# broken case cannot hang the suite.
#
# The static half holds the descriptor rule by text: every code line that closes 9 in a child or a
# subshell closes 7 too, the five subshells that close 9 with `exec` are named one by one and must
# close 7 as well, and the router's own `exec 9>&-` lines — the parent shell giving up a host lock
# while it keeps the run lock — must NOT close 7. The map's host list must be the mount guard's
# profile names.
#
# Run it directly (`tests/gate/host-routing-test.sh`) or let the gate run it: it is one of the
# selftests every run names. MAC_GATE_SCRIPT points it at another copy of the gate.
#
# Exit: 0 = every case judged as expected; 1 otherwise.
set -uo pipefail
unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCKS MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_SIMULATOR \
  MAC_GATE_HOST_ROUTE MAC_GATE_RUN_LOCK MAC_GATE_RUN_LOCK_WAIT
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
MOUNT_GUARD="$repo_root/scripts/gate-mount-guard.sh"
[ -f "$GATE" ] || { echo "FAIL: $GATE is not a file"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FAIL: flock is not installed; the locks cannot be tested"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-route-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
BG_PIDS=""
cleanup() {
  local p
  : > "$tmp/release-merkur" 2>/dev/null; : > "$tmp/release-mars" 2>/dev/null
  for p in $BG_PIDS; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  chmod -R u+rwx "$tmp" 2>/dev/null
  rm -rf "${tmp:?}"
}
trap cleanup EXIT

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

NAMED="$(sed -n 's/^for selftest_name in \(.*\); do$/\1/p' "$GATE")"
OLD_HEADER="$(printf 'lock_requested_utc\tlock_acquired_utc\tremote_start_utc\tremote_end_utc\trepo\tbranch\trun_token\tmode\texit\twall_s\tslot_wait_s\tlog_path')"
NEW_HEADER="$OLD_HEADER$(printf '\thost')"
L_MERKUR="$tmp/locks/merkur.lock"
L_MARS="$tmp/locks/mars.lock"
mkdir -p "$tmp/locks"
: > "$L_MERKUR"; : > "$L_MARS"
MAP="merkur=$L_MERKUR,mars=$L_MARS"

# --- the fixture ----------------------------------------------------------------------------------
new_repo() {
  local name="$1" work="$tmp/$1" origin="$tmp/$1.git" stub
  git init --quiet --bare "$origin" || return 1
  git init --quiet -b main "$work" || return 1
  git -C "$work" config user.email gate-test@example.invalid
  git -C "$work" config user.name "gate test"
  git -C "$work" config commit.gpgsign false
  git -C "$work" config core.hooksPath "$tmp/no-hooks"
  mkdir -p "$work/docs" "$work/Sources" "$work/tests/gate" "$work/scripts"
  printf 'a guide\n' > "$work/docs/guide.md"
  printf 'let app = 1\n' > "$work/Sources/App.swift"
  printf '.gate-artifacts/\n' > "$work/.gitignore"
  {
    printf 'targets:\n'
    printf '  MemosNG:\n'
    printf '    settings:\n'
    printf '      MARKETING_VERSION: "9.9.9"\n'
    printf '      CURRENT_PROJECT_VERSION: "999"\n'
  } > "$work/project.yml"
  for stub in $NAMED; do
    printf '#!/bin/sh\necho "%s stub ok"\nexit 0\n' "$stub" > "$work/tests/gate/$stub"
    chmod +x "$work/tests/gate/$stub"
  done
  printf 'gate_lane_is_unlocked() { return 0; }\n' > "$work/scripts/reap-gate-lanes.sh"
  cp "$repo_root/scripts/gate-admission.sh" "$work/scripts/gate-admission.sh" || return 1
  cp "$repo_root/scripts/release-version-rule.sh" "$work/scripts/release-version-rule.sh" || return 1
  cp "$repo_root/scripts/gate-mount-guard.sh" "$work/scripts/gate-mount-guard.sh" || return 1
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  git -C "$work" checkout --quiet -b fix/route-src
  printf 'let two = 2\n' >> "$work/Sources/App.swift"
  git -C "$work" commit --quiet -am "a source change, so the run owes the build host" || return 1
  printf '%s' "$work"
}

# ssh and rsync, replaced. A call whose last argument is `true` is the gate's reachability probe:
# hosts named in STUB_UNREACHABLE never answer it, and a host:n pair in STUB_DOWN_AFTER answers its
# first n probes and none after. Every call is recorded in $STUB_DIR/calls.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/tmp"
  : > "$dir/calls"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
if [ "$#" -ge 2 ] && [ "${!#}" = true ]; then
  args=("$@"); h="${args[$(($# - 2))]}"
  echo "probe $h" >> "$STUB_DIR/calls"
  n="$(grep -c "^probe $h\$" "$STUB_DIR/calls")"
  for u in ${STUB_UNREACHABLE:-}; do [ "$u" = "$h" ] && exit 255; done
  for d in ${STUB_DOWN_AFTER:-}; do
    [ "${d%%:*}" = "$h" ] && [ "$n" -gt "${d#*:}" ] && exit 255
  done
  exit 0
fi
case "$*" in
  *simctl*) echo "ssh simctl" >> "$STUB_DIR/calls"; exit 1 ;;
esac
script="$(cat)"
case "$script" in
  *'
gate_mount_guard report '*) echo "ssh mount" >> "$STUB_DIR/calls"; echo "MOUNT OK uuid=stub dev=/dev/disk8s1"; echo "mountguard=enforced marker=not-read"; exit 0 ;;
  *'gate_lane_space "$target"'*) echo "ssh admission" >> "$STUB_DIR/calls"; echo "FREE_KB 99999999 OWN_KB 0"; exit 0 ;;
  *MAC_GATE_STEP*)
    echo "ssh remote" >> "$STUB_DIR/calls"
    [ -z "${STUB_REMOTE_OUT:-}" ] || cat "$STUB_REMOTE_OUT"
    exit 0 ;;
  *gate_root_raw*)
    echo "ssh preflight" >> "$STUB_DIR/calls"
    branch="$(printf '%s\n' "$script" | sed -n "s/^branch='\(.*\)'\$/\1/p" | head -1)"
    root="/Users/gate/build/memos-ng-ios/gate"
    echo "LOCK ACQUIRED"
    echo "LOCKDIR $root/$branch.lock"
    echo "GATE_ROOT $root"
    echo "TARGET $root/$branch"
    exit 0 ;;
esac
echo "ssh other" >> "$STUB_DIR/calls"
exit 0
SSH_EOF
  cat > "$dir/bin/rsync" <<'RSYNC_EOF'
#!/usr/bin/env bash
echo "rsync" >> "$STUB_DIR/calls"
exit 0
RSYNC_EOF
  chmod +x "$dir/bin/ssh" "$dir/bin/rsync"
}

REMOTE_TXT="$tmp/remote.txt"
cat > "$REMOTE_TXT" <<'EOF'
MAC_GATE_REMOTE_CLOCK start=1759300000
::: xcodegen :::
MAC_GATE_STEP xcodegen 0 t=3
::: xcodebuild :::
MAC_GATE_SLOT slot=0 slot_wait=4 simrelease=0
MAC_GATE_STEP xcodebuild 0 t=7
MAC_GATE_REMOTE_CLOCK end=1759300010
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 xcodebuild=0 wall=10 | exit=0
EOF

# One stub directory per run; ART (the artifacts directory, i.e. the worktree's run lock) and
# LEDGER per case, so two runs of "one worktree" share ART.
new_case() {
  CASE_DIR="$tmp/case-$1"
  mkdir -p "$CASE_DIR"
  ART="$CASE_DIR/artifacts"
  LEDGER="$CASE_DIR/gate-runs.tsv"
}
gate_env() { # $1 = stub dir; reads HOST, and MAPV, SINGLE, PAUSE, UNREACH, DOWN_AFTER when set
  GATE_ENV=(env -u MAC_GATE_BRANCH -u MAC_GATE_RUN_COPY -u MAC_GATE_ESTATE_LOCK -u MAC_GATE_ESTATE_LOCKS
    -u MAC_GATE_ESTATE_LOCK_STAMPS -u MAC_GATE_RUNS_LOGS -u MAC_GATE_SELFTEST_PAUSE_DIR
    -u MAC_GATE_HOST_ROUTE -u MAC_GATE_RUN_LOCK -u MAC_GATE_RUN_LOCK_WAIT
    "PATH=$1/bin:$PATH" TMPDIR="$1/tmp"
    MAC_GATE_HOST="$HOST" MAC_GATE_ARTIFACTS="$ART" MAC_GATE_RUNS_LEDGER="$LEDGER" STUB_DIR="$1"
    STUB_REMOTE_OUT="$REMOTE_TXT" STUB_UNREACHABLE="${UNREACH:-}" STUB_DOWN_AFTER="${DOWN_AFTER:-}")
  [ -z "${MAPV:-}" ] || GATE_ENV+=(MAC_GATE_ESTATE_LOCKS="$MAPV")
  [ -z "${SINGLE:-}" ] || GATE_ENV+=(MAC_GATE_ESTATE_LOCK="$SINGLE")
  [ -z "${PAUSE:-}" ] || GATE_ENV+=(MAC_GATE_SELFTEST_PAUSE_DIR="$PAUSE")
}
run_gate() { # $1 = stub dir name, then gate arguments; sets OUT, RC, SD
  SD="$CASE_DIR/$1"; shift
  make_stubs "$SD"
  gate_env "$SD"
  OUT="$(cd "$W" && "${GATE_ENV[@]}" timeout 120 "$GATE" "$@" 2>&1)"
  RC=$?
}
# Started in the background with exec all the way down, so $! IS the gate's pid.
start_gate() { # $1 = stub dir name, $2 = output file, then gate arguments; sets PID, SD
  local out="$2"
  SD="$CASE_DIR/$1"; shift 2
  make_stubs "$SD"
  gate_env "$SD"
  ( cd "$W" && exec "${GATE_ENV[@]}" "$GATE" "$@" > "$out" 2>&1 ) &
  PID=$!
  BG_PIDS="$BG_PIDS $PID"
}
wait_for_file() { # $1 = path, $2 = pid that must stay alive meanwhile
  local n=0
  while [ ! -e "$1" ]; do
    kill -0 "$2" 2>/dev/null || return 1
    n=$((n + 1)); [ "$n" -le 400 ] || return 1
    sleep 0.05
  done
}
blocked_in_flock() {
  ps -e -o pid=,ppid=,comm= | awk -v root="$1" '
    { parent[$1] = $2; name[$1] = $3 }
    END {
      for (p in name) {
        if (name[p] != "flock") continue
        q = p
        while (q in parent && q != 1 && q != 0) { q = parent[q]; if (q == root) { print p; exit } }
      }
    }' | grep -q .
}
wait_blocked() { # $1 = pid
  local n=0
  until blocked_in_flock "$1"; do
    kill -0 "$1" 2>/dev/null || return 1
    n=$((n + 1)); [ "$n" -le 400 ] || return 1
    sleep 0.05
  done
}
wait_gone() { # $1 = pid, $2 = bound in 0.05 s polls; 0 once it has exited
  local n=0
  while kill -0 "$1" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -le "$2" ] || return 1
    sleep 0.05
  done
  wait "$1" 2>/dev/null
  return 0
}

# A stand-in for another gate holding a host's estate lock until released.
hold() { # $1 = merkur|mars
  local lock="$tmp/locks/$1.lock" n=0
  rm -f "$tmp/release-$1"
  flock "$lock" bash -c 'while [ ! -e "$0" ]; do sleep 0.05; done' "$tmp/release-$1" </dev/null >/dev/null 2>&1 &
  BG_PIDS="$BG_PIDS $!"
  eval "HOLDER_$1=$!"
  while flock -n "$lock" true; do
    n=$((n + 1)); [ "$n" -le 200 ] || return 1
    sleep 0.05
  done
}
release() { # $1 = merkur|mars
  local pid
  : > "$tmp/release-$1"
  eval "pid=\${HOLDER_$1:-}"
  [ -z "$pid" ] || wait "$pid" 2>/dev/null
  eval "HOLDER_$1="
}
is_free() { flock -n "$1" true; }

route_of() { printf '%s\n' "$1" | sed -n 's/^route       : //p' | head -1; }
line_of() { printf '%s\n' "$1" | grep -m1 -- "$2"; }
field() { printf '%s\n' "$1" | awk -F '\t' -v n="$2" '{ print $n }'; }
last_row() { tail -n 1 "$LEDGER" 2>/dev/null; }
epoch_of() { date -u -d "$1" +%s 2>/dev/null; }

W="$(new_repo src)" || { echo "FAIL: cannot build the fixture"; exit 1; }

# --- case 1: both free → merkur, the first in order; host= on the summary and the ledger ---------
new_case free-merkur
HOST=auto MAPV="$MAP" run_gate a
r="$(route_of "$OUT")"
summary="$(line_of "$OUT" '^mac-gate SUMMARY:')"
if [ "$RC" -eq 0 ] && [[ "$r" == "host=merkur reason=free:merkur "* ]] && [[ "$r" =~ \ worktree_wait=[0-9]+s\ pid=[0-9]+\ token=[0-9a-f]+$ ]] \
   && [[ "$summary" == *" host=merkur locallint=- | exit=0" ]] \
   && printf '%s\n' "$OUT" | grep -qx 'host        : merkur'; then
  ok "free merkur → merkur: exit 0, route [$r], summary ends host=merkur locallint=- | exit=0"
else
  bad "free merkur: exit $RC, route [$r], summary [$summary]"; show "$OUT"
fi
if [ "$(head -n 1 "$LEDGER" 2>/dev/null)" = "$NEW_HEADER" ] && [ "$(grep -c . "$LEDGER")" -eq 2 ] \
   && [ "$(last_row | awk -F '\t' '{ print NF }')" = 13 ] && [ "$(field "$(last_row)" 13)" = merkur ]; then
  ok "free merkur: a new ledger gets the 13-name header and a 13-field row naming merkur"
else
  bad "free merkur: ledger is not a 13-name header plus one 13-field row naming merkur"; show "$(cat "$LEDGER" 2>/dev/null)"
fi
if read -r m_host m_branch m_time m_token < "$ART/lane-host" 2>/dev/null \
   && [ "$m_host" = merkur ] && [ "$m_branch" = fix/route-src ] && [ -n "$(epoch_of "$m_time")" ] \
   && [ "$m_token" = "$(field "$(last_row)" 7)" ]; then
  ok "free merkur: the run that reached the remote left lane-host = merkur fix/route-src <utc> <its token>"
else
  bad "free merkur: lane-host is not this run's warm marker"; show "$(cat "$ART/lane-host" 2>/dev/null)"
fi
if is_free "$L_MERKUR" && is_free "$L_MARS" && grep -qx 'probe merkur' "$SD/calls" && ! grep -q 'probe mars' "$SD/calls"; then
  ok "free merkur: only merkur was probed, and both locks are free after the run"
else
  bad "free merkur: probes or locks after the run are wrong"; show "$(cat "$SD/calls")"
fi

# --- case 2: merkur held → mars; the quick line carries host=mars ---------------------------------
new_case merkur-held
hold merkur || bad "merkur-held: the stand-in could not take merkur's lock"
HOST=auto MAPV="$MAP" run_gate a --quick
release merkur
r="$(route_of "$OUT")"
quick="$(line_of "$OUT" '^MAC_GATE_QUICK: ')"
if [[ "$r" == "host=mars reason=free:mars (merkur held) "* ]] && [[ "$quick" == *" host=mars locallint=- | exit=$RC" ]] \
   && [ "$(printf '%s\n' "$OUT" | grep -c '^MAC_GATE_QUICK: ')" -eq 1 ] && [ "$(field "$(last_row)" 13)" = mars ]; then
  ok "merkur held → mars: route [$r], quick line [$quick], ledger host mars"
else
  bad "merkur held: route [$r], quick [$quick], exit $RC"; show "$OUT"
fi

# --- case 3: both held; merkur released after 3 s, the run proceeds there ------------------------
new_case both-held
hold merkur && hold mars || bad "both-held: the stand-ins could not take both locks"
HOST=auto MAPV="$MAP" start_gate a "$CASE_DIR/out.txt"
if wait_blocked "$PID"; then
  sleep 3
  blocked_in_flock "$PID" && b3=yes || b3=no
  release merkur
  wait_gone "$PID" 1200
  rc=$?
  out="$(cat "$CASE_DIR/out.txt")"
  r="$(route_of "$out")"
  if [ "$b3" = yes ] && [ "$rc" -eq 0 ] && [[ "$r" == "host=merkur reason=busy:both -> waited on merkur (first in order) "* ]] \
     && [ "$(field "$(last_row)" 13)" = merkur ]; then
    ok "both held: blocked 3 s, then ran on merkur once released: route [$r]"
  else
    bad "both held: still blocked at 3 s [$b3], route [$r]"; show "$out"
  fi
else
  bad "both held: the run never blocked on a lock"; show "$(cat "$CASE_DIR/out.txt")"
fi
release mars; release merkur

# --- cases 4-6: both held; the warm marker decides only when fresh and of this branch ------------
warm_case() { # $1 = label, $2 = marker text, $3 = the host the run must wait on
  local label="$1" marker="$2" want="$3" r out
  new_case "warm-$4"
  mkdir -p "$ART"
  printf '%s\n' "$marker" > "$ART/lane-host"
  hold merkur && hold mars || bad "$label: the stand-ins could not take both locks"
  HOST=auto MAPV="$MAP" start_gate a "$CASE_DIR/out.txt"
  if ! wait_blocked "$PID"; then
    bad "$label: the run never blocked"; show "$(cat "$CASE_DIR/out.txt")"; release merkur; release mars; return
  fi
  release "$want"
  if wait_gone "$PID" 400; then
    out="$(cat "$CASE_DIR/out.txt")"; r="$(route_of "$out")"
    case "$r" in
      "host=$want reason=busy:both -> waited on $want ("*) ok "$label: waited on $want: route [$r]" ;;
      *) bad "$label: route [$r]"; show "$out" ;;
    esac
  else
    bad "$label: releasing $want did not let the run go — it waits on the other host"
  fi
  release merkur; release mars
  wait_gone "$PID" 1200
}
now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
old_utc="$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)"
warm_case "fresh marker for this branch" "mars fix/route-src $now_utc feedface" mars fresh
warm_case "stale marker (25 h)" "mars fix/route-src $old_utc feedface" merkur stale
warm_case "marker of another branch" "mars fix/other $now_utc feedface" merkur other
if grep -q 'waited on mars (warm lane)' "$tmp/case-warm-fresh/out.txt" 2>/dev/null; then
  ok "fresh marker: the route names the warm lane as the reason"
else
  bad "fresh marker: the route does not say (warm lane)"
fi

# --- case 7: merkur held, mars unreachable → waits on merkur -------------------------------------
new_case mars-unreachable
hold merkur || bad "mars-unreachable: the stand-in could not take merkur's lock"
UNREACH=mars HOST=auto MAPV="$MAP" start_gate a "$CASE_DIR/out.txt"
if wait_blocked "$PID"; then
  is_free "$L_MARS" && mars_free=yes || mars_free=no
  release merkur
  wait_gone "$PID" 1200
  out="$(cat "$CASE_DIR/out.txt")"; r="$(route_of "$out")"
  if [ "$mars_free" = yes ] && [[ "$r" == "host=merkur reason=busy:merkur (mars unreachable) -> waited on merkur (first in order) "* ]]; then
    ok "merkur held, mars unreachable: mars's lock let go, waited on merkur: route [$r]"
  else
    bad "merkur held, mars unreachable: mars free while waiting [$mars_free], route [$r]"; show "$out"
  fi
else
  bad "merkur held, mars unreachable: the run never blocked"; show "$(cat "$CASE_DIR/out.txt")"
fi
release merkur

# --- case 8: merkur free but unreachable → skipped, mars ------------------------------------------
new_case merkur-unreachable
UNREACH=merkur HOST=auto MAPV="$MAP" run_gate a
r="$(route_of "$OUT")"
if [ "$RC" -eq 0 ] && [[ "$r" == "host=mars reason=free:mars (merkur unreachable) "* ]]; then
  ok "free but unreachable merkur skipped: route [$r]"
else
  bad "unreachable merkur: exit $RC, route [$r]"; show "$OUT"
fi

# --- case 9: the waited-on host goes away during the wait → back to the choice --------------------
new_case lost-during-wait
hold merkur && hold mars || bad "lost-during-wait: the stand-ins could not take both locks"
DOWN_AFTER=merkur:1 HOST=auto MAPV="$MAP" start_gate a "$CASE_DIR/out.txt"
if wait_blocked "$PID"; then
  release merkur
  n=0
  until [ "$(grep -c '^probe merkur$' "$SD/calls")" -ge 2 ] && blocked_in_flock "$PID"; do
    n=$((n + 1)); [ "$n" -le 400 ] || break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05
  done
  is_free "$L_MERKUR" && merkur_let_go=yes || merkur_let_go=no
  release mars
  wait_gone "$PID" 1200
  out="$(cat "$CASE_DIR/out.txt")"; r="$(route_of "$out")"
  if [ "$merkur_let_go" = yes ] && [[ "$r" == "host=mars reason="*"merkur unreachable after the wait"*"-> waited on mars"* ]] \
     && [ "$(field "$(last_row)" 13)" = mars ]; then
    ok "merkur lost after the take: its lock let go, the run waited on mars: route [$r]"
  else
    bad "lost during wait: merkur let go [$merkur_let_go], route [$r]"; show "$out"; show "$(cat "$SD/calls")"
  fi
else
  bad "lost during wait: the run never blocked"; show "$(cat "$CASE_DIR/out.txt")"
fi
release merkur; release mars

# --- case 10: every host unreachable → exit 15, nothing held, nothing sent -----------------------
new_case all-unreachable
UNREACH="merkur mars" HOST=auto MAPV="$MAP" run_gate a
if [ "$RC" -eq 15 ] && printf '%s\n' "$OUT" | grep -q 'merkur=unreachable mars=unreachable' \
   && is_free "$L_MERKUR" && is_free "$L_MARS" && [ ! -s "$LEDGER" ] && ! grep -q '^rsync$\|^ssh ' "$SD/calls"; then
  ok "all unreachable: exit 15 naming each host's state, no lock held, no row, nothing sent"
else
  bad "all unreachable: exit $RC"; show "$OUT"; show "$(cat "$SD/calls")"
fi
new_case busy-unreachable
hold merkur || bad "busy-unreachable: the stand-in could not take merkur's lock"
UNREACH="merkur mars" HOST=auto MAPV="$MAP" run_gate a
release merkur
if [ "$RC" -eq 15 ] && printf '%s\n' "$OUT" | grep -q 'merkur=busy-unreachable mars=unreachable'; then
  ok "held and unreachable merkur, unreachable mars: exit 15 naming busy-unreachable"
else
  bad "busy-unreachable: exit $RC"; show "$OUT"
fi

# --- cases 11-12: auto without the map, or a host outside the list → refused before any lock -----
new_case no-map
HOST=auto run_gate a
if [ "$RC" -eq 15 ] && printf '%s\n' "$OUT" | grep -q 'MAC_GATE_ESTATE_LOCKS' && [ ! -e "$ART/.run.lock" ]; then
  ok "auto without the map: exit 15 before the run lock"
else
  bad "auto without the map: exit $RC, artifacts [$(ls -a "$ART" 2>/dev/null | tr '\n' ' ')]"; show "$OUT"
fi
new_case unknown-host
HOST=auto MAPV="merkur=$CASE_DIR/m.lock,venus=$CASE_DIR/v.lock" run_gate a
if [ "$RC" -eq 15 ] && printf '%s\n' "$OUT" | grep -q 'venus' && [ ! -e "$CASE_DIR/m.lock" ] && [ ! -e "$CASE_DIR/v.lock" ] \
   && [ ! -e "$ART/.run.lock" ]; then
  ok "unknown host in the map: exit 15 naming it, no lock file opened, no run lock"
else
  bad "unknown host in the map: exit $RC"; show "$OUT"
fi

# --- case 13: an explicit host with MAC_GATE_ESTATE_LOCK keeps today's stamps ---------------------
new_case explicit-single
HOST=merkur SINGLE="$L_MERKUR" run_gate a
req="$(printf '%s\n' "$OUT" | sed -n 's/^estate lock : lock_requested=\([^ ]*\) (taken by this run before its copy was made)$/\1/p')"
acq="$(printf '%s\n' "$OUT" | sed -n 's/^estate lock : lock_acquired=\(.*\)$/\1/p')"
row="$(last_row)"
if [ "$RC" -eq 0 ] && [ -n "$(epoch_of "$req")" ] && [ -n "$(epoch_of "$acq")" ] \
   && [ "$(field "$row" 1)" = "$req" ] && [ "$(field "$row" 2)" = "$acq" ] && [ "$(field "$row" 13)" = merkur ] \
   && [[ "$(route_of "$OUT")" == "host=merkur reason=explicit:MAC_GATE_ESTATE_LOCK "* ]]; then
  ok "explicit merkur + MAC_GATE_ESTATE_LOCK: both stamps as before, in the log and fields 1-2, host merkur in field 13"
else
  bad "explicit single lock: exit $RC, stamps [$req] [$acq], row [$row]"; show "$OUT"
fi

# --- case 14: an explicit host with only the map takes map[host] ---------------------------------
new_case explicit-map
mkdir -p "$CASE_DIR/pause"
HOST=mars MAPV="$MAP" PAUSE="$CASE_DIR/pause" start_gate a "$CASE_DIR/out.txt"
if wait_for_file "$CASE_DIR/pause/paused" "$PID"; then
  is_free "$L_MARS" && mars_state=free || mars_state=held
  is_free "$L_MERKUR" && merkur_state=free || merkur_state=held
  : > "$CASE_DIR/pause/resume"
  wait_gone "$PID" 1200
  if [ "$mars_state" = held ] && [ "$merkur_state" = free ]; then
    ok "explicit mars with the map: the run held mars's lock and not merkur's"
  else
    bad "explicit mars with the map: mars [$mars_state], merkur [$merkur_state]"
  fi
else
  bad "explicit map: the run never paused"; show "$(cat "$CASE_DIR/out.txt")"
fi

# --- case 15: an existing 12-name ledger is appended to, never rewritten ------------------------
new_case old-ledger
{
  printf '%s\n' "$OLD_HEADER"
  printf '2026-10-14T10:00:00Z\t2026-10-14T10:01:00Z\t-\t-\tmemos-ng-ios\tfix/a\taaaa\tquick\t0\t-\t-\t/x/a.log\n'
  printf '2026-10-14T11:00:00Z\t2026-10-14T11:01:00Z\t-\t-\tmemos-ng-ios\tfix/b\tbbbb\tfull\t65\t-\t-\t/x/b.log\n'
} > "$LEDGER"
before="$(head -n 3 "$LEDGER" | sha256sum)"
HOST=auto MAPV="$MAP" run_gate a
if [ "$RC" -eq 0 ] && [ "$(head -n 3 "$LEDGER" | sha256sum)" = "$before" ] && [ "$(grep -c . "$LEDGER")" -eq 4 ] \
   && [ "$(last_row | awk -F '\t' '{ print NF }')" = 13 ] && [ "$(field "$(last_row)" 13)" = merkur ]; then
  ok "old ledger: header and old rows byte-identical (sha256 of lines 1-3), one 13-field row below them"
else
  bad "old ledger: exit $RC"; show "$(cat "$LEDGER")"
fi

# --- cases 16-19: two runs of one worktree never overlap -----------------------------------------
# Run 1 pauses after its selftests; the test then plants what run 1 would own at its copyback (an
# incoming-* folder and the test-count candidate) and starts run 2, which must wait for run 1's exit
# before its estate lock, its startup deletion or its copyback can reach those files.
pair_case() { # $1 = label, $2 = run 1 kind, $3 = run 2 kind (auto | merkur), $4 = case dir name
  local label="$1" k1="$2" k2="$3" pid1 pid2 t_resume lockline acq2 r2 out2 survived
  new_case "pair-$4"
  mkdir -p "$CASE_DIR/pause"
  if [ "$k1" = auto ]; then HOST=auto MAPV="$MAP" PAUSE="$CASE_DIR/pause" start_gate one "$CASE_DIR/one.txt"
  else HOST=merkur SINGLE="$L_MERKUR" PAUSE="$CASE_DIR/pause" start_gate one "$CASE_DIR/one.txt"; fi
  pid1="$PID"
  if ! wait_for_file "$CASE_DIR/pause/paused" "$pid1"; then
    bad "$label: run 1 never paused"; show "$(cat "$CASE_DIR/one.txt")"; return
  fi
  if [ -n "${PAIR_ABANDON:-}" ] && ! grep -q '^route       : host=mars reason=free:mars (merkur held)' "$CASE_DIR/one.txt"; then
    bad "$label: run 1 did not abandon the busy merkur for mars"
  fi
  mkdir -p "$ART/incoming-run1"; printf 'run1\n' > "$ART/incoming-run1/x"
  printf 'MemosAPITests\t1\n' > "$ART/testcount-baseline.tsv"
  if [ "$k2" = auto ]; then HOST=auto MAPV="$MAP" start_gate two "$CASE_DIR/two.txt"
  else HOST=merkur SINGLE="$L_MERKUR" start_gate two "$CASE_DIR/two.txt"; fi
  pid2="$PID"
  if ! wait_blocked "$pid2"; then
    bad "$label: run 2 never blocked"; show "$(cat "$CASE_DIR/two.txt")"
    : > "$CASE_DIR/pause/resume"; wait_gone "$pid1" 1200; wait_gone "$pid2" 1200; return
  fi
  sleep 1.5
  lockline="$(cat "$ART/.run.lock" 2>/dev/null)"
  [ -e "$ART/incoming-run1/x" ] && [ -e "$ART/testcount-baseline.tsv" ] && survived=yes || survived=no
  t_resume="$(date -u +%s)"
  : > "$CASE_DIR/pause/resume"
  wait_gone "$pid1" 1200
  wait_gone "$pid2" 1200
  out2="$(cat "$CASE_DIR/two.txt")"
  r2="$(route_of "$out2")"
  acq2="$(printf '%s\n' "$out2" | sed -n 's/^estate lock : lock_acquired=\(.*\)$/\1/p')"
  if [ "$survived" = yes ] && [[ "$lockline" == "pid=$pid1 "* ]] && [ -n "$acq2" ] \
     && [ "$(epoch_of "$acq2")" -ge "$t_resume" ] && [[ "$r2" =~ worktree_wait=([0-9]+)s\ pid= ]] && [ "${BASH_REMATCH[1]}" -gt 0 ] \
     && [[ "$(cat "$ART/.run.lock" 2>/dev/null)" == "pid=$pid2 "* ]]; then
    ok "$label: run 2 waited for run 1's exit (lock acquired $acq2, at or after the resume), run 1's files survived, the lock file named run 1 then run 2: route [$r2]"
  else
    bad "$label: survived [$survived], lock file [$lockline] (run 1 pid $pid1), acquired [$acq2] vs resume $t_resume, route [$r2]"
    show "$(cat "$CASE_DIR/one.txt")"; show "$out2"
  fi
}
pair_case "auto then auto" auto auto aa
pair_case "explicit merkur then auto" merkur auto ma
pair_case "auto then explicit merkur" auto merkur am
hold merkur || bad "abandon: the stand-in could not take merkur's lock"
PAIR_ABANDON=1 pair_case "auto abandons a busy merkur for mars and keeps the run lock" auto auto abandon
release merkur

# --- case 20: a holder killed with SIGKILL frees the run lock -----------------------------------
new_case sigkill
mkdir -p "$CASE_DIR/pause"
HOST=auto MAPV="$MAP" PAUSE="$CASE_DIR/pause" start_gate one "$CASE_DIR/one.txt"
pid1="$PID"
if wait_for_file "$CASE_DIR/pause/paused" "$pid1"; then
  HOST=auto MAPV="$MAP" start_gate two "$CASE_DIR/two.txt"
  pid2="$PID"
  if wait_blocked "$pid2"; then
    kill -KILL "$pid1"
    if wait_gone "$pid2" 1200 && [ -n "$(route_of "$(cat "$CASE_DIR/two.txt")")" ] \
       && [[ "$(cat "$ART/.run.lock")" == "pid=$pid2 "* ]]; then
      ok "SIGKILL of the holder: the next run of the worktree took the run lock and ran"
    else
      bad "SIGKILL: run 2 did not proceed"; show "$(cat "$CASE_DIR/two.txt")"
    fi
  else
    bad "SIGKILL: run 2 never blocked"; show "$(cat "$CASE_DIR/two.txt")"
  fi
else
  bad "SIGKILL: run 1 never paused"; show "$(cat "$CASE_DIR/one.txt")"
fi

# --- case 20b: a run killed with SIGKILL while it WAITS for an estate lock frees the run lock ------
# The blocking `flock 9` is a child that outlives the killed run until the estate lock is free; it
# must not hold descriptor 7, or the worktree stays locked behind a host the next run need not use.
sigkill_wait_case() { # $1 = label, $2 = auto|merkur
  local label="$1" pid n=0 freed=no
  new_case "sigkill-wait-$2"
  hold merkur || bad "$label: the stand-in could not take merkur's lock"
  if [ "$2" = auto ]; then
    hold mars || bad "$label: the stand-in could not take mars's lock"
    HOST=auto MAPV="$MAP" start_gate a "$CASE_DIR/out.txt"
  else
    HOST=merkur SINGLE="$L_MERKUR" start_gate a "$CASE_DIR/out.txt"
  fi
  pid="$PID"
  if wait_blocked "$pid"; then
    kill -KILL "$pid"
    wait_gone "$pid" 200
    while [ "$n" -le 100 ]; do
      if is_free "$ART/.run.lock"; then freed=yes; break; fi
      n=$((n + 1)); sleep 0.05
    done
    if [ "$freed" = yes ] && ! is_free "$L_MERKUR"; then
      ok "$label: SIGKILL during the estate-lock wait freed the run lock while the estate lock stayed held"
    else
      bad "$label: run lock freed [$freed] after SIGKILL during the estate-lock wait"
      show "$(cat "$CASE_DIR/out.txt")"
    fi
  else
    bad "$label: the run never blocked on the estate lock"; show "$(cat "$CASE_DIR/out.txt")"
  fi
  release merkur
  [ "$2" = auto ] && release mars
}
sigkill_wait_case "auto, every host busy" auto
sigkill_wait_case "explicit merkur, held" merkur

# --- pre-gate cases: boundary, literal-in-string, swallowed refusal, scope, concurrency -----------
# Boundary: a one-host map with that host held waits on it; an entry with an empty lock refuses.
new_case one-host
hold mars || bad "one-host: the stand-in could not take mars's lock"
HOST=auto MAPV="mars=$L_MARS" start_gate a "$CASE_DIR/out.txt"
if wait_blocked "$PID"; then
  release mars
  wait_gone "$PID" 1200
  r="$(route_of "$(cat "$CASE_DIR/out.txt")")"
  if [[ "$r" == "host=mars reason=busy:mars -> waited on mars (first in order) "* ]]; then
    ok "one-host map, host held: waited on it: route [$r]"
  else
    bad "one-host map: route [$r]"; show "$(cat "$CASE_DIR/out.txt")"
  fi
else
  bad "one-host map: the run never blocked"; show "$(cat "$CASE_DIR/out.txt")"
fi
release mars
new_case empty-entry
HOST=auto MAPV="merkur=,mars=$L_MARS" run_gate a
if [ "$RC" -eq 15 ] && printf '%s\n' "$OUT" | grep -q "entry 'merkur=' is not name=lock" && [ ! -e "$ART/.run.lock" ]; then
  ok "an entry with an empty lock path refuses (exit 15) before the run lock"
else
  bad "empty entry: exit $RC"; show "$OUT"
fi
# Literal in the value: a lock path holding '=' is the whole text after the first '='.
new_case odd-path
mkdir -p "$CASE_DIR/locks"
HOST=auto MAPV="merkur=$CASE_DIR/locks/a=b.lock,mars=$L_MARS" run_gate a
if [ "$RC" -eq 0 ] && [ -e "$CASE_DIR/locks/a=b.lock" ] && [ ! -e "$CASE_DIR/locks/a" ] \
   && [[ "$(route_of "$OUT")" == "host=merkur reason=free:merkur "* ]]; then
  ok "a lock path holding '=' is opened whole: $CASE_DIR/locks/a=b.lock"
else
  bad "odd path: exit $RC, files [$(ls "$CASE_DIR/locks" | tr '\n' ' ')]"; show "$OUT"
fi
# A refusal never swallowed: a lock that cannot be opened refuses; the host is not skipped.
new_case unopenable
HOST=auto MAPV="merkur=$CASE_DIR/no/such/dir/m.lock,mars=$L_MARS" run_gate a
if [ "$RC" -eq 15 ] && printf '%s\n' "$OUT" | grep -q "cannot open the estate lock $CASE_DIR/no/such/dir/m.lock of merkur" \
   && [ ! -s "$LEDGER" ] && ! grep -q '^probe mars$' "$SD/calls"; then
  ok "a map lock that cannot be opened refuses (exit 15) instead of moving on to mars"
else
  bad "unopenable lock: exit $RC"; show "$OUT"
fi
# Scope: --classify-only with auto routes nothing, takes no run lock and probes no host.
new_case classify-only
HOST=auto MAPV="$MAP" run_gate a --classify-only
if { [ "$RC" -eq 0 ] || [ "$RC" -eq 10 ]; } && [ ! -e "$ART/.run.lock" ] && [ ! -s "$SD/calls" ] \
   && [ -z "$(route_of "$OUT")" ] && is_free "$L_MERKUR"; then
  ok "--classify-only with auto: exit $RC, no run lock, no probe, no route"
else
  bad "classify-only: exit $RC, calls [$(cat "$SD/calls" | tr '\n' ' ')]"; show "$OUT"
fi
# Concurrency: two worktrees (two artifacts directories) never share a host while both are free.
new_case two-worktrees
mkdir -p "$CASE_DIR/pause"
HOST=auto MAPV="$MAP" PAUSE="$CASE_DIR/pause" start_gate one "$CASE_DIR/one.txt"
pid1="$PID"
if wait_for_file "$CASE_DIR/pause/paused" "$pid1"; then
  ART="$CASE_DIR/other-artifacts" HOST=auto MAPV="$MAP" run_gate two
  r1="$(route_of "$(cat "$CASE_DIR/one.txt")")"; r2="$(route_of "$OUT")"
  : > "$CASE_DIR/pause/resume"
  wait_gone "$pid1" 1200
  if [ "$RC" -eq 0 ] && [[ "$r1" == "host=merkur "* ]] && [[ "$r2" == "host=mars reason=free:mars (merkur held) "* ]] \
     && [[ "$r2" =~ worktree_wait=0s ]]; then
    ok "two worktrees: the second, not waiting on the first's run lock, took mars while merkur was held: [$r2]"
  else
    bad "two worktrees: [$r1] / [$r2], exit $RC"; show "$OUT"
  fi
else
  bad "two worktrees: run 1 never paused"; show "$(cat "$CASE_DIR/one.txt")"
fi

# --- case 21: the descriptor rule, by text -------------------------------------------------------
# The five subshells that close 9 with `exec` on a line of its own, each named by the line that
# opens it (the line before, or the two before when that one is a bare `(`).
SUBSHELL_NAMES='mount_answer="$GATE_RUN_COPY/mount-answer.txt" (
preflight_out="$(
probe_out="$(
takeover_out="$(
out="$('
fd_rule() { # $1 = a copy of the gate; prints counts or the violations; non-zero on a violation
  awk -v names="$SUBSHELL_NAMES" '
    BEGIN { n = split(names, want, "\n"); for (i = 1; i <= n; i++) { named[want[i]] = 1; seen[want[i]] = 0 } }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      t = trim($0)
      if (index(t, "9>&-") && t !~ /^#/) {
        if (t ~ /^exec[ \t]/) {
          key = (prev == "(") ? prev2 " (" : prev
          if (key in named) {
            seen[key]++
            if (t != "exec 9>&- 7>&-") { printf "named subshell [%s] at line %d does not read exec 9>&- 7>&-: %s\n", key, NR, t; bad = 1 }
          } else {
            router++
            if (index(t, "7>&-")) { printf "parent-shell exec at line %d closes 7: %s\n", NR, t; bad = 1 }
          }
        } else {
          paired++
          if (!index(t, "7>&-")) { printf "line %d closes 9 but not 7: %s\n", NR, t; bad = 1 }
        }
      }
      if (t != "") { prev2 = prev; prev = t }
    }
    END {
      for (k in seen) if (seen[k] != 1) { printf "named subshell [%s] found %d times, expected 1\n", k, seen[k]; bad = 1 }
      if (paired < 13) { printf "only %d non-exec lines close 9 (control: at least 13)\n", paired; bad = 1 }
      if (router < 1) { printf "no parent-shell exec 9>&- found (control: at least 1)\n"; bad = 1 }
      if (!bad) printf "paired=%d named=%d parent-shell=%d\n", paired, n, router
      exit bad
    }' "$1"
}
if msg="$(fd_rule "$GATE")"; then
  ok "descriptor rule holds on the gate: $msg"
else
  bad "descriptor rule:"; show "$msg"
fi
mutant="$tmp/mutant.sh"
first_pair="$(grep -n '9>&-.*7>&-' "$GATE" | grep -v '^[0-9]*: *\(#\|exec \)' | head -1 | cut -d: -f1)"
if [ -n "$first_pair" ]; then
  sed "${first_pair}s/ 7>&-//g" "$GATE" > "$mutant"
  if fd_rule "$mutant" >/dev/null; then bad "descriptor rule: a copy without line $first_pair's 7>&- still passes"
  else ok "descriptor rule: a copy without line $first_pair's 7>&- fails it"; fi
else
  bad "descriptor rule: no line pairs 9>&- with 7>&- to mutate"
fi
router_line="$(grep -n '^ *exec 9>&-$' "$GATE" | head -1 | cut -d: -f1)"
if [ -n "$router_line" ]; then
  sed "${router_line}s/exec 9>&-\$/exec 9>\&- 7>\&-/" "$GATE" > "$mutant"
  if fd_rule "$mutant" >/dev/null; then bad "descriptor rule: a parent-shell exec that gained 7>&- (line $router_line) still passes"
  else ok "descriptor rule: a parent-shell exec that gained 7>&- (line $router_line) fails it"; fi
else
  bad "descriptor rule: no parent-shell exec 9>&- to mutate"
fi
probe_exec="$(grep -n -A1 '^  probe_out="\$($' "$GATE" | sed -n 's/^\([0-9]*\)-.*exec 9>&- 7>&-$/\1/p' | head -1)"
if [ -n "$probe_exec" ]; then
  sed "${probe_exec}s/ 7>&-//" "$GATE" > "$mutant"
  if fd_rule "$mutant" >/dev/null; then bad "descriptor rule: the probe subshell without 7>&- (line $probe_exec) still passes"
  else ok "descriptor rule: the probe subshell without 7>&- (line $probe_exec) fails it"; fi
else
  bad "descriptor rule: the probe subshell's exec line does not close 7"
fi

# --- case 22: the map's hosts are the mount guard's profiles ------------------------------------
guard_hosts="$(sed -n 's/^    \([a-z][a-z0-9-]*\):[0-9A-F-]\{36\})$/\1/p' "$MOUNT_GUARD" | sort | tr '\n' ' ')"
gate_hosts="$(sed -n 's/^GATE_ROUTE_HOSTS="\(.*\)"$/\1/p' "$GATE" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')"
if [ "$(printf '%s' "$guard_hosts" | wc -w)" -eq 2 ] && [ "$guard_hosts" = "$gate_hosts" ]; then
  ok "the map's host list [$gate_hosts] is the mount guard's profile list (control: 2 names)"
else
  bad "the map's host list [$gate_hosts] is not the mount guard's [$guard_hosts]"
fi

# --- case 23: every run names this suite ---------------------------------------------------------
if [ "$(grep -c 'host-routing-test\.sh' "$GATE")" -ge 2 ] && printf ' %s ' "$NAMED" | grep -q ' host-routing-test\.sh '; then
  ok "the gate names host-routing-test.sh in both selftest lists"
else
  bad "the gate does not name host-routing-test.sh in both selftest lists"
fi

echo "host-routing: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
