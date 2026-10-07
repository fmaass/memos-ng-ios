#!/usr/bin/env bash
# testflight-cut-test.sh — proves bin/testflight-cut.sh's local half on REAL git repositories: a
# bare "origin", a working clone with successive commits, and a local bare receiver standing in for
# the Mac's release repo. A fake `ssh` on PATH serves git's receive-pack against that receiver and
# answers the one `bash -s` call with canned output, so every refusal, the estate lock's span, the
# SUMMARY line, the exit code pass-through and the immutable refs/cuts/<sha> push are exercised
# without a Mac. Every call the fake ssh serves also asks, with `flock -n` on a NEW descriptor,
# whether the estate gate lock is free at that instant: the cut must hold it across both.
#
# The Mac half's body (bin/testflight-cut-remote.sh's CUT_BODY: fetch, detached checkout,
# provenance, the disk floor, the version pair, generate, prove_unused, the lane, verify_attach) is
# run here too, under bash, against a throwaway release root with a fake fastlane, generate and df.
# Its Ruby lock-and-budget wrapper needs the Mac's system Ruby and is checked statically only.
#
# Never reaches a Mac, the network or the real estate lock: the lock is a file in this suite's own
# temporary directory. Run it directly (`tests/gate/testflight-cut-test.sh`) or let the gate run it:
# it is one of the gate's NAMED selftests (bin/mac-gate.sh, step selftest).
#
# Exit: 0 = every case as expected; 1 otherwise.
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
lcl="$repo_root/bin/testflight-cut.sh"
rs="$repo_root/bin/testflight-cut-remote.sh"
command -v flock >/dev/null 2>&1 || { echo "FAIL: flock(1) is not on PATH; this suite needs it to probe the estate lock"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-tfcut-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
holder_pid=""
cleanup() {
  [ -z "$holder_pid" ] || kill "$holder_pid" 2>/dev/null
  rm -rf "${tmp:?}"
}
trap cleanup EXIT
fails=0
passes=0
pass() { echo "PASS $1"; passes=$((passes + 1)); }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
check_eq() { # NAME WANT GOT
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}

RELEASE=/Users/fabian/build/memos-ng-ios/release
HOST=fake-mac
macroot="$tmp/mac"
receiver="$macroot$RELEASE/repo.git"
estate="$tmp/estate.lock"
: > "$estate"
mkdir -p "$macroot$RELEASE" "$tmp/bin" "$tmp/ssh" "$tmp/macbin"
# The Mac's ruby, for the runs that execute the Mac half's main: it records when it was called and
# the deadline, grace and reap it was handed (argv: -e CODE LOCK DEADLINE GRACE REAP CMD…).
cat > "$tmp/macbin/ruby" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s %s\n' "$(date +%s)" "$4" "$5" "$6" >> "$FAKE_RUBY_LOG"
EOF
chmod +x "$tmp/macbin/ruby"
git init -q --bare "$receiver"

cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Fake ssh: options are skipped, the first operand is the host, the rest is the remote command.
host=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p|-i|-l|-F|-E) shift 2 ;;
    -*) shift ;;
    *) host="$1"; shift; break ;;
  esac
done
cmd="$*"
# The estate lock, asked on a descriptor of our own: "held" means someone holds it right now.
if flock -n "$FAKE_ESTATE_LOCK" true 2>/dev/null; then lockstate=free; else lockstate=held; fi
printf '%s\t%s\t%s\n' "$host" "${cmd%% *}" "$lockstate" >> "$FAKE_SSH_DIR/calls"
[ "$host" = "$FAKE_SSH_HOST" ] || { echo "fake ssh: unexpected host [$host]" >&2; exit 255; }
case "$cmd" in
  git-receive-pack*|git-upload-pack*)
    exec sh -c "${cmd//\'\/Users\//\'$FAKE_SSH_ROOT/Users/}" ;;
  "bash -s -- "*)
    n=$(( $(find "$FAKE_SSH_DIR" -name 'remote.*.sh' | wc -l) + 1 ))
    cat > "$FAKE_SSH_DIR/remote.$n.sh"
    printf '%s\n' "$cmd" > "$FAKE_SSH_DIR/remote.$n.args"
    rrc=0
    if [ -n "${FAKE_SSH_RUN_REMOTE:-}" ]; then
      # a slow login: the Mac half starts late, then runs with a ruby that only records its call
      sleep "${FAKE_REMOTE_DELAY:-0}"
      # shellcheck disable=SC2086 # the remote command's words, as ssh would hand them to bash
      PATH="$FAKE_MAC_BIN:$PATH" bash "$FAKE_SSH_DIR/remote.$n.sh" ${cmd#bash -s -- } < /dev/null
      rrc=$?
    fi
    if [ -n "${FAKE_REMOTE_OUT:-}" ]; then printf '%s\n' "$FAKE_REMOTE_OUT"; fi
    # the instant this ssh ends, for the case that holds the lock past it
    if [ -n "${FAKE_SSH_END_MARK:-}" ]; then date +%s.%N > "$FAKE_SSH_END_MARK"; fi
    exit "${FAKE_REMOTE_RC:-$rrc}" ;;
  *) echo "fake ssh: unexpected command [$cmd]" >&2; exit 255 ;;
esac
EOF
chmod +x "$tmp/bin/ssh"

# The clone carries the scripts under test, committed, so the clean-tree precondition holds.
git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/clone" 2>/dev/null
c="$tmp/clone"
git -C "$c" config user.name test
git -C "$c" config user.email test@example.invalid
git -C "$c" checkout -q -b main
mkdir -p "$c/bin"
for f in testflight-cut.sh testflight-cut-remote.sh; do
  if [ -f "$repo_root/bin/$f" ]; then cp "$repo_root/bin/$f" "$c/bin/$f"; else echo "exit 99 # missing $f" > "$c/bin/$f"; fi
done
printf 'build/\n' > "$c/.gitignore"
printf 'one\n' > "$c/file.txt"
git -C "$c" add -A && git -C "$c" commit -q -m A && git -C "$c" push -q origin main 2>/dev/null
A="$(git -C "$c" rev-parse HEAD)"

