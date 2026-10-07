#!/usr/bin/env bash
# testflight-cut.sh — cut ONE TestFlight build of the exact commit checked out here, on the Mac.
#
#   env MAC_GATE_HOST=merkur MAC_GATE_ESTATE_LOCK=<lock file> bin/testflight-cut.sh                 # upload
#   env MAC_GATE_HOST=merkur MAC_GATE_ESTATE_LOCK=<lock file> bin/testflight-cut.sh --archive-only  # no upload
#   … bin/testflight-cut.sh --sha <40-hex>   # authorise a HEAD that is not origin/main
#
# Runs from any Linux checkout of this repository (a lane's clone, or the owner's). It needs a
# committed, clean tree whose HEAD equals origin/main after a fetch; `--sha` replaces that check
# with "HEAD equals this full sha" — it authorises the commit already checked out, it never
# selects another one. Then, in order:
#   1. takes the estate gate lock (MAC_GATE_ESTATE_LOCK, flock, waiting up to
#      MEMOS_CUT_LOCK_WAIT_S) and holds it until the Mac half has reported: a cut, a gate, another
#      lane's cut and a build-root cutover window all hold that one lock, so none of them overlaps
#      this cut on the Mac. This script runs no gate, so the lock is not wrapped around one.
#      Logged as `cut lock: waited <s> s`;
#   2. pushes the commit to the Mac's bare release repo as refs/cuts/<sha>. One immutable ref per
#      commit: no force, no lease, no remote-tracking state, and a repeat of the same commit is a
#      no-op (the repo's update hook refuses any rewrite or delete of refs/cuts/*). The COMMIT
#      travels, not a tree mirror, because the Fastfile proves provenance with
#      `git rev-parse HEAD` of the release checkout;
#   3. runs bin/testflight-cut-remote.sh there over ONE ssh call. Under the release checkout's own
#      lock it checks the commit out, regenerates the project, proves the build number unused
#      (`fastlane prove_unused`), runs `fastlane beta expected_sha:<sha>` (which claims the number
#      first) and reads App Store Connect back (`fastlane verify_attach`); with --archive-only it
#      runs `fastlane archive_ipa expected_sha:<sha>` alone and spends no number;
#   4. releases the estate lock and prints, as its LAST line,
#      testflight-cut SUMMARY: version=<v> build=<n> sha=<40> state=<state> group=<group> | exit=<rc>
#      state: VALID (beta passed its App Store Connect read-back), archive-only, FAILED, TIMEOUT,
#      LOCK-TIMEOUT (the release checkout's lock), ESTATE-LOCK-TIMEOUT, REMOTE-REFUSED,
#      PUSH-FAILED, NO-REPORT (exit 0 without the report of a finished lane), UNKNOWN(ssh-lost)
#      or REFUSED(<reason>). REFUSED(deadline-passed) is the Mac half's: D had passed once it held
#      the checkout lock, and nothing was launched. REFUSED(build-number-spent) is the Mac half's: the number is claimed
#      already, or App Store Connect holds it; REFUSED(unused-unproven) is the Mac half's too: the
#      number could not be proven unused (App Store Connect unreadable, the markers' lock), and
#      nothing was archived.
#
# Timing: ONE absolute deadline D = (start of the ssh leg) + budget, in UTC epoch seconds, is
# computed here and handed to the Mac half, which refuses to start at all when fewer than
# CUT_MIN_WINDOW_S seconds are left before D, stops the cut's process group at D (TERM), kills it
# CUT_STOP_GRACE_S later and waits CUT_REAP_S for it: everything of the cut is gone by D + G,
# G = CUT_STOP_GRACE_S + CUT_REAP_S, however late the Mac half started. When the ssh leg ends with
# ssh's 255 or without the Mac half's report line, what the Mac is doing is unknown: it may still
# be cutting. The estate lock is then HELD until D + G + CUT_CLOCK_SKEW_S (the two hosts are
# NTP-synced; the allowance covers their clocks disagreeing), logged `cut lock: holding until
# <utc> (remote outcome unknown)`, and the state is UNKNOWN(ssh-lost) with ssh's code (1 when it
# was 0). Nothing asks the Mac what happened; read its log. The constants are below, in one place.
#
# Environment:
#   MAC_GATE_HOST          (required, no default) ssh alias of the Mac build host
#   MAC_GATE_ESTATE_LOCK   (required, no default) the estate gate lock file; it must exist
#   MEMOS_CUT_TIMEOUT_MIN  wall-clock budget of the Mac half in minutes, its own lock wait included
#                          (default 120 — an UNMEASURED placeholder until the first --archive-only
#                          run is timed; see docs/TESTFLIGHT.md). Exceeding it reports TIMEOUT.
#   MEMOS_CUT_LOCK_WAIT_S  seconds to wait for the estate lock (default 21600, six hours)
#   MEMOS_CUT_TEST_TIMING  tests/gate/testflight-cut-test.sh ONLY: "<budget_s> <grace_s> <reap_s>
#                          <skew_s> <min_window_s>" replaces the budget and the four constants
#                          below, so a test can run a whole deadline in seconds. A real cut never
#                          sets it.
#
# Exit codes: 0 = the cut succeeded; 2 = refusal (nothing pushed or run); 75 = the estate lock or
# the release checkout's lock was still held at its ceiling; otherwise the code of the step that
# failed — fastlane's, git push's, ssh's 255, 124 for the budget, 20 for a spent build number,
# 21 for a number not proven unused, 1 for NO-REPORT and for an UNKNOWN(ssh-lost) whose ssh said 0.
set -u
cd "$(dirname "$0")/.." || exit 2

