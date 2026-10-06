#!/usr/bin/env bash
#
# The gate's own wait clock: the estate lock it takes when MAC_GATE_ESTATE_LOCK names one, the
# remote's start and end stamps, and the one row per run it appends to the estate ledger.
#
# The lock and the ledger answer different questions and fail differently. The LOCK is part of
# the run: a gate told to hold a lock it cannot take refuses before anything leaves this machine.
# The LEDGER is telemetry: whatever happens to it, the run's exit is the one it would have had.
# Every case below runs the gate itself against local stubs for ssh and rsync — nothing reaches a
# build host — with its own ledger (MAC_GATE_RUNS_LEDGER) and its own lock file, so a run of this
# suite never touches the estate's real ones, and a gate this suite starts never reopens a lock
# its parent holds.
#
# Waits in this file are on conditions (a marker exists, a process is blocked in flock), never on
# time: no case depends on how fast this host is.
#
# Run it directly (`tests/gate/estate-ledger-test.sh`) or let the gate run it: the controller-side
# selftest step in bin/mac-gate.sh runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; 1 otherwise.
set -uo pipefail
unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCK_STAMPS
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FAIL: flock is not installed; the estate lock cannot be tested"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-ledger-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
cleanup() {
  [ -z "${HOLDER_PID:-}" ] || kill "$HOLDER_PID" 2>/dev/null
  chmod -R u+rwx "$tmp" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

HEADER="$(printf 'lock_requested_utc\tlock_acquired_utc\tremote_start_utc\tremote_end_utc\trepo\tbranch\trun_token\tmode\texit\twall_s\tslot_wait_s\tlog_path')"
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
SUMMARY_RE='^mac-gate SUMMARY: .* \| exit=[0-9]+$'

# --- the fixture ----------------------------------------------------------------------------------
# A repository shaped like this one in the ways the local half of the gate reads. Its selftest stubs
# report what they inherited (the estate lock variable must never reach a child), whether the estate
# lock is free from where they stand, and print two lines shaped like the remote's clock: bait that
# only a parser reading outside the remote's own output would take.
new_repo() {
  local name="$1" work="$tmp/$1" origin="$tmp/$1.git"
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
  for stub in fastpath-classify-test.sh warnings-canary-test.sh testcount-test.sh admission-test.sh mainbar-freeze-rule-test.sh mount-guard-test.sh mount-refusal-path-test.sh; do
    cat > "$work/tests/gate/$stub" <<STUB_EOF
#!/usr/bin/env bash
echo "selftest" >> "\${STUB_DIR:-/nonexistent}/calls"
if [ -n "\${STUB_ESTATE:-}" ]; then
  if flock -n "\$STUB_ESTATE" true; then echo "$stub estate-lock=free"; else echo "$stub estate-lock=held"; fi
fi
if [ -n "\${STUB_FD_DIR:-}" ]; then
  state=free
  for f in /proc/\$\$/fd/*; do [ "\$(readlink "\$f")" = "\$STUB_ESTATE" ] && state=held; done
  echo "selftest \$state" >> "\$STUB_FD_DIR/fds"
fi
echo "$stub stub ok estate=[\${MAC_GATE_ESTATE_LOCK:-}]"
echo "MAC_GATE_REMOTE_CLOCK start=111"
echo "MAC_GATE_REMOTE_CLOCK end=999"
exit 0
STUB_EOF
    chmod +x "$work/tests/gate/$stub"
  done
  printf 'gate_lane_is_unlocked() { return 0; }\n' > "$work/scripts/reap-gate-lanes.sh"
  cp "$repo_root/scripts/gate-admission.sh" "$work/scripts/gate-admission.sh" || return 1
  cp "$repo_root/scripts/gate-mount-guard.sh" "$work/scripts/gate-mount-guard.sh" || return 1
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  printf '%s' "$work"
}

# ssh and rsync, replaced. Every call is recorded, so "nothing reached the build host" is a
# read-back, not an assumption.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/tmp"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
# Case 21 only (STUB_FD_DIR set): note whether this process holds the estate lock's descriptor,
# leave a child behind that outlives the gate, and, for the kind STUB_BLOCK names, wait here.
fd_note() {
  [ -n "${STUB_FD_DIR:-}" ] || return 0
  local f state=free n=0
  for f in /proc/$$/fd/*; do [ "$(readlink "$f")" = "$STUB_ESTATE" ] && state=held; done
  echo "$1 $state" >> "$STUB_FD_DIR/fds"
  sleep 30 </dev/null >/dev/null 2>&1 &
  echo "$!" >> "$STUB_FD_DIR/sleepers"
  [ "${STUB_BLOCK:-}" = "$1" ] || return 0
  echo "$$" > "$STUB_FD_DIR/blocked"
  while [ ! -e "$STUB_FD_DIR/release" ] && [ "$n" -lt 1200 ]; do sleep 0.05; n=$((n + 1)); done
}
case "$*" in
  *simctl*) echo "ssh simctl" >> "$STUB_DIR/calls"; fd_note simctl; exit 1 ;;
esac
script="$(cat)"
case "$script" in
  # the build root's mount guard (its call is the line the gate appends to the helper): a healthy mount
  *'
gate_mount_guard report '*) echo "ssh mount" >> "$STUB_DIR/calls"; fd_note mount; echo "MOUNT OK uuid=stub dev=/dev/disk8s1"; echo "mountguard=enforced marker=not-read"; exit 0 ;;
  *'gate_lane_space "$target"'*)
    echo "ssh admission" >> "$STUB_DIR/calls"; fd_note admission
    if [ -n "${STUB_ADMIT_LOW_ONCE:-}" ] && [ ! -e "$STUB_ADMIT_LOW_ONCE" ]; then
      : > "$STUB_ADMIT_LOW_ONCE"; echo "FREE_KB 0 OWN_KB 0"; exit 0
    fi
    echo "FREE_KB 99999999 OWN_KB 0"; exit 0 ;;
  *MAC_GATE_STEP*)
    echo "ssh remote" >> "$STUB_DIR/calls"; fd_note remote
    [ -z "${STUB_REMOTE_OUT:-}" ] || cat "$STUB_REMOTE_OUT"
    exit "${STUB_REMOTE_RC:-0}" ;;
  *gate_root_raw*)
    echo "ssh preflight" >> "$STUB_DIR/calls"; fd_note preflight
    branch="$(printf '%s\n' "$script" | sed -n "s/^branch='\(.*\)'\$/\1/p" | head -1)"
    root="/Users/gate/build/memos-ng-ios/gate"
    echo "LOCK ACQUIRED"
    echo "LOCKDIR $root/$branch.lock"
    echo "GATE_ROOT $root"
    echo "TARGET $root/$branch"
    exit 0 ;;
esac
echo "ssh other" >> "$STUB_DIR/calls"; fd_note other
exit 0
SSH_EOF
  cat > "$dir/bin/rsync" <<'RSYNC_EOF'
#!/usr/bin/env bash
echo "rsync" >> "$STUB_DIR/calls"
if [ -n "${STUB_FD_DIR:-}" ]; then
  state=free
  for f in /proc/$$/fd/*; do [ "$(readlink "$f")" = "$STUB_ESTATE" ] && state=held; done
  echo "rsync $state" >> "$STUB_FD_DIR/fds"
  sleep 30 </dev/null >/dev/null 2>&1 &
  echo "$!" >> "$STUB_FD_DIR/sleepers"
fi
exit 0
RSYNC_EOF
  chmod +x "$dir/bin/ssh" "$dir/bin/rsync"
}

REAL_DATE="$(command -v date)"; REAL_WC="$(command -v wc)"; REAL_TEE="$(command -v tee)"
# Failure injection, for the telemetry cases only: date fails for one kind of call (the stamps, or
# an epoch's conversion), wc fails for the byte count, and tee holds the first estate-lock stamp
# until it is told to go on. Unset, each one is the real command.
make_fault_stubs() {
  local dir="$1"
  cat > "$dir/bin/date" <<FAULT_EOF
#!/usr/bin/env bash
case "\${FAKE_DATE_FAIL:-}:\$*" in
  "stamp:-u +%Y-%m-%dT%H:%M:%SZ") exit 1 ;;
esac
case "\${FAKE_DATE_FAIL:-}" in
  convert:*) case " \$* " in *"@\${FAKE_DATE_FAIL#convert:} "*|*" -r \${FAKE_DATE_FAIL#convert:} "*) exit 1 ;; esac ;;
esac
exec "$REAL_DATE" "\$@"
FAULT_EOF
  cat > "$dir/bin/wc" <<FAULT_EOF
#!/usr/bin/env bash
[ "\${FAKE_WC_FAIL:-}" = 1 ] && [ "\$*" = "-c" ] && exit 1
exec "$REAL_WC" "\$@"
FAULT_EOF
  cat > "$dir/bin/tee" <<FAULT_EOF
#!/usr/bin/env bash
data="\$(cat)"
if [ -n "\${STUB_TEE_HOLD:-}" ] && printf '%s\n' "\$data" | grep -q '^estate lock : lock_requested='; then
  : > "\$STUB_TEE_HOLD/held"
  read -r _ < "\$STUB_TEE_HOLD/release"
fi
printf '%s\n' "\$data" | "$REAL_TEE" "\$@"
FAULT_EOF
  chmod +x "$dir/bin/date" "$dir/bin/wc" "$dir/bin/tee"
}

new_case() {
  CASE_DIR="$tmp/case-$1"
  mkdir -p "$CASE_DIR"
  make_stubs "$CASE_DIR"
  LEDGER="$CASE_DIR/gate-runs.tsv"
}

# The environment one fixture run gets. ESTATE (a lock path) and PAUSE (a pause dir) are optional.
gate_env() { # $1 = stub dir; fills GATE_ENV
  local dir="$1"
  GATE_ENV=(env -u MAC_GATE_BRANCH -u MAC_GATE_RUN_COPY -u MAC_GATE_ESTATE_LOCK -u MAC_GATE_ESTATE_LOCK_STAMPS
    -u MAC_GATE_RUNS_LOGS
    "PATH=$dir/bin:$PATH" TMPDIR="$dir/tmp"
    MAC_GATE_HOST=stub-host MAC_GATE_ARTIFACTS="${ARTIFACTS:-$dir/artifacts}"
    MAC_GATE_RUNS_LEDGER="$LEDGER" STUB_DIR="$dir"
    FAKE_DATE_FAIL="${FAKE_DATE_FAIL:-}" FAKE_WC_FAIL="${FAKE_WC_FAIL:-}" STUB_TEE_HOLD="${STUB_TEE_HOLD:-}"
    STUB_REMOTE_OUT="${STUB_REMOTE_OUT:-}" STUB_REMOTE_RC="${STUB_REMOTE_RC:-0}"
    STUB_ESTATE="${ESTATE:-}" STUB_FD_DIR="${STUB_FD_DIR:-}" STUB_BLOCK="${STUB_BLOCK:-}"
    STUB_ADMIT_LOW_ONCE="${STUB_ADMIT_LOW_ONCE:-}")
  [ -z "${POLL_S:-}" ] || GATE_ENV+=(GATE_POLL_S="$POLL_S")
  [ -z "${ESTATE:-}" ] || GATE_ENV+=(MAC_GATE_ESTATE_LOCK="$ESTATE")
  [ -z "${PAUSE:-}" ] || GATE_ENV+=(MAC_GATE_SELFTEST_PAUSE_DIR="$PAUSE")
  [ -z "${RUNS_LOGS:-}" ] || GATE_ENV+=(MAC_GATE_RUNS_LOGS="$RUNS_LOGS")
}
run_gate() { # $1 = work tree, $2 = stub dir, then gate arguments; sets OUT and RC
  local work="$1" dir="$2"; shift 2
  gate_env "$dir"
  OUT="$(cd "$work" && "${GATE_ENV[@]}" "$GATE" "$@" 2>&1)"
  RC=$?
}
# Started in the background with exec all the way down, so $! IS the gate's pid.
start_gate() { # $1 = work tree, $2 = stub dir, $3 = output file, then gate arguments; sets PID
  local work="$1" dir="$2" out="$3"; shift 3
  gate_env "$dir"
  ( cd "$work" && exec "${GATE_ENV[@]}" "$GATE" "$@" > "$out" 2>&1 ) &
  PID=$!
}
# Bounded condition waits. The bound only stops a broken case from hanging the suite.
wait_for_file() { # $1 = path, $2 = pid that must stay alive meanwhile
  local n=0
  while [ ! -e "$1" ]; do
    kill -0 "$2" 2>/dev/null || return 1
    n=$((n + 1)); [ "$n" -le 1200 ] || return 1
    sleep 0.05
  done
}
# A flock process anywhere under $1: the run is blocked on a lock right now.
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
    n=$((n + 1)); [ "$n" -le 1200 ] || return 1
    sleep 0.05
  done
}

has()  { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
calls() { cat "$1/calls" 2>/dev/null; }
rows() { [ -f "$LEDGER" ] && tail -n +2 "$LEDGER"; }
row_count() { if [ -f "$LEDGER" ]; then tail -n +2 "$LEDGER" | grep -c .; else echo 0; fi; }
field() { printf '%s\n' "$1" | awk -F '\t' -v n="$2" '{ print $n }'; }
utc_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# The one row a case produced, checked field by field against what it should say.
expect_row() { # $1 = label, then name=value pairs; "~iso" means an ISO-8601 UTC stamp
  local label="$1"; shift
  local row n pair key want got idx
  n="$(row_count)"
  if [ "$n" -ne 1 ]; then bad "$label: expected one ledger row, found $n"; show "$(cat "$LEDGER" 2>/dev/null)"; return; fi
  if [ "$(head -n1 "$LEDGER")" != "$HEADER" ]; then bad "$label: the ledger's first line is not the header"; show "$(head -n1 "$LEDGER")"; return; fi
  row="$(rows)"
  if [ "$(printf '%s\n' "$row" | awk -F '\t' '{ print NF }')" -ne 12 ]; then bad "$label: the row does not have 12 tab fields"; show "$row"; return; fi
  for pair in "$@"; do
    key="${pair%%=*}"; want="${pair#*=}"
    case "$key" in
      lock_requested) idx=1 ;; lock_acquired) idx=2 ;; remote_start) idx=3 ;; remote_end) idx=4 ;;
      repo) idx=5 ;; branch) idx=6 ;; run_token) idx=7 ;; mode) idx=8 ;; exit) idx=9 ;;
      wall) idx=10 ;; slot_wait) idx=11 ;; log) idx=12 ;;
      *) bad "$label: unknown field $key"; return ;;
    esac
    got="$(field "$row" "$idx")"
    if [ "$want" = "~iso" ]; then
      printf '%s\n' "$got" | grep -Eq "$ISO_RE" || { bad "$label: $key is not a UTC stamp: [$got]"; show "$row"; return; }
    elif [ "$got" != "$want" ]; then
      bad "$label: $key is [$got], expected [$want]"; show "$row"; return
    fi
  done
  ok "$label: one 12-field row under the header ($*)"
}
# The row's token and log must be this run's: the log exists, is named for the token, and holds the
# summary line the run printed.
expect_own_log() { # $1 = label
  local row token log
  row="$(rows)"; token="$(field "$row" 7)"; log="$(field "$row" 12)"
  if [ -n "$token" ] && [ -f "$log" ] && [ "${log##*-}" = "$token.log" ]; then
    ok "$1: the row names this run's own log, named for its token"
  else
    bad "$1: the row's token [$token] and log [$log] do not name an existing run log"
  fi
}

w="$(new_repo src)" || { echo "FAIL: cannot build the fixture"; exit 1; }
git -C "$w" checkout --quiet -b fix/ledger-src
printf 'let two = 2\n' >> "$w/Sources/App.swift"
git -C "$w" commit --quiet -am "a source change, so the run owes the build host"
d="$(new_repo docs)" || { echo "FAIL: cannot build the docs fixture"; exit 1; }
git -C "$d" checkout --quiet -b docs/ledger-docs
printf 'more guide\n' >> "$d/docs/guide.md"
git -C "$d" commit --quiet -am "a docs-only change, so the run takes the fast path"

T0=1759300000

# --- case 1: a full run that passes; the remote's own numbers reach the row ---------------------
# The step lines carry t= and the remote summary wall=; the controller's verdict line is unchanged
# by either, and the row's wall_s is end minus start of the remote's own clock.
new_case full-pass
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=$T0
::: xcodegen :::
MAC_GATE_STEP xcodegen 0 t=3
::: xcodebuild :::
MAC_GATE_SLOT slot=0 slot_wait=42 simrelease=0
MAC_GATE_STEP xcodebuild 0 t=70
MAC_GATE_REMOTE_CLOCK end=$((T0 + 77))
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 xcodebuild=0 wall=77 | exit=0
EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$w" "$CASE_DIR"
summary="$(printf '%s\n' "$OUT" | grep '^mac-gate SUMMARY:')"
if [ "$RC" -eq 0 ] && printf '%s\n' "$summary" | grep -Eq "$SUMMARY_RE" && printf '%s\n' "$summary" | grep -q ' slot_wait=42 | exit=0$'; then
  ok "full pass: exit 0, and the verdict line still ends '| exit=0' with t= and wall= in the remote's text"
else
  bad "full pass: exit $RC or a verdict line that does not parse: [$summary]"; show "$OUT"
fi
expect_row "full pass" lock_requested=- lock_acquired=- remote_start="$(utc_of "$T0")" remote_end="$(utc_of $((T0 + 77)))" \
  repo=memos-ng-ios branch=fix/ledger-src mode=full exit=0 wall=77 slot_wait=42
expect_own_log "full pass"
if grep -q '^MAC_GATE_STEP xcodebuild 0 t=70$' "$(field "$(rows)" 12)" && grep -q '^MAC_GATE_REMOTE_SUMMARY: .* wall=77 | exit=0$' "$(field "$(rows)" 12)"; then
  ok "full pass: the run log keeps the step's t= and the remote summary's wall="
else
  bad "full pass: the run log lost the t= or wall= the remote printed"
fi
if grep -q 'MAC_GATE_REMOTE_CLOCK start=111' "$(field "$(rows)" 12)"; then
  ok "full pass: control — the selftest bait (a clock line outside the remote's output) is in the log"
else
  bad "full pass: control — the bait never reached the log, so case 3 proves nothing"
fi

# --- case 2: the timing boundary — start and end in the same second ------------------------------
new_case same-second
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=$T0
MAC_GATE_STEP xcodegen 0 t=0
MAC_GATE_REMOTE_CLOCK end=$T0
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 wall=0 | exit=0
EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$w" "$CASE_DIR"
[ "$RC" -eq 0 ] && ok "same second: exit 0" || { bad "same second: exit $RC"; show "$OUT"; }
expect_row "same second" remote_start="$(utc_of "$T0")" remote_end="$(utc_of "$T0")" wall=0 slot_wait=- mode=full exit=0

# --- case 3: the docs-only fast path never reached the remote, so its row says so ----------------
new_case fastpath
run_gate "$d" "$CASE_DIR"
if [ "$RC" -eq 0 ] && has "mac-gate PASS (fast path: docs-only)" && ! calls "$CASE_DIR" | grep -q '^ssh remote$'; then
  ok "fast path: exit 0, and the remote script was never sent"
else
  bad "fast path: exit $RC, or the remote was asked"; show "$OUT"
fi
expect_row "fast path" remote_start=- remote_end=- wall=- slot_wait=- mode=fastpath exit=0 branch=docs/ledger-docs
expect_own_log "fast path"

# --- case 4: the remote refused after it started: the slot stayed unmet (11) -------------------
new_case slot-refused
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=$T0
MAC_GATE_STEP xcodegen 0 t=2
MAC_GATE_SLOT slot=11 slot_wait=600 simrelease=0
MAC_GATE_STEP xcodebuild 11 t=690
MAC_GATE_REMOTE_CLOCK end=$((T0 + 700))
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 xcodebuild=11 wall=700 | exit=11
EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=11 run_gate "$w" "$CASE_DIR"
[ "$RC" -eq 11 ] && ok "slot refused: exit 11, as before" || { bad "slot refused: exit $RC, expected 11"; show "$OUT"; }
expect_row "slot refused" remote_start="$(utc_of "$T0")" remote_end="$(utc_of $((T0 + 700)))" wall=700 slot_wait=600 mode=refused exit=11

# --- case 5: the remote's lock was taken over (exit 4) before any slot: timed, no slot wait ------
new_case lost-lock
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=$T0
remote: the gate lock of this run was taken over while it was starting (the lock now reads: gone) — stopping, nothing was touched
MAC_GATE_REMOTE_CLOCK end=$((T0 + 1))
EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=4 run_gate "$w" "$CASE_DIR"
[ "$RC" -eq 4 ] && ok "lost lock: exit 4, as before" || { bad "lost lock: exit $RC, expected 4"; show "$OUT"; }
expect_row "lost lock" remote_start="$(utc_of "$T0")" remote_end="$(utc_of $((T0 + 1)))" wall=1 slot_wait=- mode=refused exit=4

# --- case 6: a failing step: the first non-zero exit is the step's, exactly as before ----------
new_case failing
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=$T0
MAC_GATE_STEP xcodegen 0 t=1
MAC_GATE_STEP build 65 t=50
MAC_GATE_REMOTE_CLOCK end=$((T0 + 51))
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 build=65 xcodebuild=skipped wall=51 | exit=65
EOF
cp "$CASE_DIR/remote.txt" "$tmp/failing-remote.txt"
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=65 run_gate "$w" "$CASE_DIR"
if [ "$RC" -eq 65 ] && printf '%s\n' "$OUT" | grep -q '^mac-gate SUMMARY: .* remote=65 .*| exit=65$'; then
  ok "failing step: exit 65, the first failing step's, and the verdict line says so"
else
  bad "failing step: exit $RC, expected 65"; show "$OUT"
fi
expect_row "failing step" mode=full exit=65 wall=51 slot_wait=-

# --- case 7: a quick run: its own sentence, its own mode -----------------------------------------
new_case quick
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=$T0
::: lint :::
MAC_GATE_STEP lint 0 t=4
::: generate :::
MAC_GATE_STEP generate 0 t=9
::: build :::
MAC_GATE_STEP build 0 t=120
::: tests :::
MAC_GATE_SLOT slot=0 slot_wait=5 simrelease=0
MAC_GATE_STEP tests 0 t=200
MAC_GATE_QUICK_REMOTE: lint=0 build=0 tests=0
MAC_GATE_REMOTE_CLOCK end=$((T0 + 203))
EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$w" "$CASE_DIR" --quick
if [ "$RC" -eq 0 ] && has "MAC_GATE_QUICK: lint=0 build=0 tests=0 | exit=0"; then
  ok "quick: exit 0, and the quick line still reads its three numbers through t="
else
  bad "quick: exit $RC or the quick line changed"; show "$OUT"
fi
expect_row "quick" mode=quick exit=0 wall=203 slot_wait=5

# --- case 8: refusals before the run's token and log write no row, and keep their exit ---------
new_case pre-token
OUT="$(cd "$w" && env -u MAC_GATE_HOST -u MAC_GATE_ESTATE_LOCK MAC_GATE_RUNS_LEDGER="$LEDGER" \
  MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" "$GATE" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && has "MAC_GATE_HOST is not set" && [ ! -e "$LEDGER" ]; then
  ok "pre-token refusal (no build host): exit 2, named, and no ledger row"
else
  bad "pre-token refusal: exit $RC, or a ledger was written"; show "$OUT"
fi
run_gate "$w" "$CASE_DIR" --bundle MemosCoreTests
if [ "$RC" -eq 2 ] && has "only mean something with --quick" && [ ! -e "$LEDGER" ]; then
  ok "pre-token refusal (argument): exit 2, named, and no ledger row"
else
  bad "pre-token refusal (argument): exit $RC, or a ledger was written"; show "$OUT"
fi
run_gate "$w" "$CASE_DIR" --classify-only
if [ "$RC" -eq 10 ] && [ ! -e "$LEDGER" ]; then ok "--classify-only writes no row (exit 10)"
else bad "--classify-only: exit $RC, or a ledger was written"; fi
run_gate "$w" "$CASE_DIR" --help
if [ "$RC" -eq 0 ] && [ ! -e "$LEDGER" ]; then ok "--help writes no row"
else bad "--help: exit $RC, or a ledger was written"; fi

# --- case 9: a lock the gate is told to take and cannot open is a REFUSAL ----------------------
new_case lock-fail
ESTATE="$CASE_DIR/no-such-dir/estate.lock" run_gate "$w" "$CASE_DIR"
if [ "$RC" -eq 15 ] && has "REFUSED" && has "$CASE_DIR/no-such-dir/estate.lock"; then
  ok "lock failure: refused with exit 15, naming the lock"
else
  bad "lock failure: expected exit 15 naming the lock, got $RC"; show "$OUT"
fi
if [ -z "$(calls "$CASE_DIR")" ]; then
  ok "lock failure: no selftest, no ssh and no rsync ran"
else
  bad "lock failure: the run went on past the lock"; show "$(calls "$CASE_DIR")"
fi
if [ ! -e "$LEDGER" ] && [ -z "$(ls -A "$CASE_DIR/tmp")" ]; then
  ok "lock failure: no ledger row and no private copy left behind"
else
  bad "lock failure: a ledger row or a private copy was left"; show "$(ls -A "$CASE_DIR/tmp"; cat "$LEDGER" 2>/dev/null)"
fi

# --- case 10: the ledger is telemetry: an unwritable one is skipped and the exit is untouched ----
for kind in pass fail; do
  new_case "ro-$kind"
  mkdir -p "$CASE_DIR/ro"; chmod 555 "$CASE_DIR/ro"
  LEDGER="$CASE_DIR/ro/gate-runs.tsv"
  if [ "$kind" = pass ]; then
    run_gate "$d" "$CASE_DIR"; want=0
  else
    STUB_REMOTE_OUT="$tmp/failing-remote.txt" STUB_REMOTE_RC=65 run_gate "$w" "$CASE_DIR"; want=65
  fi
  if [ "$RC" -eq "$want" ] && printf '%s\n' "$OUT" | grep -q '^LEDGER-SKIPPED .'; then
    ok "unwritable ledger, $kind run: LEDGER-SKIPPED with a reason, exit still $want"
  else
    bad "unwritable ledger, $kind run: exit $RC (expected $want), or no LEDGER-SKIPPED"; show "$OUT"
  fi
  chmod 755 "$CASE_DIR/ro"
done

# --- case 11: an empty ledger file still gets its header (boundary: present but empty) --------
new_case empty-ledger
: > "$LEDGER"
run_gate "$d" "$CASE_DIR"
expect_row "empty ledger file" mode=fastpath exit=0

# --- case 12: the append waits for the ledger's flock, and two writers' rows stay whole --------
# Writer A is a holder process: it takes the ledger's flock, writes the header and its row, and
# keeps the lock until told to let go. Writer B is a real gate run. B must be found BLOCKED in flock
# with nothing of its own written, and after A lets go B's row must follow A's, whole.
new_case race
fifo="$CASE_DIR/release"; mkfifo "$fifo"
printf '%s\n' "$HEADER" > "$CASE_DIR/a-rows"
printf 'A\tA\tA\tA\tA\tA\tA\tA\tA\tA\tA\tA\n' >> "$CASE_DIR/a-rows"
flock "$LEDGER" sh -c 'cat "$1" >> "$2"; : > "$3"; read -r _ < "$4"' _ \
  "$CASE_DIR/a-rows" "$LEDGER" "$CASE_DIR/held" "$fifo" &
HOLDER_PID=$!
if wait_for_file "$CASE_DIR/held" "$HOLDER_PID"; then
  start_gate "$d" "$CASE_DIR" "$CASE_DIR/out.txt"
  if wait_blocked "$PID" && [ "$(row_count)" -eq 1 ]; then
    ok "race: writer B is blocked in flock while A holds the ledger, and has written nothing"
  else
    bad "race: writer B was not blocked by A's ledger lock (rows now $(row_count))"; show "$(cat "$LEDGER")"
  fi
  printf 'go\n' > "$fifo"
  wait "$HOLDER_PID"; HOLDER_PID=""
  wait "$PID"; RC=$?
  second="$(sed -n 3p "$LEDGER")"
  if [ "$RC" -eq 0 ] && [ "$(grep -c . "$LEDGER")" -eq 3 ] && [ "$(sed -n 1p "$LEDGER")" = "$HEADER" ] \
     && [ "$(sed -n 2p "$LEDGER" | cut -f1)" = A ] && [ "$(field "$second" 8)" = fastpath ] \
     && [ "$(printf '%s\n' "$second" | awk -F '\t' '{ print NF }')" -eq 12 ]; then
    ok "race: after A lets go, B's row follows A's, one header, both rows whole"
  else
    bad "race: the ledger after both writers is wrong (B exit $RC)"; show "$(cat "$LEDGER")"
  fi
else
  bad "race: the holder never took the ledger lock"
fi

# --- case 13: the estate lock is held across the private copy's exec, for the whole run ---------
# The run pauses after its selftests, inside the private copy; from there, and from inside a
# selftest, a sibling's `flock -n` on the same path must fail. The selftest's environment must not
# carry the lock variable, or a gate a selftest starts would queue behind its own parent.
new_case retention
ESTATE="$CASE_DIR/estate.lock"
PAUSE="$CASE_DIR/pause"; mkdir -p "$PAUSE"
ESTATE="$ESTATE" PAUSE="$PAUSE" start_gate "$d" "$CASE_DIR" "$CASE_DIR/out.txt"
if wait_for_file "$PAUSE/paused" "$PID"; then
  if flock -n "$ESTATE" true; then
    bad "retention: a sibling took the estate lock while the run was paused inside its private copy"
  else
    ok "retention: a sibling's flock -n fails while the run is paused inside its private copy"
  fi
  if ls -d "$CASE_DIR/tmp"/mac-gate-run.* >/dev/null 2>&1; then
    ok "retention: control — the paused run is executing from its private copy"
  else
    bad "retention: control — no private copy exists while the run is paused"
  fi
  : > "$PAUSE/resume"
else
  bad "retention: the run never reached its pause"; show "$(cat "$CASE_DIR/out.txt")"
fi
wait "$PID"; RC=$?
OUT="$(cat "$CASE_DIR/out.txt")"
if [ "$RC" -eq 0 ] && has "estate-lock=held" && ! has "estate-lock=free"; then
  ok "retention: every selftest saw the estate lock held, from inside the run"
else
  bad "retention: exit $RC, or a selftest found the estate lock free"; show "$OUT"
fi
if has "stub ok estate=[]" && ! has "stub ok estate=[/"; then
  ok "retention: no selftest inherited MAC_GATE_ESTATE_LOCK"
else
  bad "retention: a selftest inherited MAC_GATE_ESTATE_LOCK"; show "$(printf '%s\n' "$OUT" | grep 'stub ok')"
fi
if flock -n "$ESTATE" true; then ok "retention: the lock is free once the run has ended"
else bad "retention: the lock is still held after the run ended"; fi
expect_row "retention" lock_requested="~iso" lock_acquired="~iso" mode=fastpath exit=0
log="$(field "$(rows)" 12)"
if grep -Eq '^estate lock : lock_requested=[0-9T:-]+Z ' "$log" && grep -Eq '^estate lock : lock_acquired=[0-9T:-]+Z$' "$log"; then
  ok "retention: the run log carries both lock stamps"
else
  bad "retention: the run log lacks a lock stamp"; show "$(grep 'estate' "$log")"
fi
req="$(field "$(rows)" 1)"; acq="$(field "$(rows)" 2)"
if [ "$(date -u -d "$acq" +%s)" -ge "$(date -u -d "$req" +%s)" ]; then ok "retention: acquired is not before requested"
else bad "retention: acquired [$acq] is before requested [$req]"; fi
unset PAUSE

# --- case 14: two runs on one estate lock serialise over the WHOLE run ---------------------------
# A is paused holding the lock. B, started on the same lock, must be blocked in flock before it has
# made its private copy or its log. Only after A has exited does B run, and its row follows A's.
new_case contention
ESTATE="$CASE_DIR/estate.lock"
mkdir -p "$CASE_DIR/a" "$CASE_DIR/b"
make_stubs "$CASE_DIR/a"; make_stubs "$CASE_DIR/b"
PAUSE="$CASE_DIR/a/pause"; mkdir -p "$PAUSE"
ESTATE="$ESTATE" PAUSE="$PAUSE" start_gate "$d" "$CASE_DIR/a" "$CASE_DIR/a/out.txt"; PID_A=$PID
unset PAUSE
if wait_for_file "$CASE_DIR/a/pause/paused" "$PID_A"; then
  ESTATE="$ESTATE" start_gate "$d" "$CASE_DIR/b" "$CASE_DIR/b/out.txt"; PID_B=$PID
  if wait_blocked "$PID_B" && [ -z "$(ls -A "$CASE_DIR/b/tmp")" ] && [ ! -e "$CASE_DIR/b/artifacts" ]; then
    ok "contention: B is blocked on the estate lock before its private copy and its log exist"
  else
    bad "contention: B was not blocked before starting its run"; show "$(cat "$CASE_DIR/b/out.txt"; ls -A "$CASE_DIR/b/tmp")"
  fi
  : > "$CASE_DIR/a/pause/resume"
  wait "$PID_A"; RC_A=$?
  wait "$PID_B"; RC_B=$?
  if [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ] && [ "$(row_count)" -eq 2 ] \
     && cmp -s "$(rows | sed -n 1p | cut -f12)" "$(sed -n 's/^run log     : //p' "$CASE_DIR/a/out.txt")" \
     && cmp -s "$(rows | sed -n 2p | cut -f12)" "$(sed -n 's/^run log     : //p' "$CASE_DIR/b/out.txt")"; then
    ok "contention: both runs passed, A's row first and B's second"
  else
    bad "contention: exits $RC_A/$RC_B, or the rows are not A then B"; show "$(cat "$LEDGER" 2>/dev/null)"
  fi
else
  bad "contention: run A never reached its pause"; show "$(cat "$CASE_DIR/a/out.txt")"
fi

# --- case 15: the remote's clock, run from the gate's own text -----------------------------------
# The remote half cannot run here, but its clock can: the lines from the top of the remote script
# through the ownership check (whose refusal, exit 4, comes before anything else), and the step and
# clock functions. `date` is a counter, so every number is known in advance.
new_case clock
mkdir -p "$CASE_DIR/fake"
printf '100\n' > "$CASE_DIR/fake/now"
cat > "$CASE_DIR/fake/date" <<'DATE_EOF'
#!/usr/bin/env bash
now="$(cat "$FAKE_NOW")"
printf '%s\n' "$now"
printf '%s\n' "$((now + ${FAKE_STEP:-1}))" > "$FAKE_NOW"
DATE_EOF
chmod +x "$CASE_DIR/fake/date"
remote_body="$(awk "/cat <<'REMOTE_EOF'\$/ { f = 1; next } f && /^REMOTE_EOF\$/ { exit } f { print }" "$GATE")"
head_src="$(printf '%s\n' "$remote_body" | awk '{ print } /^GATE_LOCK="\$GATE_TARGET.lock"$/ { g = 1 } g && /^esac$/ { exit }')"
if [ -z "$remote_body" ] || ! printf '%s\n' "$head_src" | grep -q '^    exit 4 ;;$'; then
  bad "clock: the remote script's head (through the exit-4 ownership check) was not found in the gate"
else
  OUT="$(GATE_TARGET="$CASE_DIR/lane" GATE_RUN_TOKEN=feedface FAKE_NOW="$CASE_DIR/fake/now" FAKE_STEP=5 \
    PATH="$CASE_DIR/fake:$PATH" bash -c "$head_src" 2>&1)"; RC=$?
  if [ "$RC" -eq 4 ] && printf '%s\n' "$OUT" | grep -qx 'MAC_GATE_REMOTE_CLOCK start=100' \
     && printf '%s\n' "$OUT" | grep -qx 'MAC_GATE_REMOTE_CLOCK end=105' \
     && [ "$(printf '%s\n' "$OUT" | grep -c '^MAC_GATE_REMOTE_CLOCK end=')" -eq 1 ]; then
    ok "clock: the remote's early lost-lock exit (4) is timed: start=100, one end=105"
  else
    bad "clock: the early exit was not timed as start=100 end=105 (exit $RC)"; show "$OUT"
  fi
fi
fn_src() { printf '%s\n' "$remote_body" | awk -v n="$1" '$0 ~ "^"n"\\(\\) [{]" { f = 1 } f { print } f && /^[}]$/ { exit }'; }
summary_src="$(printf '%s\n' "$remote_body" | grep '^echo "MAC_GATE_REMOTE_SUMMARY:')"
clock_src="$(fn_src gate_remote_now; fn_src gate_remote_clock_start; fn_src gate_remote_clock_end; fn_src gate_remote_t; fn_src gate_remote_wall; fn_src gate_remote_step_line; fn_src step)"
if [ -z "$summary_src" ] || ! printf '%s\n' "$clock_src" | grep -q '^step() [{]'; then
  bad "clock: the step function or the remote summary line was not found in the gate"
else
  printf '100\n' > "$CASE_DIR/fake/now"
  OUT="$(FAKE_NOW="$CASE_DIR/fake/now" FAKE_STEP=3 PATH="$CASE_DIR/fake:$PATH" bash -c '
'"$clock_src"'
gate_remote_clock_start
first_fail=0; summary=""
step one true
step two false
step three true
gate_remote_clock_end
'"$summary_src"'
gate_remote_clock_end' 2>&1)"
  want="$(printf '%s\n' 'MAC_GATE_REMOTE_CLOCK start=100' '::: one :::' 'MAC_GATE_STEP one 0 t=3' \
    '::: two :::' 'MAC_GATE_STEP two 1 t=6' '::: three :::' '::: three skipped (a previous step failed) :::' \
    'MAC_GATE_REMOTE_CLOCK end=109' 'MAC_GATE_REMOTE_SUMMARY: one=0 two=1 three=skipped wall=9 | exit=1')"
  if [ "$OUT" = "$want" ]; then
    ok "clock: step lines carry t= since remote_start, the summary wall= is end minus start, end is stamped once"
  else
    bad "clock: the remote's step/summary text is not as expected"; show "$OUT"
  fi
fi
step_echoes="$(printf '%s\n' "$remote_body" | grep -c 'echo "MAC_GATE_STEP ')"
helper_echo="$(fn_src gate_remote_step_line | grep -c '^  echo "MAC_GATE_STEP \$1 \$2 t=\$t"$')"
step_calls="$(printf '%s\n' "$remote_body" | grep -cE '^ *gate_remote_step_line ("\$name"|lint|generate|build|tests) ')"
if [ "$step_echoes" -eq 1 ] && [ "$helper_echo" -eq 1 ] && [ "$step_calls" -eq 5 ]; then
  ok "clock: every MAC_GATE_STEP line (step() and the four quick ones) is printed by the one timed helper"
else
  bad "clock: MAC_GATE_STEP printed outside the timed helper ($step_echoes echo lines, helper $helper_echo, $step_calls calls)"
fi

# --- case 16: the estate lock covers the startup cleanup too -------------------------------------
# Run A holds the lock, paused; the candidate it promoted sits in the artifacts folder B shares.
# B, queued on the same lock, may not have deleted it while A still holds the lock.
new_case candidate
ESTATE="$CASE_DIR/estate.lock"
shared="$CASE_DIR/shared-artifacts"
mkdir -p "$CASE_DIR/a" "$CASE_DIR/b"; make_stubs "$CASE_DIR/a"; make_stubs "$CASE_DIR/b"
PAUSE="$CASE_DIR/a/pause"; mkdir -p "$PAUSE"
ESTATE="$ESTATE" PAUSE="$PAUSE" ARTIFACTS="$shared" start_gate "$d" "$CASE_DIR/a" "$CASE_DIR/a/out.txt"; PID_A=$PID
unset PAUSE
if wait_for_file "$CASE_DIR/a/pause/paused" "$PID_A"; then
  printf 'MemosAPITests\t1\n' > "$shared/testcount-baseline.tsv"
  ESTATE="$ESTATE" ARTIFACTS="$shared" start_gate "$d" "$CASE_DIR/b" "$CASE_DIR/b/out.txt"; PID_B=$PID
  if wait_blocked "$PID_B" && [ -f "$shared/testcount-baseline.tsv" ]; then
    ok "candidate: a run queued on the estate lock has not touched the holder's promoted candidate"
  else
    bad "candidate: the queued run deleted the holder's candidate before it held the lock"
  fi
  : > "$CASE_DIR/a/pause/resume"
  wait "$PID_A"; wait "$PID_B"
else
  bad "candidate: run A never reached its pause"; show "$(cat "$CASE_DIR/a/out.txt")"
fi

# --- case 17: a signal right after the log exists still reaches the ledger ----------------------
# tee holds the first stamp line (the first thing printed after the log is created); TERM arrives
# while it is held. The run must end through its traps: one row, with the signal's exit.
new_case term
make_fault_stubs "$CASE_DIR"
mkdir -p "$CASE_DIR/hold"; mkfifo "$CASE_DIR/hold/release"
ESTATE="$CASE_DIR/estate.lock" STUB_TEE_HOLD="$CASE_DIR/hold" start_gate "$d" "$CASE_DIR" "$CASE_DIR/out.txt"
if wait_for_file "$CASE_DIR/hold/held" "$PID"; then
  kill -TERM "$PID"
  printf 'go\n' > "$CASE_DIR/hold/release"
  wait "$PID"; RC=$?
  OUT="$(cat "$CASE_DIR/out.txt")"
  if [ "$RC" -eq 143 ]; then ok "term: the run ended with the TERM trap's exit (143)"
  else bad "term: exit $RC, expected 143"; show "$OUT"; fi
  expect_row "term" lock_requested="~iso" lock_acquired="~iso" remote_start=- wall=- mode=full exit=143
else
  bad "term: the run never printed its first stamp"; show "$(cat "$CASE_DIR/out.txt")"
fi
unset ESTATE

# --- case 18: every telemetry read that fails says so and writes no row -------------------------
skip_case() { # $1 = label, $2 = expected exit
  if [ "$RC" -eq "$2" ] && printf '%s\n' "$OUT" | grep -q '^LEDGER-SKIPPED .' && [ "$(row_count)" -eq 0 ]; then
    ok "$1: LEDGER-SKIPPED, no row, exit still $2"
  else
    bad "$1: exit $RC (expected $2), rows $(row_count), or no LEDGER-SKIPPED"; show "$OUT"; show "$(cat "$LEDGER" 2>/dev/null)"
  fi
}
new_case stamp-date; make_fault_stubs "$CASE_DIR"
FAKE_DATE_FAIL=stamp ESTATE="$CASE_DIR/estate.lock" run_gate "$d" "$CASE_DIR"
skip_case "estate stamp clock unreadable" 0
new_case convert-start; make_fault_stubs "$CASE_DIR"
FAKE_DATE_FAIL="convert:$T0" STUB_REMOTE_OUT="$tmp/case-full-pass/remote.txt" run_gate "$w" "$CASE_DIR"
skip_case "remote_start cannot be converted to UTC" 0
new_case convert-end; make_fault_stubs "$CASE_DIR"
FAKE_DATE_FAIL="convert:$((T0 + 77))" STUB_REMOTE_OUT="$tmp/case-full-pass/remote.txt" run_gate "$w" "$CASE_DIR"
skip_case "remote_end cannot be converted to UTC" 0
new_case offset; make_fault_stubs "$CASE_DIR"
FAKE_WC_FAIL=1 STUB_REMOTE_OUT="$tmp/case-full-pass/remote.txt" run_gate "$w" "$CASE_DIR"
skip_case "remote output offset unreadable" 0
new_case remote-clock
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=unreadable
MAC_GATE_STEP xcodegen 0 t=-
MAC_GATE_REMOTE_CLOCK end=unreadable
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 wall=- | exit=0
EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" run_gate "$w" "$CASE_DIR"
skip_case "build host clock unreadable" 0
printf '#!/bin/sh\nexit 1\n' > "$tmp/case-clock/fake/date"
OUT="$(PATH="$tmp/case-clock/fake:$PATH" bash -c '
'"$clock_src"'
gate_remote_clock_start
first_fail=0; summary=""
step one true
gate_remote_clock_end
'"$summary_src" 2>&1)"
want="$(printf '%s\n' 'MAC_GATE_REMOTE_CLOCK start=unreadable' '::: one :::' 'MAC_GATE_STEP one 0 t=-' \
  'MAC_GATE_REMOTE_CLOCK unreadable (the clock failed at step one)' \
  'MAC_GATE_REMOTE_CLOCK end=unreadable' 'MAC_GATE_REMOTE_SUMMARY: one=0 wall=- | exit=0')"
if [ "$OUT" = "$want" ]; then ok "clock: a remote clock that fails prints unreadable, t=- and wall=-, never a number"
else bad "clock: a failing remote clock printed something else"; show "$OUT"; fi

# --- case 19: an unreadable stamp early in a remote log longer than a pipe buffer --------------
new_case large-log
{
  echo "MAC_GATE_REMOTE_CLOCK start=unreadable"
  awk 'BEGIN { for (i = 0; i < 4000; i++) printf "compile line %05d ................................................\n", i }'
  echo "MAC_GATE_STEP xcodegen 0 t=-"
  echo "MAC_GATE_REMOTE_CLOCK end=$((T0 + 10))"
  echo "MAC_GATE_REMOTE_SUMMARY: xcodegen=0 wall=- | exit=0"
} > "$CASE_DIR/remote.txt"
if [ "$(wc -c < "$CASE_DIR/remote.txt")" -ge 131072 ]; then
  ok "large log: control — the remote transcript is at least 128 KiB"
else
  bad "large log: control — the remote transcript is smaller than 128 KiB"
fi
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" run_gate "$w" "$CASE_DIR"
skip_case "unreadable start before 128 KiB of output" 0

# --- case 20: a clock that fails only at one step's timestamp ------------------------------------
new_case step-clock
cat > "$CASE_DIR/remote.txt" <<EOF
MAC_GATE_REMOTE_CLOCK start=$T0
MAC_GATE_STEP xcodegen 0 t=2
MAC_GATE_STEP build 0 t=-
MAC_GATE_REMOTE_CLOCK unreadable (the clock failed at step build)
MAC_GATE_REMOTE_CLOCK end=$((T0 + 40))
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 build=0 wall=40 | exit=0
EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" run_gate "$w" "$CASE_DIR"
skip_case "one step's timestamp unreadable" 0
cat > "$tmp/case-clock/fake/date" <<'DATE_EOF'
#!/usr/bin/env bash
n="$(cat "$FAKE_NOW")"
printf '%s\n' "$((n + 1))" > "$FAKE_NOW"
[ "$n" -ne "${FAKE_FAIL_AT:-0}" ] || exit 1
printf '%s\n' "$((100 + 3 * n))"
DATE_EOF
printf '0\n' > "$tmp/case-clock/fake/now"
OUT="$(FAKE_NOW="$tmp/case-clock/fake/now" FAKE_FAIL_AT=2 PATH="$tmp/case-clock/fake:$PATH" bash -c '
'"$clock_src"'
gate_remote_clock_start
first_fail=0; summary=""
step one true
step two true
step three true
gate_remote_clock_end
'"$summary_src" 2>&1)"
want="$(printf '%s\n' 'MAC_GATE_REMOTE_CLOCK start=100' '::: one :::' 'MAC_GATE_STEP one 0 t=3' \
  '::: two :::' 'MAC_GATE_STEP two 0 t=-' 'MAC_GATE_REMOTE_CLOCK unreadable (the clock failed at step two)' \
  '::: three :::' 'MAC_GATE_STEP three 0 t=9' 'MAC_GATE_REMOTE_CLOCK end=112' \
  'MAC_GATE_REMOTE_SUMMARY: one=0 two=0 three=0 wall=12 | exit=0')"
if [ "$OUT" = "$want" ]; then ok "clock: a step whose timestamp fails keeps its exit, prints t=- and the unreadable marker"
else bad "clock: a one-step clock failure printed something else"; show "$OUT"; fi

# --- case 21: a signal between the log's creation and anything after it -------------------------
# od gives this run a known token, so a mkdir stub can create that token's log itself — standing in
# for the instant open_run_log has created it — and hold there; TERM arrives while it is held.
new_case init-term
make_fault_stubs "$CASE_DIR"
printf '#!/bin/sh\necho " de ad be ef 00 11 22 33"\n' > "$CASE_DIR/bin/od"
hold_log="$CASE_DIR/artifacts/mac-gate-docs-ledger-docs-deadbeef00112233.log"
cat > "$CASE_DIR/bin/mkdir" <<MKDIR_EOF
#!/usr/bin/env bash
"$(command -v mkdir)" "\$@" || exit \$?
if [ "\$*" = "-p $CASE_DIR/artifacts" ] && [ ! -e "$CASE_DIR/hold/held" ]; then
  : > "$hold_log"
  : > "$CASE_DIR/hold/held"
  read -r _ < "$CASE_DIR/hold/release"
fi
MKDIR_EOF
chmod +x "$CASE_DIR/bin/od" "$CASE_DIR/bin/mkdir"
mkdir -p "$CASE_DIR/hold"; mkfifo "$CASE_DIR/hold/release"
start_gate "$d" "$CASE_DIR" "$CASE_DIR/out.txt"
if wait_for_file "$CASE_DIR/hold/held" "$PID"; then
  kill -TERM "$PID"
  printf 'go\n' > "$CASE_DIR/hold/release"
  wait "$PID"; RC=$?
  OUT="$(cat "$CASE_DIR/out.txt")"
  if [ "$RC" -eq 143 ] && { [ "$(row_count)" -eq 1 ] || has "LEDGER-SKIPPED"; }; then
    ok "init term: a TERM once the log exists ends in a row or LEDGER-SKIPPED (exit 143)"
  else
    bad "init term: exit $RC, rows $(row_count), and no LEDGER-SKIPPED"; show "$OUT"
  fi
  expect_row "init term" log="$CASE_DIR/gate-logs/memos-ng-ios-${hold_log##*/mac-gate-}" exit=143 mode=full remote_start=-
  if cmp -s "$CASE_DIR/gate-logs/memos-ng-ios-${hold_log##*/mac-gate-}" "$hold_log"; then
    ok "init term: the row's durable copy is the run's local log, byte for byte"
  else
    bad "init term: the durable copy differs from $hold_log"
  fi
else
  bad "init term: the run never reached its log's creation"; show "$(cat "$CASE_DIR/out.txt")"
fi

# --- case 21: the estate lock's descriptor reaches no child of the run ---------------------------
# The lock is an open file description: whoever holds a copy of it holds the lock. The run must,
# because it is the run; nothing it starts may, or a child that outlives it (an ssh client the
# build host keeps busy, a sleep) holds the next run back after this one is gone. Every stub child
# notes whether it holds the descriptor and leaves a sleeper behind that outlives the gate; then
# the run is killed outright while one stub is still busy — at the preflight (a command
# substitution), the admission (a command substitution inside the helper's own) and the remote
# (a pipeline into tee) — and the lock must be free while that stub still lives.
new_case fd-scope
ESTATE="$CASE_DIR/estate.lock"
STUB_FD_DIR="$CASE_DIR/fd"; mkdir -p "$STUB_FD_DIR"
cat > "$CASE_DIR/bin/sleep" <<SLEEP_EOF
#!/usr/bin/env bash
state=free
for f in /proc/\$\$/fd/*; do [ "\$(readlink "\$f")" = "$ESTATE" ] && state=held; done
echo "sleep:\$* \$state" >> "$STUB_FD_DIR/fds"
exec "$(command -v sleep)" "\$@"
SLEEP_EOF
chmod +x "$CASE_DIR/bin/sleep"
ESTATE="$ESTATE" STUB_FD_DIR="$STUB_FD_DIR" STUB_ADMIT_LOW_ONCE="$CASE_DIR/admit-low" POLL_S=1 \
  run_gate "$w" "$CASE_DIR"
fds="$(cat "$STUB_FD_DIR/fds" 2>/dev/null)"
missing=""
for kind in selftest preflight admission sleep:1 remote rsync other simctl; do
  printf '%s\n' "$fds" | grep -q "^$kind " || missing="$missing $kind"
done
[ "$(printf '%s\n' "$fds" | grep -c '^admission ')" -ge 2 ] || missing="$missing admission-twice"
if [ "$RC" -eq 0 ] && [ -z "$missing" ]; then
  ok "fd scope: control — every kind of child ran (selftest, preflight, admission twice, its poll sleep, remote, rsync, lane lock and device release)"
else
  bad "fd scope: control — exit $RC, kinds never seen:${missing:- none}"; show "$fds"; show "$OUT"
fi
if [ -n "$fds" ] && ! printf '%s\n' "$fds" | grep -q ' held$'; then
  ok "fd scope: no child of the run held the estate lock's descriptor"
else
  bad "fd scope: a child of the run held the estate lock's descriptor"; show "$(printf '%s\n' "$fds" | grep ' held$')"
fi
alive=0
while read -r p; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done < "$STUB_FD_DIR/sleepers"
if [ "$alive" -gt 0 ] && flock -n "$ESTATE" true; then
  ok "fd scope: the lock is free once the run has ended, with $alive of its children still alive"
else
  bad "fd scope: $alive children outlived the run, and the lock is $(flock -n "$ESTATE" true && echo free || echo held)"
fi
xargs kill < "$STUB_FD_DIR/sleepers" 2>/dev/null
for kind in preflight admission remote; do
  new_case "fd-kill-$kind"
  ESTATE="$CASE_DIR/estate.lock"
  STUB_FD_DIR="$CASE_DIR/fd"; mkdir -p "$STUB_FD_DIR"
  ESTATE="$ESTATE" STUB_FD_DIR="$STUB_FD_DIR" STUB_BLOCK="$kind" \
    start_gate "$w" "$CASE_DIR" "$CASE_DIR/out.txt"
  if wait_for_file "$STUB_FD_DIR/blocked" "$PID"; then
    busy="$(cat "$STUB_FD_DIR/blocked")"
    if flock -n "$ESTATE" true; then held_before=free; else held_before=held; fi
    kill -KILL "$PID"; wait "$PID" 2>/dev/null
    if [ "$held_before" = held ] && kill -0 "$busy" 2>/dev/null && flock -n "$ESTATE" true; then
      ok "fd scope: killed during the $kind, the lock is free while that child still lives"
    else
      bad "fd scope: killed during the $kind — lock before the kill $held_before, child $(kill -0 "$busy" 2>/dev/null && echo alive || echo gone), lock now $(flock -n "$ESTATE" true && echo free || echo held)"
      show "$(cat "$STUB_FD_DIR/fds" 2>/dev/null)"
    fi
  else
    bad "fd scope: the run never reached the $kind"; show "$(cat "$CASE_DIR/out.txt")"
    kill -KILL "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  fi
  : > "$STUB_FD_DIR/release"
  xargs kill < "$STUB_FD_DIR/sleepers" 2>/dev/null
done
unset STUB_FD_DIR

# --- case 22: the row names a durable copy of the COMPLETE run log, beside the ledger ------------
# A worktree's .gate-artifacts dies with the worktree at merge-closeout, so a row naming the local
# log would point at nothing once its branch merged. The copy is named for the repo, the branch
# (slash to dash) and the run's token; it holds every byte the local log holds when the run has
# ended; and a copy that cannot be made never costs the row or the run's exit code.
# expect_durable_log: the one row names <dir>/memos-ng-ios-<slug>-<token>.log, that file exists,
# and it is byte-for-byte the local log of the run as it stands after the run ended.
expect_durable_log() { # $1 = label, $2 = the directory the copy must be in, $3 = branch slug
  local label="$1" dir="$2" slug="$3" row token got local_log
  row="$(rows | tail -n 1)"; token="$(field "$row" 7)"; got="$(field "$row" 12)"
  local_log="${ARTIFACTS:-$CASE_DIR/artifacts}/mac-gate-$slug-$token.log"
  if [ -z "$token" ] || [ "$got" != "$dir/memos-ng-ios-$slug-$token.log" ]; then
    bad "$label: log_path is [$got], expected [$dir/memos-ng-ios-$slug-$token.log]"; show "$row"; return
  fi
  if [ ! -f "$got" ] || [ ! -f "$local_log" ]; then
    bad "$label: the copy [$got] or the local log [$local_log] does not exist"; return
  fi
  if [ "$(wc -c < "$got")" -eq "$(wc -c < "$local_log")" ] && cmp -s "$got" "$local_log" \
     && grep -q "$SUMMARY_RE" "$got"; then
    ok "$label: the row names the durable copy, $(wc -c < "$got") bytes, identical to the finished local log"
  else
    bad "$label: the copy ($(wc -c < "$got") bytes) differs from the finished local log ($(wc -c < "$local_log") bytes)"
  fi
}
# Default: the directory beside the ledger, created when absent; a full run, branch fix/ledger-src.
new_case durable-default
STUB_REMOTE_OUT="$tmp/case-full-pass/remote.txt" run_gate "$w" "$CASE_DIR"
[ "$RC" -eq 0 ] && ok "durable default: exit 0" || { bad "durable default: exit $RC"; show "$OUT"; }
expect_durable_log "durable default" "$CASE_DIR/gate-logs" fix-ledger-src
if has "LEDGER-LOG-KEPT-LOCAL"; then bad "durable default: a copy that was made still says LEDGER-LOG-KEPT-LOCAL"; show "$OUT"
else ok "durable default: no LEDGER-LOG-KEPT-LOCAL when the copy was made"; fi
# Override, fast path: MAC_GATE_RUNS_LOGS wins, its missing parents are made, a space in the path
# survives quoting, and nothing appears in the default directory.
new_case durable-override
RUNS_LOGS="$CASE_DIR/with space/logs" run_gate "$d" "$CASE_DIR"
[ "$RC" -eq 0 ] && ok "durable override: exit 0" || { bad "durable override: exit $RC"; show "$OUT"; }
expect_durable_log "durable override, fast path" "$CASE_DIR/with space/logs" docs-ledger-docs
if [ -e "$CASE_DIR/gate-logs" ]; then bad "durable override: the default directory beside the ledger was written too"
else ok "durable override: the default directory beside the ledger was not created"; fi
# Two runs of one branch: two rows, two distinct copies, each its own run's log.
new_case durable-twice
run_gate "$d" "$CASE_DIR"; rc1=$RC
first="$(rows | tail -n 1)"
run_gate "$d" "$CASE_DIR"; rc2=$RC
second="$(rows | tail -n 1)"
p1="$(field "$first" 12)"; p2="$(field "$second" 12)"
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$(row_count)" -eq 2 ] && [ "$p1" != "$p2" ] \
   && [ "${p1%/*}" = "$CASE_DIR/gate-logs" ] && [ "${p2%/*}" = "$CASE_DIR/gate-logs" ] \
   && [ -f "$p1" ] && [ -f "$p2" ] && [ "$(ls "$CASE_DIR/gate-logs" | grep -c .)" -eq 2 ] \
   && cmp -s "$p1" "$CASE_DIR/artifacts/mac-gate-docs-ledger-docs-$(field "$first" 7).log"; then
  ok "durable twice: two runs of one branch keep two copies, the first still its own run's log"
else
  bad "durable twice: exits $rc1/$rc2, rows $(row_count), copies [$p1] [$p2]"; show "$(ls -la "$CASE_DIR/gate-logs" 2>&1)"
fi
# A copy that cannot be made: the directory cannot be created (parent read-only), or it exists and
# cannot be written. The row is still written, naming the local log; one LEDGER-LOG-KEPT-LOCAL
# line says why, on stdout and in that log; the exit code is the run's own, pass or fail.
for kind in uncreatable unwritable; do
  for run in pass fail; do
    new_case "keep-$kind-$run"
    mkdir -p "$CASE_DIR/ro"
    if [ "$kind" = uncreatable ]; then RUNS_LOGS="$CASE_DIR/ro/logs"; else RUNS_LOGS="$CASE_DIR/ro"; fi
    chmod 555 "$CASE_DIR/ro"
    if [ "$run" = pass ]; then
      RUNS_LOGS="$RUNS_LOGS" run_gate "$d" "$CASE_DIR"; want=0; slug=docs-ledger-docs
    else
      RUNS_LOGS="$RUNS_LOGS" STUB_REMOTE_OUT="$tmp/failing-remote.txt" STUB_REMOTE_RC=65 run_gate "$w" "$CASE_DIR"
      want=65; slug=fix-ledger-src
    fi
    chmod 755 "$CASE_DIR/ro"
    row="$(rows | tail -n 1)"; token="$(field "$row" 7)"
    local_log="$CASE_DIR/artifacts/mac-gate-$slug-$token.log"
    if [ "$RC" -eq "$want" ] && [ "$(row_count)" -eq 1 ] && [ "$(field "$row" 12)" = "$local_log" ] \
       && [ "$(field "$row" 9)" = "$want" ] \
       && [ "$(printf '%s\n' "$OUT" | grep -c '^LEDGER-LOG-KEPT-LOCAL .')" -eq 1 ] \
       && [ "$(grep -c '^LEDGER-LOG-KEPT-LOCAL .' "$local_log")" -eq 1 ] \
       && ! has "LEDGER-SKIPPED" && [ -z "$(ls -A "$CASE_DIR/ro")" ]; then
      ok "copy failure ($kind dir, $run run): row kept naming the local log, one LEDGER-LOG-KEPT-LOCAL, exit still $want"
    else
      bad "copy failure ($kind dir, $run run): exit $RC (expected $want), rows $(row_count), log_path [$(field "$row" 12)]"
      show "$OUT"; show "$(ls -la "$CASE_DIR/ro" 2>&1)"
    fi
  done
done
unset RUNS_LOGS
# A file already at the copy's name is somebody else's: it is left as it was, and the row keeps the
# local log. The token is pinned through od so the name is known before the run.
new_case keep-existing
printf '#!/bin/sh\necho " de ad be ef 00 11 22 33"\n' > "$CASE_DIR/bin/od"; chmod +x "$CASE_DIR/bin/od"
mkdir -p "$CASE_DIR/gate-logs"
printf 'another run\n' > "$CASE_DIR/gate-logs/memos-ng-ios-docs-ledger-docs-deadbeef00112233.log"
run_gate "$d" "$CASE_DIR"
row="$(rows | tail -n 1)"
if [ "$RC" -eq 0 ] && [ "$(row_count)" -eq 1 ] \
   && [ "$(field "$row" 12)" = "$CASE_DIR/artifacts/mac-gate-docs-ledger-docs-deadbeef00112233.log" ] \
   && [ "$(cat "$CASE_DIR/gate-logs/memos-ng-ios-docs-ledger-docs-deadbeef00112233.log")" = "another run" ] \
   && [ "$(printf '%s\n' "$OUT" | grep -c '^LEDGER-LOG-KEPT-LOCAL .')" -eq 1 ]; then
  ok "copy name taken: the file there is untouched, the row keeps the local log, one LEDGER-LOG-KEPT-LOCAL"
else
  bad "copy name taken: exit $RC, rows $(row_count), log_path [$(field "$row" 12)]"; show "$OUT"
fi
# A ledger that refuses AFTER the copy was made (a device that is always full, so the header write
# fails): no row, LEDGER-SKIPPED, and the copy still holds every byte of the local log — the skip
# line included. Linux only: /dev/full does not exist on macOS.
if [ -c /dev/full ]; then
  new_case skip-after-copy
  LEDGER=/dev/full RUNS_LOGS="$CASE_DIR/logs" run_gate "$d" "$CASE_DIR"
  copy="$(ls "$CASE_DIR/logs"/memos-ng-ios-docs-ledger-docs-*.log 2>/dev/null)"
  local_log="$CASE_DIR/artifacts/mac-gate-${copy##*/memos-ng-ios-}"
  if [ "$RC" -eq 0 ] && has "LEDGER-SKIPPED cannot write the header" && [ -n "$copy" ] && [ -f "$local_log" ] \
     && [ "$(tail -n 1 "$copy")" = "LEDGER-SKIPPED cannot write the header of /dev/full" ] \
     && [ "$(wc -c < "$copy")" -eq "$(wc -c < "$local_log")" ] && cmp -s "$copy" "$local_log"; then
    ok "skip after copy: LEDGER-SKIPPED reaches the copy too, which stays byte for byte the local log"
  else
    bad "skip after copy: exit $RC, copy [$copy] vs [$local_log]"; show "$OUT"
  fi
else
  echo "skip skip-after-copy: no /dev/full on this host, not judged"
fi

echo "estate-ledger-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