# run_cut [VAR=value…] -- [script args…]: runs the cut from the clone; output in $tmp/out, exit code
# in $rc, last line in $last. MAC_GATE_HOST and MAC_GATE_ESTATE_LOCK are set unless the caller
# passes UNSET_HOST=1 or UNSET_LOCK=1; RUN_TIMEOUT=<s> bounds the run. The timing is MEMOS_CUT_TEST_TIMING="0 0 0 0 0" (a deadline
# at the ssh leg's start, so an unknown outcome holds nothing) unless the caller passes its own;
# an empty MEMOS_CUT_TEST_TIMING= runs the real constants.
run_cut() {
  local envs=() args=() hostenv=(MAC_GATE_HOST="$HOST") lockenv=(MAC_GATE_ESTATE_LOCK="$estate") e limit=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")
  for e in "${envs[@]+"${envs[@]}"}"; do
    [ "$e" = UNSET_HOST=1 ] && hostenv=()
    [ "$e" = UNSET_LOCK=1 ] && lockenv=()
    case "$e" in RUN_TIMEOUT=*) limit=(timeout -k 5 "${e#RUN_TIMEOUT=}") ;; esac
  done
  rm -f "$tmp/ssh/calls"
  (cd "$c" && env -u MAC_GATE_HOST -u MAC_GATE_ESTATE_LOCK -u MEMOS_CUT_TIMEOUT_MIN -u MEMOS_CUT_LOCK_WAIT_S \
      -u MEMOS_CUT_TEST_TIMING \
      PATH="$tmp/bin:$PATH" FAKE_SSH_DIR="$tmp/ssh" FAKE_SSH_HOST="$HOST" FAKE_SSH_ROOT="$macroot" \
      FAKE_ESTATE_LOCK="$estate" FAKE_MAC_BIN="$tmp/macbin" FAKE_RUBY_LOG="$tmp/ruby.log" \
      MEMOS_CUT_TEST_TIMING="0 0 0 0 0" \
      "${hostenv[@]+"${hostenv[@]}"}" "${lockenv[@]+"${lockenv[@]}"}" "${envs[@]+"${envs[@]}"}" \
      "${limit[@]+"${limit[@]}"}" bash bin/testflight-cut.sh "${args[@]+"${args[@]}"}") > "$tmp/out" 2>&1
  rc=$?
  last="$(tail -n 1 "$tmp/out")"
}
cuts() { git -C "$receiver" for-each-ref --format='%(refname) %(objectname)' refs/cuts/ | sort; }
ssh_calls() { if [ -f "$tmp/ssh/calls" ]; then wc -l < "$tmp/ssh/calls" | tr -d ' '; else echo 0; fi; }
# call_shape: one "<command> <lock state>" per ssh call, in order.
call_shape() { if [ -f "$tmp/ssh/calls" ]; then cut -f2,3 "$tmp/ssh/calls" | tr '\t' ' ' | paste -sd ';' -; fi; }
lock_free_now() { if flock -n "$estate" true 2>/dev/null; then echo free; else echo held; fi; }
REPORT_OK="testflight-cut REMOTE: version=2.2.2 build=43 group=household stage=verify"
REPORT_ARCHIVE="testflight-cut REMOTE: version=2.2.2 build=43 group=household stage=fastlane"

refused() { # NAME TOKEN SHA-FIELD REFS-EXPECTED — exit 2, the token named, nothing remote touched
  check_eq "$1/exit" 2 "$rc"
  check_eq "$1/summary" "testflight-cut SUMMARY: version=- build=- sha=$3 state=REFUSED($2) group=- | exit=2" "$last"
  check_eq "$1/no-ssh" 0 "$(ssh_calls)"
  check_eq "$1/no-push" "$4" "$(cuts | grep -c .)"
}

# --- refusals (nothing pushed yet) ---
run_cut UNSET_HOST=1 --; refused no-host no-host - 0
run_cut MAC_GATE_HOST= --; refused empty-host no-host - 0
run_cut UNSET_LOCK=1 --; refused no-estate-lock no-estate-lock - 0
check_eq no-estate-lock/names-variable 1 "$(grep -c 'MAC_GATE_ESTATE_LOCK is not set' "$tmp/out")"
run_cut MAC_GATE_ESTATE_LOCK= --; refused empty-estate-lock no-estate-lock - 0
# A lock path that names no existing file excludes nothing: refused, and no file is created.
run_cut MAC_GATE_ESTATE_LOCK="$tmp/nowhere/estate.lock" --; refused estate-lock-missing estate-lock - 0
run_cut MAC_GATE_ESTATE_LOCK="$tmp/typo.lock" --; refused estate-lock-typo estate-lock - 0
check_eq estate-lock-typo/not-created 0 "$( [ -e "$tmp/typo.lock" ] && echo 1 || echo 0)"
printf 'two\n' >> "$c/file.txt"
run_cut --; refused dirty-tracked dirty - 0
git -C "$c" checkout -q -- file.txt
printf 'x\n' > "$c/stray.txt"
run_cut --; refused dirty-untracked dirty - 0
rm -f "$c/stray.txt"
mkdir -p "$c/build"; printf 'ignored\n' > "$c/build/out"   # ignored files are not dirt
run_cut MEMOS_CUT_TIMEOUT_MIN=0 --; refused timeout-zero bad-timeout - 0
run_cut MEMOS_CUT_TIMEOUT_MIN=abc --; refused timeout-text bad-timeout - 0
run_cut MEMOS_CUT_TIMEOUT_MIN=100000 --; refused timeout-huge bad-timeout - 0
run_cut MEMOS_CUT_TEST_TIMING="1 1 1 1" --; refused test-timing-four bad-test-timing - 0
run_cut MEMOS_CUT_TEST_TIMING="1 1 1 1 -1" --; refused test-timing-negative bad-test-timing - 0
run_cut MEMOS_CUT_TEST_TIMING="1 1 1 1 1 1" --; refused test-timing-six bad-test-timing - 0
run_cut MEMOS_CUT_LOCK_WAIT_S=abc --; refused lock-wait-text bad-lock-wait - 0
run_cut MEMOS_CUT_LOCK_WAIT_S=-1 --; refused lock-wait-negative bad-lock-wait - 0
run_cut -- --sha; refused sha-missing bad-sha - 0
run_cut -- --sha "${A:0:12}"; refused sha-short bad-sha - 0
run_cut -- --sha "$(printf '%s' "$A" | tr a-f A-F)"; refused sha-upper bad-sha - 0
run_cut -- --bogus; refused unknown-arg usage - 0
check_eq refusals/lock-left-free free "$(lock_free_now)"