RELEASE_ROOT=/Users/fabian/build/memos-ng-ios/release
REMOTE_SCRIPT=bin/testflight-cut-remote.sh
sha="-"
version="-"
build="-"
group="-"

summary() { # STATE EXIT
  printf 'testflight-cut SUMMARY: version=%s build=%s sha=%s state=%s group=%s | exit=%s\n' \
    "$version" "$build" "$sha" "$1" "$group" "$2"
}
refuse() { # TOKEN MESSAGE
  printf 'testflight-cut: REFUSED: %s\n' "$2" >&2
  summary "REFUSED($1)" 2
  exit 2
}
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

sha_arg=""
have_sha=0
lane=beta
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) have_sha=1; sha_arg="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
    --archive-only) lane=archive_ipa; shift ;;
    -h|--help) usage; exit 0 ;;
    *) refuse usage "unknown argument '$1' (bin/testflight-cut.sh [--sha <40-hex>] [--archive-only])" ;;
  esac
done

host="${MAC_GATE_HOST:-}"
[ -n "$host" ] || refuse no-host "MAC_GATE_HOST is not set (ssh alias of the Mac build host; there is no default)"

estate_lock="${MAC_GATE_ESTATE_LOCK:-}"
[ -n "$estate_lock" ] ||
  refuse no-estate-lock "MAC_GATE_ESTATE_LOCK is not set (the estate gate lock file this cut holds from its push to the Mac's report; there is no default)"
# A path naming no file would create a fresh one and exclude nothing.
[ -f "$estate_lock" ] ||
  refuse estate-lock "MAC_GATE_ESTATE_LOCK names no existing file ($estate_lock); a new lock file would exclude nothing"

timeout_min="${MEMOS_CUT_TIMEOUT_MIN:-120}"
[[ "$timeout_min" =~ ^[1-9][0-9]{0,3}$ ]] ||
  refuse bad-timeout "MEMOS_CUT_TIMEOUT_MIN must be whole minutes, 1-9999 (got '$timeout_min')"
budget=$((timeout_min * 60))

lock_wait="${MEMOS_CUT_LOCK_WAIT_S:-21600}"
[[ "$lock_wait" =~ ^[0-9]{1,6}$ ]] ||
  refuse bad-lock-wait "MEMOS_CUT_LOCK_WAIT_S must be whole seconds, 0-999999 (got '$lock_wait')"

# The cut's timing constants, all of them (docs/TESTFLIGHT.md, "Timing"):
CUT_STOP_GRACE_S=60  # the Mac half TERMs the cut at D and KILLs its group this much later
CUT_REAP_S=10        # ... then waits at most this long for the killed group to be reaped
CUT_CLOCK_SKEW_S=120 # this host and the Mac are NTP-synced; the most their clocks may differ
CUT_MIN_WINDOW_S=300 # the Mac half does not start with less than this left before D: checkout,
                     # generate and the proof alone take minutes, so a shorter window spends the
                     # lock on a cut that cannot reach the upload
if [ -n "${MEMOS_CUT_TEST_TIMING:-}" ]; then
  [[ "$MEMOS_CUT_TEST_TIMING" =~ ^[0-9]{1,6}( [0-9]{1,6}){4}$ ]] ||
    refuse bad-test-timing "MEMOS_CUT_TEST_TIMING must be five whole numbers of seconds (got '$MEMOS_CUT_TEST_TIMING')"
  read -r budget CUT_STOP_GRACE_S CUT_REAP_S CUT_CLOCK_SKEW_S CUT_MIN_WINDOW_S <<<"$MEMOS_CUT_TEST_TIMING"
fi

if [ "$have_sha" -eq 1 ] && ! [[ "$sha_arg" =~ ^[0-9a-f]{40}$ ]]; then
  refuse bad-sha "--sha needs the full 40-character lowercase commit sha (got '$sha_arg')"
fi

command -v timeout >/dev/null 2>&1 || refuse no-timeout "timeout(1) is not on PATH"
command -v flock >/dev/null 2>&1 || refuse no-flock "flock(1) is not on PATH"

porcelain="$(git status --porcelain 2>&1)" || refuse no-repo "git status failed: $porcelain"
[ -z "$porcelain" ] ||
  refuse dirty "the tree is not clean (tracked changes, or an untracked file such as a log written into the checkout); commit, or write the log outside the checkout"