# --- first cut of A: pushes refs/cuts/A, then hands the sha, lane and budget to the Mac, holding
# the estate lock across both ---
t_before="$(date +%s)"
run_cut FAKE_REMOTE_OUT="$REPORT_OK" FAKE_REMOTE_RC=0 MEMOS_CUT_TEST_TIMING= --
check_eq cutA/exit 0 "$rc"
check_eq cutA/summary "testflight-cut SUMMARY: version=2.2.2 build=43 sha=$A state=VALID group=household | exit=0" "$last"
check_eq cutA/ref "refs/cuts/$A $A" "$(cuts)"
check_eq cutA/push-then-ssh-under-lock "git-receive-pack held;bash held" "$(call_shape)"
check_eq cutA/lock-released-after free "$(lock_free_now)"
check_eq cutA/lock-wait-logged 1 "$(grep -cE '^cut lock: waited [0-9]+ s$' "$tmp/out")"
# the Mac half gets the ABSOLUTE deadline (ssh leg start + 7200 s) and the real constants
args_d="$(sed -nE "s/^bash -s -- $A beta ([0-9]+) 60 10 300\$/\1/p" "$tmp/ssh/remote.1.args" 2>/dev/null)"
check_eq cutA/remote-args-absolute-deadline 1 \
  "$( [ -n "$args_d" ] && [ "$args_d" -ge "$((t_before + 7200))" ] && [ "$args_d" -le "$((t_before + 7205))" ] && echo 1 || echo 0)"
check_eq cutA/deadline-logged 1 "$(grep -c "^testflight-cut: running beta on $HOST until .* (deadline=$args_d, budget 7200 s)\$" "$tmp/out")"
if cmp -s "$tmp/ssh/remote.1.sh" "$rs"; then pass cutA/remote-script-sent
else fail cutA/remote-script-sent "the bytes sent to the Mac are not bin/testflight-cut-remote.sh"; fi
# The lock is taken after the local checks and released before the summary: the release line
# comes after the remote's report and before the SUMMARY.
order="$(grep -nE '^cut lock: (waited|released)|^testflight-cut REMOTE: |^testflight-cut SUMMARY: ' "$tmp/out" | sed "s/^[0-9]*://" | cut -c1-16 | paste -sd '|' -)"
check_eq cutA/lock-span-order "cut lock: waited|testflight-cut R|cut lock: releas|testflight-cut S" "$order"

# --- another holder of the estate lock: the cut waits, and at its ceiling stops with nothing
# pushed and nothing run on the Mac ---
printf 'two\n' >> "$c/file.txt"
git -C "$c" commit -q -am B
B="$(git -C "$c" rev-parse HEAD)"
git -C "$c" push -q origin main 2>/dev/null
( exec 8>>"$estate"; flock 8; : > "$tmp/holder.ready"; while [ ! -e "$tmp/holder.release" ]; do sleep 0.1; done ) &
holder_pid=$!
for _ in $(seq 1 100); do [ -e "$tmp/holder.ready" ] && break; sleep 0.1; done
check_eq lock-contended/holder-has-it held "$(lock_free_now)"
run_cut FAKE_REMOTE_OUT="$REPORT_OK" MEMOS_CUT_LOCK_WAIT_S=1 --
check_eq lock-contended/exit 75 "$rc"
check_eq lock-contended/summary "testflight-cut SUMMARY: version=- build=- sha=$B state=ESTATE-LOCK-TIMEOUT group=- | exit=75" "$last"
check_eq lock-contended/no-ssh 0 "$(ssh_calls)"
check_eq lock-contended/no-push "refs/cuts/$A $A" "$(cuts)"
# …and with time to wait, it takes the lock once the holder lets go.
( sleep 1; : > "$tmp/holder.release" ) &
t_before="$(date +%s)"
run_cut FAKE_REMOTE_OUT="$REPORT_ARCHIVE" MEMOS_CUT_LOCK_WAIT_S=30 MEMOS_CUT_TIMEOUT_MIN=5 MEMOS_CUT_TEST_TIMING= -- --archive-only
wait "$holder_pid" 2>/dev/null; holder_pid=""
check_eq lock-waited/exit 0 "$rc"
check_eq lock-waited/summary "testflight-cut SUMMARY: version=2.2.2 build=43 sha=$B state=archive-only group=household | exit=0" "$last"
# the deadline counts from the ssh leg, after the lock wait
args_d="$(sed -nE "s/^bash -s -- $B archive_ipa ([0-9]+) 60 10 300\$/\1/p" "$tmp/ssh/remote.2.args" 2>/dev/null)"
check_eq lock-waited/remote-args-absolute-deadline 1 \
  "$( [ -n "$args_d" ] && [ "$args_d" -ge "$((t_before + 301))" ] && [ "$args_d" -le "$((t_before + 310))" ] && echo 1 || echo 0)"
check_eq lock-waited/push-then-ssh-under-lock "git-receive-pack held;bash held" "$(call_shape)"
waited="$(sed -nE 's/^cut lock: waited ([0-9]+) s$/\1/p' "$tmp/out")"
check_eq lock-waited/waited-at-least-1s 1 "$( [ -n "$waited" ] && [ "$waited" -ge 1 ] && echo 1 || echo 0)"
check_eq lock-waited/both-refs "$(printf 'refs/cuts/%s %s\nrefs/cuts/%s %s\n' "$A" "$A" "$B" "$B" | sort)" "$(cuts)"

# --- HEAD ahead of origin/main without --sha is refused ---
printf 'three\n' >> "$c/file.txt"
git -C "$c" commit -q -am C
C="$(git -C "$c" rev-parse HEAD)"
run_cut --; refused not-origin-main not-origin-main "$C" 2
git -C "$c" reset -q --hard "$B"

# --- a repeated cut of the same commit pushes nothing new and still runs the Mac half ---
before="$(cuts)"
run_cut FAKE_REMOTE_OUT="$REPORT_OK" --
check_eq repeat/exit 0 "$rc"
check_eq repeat/refs-unchanged "$before" "$(cuts)"
check_eq repeat/push-noop 1 "$(grep -c 'up-to-date' "$tmp/out")"
check_eq repeat/remote-ran 1 "$(grep -c 'bash' "$tmp/ssh/calls")"

# --- --sha authorises the current HEAD only; it never selects another commit ---
run_cut -- --sha "$A"; refused sha-not-head sha-mismatch "$A" 2
git -C "$c" checkout -q --detach "$A"
run_cut FAKE_REMOTE_OUT="$REPORT_OK" -- --sha "$A"
check_eq sha-is-head/exit 0 "$rc"
check_eq sha-is-head/summary "testflight-cut SUMMARY: version=2.2.2 build=43 sha=$A state=VALID group=household | exit=0" "$last"
run_cut --; refused detached-not-main not-origin-main "$A" 2
git -C "$c" checkout -q main

# --- ONE absolute deadline D: the Mac half starts 2 s late (a slow login), then the ssh drops
# without a report. The Mac half must run to D itself (not to its own start + budget), and the
# estate lock must stay held until D + G + skew (here budget 6, grace 1, reap 1, skew 1, window 1:
# held to D + 3), released only then ---
rm -f "$tmp/ssh-end" "$tmp/lost.done" "$tmp/ruby.log" "$tmp"/ssh/remote.*
( run_cut RUN_TIMEOUT=40 FAKE_SSH_RUN_REMOTE=1 FAKE_REMOTE_DELAY=2 FAKE_REMOTE_RC=255 FAKE_SSH_END_MARK="$tmp/ssh-end" \
    MEMOS_CUT_TEST_TIMING="6 1 1 1 1" --
  cp "$tmp/out" "$tmp/lost.out"; echo "$rc" > "$tmp/lost.rc"; date +%s.%N > "$tmp/lost.done" ) &
lost_pid=$!
for _ in $(seq 1 100); do [ -s "$tmp/ssh-end" ] && break; sleep 0.1; done
check_eq ssh-lost/ssh-ended 1 "$( [ -s "$tmp/ssh-end" ] && echo 1 || echo 0)"
D="$(sed -nE 's/^testflight-cut: running beta on .* \(deadline=([0-9]+), budget 6 s\)$/\1/p' "$tmp/out" | head -n 1)"
check_eq ssh-lost/deadline-logged 1 "$( [ -n "$D" ] && echo 1 || echo 0)"
D="${D:-0}"
check_eq ssh-lost/remote-args "bash -s -- $B beta $D 1 1 1" "$(cat "$tmp/ssh/remote.1.args" 2>/dev/null)"
read -r r_start r_deadline r_grace r_reap < "$tmp/ruby.log" 2>/dev/null || r_start=""
check_eq ssh-lost/remote-started-late 1 "$( [ -n "$r_start" ] && [ "$r_start" -ge "$((D - 6 + 2))" ] && echo 1 || echo 0)"
check_eq ssh-lost/remote-deadline-is-D "$D 1 1" "${r_deadline:-} ${r_grace:-} ${r_reap:-}"
check_eq ssh-lost/remote-says-time-left 1 "$(grep -cE "^testflight-cut: started [0-9]+ s before the deadline $D\$" "$tmp/out")"
sleep 0.5
check_eq ssh-lost/held-after-ssh-returned held "$(lock_free_now)"
# just short of D + G + skew = D + 3 it is still held
while [ "$(date +%s)" -lt "$((D + 2))" ]; do sleep 0.1; done
check_eq ssh-lost/held-until-past-D-plus-G-plus-skew held "$(lock_free_now)"
wait "$lost_pid" 2>/dev/null
check_eq ssh-lost/released-after free "$(lock_free_now)"
check_eq ssh-lost/released-not-before-D-plus-3 1 \
  "$(awk -v d="$D" -v b="$(cat "$tmp/lost.done" 2>/dev/null || echo 0)" 'BEGIN {print (b >= d + 3 && b < d + 6) ? 1 : 0}')"
check_eq ssh-lost/exit 255 "$(cat "$tmp/lost.rc" 2>/dev/null)"
check_eq ssh-lost/summary "testflight-cut SUMMARY: version=- build=- sha=$B state=UNKNOWN(ssh-lost) group=- | exit=255" \
  "$(tail -n 1 "$tmp/lost.out" 2>/dev/null)"
check_eq ssh-lost/hold-logged "cut lock: holding until $(date -u -d "@$((D + 3))" +%Y-%m-%dT%H:%M:%SZ) (remote outcome unknown)" \
  "$(grep '^cut lock: holding until ' "$tmp/lost.out" 2>/dev/null)"
order="$(grep -nE '^cut lock: (waited|holding|released)|^testflight-cut SUMMARY: ' "$tmp/lost.out" 2>/dev/null | sed "s/^[0-9]*://" | cut -c1-16 | paste -sd '|' -)"
check_eq ssh-lost/order "cut lock: waited|cut lock: holdin|cut lock: releas|testflight-cut S" "$order"
check_eq ssh-lost/one-ssh-to-the-mac 1 "$(grep -c 'bash' "$tmp/ssh/calls" 2>/dev/null)"

# --- too late to be useful: the Mac half starts 2 s late with 4 s to its deadline and a 3 s
# minimum window, so it refuses before anything runs ---
rm -f "$tmp/ruby.log"
run_cut FAKE_SSH_RUN_REMOTE=1 FAKE_REMOTE_DELAY=2 MEMOS_CUT_TEST_TIMING="4 0 0 0 3" --
check_eq too-late/exit 3 "$rc"
check_eq too-late/summary "testflight-cut SUMMARY: version=- build=- sha=$B state=REMOTE-REFUSED group=- | exit=3" "$last"
check_eq too-late/nothing-ran 0 "$( [ -s "$tmp/ruby.log" ] && echo 1 || echo 0)"
check_eq too-late/says-why 1 "$(grep -cE '^testflight-cut: too late to start: [0-9-]+ s left before the deadline [0-9]+, need more than 3 - nothing ran$' "$tmp/out")"
check_eq too-late/lock-released free "$(lock_free_now)"
# …and with the window met it starts
run_cut FAKE_SSH_RUN_REMOTE=1 FAKE_REMOTE_OUT="$REPORT_OK" MEMOS_CUT_TEST_TIMING="30 0 0 0 3" --
check_eq window-met/exit 0 "$rc"
check_eq window-met/ruby-ran 1 "$( [ -s "$tmp/ruby.log" ] && echo 1 || echo 0)"
# the Mac half refuses malformed timing arguments before anything runs
rm -f "$tmp/ruby.log"
for bad in "abc 1 1 1" "$(( $(date +%s) + 100 )) x 1 1" "$(( $(date +%s) + 100 )) 1 1" "0 1 1 1"; do
  (cd "$tmp" && PATH="$tmp/macbin:$PATH" FAKE_RUBY_LOG="$tmp/ruby.log" bash "$rs" "$B" beta $bad) > "$tmp/rout" 2>&1
  check_eq "remote-bad-timing/[$bad]/exit" 2 "$?"
done
check_eq remote-bad-timing/nothing-ran 0 "$( [ -s "$tmp/ruby.log" ] && echo 1 || echo 0)"