head="$(git rev-parse --verify HEAD 2>/dev/null)" || refuse no-repo "this checkout has no HEAD"

if [ "$have_sha" -eq 1 ]; then
  sha="$sha_arg"
  [ "$head" = "$sha" ] ||
    refuse sha-mismatch "HEAD is $head, --sha is $sha: --sha authorises the checked-out commit, it never selects another"
else
  sha="$head"
  git fetch --quiet origin +refs/heads/main:refs/remotes/origin/main ||
    refuse fetch "git fetch of origin main failed"
  main="$(git rev-parse --verify refs/remotes/origin/main)"
  [ "$head" = "$main" ] ||
    refuse not-origin-main "HEAD $head is not origin/main $main (pass --sha $head to cut it anyway)"
fi

# The estate lock, on descriptor 9, from here until the Mac half has reported. The push and the
# ssh inherit the descriptor, so the lock outlives this shell only as long as they do.
{ exec 9>>"$estate_lock"; } 2>/dev/null || refuse estate-lock "cannot open the estate lock $estate_lock"
echo "testflight-cut: waiting for the estate lock $estate_lock (up to ${lock_wait} s)"
lock_t0="$(date +%s)"
if ! flock -w "$lock_wait" 9; then
  echo "testflight-cut: the estate lock $estate_lock was still held after ${lock_wait} s" >&2
  summary ESTATE-LOCK-TIMEOUT 75
  exit 75
fi
echo "cut lock: waited $(( $(date +%s) - lock_t0 )) s"
release_estate_lock() {
  flock -u 9 2>/dev/null
  exec 9>&-
  echo "cut lock: released"
}

echo "testflight-cut: pushing $sha to $host as refs/cuts/$sha"
GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
  git push "ssh://$host$RELEASE_ROOT/repo.git" "$sha:refs/cuts/$sha"
push_rc=$?
if [ "$push_rc" -ne 0 ]; then
  release_estate_lock
  summary PUSH-FAILED "$push_rc"
  exit "$push_rc"
fi

log="$(mktemp)"
trap 'rm -f "${log:?}"' EXIT
ssh_t0="$(date +%s)"
deadline=$((ssh_t0 + budget))
hold_until=$((deadline + CUT_STOP_GRACE_S + CUT_REAP_S + CUT_CLOCK_SKEW_S))
utc() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
echo "testflight-cut: running $lane on $host until $(utc "$deadline") (deadline=$deadline, budget ${budget} s)"
# The Mac half enforces the deadline itself, its own lock wait included, and stops fastlane's whole
# process group. This outer timeout is only the backstop for a link that dies without ssh
# noticing: it ends the ssh leg 60 s after the hold below would have ended anyway.
timeout --kill-after=30 "$((hold_until - ssh_t0 + 60))" \
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
  "$host" "bash -s -- $sha $lane $deadline $CUT_STOP_GRACE_S $CUT_REAP_S $CUT_MIN_WINDOW_S" \
  < "$REMOTE_SCRIPT" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

report="$(grep '^testflight-cut REMOTE: ' "$log" | tail -n 1)"
field() { # NAME — one key=value of the report; anything but a plain token reads as `?`
  local v
  v="$(printf '%s\n' "$report" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1)"
  if [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]]; then printf '%s' "$v"; else printf '?'; fi
}
stage=""
if [ -n "$report" ]; then
  version="$(field version)"
  build="$(field build)"
  group="$(field group)"
  stage="$(field stage)"
fi

# No report, or ssh's own 255: the Mac half may still be cutting, so the lock stays held for as
# long as it could still run. No second ssh asks it; its log says what happened.
if [ "$rc" -eq 255 ] || [ -z "$report" ]; then
  echo "cut lock: holding until $(utc "$hold_until") (remote outcome unknown)"
  now="$(date +%s)"
  while [ "$now" -lt "$hold_until" ]; do
    sleep "$((hold_until - now))"
    now="$(date +%s)"
  done
  release_estate_lock
  [ "$rc" -ne 0 ] || rc=1
  summary "UNKNOWN(ssh-lost)" "$rc"
  exit "$rc"
fi
release_estate_lock

case "$rc:$stage" in
  124:budget) state=TIMEOUT ;;
  75:lock) state=LOCK-TIMEOUT ;;
  76:expired) state="REFUSED(deadline-passed)" ;;
  0:verify) if [ "$lane" = beta ]; then state=VALID; else state=NO-REPORT; rc=1; fi ;;
  0:fastlane) if [ "$lane" = archive_ipa ]; then state=archive-only; else state=NO-REPORT; rc=1; fi ;;
  0:*) state=NO-REPORT; rc=1 ;;
  20:prove) state="REFUSED(build-number-spent)" ;;
  *:prove) state="REFUSED(unused-unproven)" ;;
  *:precheck) state=REMOTE-REFUSED ;;
  *) state=FAILED ;;
esac
summary "$state" "$rc"
exit "$rc"