# --- exit-code pass-through and the state each outcome reports ---
outcome() { # NAME LANE RC REMOTE_OUT WANT_STATE WANT_EXIT WANT_VERSION WANT_BUILD WANT_GROUP
  local flag=()
  [ "$2" = archive ] && flag=(--archive-only)
  run_cut FAKE_REMOTE_RC="$3" FAKE_REMOTE_OUT="$4" -- "${flag[@]+"${flag[@]}"}"
  check_eq "$1/exit" "$6" "$rc"
  check_eq "$1/summary" "testflight-cut SUMMARY: version=$7 build=$8 sha=$B state=$5 group=$9 | exit=$6" "$last"
  check_eq "$1/lock-released" free "$(lock_free_now)"
}
R="testflight-cut REMOTE: version=2.2.2 build=43 group=household"
outcome spent beta 20 "$R stage=prove" "REFUSED(build-number-spent)" 20 2.2.2 43 household
# only the Mac half's 20 says spent; any other prove failure proved nothing either way
outcome unproven beta 21 "$R stage=prove" "REFUSED(unused-unproven)" 21 2.2.2 43 household
outcome unproven-other-rc beta 1 "$R stage=prove" "REFUSED(unused-unproven)" 1 2.2.2 43 household
outcome fastlane-fail beta 1 "$R stage=fastlane" FAILED 1 2.2.2 43 household
outcome verify-fail beta 1 "$R stage=verify" FAILED 1 2.2.2 43 household
outcome generate-fail beta 14 "$R stage=generate" FAILED 14 2.2.2 43 household
outcome remote-precheck beta 3 "testflight-cut REMOTE: version=- build=- group=- stage=precheck" REMOTE-REFUSED 3 - - -
# the Mac half's wrapper reports its own budget and lock deadlines
outcome budget beta 124 "testflight-cut REMOTE: version=- build=- group=- stage=budget" TIMEOUT 124 - - -
outcome lock-wait beta 75 "testflight-cut REMOTE: version=- build=- group=- stage=lock" LOCK-TIMEOUT 75 - - -
outcome expired beta 76 "testflight-cut REMOTE: version=- build=- group=- stage=expired" "REFUSED(deadline-passed)" 76 - - -
outcome rc76-other-stage beta 76 "$R stage=fastlane" FAILED 76 2.2.2 43 household
outcome rc124-other-stage beta 124 "$R stage=fastlane" FAILED 124 2.2.2 43 household
outcome rc75-other-stage beta 75 "$R stage=fastlane" FAILED 75 2.2.2 43 household
# no report, or ssh's own 255: the outcome is unknown (the hold is 0 s in these cases)
outcome ssh-down beta 255 "" "UNKNOWN(ssh-lost)" 255 - - -
outcome ssh-down-after-report beta 255 "$REPORT_OK" "UNKNOWN(ssh-lost)" 255 2.2.2 43 household
outcome no-report beta 0 "" "UNKNOWN(ssh-lost)" 1 - - -
outcome no-report-rc1 beta 1 "" "UNKNOWN(ssh-lost)" 1 - - -
outcome outer-timeout beta 124 "" "UNKNOWN(ssh-lost)" 124 - - -
outcome archive-no-report archive 0 "" "UNKNOWN(ssh-lost)" 1 - - -
outcome precheck-with-rc0 beta 0 "testflight-cut REMOTE: version=- build=- group=- stage=precheck" NO-REPORT 1 - - -
# beta is VALID only after verify_attach; a beta report that stopped at fastlane is not a cut.
outcome beta-without-verify beta 0 "$REPORT_ARCHIVE" NO-REPORT 1 2.2.2 43 household
outcome archive-reporting-verify archive 0 "$REPORT_OK" NO-REPORT 1 2.2.2 43 household
outcome prove-rc0 beta 0 "$R stage=prove" NO-REPORT 1 2.2.2 43 household
# Only the LAST report line counts: a marker echoed earlier in the run must not win.
outcome last-report-wins beta 0 "$(printf 'testflight-cut REMOTE: version=9 build=9 group=x stage=precheck\n%s' "$REPORT_OK")" VALID 0 2.2.2 43 household
# A field value carrying a space or shell syntax is reported as `?`, never evaluated.
outcome hostile-field beta 0 'testflight-cut REMOTE: version=$(touch /tmp/x) build=43 group=household stage=verify' VALID 0 '?' 43 household

# --- a failed push stops before the Mac half runs, and lets the lock go ---
mv "$receiver" "$receiver.away"
run_cut FAKE_REMOTE_OUT="$REPORT_OK" --
case "$rc" in 0|2) fail push-fail/exit "want git's non-zero, non-refusal exit, got $rc" ;; *) pass push-fail/exit ;; esac
check_eq push-fail/summary "testflight-cut SUMMARY: version=- build=- sha=$B state=PUSH-FAILED group=- | exit=$rc" "$last"
check_eq push-fail/no-remote-run 0 "$(grep -c 'bash' "$tmp/ssh/calls")"
check_eq push-fail/lock-released free "$(lock_free_now)"
mv "$receiver.away" "$receiver"

# --- the Mac half's body, under bash, against a throwaway release root ---
# A fixture commit shaped like the app: project.yml with comment decoys and a second target's
# pair, a bin/generate.sh that records its call and writes only ignored files.
src="$tmp/src"
git init -q "$src"
git -C "$src" config user.name test
git -C "$src" config user.email test@example.invalid
mkdir -p "$src/bin"
cat > "$src/project.yml" <<'YML'
targets:
  MemosNG:
    settings:
      base:
        # MARKETING_VERSION: "0.0.1"
        # CURRENT_PROJECT_VERSION: "1"
        MARKETING_VERSION: "2.2.2"
        CURRENT_PROJECT_VERSION: "43"
  MemosShare:
    settings:
      base:
        MARKETING_VERSION: "9.9.9"
        CURRENT_PROJECT_VERSION: "99"
YML
printf '#!/bin/sh\necho generate >> "$FAKE_CALLS"\nmkdir -p MemosNG.xcodeproj\nexit "${FAKE_GENERATE_RC:-0}"\n' > "$src/bin/generate.sh"
chmod 755 "$src/bin/generate.sh"
printf '/build/\n*.xcodeproj\n' > "$src/.gitignore"
git -C "$src" add -A && git -C "$src" commit -q -m fixture
S="$(git -C "$src" rev-parse HEAD)"
groot="$tmp/release"
git init -q --bare "$groot/repo.git"
git clone -q "$groot/repo.git" "$groot/work" 2>/dev/null
git -C "$src" push -q "$groot/repo.git" "$S:refs/cuts/$S"
envf="$tmp/ci.env"
printf 'ASC_KEY_ID=SELFTEST-SECRET-KEYID\nCI_KEYCHAIN_PW=selftest-secret-pw\n' > "$envf"
mkdir -p "$tmp/rbin"
# macOS df -g; GNU df has no -g, so the floor reads this instead.
printf '#!/bin/sh\necho "Filesystem 1G-blocks Used Available Capacity Mounted"\necho "/dev/disk9s1 460 360 ${FAKE_DF_AVAIL:-100} 79%% /x"\n' > "$tmp/rbin/df"
cat > "$tmp/rbin/fastlane" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_CALLS"
[ -n "${ASC_KEY_ID:-}" ] || { echo "fake fastlane: the env file was not sourced" >&2; exit 98; }
case "$1" in
  prove_unused) if [ -n "${FAKE_PROVE_OUT:-}" ]; then printf '%s\n' "$FAKE_PROVE_OUT"; fi; exit "${FAKE_PROVE_RC:-0}" ;;
  verify_attach) exit "${FAKE_VERIFY_RC:-0}" ;;
  *) exit "${FAKE_LANE_RC:-0}" ;;
esac
EOF
chmod 755 "$tmp/rbin/df" "$tmp/rbin/fastlane"
body=""
if [ -f "$rs" ]; then
  body="$(MEMOS_CUT_SOURCE_ONLY=1 bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${CUT_BODY:-}"' _ "$rs")"
fi
check_eq body/extracted 1 "$( [ -n "$body" ] && echo 1 || echo 0)"
run_body() { # [VAR=value…] -- SHA LANE: runs CUT_BODY; output in $tmp/bout, exit in $brc, calls in $bcalls
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$tmp/bcalls"
  rm -rf "$tmp/btmp" && mkdir "$tmp/btmp"
  (cd "$tmp" && env PATH="$tmp/rbin:$PATH" FAKE_CALLS="$tmp/bcalls" TMPDIR="$tmp/btmp" "${envs[@]+"${envs[@]}"}" \
      bash -c "$body" testflight-cut-body "$1" "$2" "$groot" "$envf" "$tmp/rbin/fastlane") > "$tmp/bout" 2>&1
  brc=$?
  if ! bcalls="$(paste -sd ';' - < "$tmp/bcalls")"; then
    fail body/calls-readable "the call log $tmp/bcalls could not be read"; bcalls="?"
  fi
  breport="$(grep '^testflight-cut REMOTE: ' "$tmp/bout" | tail -n 1)"
}
RB="testflight-cut REMOTE: version=2.2.2 build=43 group=household"
run_body -- "$S" beta
check_eq body-beta/exit 0 "$brc"
check_eq body-beta/order "generate;prove_unused version:2.2.2 build:43;beta expected_sha:$S;verify_attach version:2.2.2 build:43" "$bcalls"
check_eq body-beta/report "$RB stage=verify" "$breport"
check_eq body-beta/detached-at-sha "$S" "$(git -C "$groot/work" rev-parse HEAD)"
check_eq body-beta/no-secret-printed 0 "$(grep -c 'SELFTEST-SECRET\|selftest-secret' "$tmp/bout")"
SPENT_OUT='[!] NOT PROVEN UNUSED: App Store Connect already holds 2.2.2 (43): build 9 is VALID [CUT-GUARD-VERDICT=spent]'
run_body FAKE_PROVE_RC=1 FAKE_PROVE_OUT="$SPENT_OUT" -- "$S" beta
check_eq body-spent/exit 20 "$brc"
check_eq body-spent/no-archive "generate;prove_unused version:2.2.2 build:43" "$bcalls"
check_eq body-spent/report "$RB stage=prove" "$breport"
check_eq body-spent/lane-output-shown 1 "$(grep -cF -- "$SPENT_OUT" "$tmp/bout")"
check_eq body-spent/no-temp-left "" "$(ls -A "$tmp/btmp")"
run_body FAKE_PROVE_RC=1 FAKE_PROVE_OUT='[!] NOT PROVEN UNUSED: 2.2.2 (43): App Store Connect has no app x [CUT-GUARD-VERDICT=unproven]' -- "$S" beta
check_eq body-unproven/exit 21 "$brc"
check_eq body-unproven/no-archive "generate;prove_unused version:2.2.2 build:43" "$bcalls"
check_eq body-unproven/report "$RB stage=prove" "$breport"
check_eq body-unproven/no-temp-left "" "$(ls -A "$tmp/btmp")"
run_body FAKE_PROVE_RC=1 -- "$S" beta
check_eq body-unproven-no-verdict/exit 21 "$brc"
check_eq body-unproven-no-verdict/no-archive "generate;prove_unused version:2.2.2 build:43" "$bcalls"
# a quoted answer that names the spent verdict is not the guard's: the guard's token is the last
run_body FAKE_PROVE_RC=1 FAKE_PROVE_OUT='[!] NOT PROVEN UNUSED: 2.2.2 (43): odd [CUT-GUARD-VERDICT=spent] [CUT-GUARD-VERDICT=unproven]' -- "$S" beta
check_eq body-unproven-decoy/exit 21 "$brc"
# a spent token on a passing lane changes nothing: the exit code decides whether it refused
run_body FAKE_PROVE_OUT='[CUT-GUARD-VERDICT=spent]' -- "$S" beta
check_eq body-verdict-on-rc0/exit 0 "$brc"
run_body FAKE_LANE_RC=7 -- "$S" beta
check_eq body-beta-fails/exit 7 "$brc"
check_eq body-beta-fails/no-verify "generate;prove_unused version:2.2.2 build:43;beta expected_sha:$S" "$bcalls"
check_eq body-beta-fails/report "$RB stage=fastlane" "$breport"
run_body FAKE_VERIFY_RC=5 -- "$S" beta
check_eq body-verify-fails/exit 5 "$brc"
check_eq body-verify-fails/report "$RB stage=verify" "$breport"
# --archive-only spends no number: no proof is written, nothing is read back.
run_body -- "$S" archive_ipa
check_eq body-archive/exit 0 "$brc"
check_eq body-archive/order "generate;archive_ipa expected_sha:$S" "$bcalls"
check_eq body-archive/report "$RB stage=fastlane" "$breport"
run_body FAKE_GENERATE_RC=4 -- "$S" beta
check_eq body-generate-fails/exit 4 "$brc"
check_eq body-generate-fails/no-fastlane "generate" "$bcalls"
check_eq body-generate-fails/report "$RB stage=generate" "$breport"
run_body FAKE_DF_AVAIL=2 -- "$S" beta
check_eq body-floor/exit 3 "$brc"
check_eq body-floor/nothing-ran "" "$bcalls"
check_eq body-floor/report "testflight-cut REMOTE: version=- build=- group=- stage=precheck" "$breport"
check_eq body-floor/names-floor 1 "$(grep -c 'DISK FLOOR: 2 GiB free' "$tmp/bout")"
run_body FAKE_DF_AVAIL=3 -- "$S" archive_ipa
check_eq body-floor-exact/exit 0 "$brc"
run_body -- "$(printf '%040d' 0 | tr 0 a)" beta
check_eq body-unknown-sha/exit 3 "$brc"
check_eq body-unknown-sha/nothing-ran "" "$bcalls"
check_eq body-unknown-sha/report "testflight-cut REMOTE: version=- build=- group=- stage=precheck" "$breport"
printf 'x\n' > "$groot/work/stray"
run_body -- "$S" beta
check_eq body-dirty/exit 3 "$brc"
check_eq body-dirty/nothing-ran "" "$bcalls"
rm -f "$groot/work/stray"
run_body -- "$S" beta
check_eq body-clean-again/exit 0 "$brc"
mv "$envf" "$envf.away"
run_body -- "$S" beta
check_eq body-no-env/exit 3 "$brc"
check_eq body-no-env/nothing-ran "" "$bcalls"
mv "$envf.away" "$envf"

# --- static checks on the script the Mac runs and on the local half ---
for f in "$rs" "$lcl"; do
  n="$(basename "$f")"
  if [ ! -f "$f" ]; then fail "static/$n" "missing"; continue; fi
  check_eq "static/$n/no-short-hostname" 0 "$(grep -c 'merkur.local' "$f")"
  check_eq "static/$n/no-simctl" 0 "$(grep -c 'simctl' "$f")"
  check_eq "static/$n/no-mac-gate" 0 "$(grep -c 'mac-gate' "$f")"
  check_eq "static/$n/no-release-lock" 0 "$(grep -c 'release-lock' "$f")"
  check_eq "static/$n/no-mardermusic-names" 0 "$(grep -cE 'MM_|Mardermusic|mardermusic' "$f")"
  check_eq "static/$n/no-xtrace" 0 "$(grep -cE 'set -[a-z]*x|bash -x|SHELLOPTS|BASH_XTRACEFD' "$f")"
  check_eq "static/$n/parses" 0 "$(bash -n "$f" > /dev/null 2>&1; echo "$?")"
done
if [ -f "$rs" ]; then
  # the Mac half never takes the estate lock (the local half holds it) and runs no flock(1)
  check_eq static/remote/no-estate-lock 0 "$(grep -c 'ESTATE_LOCK\|wp13-gate' "$rs")"
  check_eq static/remote/no-flock-exec 0 "$(grep -cE '(^|[;&|({[:space:]])flock([[:space:]]|$)' "$rs")"
  check_eq static/remote/control-ruby-flock 1 "$(grep -c 'lock.flock(File::LOCK_EX | File::LOCK_NB)' "$rs")"
  # the wrapper's own deadlines are reported, so the controller knows them from a lost ssh
  check_eq static/remote/wrapper-reports-lock 1 \
    "$(grep -c '^    say.call(\$stdout, "testflight-cut REMOTE: version=- build=- group=- stage=lock")$' "$rs")"
  check_eq static/remote/wrapper-reports-budget 1 \
    "$(grep -c '^say.call(\$stdout, "testflight-cut REMOTE: version=- build=- group=- stage=budget") if current\[:timed_out\]$' "$rs")"
  check_eq static/remote/control-set-plus-x 1 "$(grep -c '^  set +x$' "$rs")"
  check_eq static/remote/env-file "1" "$(grep -c 'env_file="$HOME/.config/memosng-ci.env"' "$rs")"
fi
if [ -f "$lcl" ]; then
  check_eq static/local/no-default-host 0 "$(grep -cE 'MAC_GATE_HOST:-[^}]' "$lcl")"
  check_eq static/local/control-host-read 1 "$(grep -c 'host="${MAC_GATE_HOST:-}"' "$lcl")"
  check_eq static/local/no-default-estate-lock 0 "$(grep -cE 'MAC_GATE_ESTATE_LOCK:-[^}]' "$lcl")"
  check_eq static/local/control-estate-lock-read 1 "$(grep -c 'estate_lock="${MAC_GATE_ESTATE_LOCK:-}"' "$lcl")"
  # without the test override the hold after an unknown outcome is the budget plus 600 s
  # the timing constants, in one place, and how they combine
  check_eq static/local/timing-constants "CUT_STOP_GRACE_S=60|CUT_REAP_S=10|CUT_CLOCK_SKEW_S=120|CUT_MIN_WINDOW_S=300" \
    "$(grep -oE '^CUT_(STOP_GRACE|REAP|CLOCK_SKEW|MIN_WINDOW)_S=[0-9]+' "$lcl" | paste -sd '|' -)"
  check_eq static/local/deadline-is-absolute 1 "$(grep -c '^deadline=$((ssh_t0 + budget))$' "$lcl")"
  check_eq static/local/hold-is-D-plus-G-plus-skew 1 \
    "$(grep -c '^hold_until=$((deadline + CUT_STOP_GRACE_S + CUT_REAP_S + CUT_CLOCK_SKEW_S))$' "$lcl")"
  check_eq static/local/backstop-after-the-hold 1 "$(grep -c '^timeout --kill-after=30 "$((hold_until - ssh_t0 + 60))" \\$' "$lcl")"
  # the Mac half's wrapper reads D against the wall clock once, and TERMs/KILLs on D
  check_eq static/remote/wrapper-deadline-absolute 1 \
    "$(grep -c '^deadline = clock.call + (Integer(deadline_epoch) - Time.now.to_f)$' "$rs")"
  check_eq static/remote/wrapper-term-at-D 1 "$(grep -c '^    current\[:term_at\] = deadline ' "$rs")"
  check_eq static/remote/wrapper-reap-absolute 1 \
    "$(grep -c '^    reap_until = current\[:term_at\] + GRACE + REAP ' "$rs")"
  check_eq static/remote/wrapper-signal-never-past-D 2 "$(grep -c 'term_at\] .*= \[clock.call, deadline\].min' "$rs")"
  # the expiry check stands between the lock and the launch (fastlane/test/cut_wrapper_test.rb runs it)
  we="$(grep -n '^if clock.call >= deadline$' "$rs" | cut -d: -f1 | head -n 1)"
  wl="$(grep -n '^until lock.flock(File::LOCK_EX | File::LOCK_NB)$' "$rs" | cut -d: -f1 | head -n 1)"
  ws="$(grep -n '^pid = Process.spawn(\*cut_cmd, pgroup: true)$' "$rs" | cut -d: -f1 | head -n 1)"
  check_eq static/remote/wrapper-expiry-between-lock-and-spawn 1 \
    "$( [ -n "$we" ] && [ -n "$wl" ] && [ -n "$ws" ] && [ "$we" -gt "$wl" ] && [ "$ws" -gt "$we" ] && echo 1 || echo 0)"
  check_eq static/remote/no-fixed-grace 0 "$(grep -c 'TESTFLIGHT_CUT_GRACE\|clock.call + 10' "$rs")"
fi

# --- the Fastfile's wiring, read statically (the controller has no Ruby; the lanes themselves run
# only on the Mac). Each lane's statements, comments and blanks dropped, in order. ---
ff="$repo_root/fastlane/Fastfile"
lane_body() { # NAME
  awk -v start="  lane :$1 do" 'index($0, start) == 1 {on = 1; next} on && /^  end$/ {exit} on' "$ff" |
    grep -vE '^[[:space:]]*(#|$)'
}
line_of() { # TEXT BODY: the first line of BODY holding TEXT, or 0
  local n
  n="$(printf '%s\n' "$2" | grep -nF -- "$1" | head -n 1 | cut -d: -f1)"
  echo "${n:-0}"
}
# The decisions themselves are fastlane/lib/cut_guard.rb's, held by fastlane/test/cut_guard_test.rb;
# what is read here is that each lane hands itself to that module first and does nothing outside it.
PROV='    guarded { CutGuard.provenance!(expected_sha: options[:expected_sha], head: method(:git_head), status: method(:git_status)) } if options.key?(:expected_sha)'
archive_body="$(lane_body archive_ipa)"
beta_body="$(lane_body beta)"
prove_body="$(lane_body prove_unused)"
check_eq fastfile/requires-cut-guard 1 "$(grep -c '^require File.expand_path("lib/cut_guard", __dir__)$' "$ff")"
check_eq fastfile/archive-first-is-provenance "$PROV" "$(printf '%s\n' "$archive_body" | head -n 1)"
check_eq fastfile/beta-first-is-the-guard "    guarded do|      CutGuard.beta(" "$(printf '%s\n' "$beta_body" | head -n 2 | paste -sd '|' -)"
check_eq fastfile/beta-guard-is-the-whole-lane "    end" "$(printf '%s\n' "$beta_body" | tail -n 1)"
check_eq fastfile/beta-passes-the-sha-or-nil 1 \
  "$(printf '%s\n' "$beta_body" | grep -cxF '        expected_sha: options.key?(:expected_sha) ? options[:expected_sha].to_s : nil,')"
check_eq fastfile/beta-claims-through-the-runner 1 "$(printf '%s\n' "$beta_body" | grep -c 'runner: method(:run_cut_markers)')"
check_eq fastfile/beta-archive-only-as-the-callable 1 "$(printf '%s\n' "$beta_body" | grep -c '^        archive: -> { archive_ipa(')"
check_eq fastfile/beta-archive-once 1 "$(printf '%s\n' "$beta_body" | grep -c 'archive_ipa(')"
bl="$(line_of '        upload: lambda do |version, build_number|' "$beta_body")"
bu="$(line_of 'upload_to_testflight(' "$beta_body")"
bv="$(line_of 'verify_attach(' "$beta_body")"
check_eq fastfile/beta-upload-only-inside-the-callable 1 \
  "$( [ "$bl" -gt 2 ] && [ "$bu" -gt "$bl" ] && [ "$bv" -gt "$bu" ] && echo 1 || echo 0)"
check_eq fastfile/beta-uploads-once 1 "$(printf '%s\n' "$beta_body" | grep -c 'upload_to_testflight(')"
check_eq fastfile/prove-first-is-the-guard "    guarded do|      CutGuard.prove(" "$(printf '%s\n' "$prove_body" | head -n 2 | paste -sd '|' -)"
check_eq fastfile/prove-asks-only-in-the-callable 1 "$(printf '%s\n' "$prove_body" | grep -c '^        asc: -> { api_key; asc_attach_status(')"
check_eq fastfile/prove-marks-through-the-runner 1 "$(printf '%s\n' "$prove_body" | grep -c 'runner: method(:run_cut_markers)')"
check_eq fastfile/prove-ends-in-success "UI.success" "$(printf '%s\n' "$prove_body" | tail -n 1 | sed 's/^ *//' | cut -c1-10)"
check_eq fastfile/markers-run-direct 1 \
  "$(grep -c '^  output, status = Open3.capture2e("/bin/bash", CUT_MARKERS, \*argv)$' "$ff")"
check_eq fastfile/no-old-helpers 0 "$(grep -c 'assert_provenance!\|cut_markers!\|project_version_pair' "$ff")"
check_eq fastfile/markers-script 1 "$(grep -c '^CUT_MARKERS = "#{ROOT}/scripts/release/cut-markers.sh"$' "$ff")"
# the sentence prove_unused waits for is the one the verdict really returns
check_eq fastfile/no-such-build-is-the-verdicts 1 \
  "$(grep -c 'return \[:fail, "App Store Connect has no such build"\] if build.nil?' "$repo_root/fastlane/lib/asc_readback.rb")"
check_eq fastfile/no-such-build-constant 1 \
  "$(grep -c '^  NO_SUCH_BUILD = "App Store Connect has no such build"' "$repo_root/fastlane/lib/cut_guard.rb")"
# the release lock path stays fixed (the markers' directory is the only overridable path)
check_eq fastfile/release-lock-fixed 1 "$(grep -c '^RELEASE_LOCK_PATH = File.expand_path("~/.release-lock")' "$ff")"
check_eq fastfile/no-marker-dir-in-fastfile 0 \
  "$(cat "$ff" "$repo_root/fastlane/lib/cut_guard.rb" | grep -c 'MEMOSNG_CUT_DIR\|memosng-cut')"

echo "testflight-cut-test: $passes passed, $fails failed"
[ "$fails" -eq 0 ] || { echo "TESTFLIGHT-CUT-TEST FAIL"; exit 1; }
echo "TESTFLIGHT-CUT-TEST ok"
