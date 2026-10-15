#!/usr/bin/env bash
#
# mac-gate.sh — the build authority for this repo.
#
# Swift cannot be built on the Linux machine this repo is developed on, so every build, test,
# lint and dependency check runs on a Mac build host. This script is the ONLY sanctioned way to
# get there: it mirrors the working tree into a disposable gate directory on that host, runs the
# ordered checks, streams their output, copies the result bundle back, and returns the remote
# exit code unmasked.
#
# The ordered checks are: the gate's own classifier test, generate the project, lint, test, rebuild
# every package with warnings as errors, check the dependency rule, the share-link rule, the
# text-selection rule, the refusal-sites rule, the openapi-coverage rule and the release-notes
# rule, read the SHIPPING bundles back, and count the tests that actually ran.
#
# A change set of documentation and repository metadata only takes a FAST PATH. What the branch
# changed against origin/main (merge-base, renames not followed, so a rename is judged by both of
# its names) plus everything staged, edited or untracked in the working tree is classified against
# the allowlist in gate_path_is_metadata() below: docs/, any .md, .gitignore, .gitattributes,
# .editorconfig, CODEOWNERS, LICENSE. When every changed path is on it and none of them is a
# symbolic link, the gate reports "PASS (fast path: docs-only)" naming each path and the base it
# measured from, and copies nothing to the build host. Everything else — project.yml, any manifest,
# any source file, this script, the tests — meets the full gate, so a version bump can never skip
# the release-number check. What still runs on the fast path is what is local and cheap: the
# classifier's own test suite (tests/gate/fastpath-classify-test.sh, the gate's integrity check,
# which runs on EVERY gate) and the release-version authority check. The remote steps are skipped
# whole, `pins` included: it needs a generated project and a package resolution on the build host,
# which is the copy the fast path exists to avoid, and it reads Package.resolved — a file no
# docs-only change set can contain. Files git IGNORES are outside this classification by design:
# they never reach main, and the full gate builds whatever is on disk regardless.
#
# Git is the only medium of exchange between the two machines. The gate directory is a mirror,
# never a checkout: it is rsync'd with --delete, it is never opened in Xcode, and a developer's
# own clone on the build host is never a target (the containment check below enforces that).
#
# Usage:
#   MAC_GATE_HOST=<ssh-alias> bin/mac-gate.sh
#   MAC_GATE_HOST=<ssh-alias> bin/mac-gate.sh --quick [--bundle <name> | --only-testing <id>
#                                     [--iterations <N>]]
#                                     the ITERATION loop, never a verdict: lint, then compile for
#                                     testing on this branch's warm lane and run the named scope on
#                                     it. A lint error stops the run before anything is built.
#                                     --bundle names one of the gate's test bundles;
#                                     --only-testing takes an xcodebuild identifier
#                                     (Bundle, Bundle/Suite or Bundle/Suite/test). Neither means
#                                     anything without --quick, and only one of them at a time.
#                                     With --quick alone every bundle runs.
#                                     --iterations N (1..1000, only beside --only-testing) runs
#                                     that scope N times, stopping at the first failing run
#                                     (-test-iterations N -run-tests-until-failure), and the
#                                     MAC_GATE_QUICK line then carries iterations=N.
#   bin/mac-gate.sh --classify-only   print how this branch's change set classifies, and stop.
#                                     Needs no build host. Exit 0 = the docs-only fast path
#                                     applies, 10 = the full gate is owed.
#   bin/mac-gate.sh --help            print this usage.
#
# What the quick mode SKIPS is the whole difference: the package rebuilds with warnings fatal, the
# warnings canary, the pin check, the entitlement, dependency-rule, share-link, text-selection,
# refusal-sites, openapi-coverage and release-notes rules, the
# shipping-bundle read-back and the per-bundle test count. What it keeps is everything that makes
# a run safe to start: the selftests, the release-version check, the classification, this branch's
# lane lock, the run admission, the simulator slot and the private simulator — and the lint, which costs seconds and which
# the full gate would fail on anyway. It prints one line of its own,
# MAC_GATE_QUICK: lint=<rc> build=<rc> tests=<rc> locallint=<rc|-> | exit=<rc>, which is deliberately NOT the gate's
# summary line — a quick run can never be read, or pasted, as a verdict. The verdict is the full
# gate.
# It reuses the lane's DerivedData, which is why it is quick and why it takes the same lock: the
# tree it compiles into is the tree a full run of this branch would rsync --delete.
#
# Two gates for two branches can run at the same time. They must not share a simulator: the
# device holds ONE installation per bundle id, so a second branch installing over the first
# leaves an app whose frameworks belong to the other branch — dyld "Symbol not found" at launch
# and a red gate that says nothing about the code under test (observed 2026-08-24, three
# concurrent gates, two false reds). So by default this script gives each run its own device:
# created on the build host after the compile, just before the tests, named for the branch and the
# run token, and deleted again right after them and on every exit path (see the trap in the remote
# script).
#
# Gates of DIFFERENT projects share the host too, and two simulator phases at once fill its disk and
# its swap (measured 2026-09-28..30). So the simulator phase — device creation, boot, the tests,
# the device's deletion — runs only inside the host-wide slot, and compiling happens outside it:
# `xcodebuild build-for-testing` against the generic simulator destination, then
# `test-without-building` on the private device. Before anything is copied the run waits for room
# on the disk (run admission); before the device exists it waits for the slot and for the host's
# conditions (simulator admission). Both are conditions, never timers: a wait ends in admission or
# in a refusal with its own code. scripts/gate-admission.sh holds both, byte-identical across the
# projects that gate on the host.
#
# Environment:
#   MAC_GATE_HOST        (required) ssh alias/host of the Mac build host, or `auto`: the run
#                        picks the host itself from MAC_GATE_ESTATE_LOCKS — the first whose lock
#                        is free and which answers ssh, in map order; with every host busy, a
#                        blocking wait on the host whose lane last ran this branch (the
#                        <artifacts>/lane-host marker, under 24 h old), else the first. The choice
#                        and its reason are the log's `route` line; host= is on the SUMMARY and
#                        quick lines and in the ledger's 13th field. Not for bin/testflight-cut.sh.
#   MAC_GATE_BRANCH      override the branch that names the gate directory (default: current)
#   MAC_GATE_SIMULATOR   run on this EXISTING, shared device by name instead of a private one.
#                        Only for reproducing a device-specific failure — it gives up the
#                        isolation above, so two runs set to the same name can cross-install.
#   MAC_GATE_DEVICE_TYPE device type identifier for the private device
#                        (e.g. com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro). Default:
#                        chosen on the build host from the newest installed iOS runtime.
#   MAC_GATE_ARTIFACTS   local directory for the copied-back .xcresult/screenshots and for this
#                        run's own log, mac-gate-<branch>-<run token>.log — one file per run, so
#                        two runs cannot write over each other and a caller's redirect cannot
#                        truncate either (default: <repo>/.gate-artifacts)
#   MAC_GATE_ESTATE_LOCK  a lock file this run takes itself (flock, blocking) before anything else
#                        it does but the local lint, and holds until it ends; the wait is stamped into the run log and
#                        the run ledger. Unset: no lock is taken. A lock it cannot open or take
#                        refuses the run (exit 15). Never set it under an outside `flock` on the
#                        same path: the gate's own open is a second lock on that file, and it waits
#                        forever for the wrapper that is waiting for the gate.
#   MAC_GATE_ESTATE_LOCKS the per-host lock map, name=lock,name=lock in preference order (names:
#                        merkur, mars). Read by `auto`, and by an explicit host when
#                        MAC_GATE_ESTATE_LOCK is unset (it takes its own entry). An unknown name,
#                        or `auto` without the map, refuses the run (exit 15) before any lock.
#                        Every run that builds also holds <artifacts>/.run.lock (flock, fd 7) from
#                        before its estate lock until it exits, so two runs of one worktree never
#                        overlap, whatever host each one is on.
#   MAC_GATE_RUNS_LEDGER the run ledger every run past its log's creation appends ONE row to
#                        (default /home/fabian/projects/worktrees/gate-runs.tsv).
#   MAC_GATE_RUNS_LOGS   where that row's durable copy of this run's complete log goes, as
#                        memos-ng-ios-<branch>-<run token>.log, and which the row names: a
#                        worktree's .gate-artifacts goes with the worktree at merge-closeout
#                        (default: gate-logs/ beside MAC_GATE_RUNS_LEDGER).
#   MAC_GATE_TEST_BUNDLES  ADDITIONAL test bundles that must each run >= 1 test. The bundles
#                        below are always enforced and cannot be removed by setting this — an
#                        override that could shrink the list would let a suite stop being built
#                        without the gate noticing. Adding one is not a verdict either: the
#                        tracked test-count baseline must name exactly the bundles a run wanted,
#                        so a run with a different list fails at testcount by design, until the
#                        baseline is re-recorded from a run that wanted the same list.
#
# Two gates for the SAME branch are a different matter: they share the gate directory, the work
# directory, the DerivedData and the result bundle, so the second one's `rsync --delete` rewrites
# the tree the first is building and the verdict belongs to neither. Those runs are serialised by
# a lock on the branch's gate directory, taken before anything is copied. The loser does not
# wait: it says who holds the lock and stops.
#
# Before copying, a successful pruned origin fetch with the standard fetch refspec lets the
# build host reclaim unlocked gate/work lanes older than 24 hours and absent from both local
# and origin heads. Current lanes are protected. Reaping logs directory sizes and the data
# volume's free space before and after; a failed fetch or non-standard refspec skips it.
#
# Exit codes: 2 = refusal (unsafe or unusable inputs, nothing was copied or run);
#             3 = another run of this branch holds the gate lock (nothing was copied or run);
#             4 = the lock this run held was reaped while the run was starting, and the build host
#                 half stopped before touching anything;
#            10 = --classify-only only: this change set owes the full gate (0 there means the
#                 fast path applies);
#            11 = the simulator slot or the host's conditions stayed unmet until the ceiling
#                 (slot=11; the build ran, no device was created);
#            12 = free space stayed below the threshold until the ceiling (admit=12 before
#                 anything was copied, or slot=12 before the device);
#            13 = a reading the admission depends on could not be taken three polls running
#                 (admit=13 or slot=13);
#            14 = slot=14, in the build host's log only: its controller's ssh went away before the
#                 slot was claimed, so it stopped waiting instead of testing for nobody;
#            15 = MAC_GATE_ESTATE_LOCK(S) names a lock this run could not open or take, the map
#                 is missing or names an unknown host, no host of the map can take the run, or
#                 the worktree run lock could not be taken (nothing was copied, run or written
#                 to the run ledger);
#            16 = mount=16: the build host's build root is not proven to be that host's designated
#                 build image (the guard refused, or its answer could not be read), and no
#                 valid pending marker allowed the refusal to be reported instead; nothing was
#                 written on the host, no slot was claimed and no device was created;
#             1 = also locallint=1: `swift format lint` failed on the calling machine before the
#                 estate lock was requested (the lint's own code; locallint=1 on the summary and
#                 mode=refused in the run ledger tell it from a build-host step's 1); nothing
#                 was copied, no lock was taken and the build host was never contacted;
#             otherwise the exit code of the first failing step.

set -uo pipefail

GATE_ROOT_REMOTE='$HOME/build/memos-ng-ios/gate'
# Empty means "create a private device for this run" — the default. A name here is the opt-out.
SIMULATOR="${MAC_GATE_SIMULATOR:-}"
DEVICE_TYPE="${MAC_GATE_DEVICE_TYPE:-}"
# Always enforced. MAC_GATE_TEST_BUNDLES may only ADD to this list.
MANDATORY_TEST_BUNDLES="MemosAPITests MemosCoreTests MemosOutboxTests MemosFeaturesTests MemosShareKitTests"
TEST_BUNDLES="$MANDATORY_TEST_BUNDLES"
for extra in ${MAC_GATE_TEST_BUNDLES:-}; do
  case " $TEST_BUNDLES " in
    *" $extra "*) ;;
    *) TEST_BUNDLES="$TEST_BUNDLES $extra" ;;
  esac
done

die_refuse() {
  printf 'mac-gate: REFUSED: %s\n' "$1" >&2
  exit 2
}

# Whether this process is the run's private copy (see "the run's private copy" below): defined
# here, ahead of everything that mutates anything, because the estate lock is taken first.
gate_run_copy_is_own() {
  local claimed="${MAC_GATE_RUN_COPY:-}" here
  [ -n "$claimed" ] || return 1
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1
  [ "$here" = "$claimed" ] || return 1
  case "${here##*/}" in mac-gate-run.*) ;; *) return 1 ;; esac
  [ "$(cat "$here/.mac-gate-run-copy" 2>/dev/null)" = "$here" ]
}
# The estate lock. The bootstrap takes it before anything this run does can change anything — the
# stale-candidate cleanup below included — so the run it covers is the whole run, what an outside
# `flock … mac-gate.sh` used to cover. The descriptor it is held on (9, opened without
# close-on-exec) is the one the exec further down hands to the copy: the copy never reopens it, so
# there is no moment between the two in which the lock is free. Everything from here to that exec
# is ONE brace group: bash reads a compound command whole before running any of it, so a wait of
# hours cannot end in reading a file that was edited meanwhile. The copy drops the variable, so a
# gate a selftest starts never queues behind the run that started it. A clock that cannot be read
# leaves "?" as the stamp: the lock is still held, and the run ledger declines the row.
# That same missing close-on-exec hands descriptor 9 to every child, and a child that holds it holds
# the lock: an ssh client the build host keeps busy would hold the next run back after this one was
# killed. So every child that can outlive a moment — each ssh, rsync, timeout, flock, fetch, poll
# sleep, selftest, helper and the tee beside them — is started with `9>&-`, and a subshell that
# waits on one closes it first with `exec 9>&-`. A redirect around a group in this shell is not
# enough: bash keeps its saved copy open in every subshell forked inside. The exec to the copy is
# the one launch that keeps it. tests/gate/estate-ledger-test.sh (case 21) kills a run mid-child.
GATE_ESTATE_LOCK_REQUESTED=""
GATE_ESTATE_LOCK_ACQUIRED=""
# The build host's swift-format, read on merkur with `swift format --version` on 2026-10-13. The
# live value reaches a run only with the build host's own lint step (its MAC_GATE_SWIFTFORMAT
# line), long after the local lint has spoken, so the local verdict line names this pin; compare
# the two lines in one run log to see whether the pin is still true.
GATE_SWIFTFORMAT_MAC="6.3.0 (pinned, read 2026-10-13)"
GATE_SWIFTFORMAT_MAC_MAJOR=6
GATE_LOCALLINT_RC=""
GATE_LOCALLINT_TEXT=""
GATE_LOCALLINT_SECS="?"
die_estate_lock() {
  printf 'mac-gate: REFUSED: %s\n' "$1" >&2
  exit 15
}
# --- host routing (MEMNG-824) ---------------------------------------------------------------------
# MAC_GATE_ESTATE_LOCKS=name=lock,name=lock maps each build host to its estate lock, in preference
# order. MAC_GATE_HOST=auto picks the host here, in the bootstrap, because the lock IS the choice
# and it has to be held before the copy is made. The names it may hold are the mount guard's
# profiles (scripts/gate-mount-guard.sh), and tests/gate/host-routing-test.sh holds this list to
# them: a host without a profile is refused by the guard anyway, so it is refused here before any
# lock is touched.
GATE_ROUTE_HOSTS="merkur mars"
GATE_ROUTE_NAMES=()
GATE_ROUTE_LOCKS=()
GATE_ROUTE_HOST=""
GATE_ROUTE_REASON=""
# What the bootstrap hands the copy: the route's reason, the worktree run lock's path and its wait.
GATE_HOST_ROUTE=""
GATE_RUN_LOCK_FILE=""
GATE_RUN_LOCK_WAIT=""
gate_route_parse_map() { # $1 = MAC_GATE_ESTATE_LOCKS; refuses (exit 15) before any lock is touched
  local entry name path
  local -a entries=()
  GATE_ROUTE_NAMES=()
  GATE_ROUTE_LOCKS=()
  IFS=, read -r -a entries <<< "$1"
  [ "${#entries[@]}" -gt 0 ] || die_estate_lock "MAC_GATE_ESTATE_LOCKS names no host (name=lock,name=lock)"
  for entry in "${entries[@]}"; do
    name="${entry%%=*}"
    path="${entry#*=}"
    [ "$entry" != "$name" ] && [ -n "$name" ] && [ -n "$path" ] \
      || die_estate_lock "MAC_GATE_ESTATE_LOCKS entry '$entry' is not name=lock"
    case " $GATE_ROUTE_HOSTS " in
      *" $name "*) ;;
      *) die_estate_lock "MAC_GATE_ESTATE_LOCKS names $name, which is not a build host this gate knows ($GATE_ROUTE_HOSTS)" ;;
    esac
    case " ${GATE_ROUTE_NAMES[*]} " in
      *" $name "*) die_estate_lock "MAC_GATE_ESTATE_LOCKS names $name twice" ;;
    esac
    GATE_ROUTE_NAMES+=("$name")
    GATE_ROUTE_LOCKS+=("$path")
  done
}
gate_route_lock_of() { # $1 = host; its lock on stdout, non-zero when the map does not name it
  local i
  for i in "${!GATE_ROUTE_NAMES[@]}"; do
    [ "${GATE_ROUTE_NAMES[$i]}" = "$1" ] || continue
    printf '%s' "${GATE_ROUTE_LOCKS[$i]}"
    return 0
  done
  return 1
}
# A free lock on a Mac that is off proves nothing, so "free" means free AND answering.
gate_route_probe() { # $1 = host
  timeout 30 ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$1" true </dev/null >/dev/null 2>&1 9>&- 7>&-
}
# The host whose lane last ran this branch from this worktree, when that was under 24 hours ago
# (the lane reaper's own age bound): its DerivedData is likely still warm. Consulted only when
# every host is busy, so a wrong guess costs one cold build and never a queue.
gate_route_warm_host() { # $1 = artifacts directory, $2 = branch
  local m_host="" m_branch="" m_time="" m_token="" then now
  [ -n "$1" ] || return 1
  { read -r m_host m_branch m_time m_token < "$1/lane-host"; } 2>/dev/null || return 1
  [ -n "$m_host" ] && [ -n "$2" ] && [ "$m_branch" = "$2" ] || return 1
  then="$(date -u -d "$m_time" +%s 2>/dev/null)" \
    || then="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$m_time" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)" || return 1
  case "$then:$now" in [0-9]*:[0-9]*) ;; *) return 1 ;; esac
  case "$then$now" in *[!0-9]*) return 1 ;; esac
  [ $((now - then)) -ge 0 ] && [ $((now - then)) -lt 86400 ] || return 1
  printf '%s' "$m_host"
}
# Leaves descriptor 9 holding the chosen host's estate lock, and sets GATE_ROUTE_HOST and
# GATE_ROUTE_REASON. Runs in the bootstrap's own shell, never in a subshell: the lock it takes is
# the run's. Its `exec 9>&-` lines give up a host's lock in this shell and close nothing else —
# descriptor 7, the worktree run lock, stays open for the whole run.
#   (a) each host in map order: flock -n; free and answering is taken at once; free but silent is
#       let go as unreachable; held is let go as busy (a held lock is never read as a dead host);
#   (b) no host taken: each busy host is probed; busy and answering form the wait set;
#   (c) an empty wait set refuses (exit 15), naming every host's state;
#   (d) the warm lane's host when it is in the set, else the first in map order;
#   (e) a blocking flock on it — as long as its holder needs; the other host freeing meanwhile
#       does not move the run;
#   (f) after the take one more probe: a host that went away during the wait is let go, dropped
#       from the set, and the choice is made again (each host can be dropped once, so this ends).
gate_route_auto() { # $1 = artifacts directory, $2 = branch
  local i h l pick why warm kept="" busy_names="" unreachable="" lost="" states="" n_busy=0
  local -a state=() waitset=() rest=()
  for i in "${!GATE_ROUTE_NAMES[@]}"; do
    h="${GATE_ROUTE_NAMES[$i]}"
    l="${GATE_ROUTE_LOCKS[$i]}"
    { exec 9>>"$l"; } 2>/dev/null \
      || die_estate_lock "cannot open the estate lock $l of $h (MAC_GATE_ESTATE_LOCKS)"
    if flock -n 9 7>&-; then
      if gate_route_probe "$h"; then
        kept="$h"
        break
      fi
      exec 9>&-
      state[$i]=unreachable
      unreachable="$unreachable${unreachable:+, }$h unreachable"
    else
      exec 9>&-
      state[$i]=busy
      busy_names="$busy_names${busy_names:+,}$h"
      n_busy=$((n_busy + 1))
    fi
  done
  if [ -n "$kept" ]; then
    GATE_ROUTE_HOST="$kept"
    states="$busy_names"
    [ -z "$states" ] || states="${states//,/ held, } held"
    [ -z "$unreachable" ] || states="$states${states:+, }$unreachable"
    GATE_ROUTE_REASON="free:$kept${states:+ ($states)}"
    return 0
  fi
  for i in "${!GATE_ROUTE_NAMES[@]}"; do
    [ "${state[$i]:-}" = busy ] || continue
    if gate_route_probe "${GATE_ROUTE_NAMES[$i]}"; then
      waitset+=("$i")
    else
      state[$i]=busy-unreachable
      unreachable="$unreachable${unreachable:+, }${GATE_ROUTE_NAMES[$i]} unreachable"
    fi
  done
  warm="$(gate_route_warm_host "$1" "$2")" || warm=""
  while :; do
    if [ "${#waitset[@]}" -eq 0 ]; then
      states=""
      for i in "${!GATE_ROUTE_NAMES[@]}"; do states="$states ${GATE_ROUTE_NAMES[$i]}=${state[$i]:-unprobed}"; done
      die_estate_lock "no build host can take this run:$states (MAC_GATE_ESTATE_LOCKS)"
    fi
    pick="${waitset[0]}"
    why="first in order"
    for i in "${waitset[@]}"; do
      if [ -n "$warm" ] && [ "${GATE_ROUTE_NAMES[$i]}" = "$warm" ]; then pick="$i"; why="warm lane"; fi
    done
    h="${GATE_ROUTE_NAMES[$pick]}"
    l="${GATE_ROUTE_LOCKS[$pick]}"
    printf 'mac-gate: every build host is busy; waiting for %s (%s)\n' "$h" "$why" >&2
    { exec 9>>"$l"; } 2>/dev/null \
      || die_estate_lock "cannot open the estate lock $l of $h (MAC_GATE_ESTATE_LOCKS)"
    flock 9 7>&- \
      || die_estate_lock "cannot take the estate lock $l of $h (MAC_GATE_ESTATE_LOCKS)"
    gate_route_probe "$h" && break
    exec 9>&-
    state[$pick]=unreachable-after-wait
    lost="$lost${lost:+, }$h unreachable after the wait"
    rest=()
    for i in "${waitset[@]}"; do [ "$i" = "$pick" ] || rest+=("$i"); done
    waitset=("${rest[@]+"${rest[@]}"}")
  done
  GATE_ROUTE_HOST="$h"
  if [ "$n_busy" -eq "${#GATE_ROUTE_NAMES[@]}" ] && [ "$n_busy" -eq 2 ]; then busy_names=both; fi
  states="$unreachable"
  [ -z "$lost" ] || states="$states${states:+, }$lost"
  GATE_ROUTE_REASON="busy:$busy_names${states:+ ($states)} -> waited on $h ($why)"
}
{
if gate_run_copy_is_own; then
  if [ -n "${MAC_GATE_ESTATE_LOCK_STAMPS:-}" ]; then
    GATE_ESTATE_LOCK_REQUESTED="${MAC_GATE_ESTATE_LOCK_STAMPS%% *}"
    GATE_ESTATE_LOCK_ACQUIRED="${MAC_GATE_ESTATE_LOCK_STAMPS#* }"
  fi
  GATE_HOST_ROUTE="${MAC_GATE_HOST_ROUTE:-}"
  GATE_RUN_LOCK_FILE="${MAC_GATE_RUN_LOCK:-}"
  GATE_RUN_LOCK_WAIT="${MAC_GATE_RUN_LOCK_WAIT:-}"
  # The bootstrap's lint verdict, which the candidate removal below needs before the copy's own
  # locallint step reads it again.
  { read -r GATE_LOCALLINT_RC _ < "$MAC_GATE_RUN_COPY/locallint.rc"; } 2>/dev/null || GATE_LOCALLINT_RC=""
  unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_ESTATE_LOCKS \
    MAC_GATE_HOST_ROUTE MAC_GATE_RUN_LOCK MAC_GATE_RUN_LOCK_WAIT
else
  unset MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_HOST_ROUTE MAC_GATE_RUN_LOCK MAC_GATE_RUN_LOCK_WAIT
  # The local lint (MEMNG-807, scripts/local-lint.sh) comes before the estate lock is requested,
  # or it saves nothing: a formatting error used to wait out the whole queue only to fail the
  # build host's first step (41 minutes, 2026-10-13). It runs here, in the original text, because
  # the private copy is made after the lock; the helper's text is read once and evaluated, so an
  # edit to the tree during the lint cannot change what runs. --help and --classify-only build
  # nothing and lint nothing, and neither does a run without MAC_GATE_HOST, which the copy refuses
  # before it does anything. A failure (rc 1) skips the lock; the copy refuses the run.
  gate_lint_wanted=1
  [ -n "${MAC_GATE_HOST:-}" ] || gate_lint_wanted=0
  for gate_arg in "$@"; do
    case "$gate_arg" in --help|-h|--classify-only) gate_lint_wanted=0 ;; esac
  done
  if [ "$gate_lint_wanted" -eq 1 ]; then
    gate_lint_none="MAC_GATE_LOCALLINT rc=- local=none version=- mac=$GATE_SWIFTFORMAT_MAC"
    gate_lint_t0="$(date +%s)"
    gate_lint_root="$(git rev-parse --show-toplevel 2>/dev/null)" || gate_lint_root=""
    if [ -z "$gate_lint_root" ]; then
      GATE_LOCALLINT_RC=100
      GATE_LOCALLINT_TEXT="locallint   : fell through — not inside a git working tree
$gate_lint_none"
    elif ! gate_lint_src="$(cat "$gate_lint_root/scripts/local-lint.sh" 2>/dev/null)"; then
      GATE_LOCALLINT_RC=100
      GATE_LOCALLINT_TEXT="locallint   : fell through — $gate_lint_root/scripts/local-lint.sh is not in this tree; the build host lints this run as before
$gate_lint_none"
    elif ! eval "$gate_lint_src" || ! declare -F local_lint_report >/dev/null; then
      GATE_LOCALLINT_RC=100
      GATE_LOCALLINT_TEXT="locallint   : fell through — $gate_lint_root/scripts/local-lint.sh did not load; the build host lints this run as before
$gate_lint_none"
    else
      printf 'mac-gate: linting %s on this machine before the estate lock is requested\n' "$gate_lint_root" >&2
      GATE_LOCALLINT_TEXT="$(local_lint_report "$gate_lint_root" "$GATE_SWIFTFORMAT_MAC" "$GATE_SWIFTFORMAT_MAC_MAJOR" 2>&1)"
      GATE_LOCALLINT_RC=$?
    fi
    gate_lint_t1="$(date +%s)"
    case "$gate_lint_t0:$gate_lint_t1" in
      [0-9]*:[0-9]*) GATE_LOCALLINT_SECS=$((gate_lint_t1 - gate_lint_t0)) ;;
    esac
  fi
  # Which estate lock this run takes. MAC_GATE_ESTATE_LOCK, when set, is taken exactly as it always
  # was, by every run; the map is read only by a run that builds (not --help, --classify-only or a
  # run without a host): auto routes over it, an explicit host takes its own entry. auto ignores
  # MAC_GATE_ESTATE_LOCK, which names no host. Every refusal here comes before any lock is taken.
  gate_route_source=none
  gate_route_lock=""
  if [ "$GATE_LOCALLINT_RC" != 1 ]; then
    if [ "$gate_lint_wanted" -eq 1 ] && [ "$MAC_GATE_HOST" = auto ]; then
      [ -n "${MAC_GATE_ESTATE_LOCKS:-}" ] \
        || die_estate_lock "MAC_GATE_HOST=auto needs MAC_GATE_ESTATE_LOCKS (name=lock,name=lock, in preference order)"
      gate_route_parse_map "$MAC_GATE_ESTATE_LOCKS"
      gate_route_source=auto
    elif [ -n "${MAC_GATE_ESTATE_LOCK:-}" ]; then
      gate_route_source=MAC_GATE_ESTATE_LOCK
      gate_route_lock="$MAC_GATE_ESTATE_LOCK"
    elif [ "$gate_lint_wanted" -eq 1 ] && [ -n "${MAC_GATE_ESTATE_LOCKS:-}" ]; then
      gate_route_parse_map "$MAC_GATE_ESTATE_LOCKS"
      if gate_route_lock="$(gate_route_lock_of "$MAC_GATE_HOST")"; then
        gate_route_source=MAC_GATE_ESTATE_LOCKS
      else
        gate_route_lock=""
      fi
    fi
  fi
  # lock_requested is stamped BEFORE the worktree run lock, so the ledger's wait includes a wait
  # for an earlier run of this worktree as well as the estate's queue; the route line separates them.
  if [ "$gate_route_source" != none ]; then
    GATE_ESTATE_LOCK_REQUESTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || GATE_ESTATE_LOCK_REQUESTED="?"
    [ -n "$GATE_ESTATE_LOCK_REQUESTED" ] || GATE_ESTATE_LOCK_REQUESTED="?"
  fi
  # The worktree run lock, taken by every run that builds or tests, whatever its host. The lane
  # lock is per host, so without it two runs of this worktree could hold merkur's and mars's locks
  # at once over one artifacts directory — and the later one's startup deletes the earlier one's
  # test-count candidate, its copyback every incoming-* folder. A kernel flock on descriptor 7,
  # which the exec below hands to the copy like 9: the kernel frees it however the run ends,
  # SIGKILL included, so there is no owner to judge and nothing to reclaim. Children close 7
  # wherever they close 9 (`9>&- 7>&-`), or a child that outlives the run would hold it — the
  # estate-lock `flock 9` children too (`flock 9 7>&-`), which wait on 9 and so cannot close it.
  if [ "$gate_lint_wanted" -eq 1 ] && [ "$GATE_LOCALLINT_RC" != 1 ]; then
    gate_wt_root="$(git rev-parse --show-toplevel 2>/dev/null)" || gate_wt_root=""
    case "${MAC_GATE_ARTIFACTS:-}" in
      /*) gate_wt_art="$MAC_GATE_ARTIFACTS" ;;
      "") gate_wt_art="${gate_wt_root:+$gate_wt_root/.gate-artifacts}" ;;
      *) gate_wt_art="${gate_wt_root:+$gate_wt_root/$MAC_GATE_ARTIFACTS}" ;;
    esac
    if [ -n "$gate_wt_art" ]; then
      { mkdir -p "$gate_wt_art" && exec 7>>"$gate_wt_art/.run.lock"; } 2>/dev/null \
        || die_estate_lock "cannot open the worktree run lock $gate_wt_art/.run.lock"
      gate_wt_t0="$(date +%s)"
      flock -x 7 \
        || die_estate_lock "cannot take the worktree run lock $gate_wt_art/.run.lock"
      gate_wt_t1="$(date +%s)"
      gate_wt_wait="?"
      case "$gate_wt_t0:$gate_wt_t1" in
        [0-9]*:[0-9]*) gate_wt_wait=$((gate_wt_t1 - gate_wt_t0)) ;;
      esac
      export MAC_GATE_RUN_LOCK="$gate_wt_art/.run.lock" MAC_GATE_RUN_LOCK_WAIT="$gate_wt_wait"
    fi
    if [ "$gate_route_source" = auto ]; then
      gate_route_auto "${gate_wt_art:-}" "${MAC_GATE_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
      export MAC_GATE_HOST="$GATE_ROUTE_HOST"
      export MAC_GATE_HOST_ROUTE="$GATE_ROUTE_REASON"
    elif [ "$gate_route_source" = none ]; then
      export MAC_GATE_HOST_ROUTE="explicit:no-estate-lock"
    else
      export MAC_GATE_HOST_ROUTE="explicit:$gate_route_source"
    fi
  fi
  if [ -n "$gate_route_lock" ]; then
    { exec 9>>"$gate_route_lock"; } 2>/dev/null \
      || die_estate_lock "cannot open the estate lock $gate_route_lock ($gate_route_source)"
    flock 9 7>&- \
      || die_estate_lock "cannot take the estate lock $gate_route_lock ($gate_route_source)"
  fi
  if [ "$gate_route_source" != none ]; then
    GATE_ESTATE_LOCK_ACQUIRED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || GATE_ESTATE_LOCK_ACQUIRED="?"
    [ -n "$GATE_ESTATE_LOCK_ACQUIRED" ] || GATE_ESTATE_LOCK_ACQUIRED="?"
    export MAC_GATE_ESTATE_LOCK_STAMPS="$GATE_ESTATE_LOCK_REQUESTED $GATE_ESTATE_LOCK_ACQUIRED"
  fi
fi

# --- the test-count candidate: cleared before anything else --------------------------------------
# The candidate at the documented path (`<repo root>/.gate-artifacts/testcount-baseline.tsv`, or
# `$MAC_GATE_ARTIFACTS/testcount-baseline.tsv`) is what the documented `cp` records, so it must be
# one this run put there through its validated copyback and nothing else. The copyback never writes
# that path directly — it stages into `incoming-<run token>/` and scripts/testcount-candidate-owner.sh
# promotes the candidate only beside this run's stamp — so an earlier run's candidate is the only
# other thing that can be there. It goes here, first: before the arguments are read and before any
# refusal, so every exit this run can take after this point — a refused argument, a missing host, a
# failed mirror, a signal — leaves no candidate unless this run's own promotion wrote it. Staging
# folders an earlier run abandoned are NOT touched here but in the copyback, right before this run's
# own copy: this point is reached before the lane lock, so by `--help`, `--classify-only` and a run
# the lock is about to refuse, and a discard here could take a live run's staging mid-copy. The
# folder is resolved the way the rest of the run resolves it (a relative override is relative to
# the repository root); a run that can resolve neither an override nor a root has no documented path
# and clears nothing, and is refused below as it always was. A removal that fails refuses the run:
# the refusal names the file, and nothing after it runs. The one run that clears nothing is one the
# local lint refused (rc 1): it never took the estate lock, and the estate lock is what kept this
# removal from taking the candidate a run of the same worktree is still promoting in its
# copyback; the lane lock comes too late to cover it. Such a run builds nothing and promotes
# nothing, so a candidate beside a locallint=1 run is never that run's.
early_root="$(git rev-parse --show-toplevel 2>/dev/null)" || early_root=""
case "${MAC_GATE_ARTIFACTS:-}" in
  /*) artifacts="$MAC_GATE_ARTIFACTS" ;;
  "") artifacts="${early_root:+$early_root/.gate-artifacts}" ;;
  *) artifacts="${early_root:+$early_root/$MAC_GATE_ARTIFACTS}" ;;
esac
if [ -n "$artifacts" ] && [ "$GATE_LOCALLINT_RC" != 1 ]; then
  rm -f "$artifacts/testcount-baseline.tsv" \
    || die_refuse "cannot remove $artifacts/testcount-baseline.tsv: stale candidate left in place — not this run's"
fi

# --- the run's private copy ----------------------------------------------------------------------
# Bash reads a script as it runs it, so an edit to this file during a run is read at the old byte
# offset in the NEW text. A gate once died at its summary line with a syntax error and no verdict,
# after the build host had finished, because its worktree was edited mid-run (2026-09-09). So a run
# copies this file, and every helper it hands to the build host or runs itself, into a private
# directory and execs the copy: from then on the tree can change freely. The helpers come from the
# CALLER's repository — the same `git rev-parse --show-toplevel` in the caller's directory the rest
# of the run uses, which exec leaves where it was — never from wherever this file sits. Everything
# above this point runs from the original text, and has to: the stale candidate goes before
# anything can refuse, so the copy clears it again, which costs nothing.
#
# A copy knows it is one by where it runs from: a directory named mac-gate-run.*, named by
# MAC_GATE_RUN_COPY, holding the marker only this bootstrap writes. Anything else — the variable
# unset, or exported by a caller at some other directory — makes a fresh copy, because the copy's
# directory is what the run removes when it ends. The variable is dropped as soon as it is read, so
# a gate a selftest starts makes a copy of its own.
GATE_RUN_HELPERS="reap-gate-lanes.sh gate-work-dir.sh gate-root-refusal.sh testcount-candidate-owner.sh gate-admission.sh gate-mount-guard.sh"
gate_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi \
    | awk '{print $1}'
}
if gate_run_copy_is_own; then
  GATE_RUN_COPY="$MAC_GATE_RUN_COPY"
  unset MAC_GATE_RUN_COPY
else
  unset MAC_GATE_RUN_COPY
  gate_run_dir="$(mktemp -d "${TMPDIR:-/tmp}/mac-gate-run.XXXXXX")" \
    || die_refuse "cannot create a private directory to run the gate from"
  gate_run_dir="$(cd "$gate_run_dir" && pwd -P)" \
    || die_refuse "cannot resolve the private directory $gate_run_dir"
  gate_origin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  gate_caller_root="$(git rev-parse --show-toplevel 2>/dev/null)" || gate_caller_root=""
  mkdir "$gate_run_dir/scripts" && cp -p "$gate_origin" "$gate_run_dir/mac-gate.sh" \
    && printf '%s\n' "$gate_origin" > "$gate_run_dir/.mac-gate-origin" \
    || { rm -rf "$gate_run_dir"; die_refuse "cannot copy $gate_origin into $gate_run_dir"; }
  if [ -n "$gate_caller_root" ]; then
    for gate_helper in $GATE_RUN_HELPERS; do
      # A helper this tree does not have stays missing in the copy, and fails where it always did.
      [ -e "$gate_caller_root/scripts/$gate_helper" ] || continue
      cp -p "$gate_caller_root/scripts/$gate_helper" "$gate_run_dir/scripts/$gate_helper" \
        || { rm -rf "$gate_run_dir"; die_refuse "cannot copy scripts/$gate_helper into $gate_run_dir"; }
    done
  fi
  if [ -n "$GATE_LOCALLINT_RC" ]; then
    { printf '%s\n' "$GATE_LOCALLINT_TEXT" > "$gate_run_dir/locallint.txt" \
        && printf '%s %s\n' "$GATE_LOCALLINT_RC" "$GATE_LOCALLINT_SECS" > "$gate_run_dir/locallint.rc"; } \
      || { rm -rf "$gate_run_dir"; die_refuse "cannot hand the local lint's verdict to $gate_run_dir"; }
  fi
  printf '%s\n' "$gate_run_dir" > "$gate_run_dir/.mac-gate-run-copy" \
    || { rm -rf "$gate_run_dir"; die_refuse "cannot mark $gate_run_dir as this run's copy"; }
  export MAC_GATE_RUN_COPY="$gate_run_dir"
  exec "${BASH:-bash}" "$gate_run_dir/mac-gate.sh" "$@"
fi
}
remove_run_copy() {
  [ -n "${GATE_RUN_COPY:-}" ] || return 0
  rm -rf "$GATE_RUN_COPY"
  GATE_RUN_COPY=""
}
trap 'remove_run_copy' EXIT
GATE_SCRIPT_ORIGIN="$(cat "$GATE_RUN_COPY/.mac-gate-origin" 2>/dev/null)"
GATE_SCRIPT_SHA256="$(gate_sha256 "$GATE_RUN_COPY/mac-gate.sh")"
case "$GATE_SCRIPT_SHA256" in
  [0-9a-f]*) [ "${#GATE_SCRIPT_SHA256}" -eq 64 ] \
    || die_refuse "cannot name the sha256 of $GATE_RUN_COPY/mac-gate.sh" ;;
  *) die_refuse "cannot name the sha256 of $GATE_RUN_COPY/mac-gate.sh" ;;
esac
# Selftest only: see the pause after the selftest step. Read once and dropped, so no child of this
# run — a gate a selftest starts included — ever pauses.
GATE_SELFTEST_PAUSE_DIR="${MAC_GATE_SELFTEST_PAUSE_DIR:-}"
unset MAC_GATE_SELFTEST_PAUSE_DIR

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# --classify-only answers one question — does this change set owe a build — and it has to be
# answerable without a Mac: it is what the gate's own test suite drives, and a classification that
# needed the build host would be the gate rather than a decision about it.
CLASSIFY_ONLY=0
QUICK=0
QUICK_BUNDLE=""
QUICK_ONLY_TESTING=""
QUICK_ITERATIONS=""
# A while/shift loop rather than `for arg`, because two of these take a value. The value is
# checked where it is read: a flag whose argument is missing would otherwise swallow the NEXT
# flag, and `--quick --bundle --only-testing X` would run a scope nobody asked for.
while [ $# -gt 0 ]; do
  case "$1" in
    --classify-only) CLASSIFY_ONLY=1 ;;
    --quick) QUICK=1 ;;
    --bundle)
      case "${2:-}" in
        ""|-*) die_refuse "--bundle needs a test bundle name (one of: $TEST_BUNDLES)" ;;
      esac
      QUICK_BUNDLE="$2"; shift ;;
    --only-testing)
      case "${2:-}" in
        ""|-*) die_refuse "--only-testing needs an xcodebuild test identifier (Bundle, Bundle/Suite or Bundle/Suite/test)" ;;
      esac
      QUICK_ONLY_TESTING="$2"; shift ;;
    --iterations)
      case "${2:-}" in
        ""|-*) die_refuse "--iterations needs a positive whole number of runs (1 to 1000)" ;;
      esac
      QUICK_ITERATIONS="$2"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die_refuse "unknown argument: $(printf '%q' "$1") (see --help)" ;;
  esac
  shift
done

# The combinations, refused here rather than half-honoured later. A scope is a thing only the
# quick mode has; the full gate runs every bundle and always will, so a scope beside it is an
# instruction this script cannot carry out, not a preference it can ignore.
if [ -n "$QUICK_BUNDLE" ] && [ -n "$QUICK_ONLY_TESTING" ]; then
  die_refuse "--bundle and --only-testing are two ways to name one scope; pass one of them"
fi
if [ "$QUICK" -eq 0 ] && { [ -n "$QUICK_BUNDLE" ] || [ -n "$QUICK_ONLY_TESTING" ]; }; then
  die_refuse "--bundle and --only-testing only mean something with --quick; the full gate runs every bundle"
fi
# An iteration count repeats ONE named scope until it fails: the evidence it exists for is "this
# test, N times in a row", so a bundle or the whole suite beside it is refused rather than run.
if [ -n "$QUICK_ITERATIONS" ] && { [ "$QUICK" -eq 0 ] || [ -z "$QUICK_ONLY_TESTING" ]; }; then
  die_refuse "--iterations repeats one named scope, so it needs --quick --only-testing <id>"
fi
if [ -n "$QUICK_ITERATIONS" ]; then
  # Digits only and no leading zero, read as text before any arithmetic: a value bash would
  # misread (octal, overflow) never reaches a comparison. The ceiling is because every iteration
  # runs inside the host-wide simulator slot, which every other lane's gate waits on.
  case "$QUICK_ITERATIONS" in
    *[!0-9]*|0*)
      die_refuse "--iterations $(printf '%q' "$QUICK_ITERATIONS"): not a positive whole number" ;;
  esac
  if [ "${#QUICK_ITERATIONS}" -gt 4 ] || [ "$QUICK_ITERATIONS" -gt 1000 ]; then
    die_refuse "--iterations $QUICK_ITERATIONS: at most 1000 runs, each one inside the shared simulator slot"
  fi
fi
if [ "$QUICK" -eq 1 ] && [ "$CLASSIFY_ONLY" -eq 1 ]; then
  die_refuse "--quick and --classify-only ask for different things: one builds and tests, the other only says whether a build is owed"
fi
if [ -n "$QUICK_BUNDLE" ]; then
  # Whitespace first, and then a whole-word comparison. The bundle list is one space-separated
  # string, so a substring test against it accepts a value that spans two names — "MemosAPITests
  # MemosCoreTests" is inside " $TEST_BUNDLES " and names no bundle at all — and a trailing space
  # turns a good name into one xcodebuild would read as an identifier that matches nothing.
  case "$QUICK_BUNDLE" in
    *[[:space:]]*)
      die_refuse "--bundle names ONE test bundle, and $(printf '%q' "$QUICK_BUNDLE") contains whitespace (one of: $TEST_BUNDLES)" ;;
  esac
  quick_bundle_known=0
  for known_bundle in $TEST_BUNDLES; do
    [ "$QUICK_BUNDLE" != "$known_bundle" ] || quick_bundle_known=1
  done
  [ "$quick_bundle_known" -eq 1 ] \
    || die_refuse "--bundle $QUICK_BUNDLE: not one of the test bundles this gate builds ($TEST_BUNDLES)"
fi

# Single-quote escaping for values interpolated into a script sent to the build host, so a branch
# name can never become remote shell syntax.
esc() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

# --- inputs -----------------------------------------------------------------------------------
host="${MAC_GATE_HOST:-}"
[ -n "$host" ] || [ "$CLASSIFY_ONLY" -eq 1 ] \
  || die_refuse "MAC_GATE_HOST is not set (ssh alias of the Mac build host)"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die_refuse "not inside a git working tree"
cd "$repo_root" || die_refuse "cannot enter $repo_root"

# (1) refuse unless the local tree has a HEAD — an empty repo has nothing reviewable to build,
#     and the provenance header below would be a lie.
head_sha="$(git rev-parse --verify HEAD 2>/dev/null)" \
  || die_refuse "the working tree has no HEAD commit (nothing to build from)"

branch="${MAC_GATE_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
[ -n "$branch" ] || die_refuse "cannot determine the branch name"
[ "$branch" != "HEAD" ] || die_refuse "detached HEAD: set MAC_GATE_BRANCH to name the gate directory"

# The branch names a directory that `rsync --delete` will empty, and it reaches the build host
# inside a script. So it is validated HERE, before anything is sent or run: an unvalidated value
# could carry a newline and append a line of its own to the build host's reply, naming a target
# outside the gate root for rsync to delete.
case "$branch" in
  *[!A-Za-z0-9._/-]*)
    die_refuse "branch name may only contain A-Z a-z 0-9 . _ - / (got: $(printf '%q' "$branch"))" ;;
esac
case "/$branch/" in
  */../*) die_refuse "branch name may not contain a '..' segment: $branch" ;;
esac
case "$branch" in
  /*) die_refuse "branch name may not be absolute: $branch" ;;
esac


# --- what a change set is, and whether it owes a build ------------------------------------------
# The one verdict this gate reaches without building anything. It is a decision about what reaches
# the build host, so it is taken from what WOULD reach it: the commits this branch adds to
# origin/main and everything the working tree holds on top of them — rsync copies the tree, not
# the history.
CLASSIFY_VERDICT=""
CLASSIFY_BASE="-"
CLASSIFY_REASON=""
CLASSIFY_PATHS=""
ORIGIN_FETCHED=0

# The allowlist, by NAME. Conservative on purpose: it names what cannot change a build, and
# everything it does not name meets the full gate — project.yml (where the release numbers live),
# every Package.swift and Package.resolved, xcconfig, entitlements and plist files, this script,
# the tests, and anything under Packages/, Sources/ or an App directory. LICENSE is spelled out
# rather than globbed, because a LICENSE* glob would also read LICENSEChecker.swift as metadata.
# A package's bundled resource is never metadata, whatever its extension: the release notes are a
# .md the app ships and the notes step checks (MEMNG-497).
gate_path_is_metadata() {
  local path="$1" base="${1##*/}"
  case "$path" in
    Packages/*/Sources/*/Resources/*) return 1 ;;
    docs/*) return 0 ;;
    *.md) return 0 ;;
  esac
  case "$base" in
    .gitignore|.gitattributes|.editorconfig|CODEOWNERS) return 0 ;;
    LICENSE|LICENCE|LICENSE.txt|LICENCE.txt|LICENSE.md|LICENCE.md) return 0 ;;
  esac
  return 1
}

gate_classify() {
  CLASSIFY_VERDICT=full
  CLASSIFY_BASE="-"
  CLASSIFY_REASON=""
  CLASSIFY_PATHS=""

  # Fetched first: the base is only as honest as the ref it is read from, and a stale origin/main
  # would make an old change set look small. A fetch that cannot reach the remote is not fatal —
  # it falls back to the ref on disk and says so — but a base that cannot be resolved at all owes
  # the full gate, because then nothing is known about what changed.
  local fetch_note=""
  # Pruning makes deleted branches disappear from the local inventory used by the lane reaper.
  if git fetch --quiet --prune origin 2>/dev/null 9>&- 7>&-; then
    ORIGIN_FETCHED=1
  else
    fetch_note=" (origin could not be fetched — the origin/main already on disk was used)"
  fi
  # main needs the inventory too, even though it has no change set to classify.
  case "$branch" in
    main|master)
      CLASSIFY_REASON="the branch is $branch, which is not a change set measured against origin/main${fetch_note}"
      return 0 ;;
  esac
  local base
  base="$(git merge-base origin/main HEAD 2>/dev/null)" || base=""
  if [ -z "$base" ]; then
    CLASSIFY_REASON="the merge-base with origin/main cannot be resolved${fetch_note}"
    return 0
  fi
  CLASSIFY_BASE="$base"

  # Three sources, because three different things end up on the build host: what the branch
  # committed (--no-renames, so a rename is BOTH names and the source file that left is judged
  # too), what is staged or edited in the working tree, and what is untracked but not ignored.
  #
  # Each one is checked, because a git that FAILS prints nothing and nothing reads exactly like "no
  # source file changed" — which is how a broken enumeration becomes a fast path. `local` is
  # declared apart from every assignment below on purpose: `local x="$(cmd)"` returns local's own
  # status, not the command's, and would swallow the very failure this guards against.
  local branch_paths tree_paths untracked_paths index_tags
  branch_paths="$(git diff --name-only --no-renames "$base...HEAD" 2>/dev/null)" || {
    CLASSIFY_REASON="the commits on this branch could not be enumerated (git diff $base...HEAD failed)"
    return 0
  }
  tree_paths="$(git diff --name-only --no-renames HEAD 2>/dev/null)" || {
    CLASSIFY_REASON="the working tree could not be enumerated (git diff HEAD failed)"
    return 0
  }
  untracked_paths="$(git ls-files --others --exclude-standard 2>/dev/null)" || {
    CLASSIFY_REASON="the untracked files could not be enumerated (git ls-files --others failed)"
    return 0
  }
  # An entry git has been told to stop looking at — assume-unchanged (a lowercase tag) or
  # skip-worktree (S) — is a file neither diff above will mention and rsync will copy regardless.
  index_tags="$(git ls-files -v 2>/dev/null)" || {
    CLASSIFY_REASON="the index could not be read (git ls-files -v failed)"
    return 0
  }
  if printf '%s\n' "$index_tags" | grep -qE '^[a-zS] '; then
    CLASSIFY_REASON="the index carries assume-unchanged or skip-worktree entries, so a change to one of them would be built without ever being classified"
    return 0
  fi

  local paths
  paths="$(printf '%s\n%s\n%s\n' "$branch_paths" "$tree_paths" "$untracked_paths" \
    | sed '/^$/d' | sort -u)"
  if [ -z "$paths" ]; then
    CLASSIFY_REASON="nothing changed against origin/main${fetch_note}"
    return 0
  fi
  CLASSIFY_PATHS="$paths"

  local path entry mode
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # A path git had to quote carries a character this loop reads one way and the shell another;
    # it is never allowlisted, whatever its name looks like.
    case "$path" in
      '"'*)
        CLASSIFY_REASON="the change set holds a path git could not print literally ($path)"
        return 0 ;;
    esac
    if ! gate_path_is_metadata "$path"; then
      CLASSIFY_REASON="$path is neither documentation nor repository metadata"
      return 0
    fi
    # A name is not a file. Only an ORDINARY file may be passed unbuilt: 120000 is a symbolic link
    # whose name says nothing about what it points at, 160000 is a submodule pointer that carries
    # a whole tree behind a documentation-shaped name, and any other mode is something this gate
    # has never been shown. Read in the index, in HEAD and on disk, because the change set spans
    # all three, and a read that fails is not a read that found an ordinary file.
    entry="$(git ls-files -s -- "$path" 2>/dev/null)" || {
      CLASSIFY_REASON="the index entry for $path could not be read"
      return 0
    }
    mode="$(printf '%s\n' "$entry" | awk 'NR==1 {print $1}')"
    if [ -n "$mode" ] && [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; then
      CLASSIFY_REASON="$path is not an ordinary file in the index (mode $mode)"
      return 0
    fi
    entry="$(git ls-tree -r --full-tree HEAD -- "$path" 2>/dev/null)" || {
      CLASSIFY_REASON="the HEAD entry for $path could not be read"
      return 0
    }
    mode="$(printf '%s\n' "$entry" | awk 'NR==1 {print $1}')"
    if [ -n "$mode" ] && [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; then
      CLASSIFY_REASON="$path is not an ordinary file in HEAD (mode $mode)"
      return 0
    fi
    if [ -L "$path" ]; then
      CLASSIFY_REASON="$path is a symbolic link on disk, so its name says nothing about what would be built"
      return 0
    fi
  done <<< "$paths"

  CLASSIFY_VERDICT=fastpath
  CLASSIFY_REASON="every changed path is documentation or repository metadata${fetch_note}"
  return 0
}

# --- this run's own log ---------------------------------------------------------------------------
# The gate keeps its whole output itself, at a path no other run can have produced: the artifacts
# directory, the branch, and this run's token. A caller may redirect stdout wherever it likes and
# none of it can reach this file — which is the point. Two agents once pointed two runs at one
# generic name in a shared scratch directory; the second `>` truncated the first run's evidence
# while it was still being written, the reader watching that file was left with nothing, and the
# run had to be started again (2026-09-09). So two runs of the SAME branch write two files, and
# every exit path names the one it wrote on the line before its verdict.
branch_slug="$(printf '%s' "$branch" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-')"
branch_slug="${branch_slug:0:40}"
# A token, because a pid is not proof of identity to the far side: the remote half of this run has
# to be able to ask "is the lock in that directory still MINE", and a reap replaces the directory
# with one that carries somebody else's token. The log is named for it for the same reason the lock
# carries it — one run, one name, and a re-run of a branch never lands on the file its predecessor
# is still writing.
RUN_TOKEN="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$RUN_TOKEN" ] || RUN_TOKEN="$$-$(date -u +%s)"
log="$artifacts/mac-gate-$branch_slug-$RUN_TOKEN.log"
# Opened where the run wants it rather than on the way past, because the default artifacts
# directory is INSIDE the tree the classifier reads: a log created before the classification would
# be an untracked path in the change set it is classifying.
open_run_log() {
  mkdir -p "$artifacts" || die_refuse "cannot create the artifacts directory $artifacts"
  : > "$log" || die_refuse "cannot write $log"
}
say() { printf '%s\n' "$*" | tee -a "$log"; }

if [ "$CLASSIFY_ONLY" -eq 1 ]; then
  gate_classify
  # Opened after the classification, never before it: see open_run_log.
  open_run_log
  {
    printf 'CLASSIFY verdict=%s\n' "$CLASSIFY_VERDICT"
    printf 'CLASSIFY base=%s\n' "$CLASSIFY_BASE"
    printf 'CLASSIFY reason=%s\n' "$CLASSIFY_REASON"
    if [ -n "$CLASSIFY_PATHS" ]; then
      printf '%s\n' "$CLASSIFY_PATHS" | sed 's/^/CLASSIFY path /'
    fi
    printf 'CLASSIFY log=%s\n' "$log"
  } | tee -a "$log"
  [ "$CLASSIFY_VERDICT" = fastpath ] && exit 0
  exit 10
fi

# The private device is named here, where the branch and this run's token are known: the branch so
# a stray device says which run left it behind, the token so two runs of the SAME branch (a re-run
# started before the first one let go) still cannot land on one device, and so the slot's owner
# record can name the device before it exists: a recovery finds it by that name alone. It reuses the branch slug
# the run log is named from, which is already reduced to the character set the branch validation
# above allows, minus '/', and cut short enough to stay a readable name in `simctl list`.
DEVICE_NAME="gate-${branch_slug}-$RUN_TOKEN"

# Who this run is, for the gate lock below. The host is in it because the pid alone is only
# meaningful to the machine that issued it, and the lock is read by whoever comes next; the token
# is the one this run's log is named for.
LOCK_DIR=""
LOCK_OWNER="host=$(hostname -s) pid=$$ at $(date -u +%Y-%m-%dT%H:%M:%SZ) token=$RUN_TOKEN"


# The build host deletes the device when the remote script ends, however it ends. That covers a
# failing step and a refusal — it does NOT cover this script being interrupted: a remote shell
# whose ssh client has gone away is not signalled, it runs on until a write to the dead
# connection kills it, and a shell killed that way runs no trap (measured 2026-08-24: after the
# local ssh was killed the device was still there). So the device is claimed from this side too,
# by a name only this run can have produced. Deleting a name that is already gone is a no-op, so
# the two claims cannot fight; the message below is printed only when this side found something
# still standing.
# Nothing of this run's can exist on the host before the mount step accepted the build root, and a
# signal during that step's own ssh must not be answered with more ssh: no give-back until then.
GATE_MOUNT_ACCEPTED=0
remove_gate_device() {
  [ "$GATE_MOUNT_ACCEPTED" -eq 1 ] || return 0
  [ -z "$SIMULATOR" ] || return 0   # a device this run did not create is not this run's to delete
  [ -n "${DEVICE_NAME:-}" ] || return 0
  local name; name="$(esc "$DEVICE_NAME")"
  timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
     xcrun simctl shutdown '$name' >/dev/null 2>&1
     xcrun simctl delete '$name' >/dev/null 2>&1" 9>&- 7>&- \
    && say "simulator   : removed the leftover device $DEVICE_NAME from the build host"
  return 0
}
# The lock goes back the same way the device does, and for the same reason: every exit path,
# including the interrupted one. It is removed only while this run still owns it — a lock taken
# over by a later run after this one was killed is that run's, not this one's to drop.
release_gate_lock() {
  [ -n "${LOCK_DIR:-}" ] || return 0
  local dir="$LOCK_DIR"
  # Cleared first: a signal arm and the EXIT trap both reach here.
  LOCK_DIR=""
  {
    printf "lock='%s'\n" "$(esc "$dir")"
    printf "owner='%s'\n" "$(esc "$LOCK_OWNER")"
    cat <<'REL_EOF'
[ -d "$lock" ] || exit 0
if [ "$(cat "$lock/owner" 2>/dev/null)" = "$owner" ]; then rm -rf "$lock"; fi
REL_EOF
  } 9>&- 7>&- | timeout 90 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' >/dev/null 2>&1 9>&- 7>&-
  return 0
}

die_locked() {
  printf 'mac-gate: REFUSED: %s\n' "$1" >&2
  printf 'mac-gate: REFUSED: %s\n' "$1" >> "$log" 2>/dev/null
  # A quick run that never got the lock built nothing, so it reports nothing built — but it still
  # reports, on its own line, because that line is what the caller reads.
  [ "${QUICK:-0}" -eq 0 ] \
    || printf 'MAC_GATE_QUICK: lint=- build=- tests=- host=%s locallint=%s | exit=3\n' "${host:--}" "${GATE_LOCALLINT_FIELD:--}" | tee -a "$log"
  exit 3
}

# --- the run ledger -------------------------------------------------------------------------------
# One row per run that got this far (its token and log exist), appended by the exit trap below
# once the cleanup is done, so every way out — a verdict, a refusal, a signal — is counted the
# same way. Twelve tab-separated fields; a field the run never reached is "-":
#   lock_requested_utc lock_acquired_utc  the estate lock's wait, when this run took it;
#   remote_start_utc remote_end_utc       the build host's own clock (MAC_GATE_REMOTE_CLOCK lines,
#                                         read only from what the remote printed — never from the
#                                         selftests' output above it);
#   repo branch run_token                 who this run was;
#   mode                                  refused (an exit code the table at the top calls a
#                                         refusal), else fastpath, else quick, else full;
#   exit                                  the run's own exit code;
#   wall_s                                remote_end - remote_start;
#   slot_wait_s                           the slot parser's slot_wait, once the remote has returned;
#   log_path                              the durable copy of this run's complete log, taken
#                                         under the ledger's flock after everything else the run
#                                         wrote; the local log instead, after one
#                                         LEDGER-LOG-KEPT-LOCAL line saying why, when no copy
#                                         could be made.
# It is telemetry. The append runs in a subshell, under a flock on the ledger, and anything that
# goes wrong there says LEDGER-SKIPPED and why; the run's exit code is captured before the cleanup
# and is the code the trap exits with, whatever the ledger did.
GATE_RUNS_LEDGER="${MAC_GATE_RUNS_LEDGER:-/home/fabian/projects/worktrees/gate-runs.tsv}"
# Derived from the ledger, so a suite that points the ledger at a scratch file keeps the copies
# there too.
GATE_RUNS_LOGS="${MAC_GATE_RUNS_LOGS:-$(dirname "$GATE_RUNS_LEDGER")/gate-logs}"
GATE_LEDGER_LOG_COPY=""
GATE_LEDGER_LOG_PATH=""
GATE_LEDGER_FASTPATH=0
# Set by the local lint's refusal, whose exit code (1) is not one the table calls a refusal.
GATE_LEDGER_REFUSED=0
GATE_REMOTE_LOG_OFFSET=""
gate_ledger_skip() {
  printf 'LEDGER-SKIPPED %s\n' "$1"
  printf 'LEDGER-SKIPPED %s\n' "$1" >> "$log" 2>/dev/null
  # Once the copy exists it must keep saying everything the local log says.
  [ -z "$GATE_LEDGER_LOG_COPY" ] || printf 'LEDGER-SKIPPED %s\n' "$1" >> "$GATE_LEDGER_LOG_COPY" 2>/dev/null
}
gate_ledger_kept_local() {
  printf 'LEDGER-LOG-KEPT-LOCAL %s\n' "$1"
  printf 'LEDGER-LOG-KEPT-LOCAL %s\n' "$1" >> "$log" 2>/dev/null
}
# Sets GATE_LEDGER_LOG_PATH to the log the row will name. Called from the append with the ledger's
# flock held, after the run's last write to $log, so the copy holds the whole run; only the
# ledger's own skip lines can follow it, and gate_ledger_skip writes those into the copy as well.
# A copy that cannot be made or does not compare equal costs the copy, never the row: the row
# names the local log, which the LEDGER-LOG-KEPT-LOCAL line has already reached.
gate_ledger_keep_log() {
  local dest="$GATE_RUNS_LOGS/memos-ng-ios-$branch_slug-$RUN_TOKEN.log"
  GATE_LEDGER_LOG_PATH="$log"
  mkdir -p "$GATE_RUNS_LOGS" 2>/dev/null \
    || { gate_ledger_kept_local "cannot create $GATE_RUNS_LOGS"; return 1; }
  # The token is this run's alone; a file already there is somebody else's and stays untouched.
  [ ! -e "$dest" ] \
    || { gate_ledger_kept_local "$dest already exists and is not this run's"; return 1; }
  cp "$log" "$dest" 2>/dev/null && cmp -s "$log" "$dest" \
    || { rm -f "${dest:?}" 2>/dev/null; gate_ledger_kept_local "cannot copy $log to $dest"; return 1; }
  GATE_LEDGER_LOG_COPY="$dest"
  GATE_LEDGER_LOG_PATH="$dest"
}
gate_ledger_utc() { # an epoch on stdout as UTC; non-zero, with nothing printed, when it cannot
  local out
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  out="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    || out="$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 1
  gate_ledger_is_utc "$out" || return 1
  printf '%s' "$out"
}
gate_ledger_is_utc() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
  esac
  return 1
}
gate_ledger_field() { printf '%s' "${1:--}" | tr '\t\n' '  '; }
# Every step is checked: errexit is off in this script, so a status nobody reads is a status lost.
# Any failure says LEDGER-SKIPPED and why, and writes no row — a row with a hole where a
# measurement should be would read as a measurement.
gate_ledger_append() { # $1 = the run's exit code
  local rc="$1" mode remote_text="" clock="" start="" end="" start_utc="-" end_utc="-" wall="-" slot_wait="-"
  local row t=$'\t' value
  case "$GATE_LEDGER_REFUSED:$rc" in
    1:*|*:2|*:3|*:4|*:11|*:12|*:13|*:14|*:15|*:16) mode=refused ;;
    *)
      if [ "$GATE_LEDGER_FASTPATH" -eq 1 ]; then mode=fastpath
      elif [ "${QUICK:-0}" -eq 1 ]; then mode=quick
      else mode=full; fi ;;
  esac
  if [ -n "$GATE_ESTATE_LOCK_REQUESTED" ]; then
    gate_ledger_is_utc "$GATE_ESTATE_LOCK_REQUESTED" \
      || { gate_ledger_skip "the estate lock's request time could not be read ($GATE_ESTATE_LOCK_REQUESTED)"; return 1; }
    gate_ledger_is_utc "$GATE_ESTATE_LOCK_ACQUIRED" \
      || { gate_ledger_skip "the estate lock's acquisition time could not be read ($GATE_ESTATE_LOCK_ACQUIRED)"; return 1; }
  fi
  if [ -n "$GATE_REMOTE_LOG_OFFSET" ]; then
    case "$GATE_REMOTE_LOG_OFFSET" in
      *[!0-9]*) gate_ledger_skip "where the remote's output starts in $log could not be read"; return 1 ;;
    esac
    remote_text="$(tail -c +"$((GATE_REMOTE_LOG_OFFSET + 1))" "$log")" \
      || { gate_ledger_skip "cannot read the remote's output back from $log"; return 1; }
    # One pass that reads ALL of the remote's text from a here-string — nothing here stops reading
    # early, so a long build log cannot turn a match into a broken pipe — and answers three
    # things on one line: whether any clock read failed (a stamp that is not digits, or the
    # marker a step prints when its timestamp failed), the first start and the last end.
    clock="$(awk '
      /^MAC_GATE_REMOTE_CLOCK start=/ { v = substr($0, 29); if (v ~ /^[0-9]+$/) { if (s == "") s = v } else bad = 1; next }
      /^MAC_GATE_REMOTE_CLOCK end=/   { v = substr($0, 27); if (v ~ /^[0-9]+$/) e = v; else bad = 1; next }
      /^MAC_GATE_REMOTE_CLOCK unreadable/ { bad = 1 }
      END { print (bad ? "unreadable" : "ok"), (s == "" ? "-" : s), (e == "" ? "-" : e) }
    ' <<< "$remote_text")" \
      || { gate_ledger_skip "cannot read the build host's clock lines from $log"; return 1; }
    case "$clock" in
      "ok "*) ;;
      "unreadable "*) gate_ledger_skip "the build host could not read its own clock"; return 1 ;;
      *) gate_ledger_skip "cannot read the build host's clock lines from $log"; return 1 ;;
    esac
    start="${clock#ok }"; start="${start%% *}"; [ "$start" != "-" ] || start=""
    end="${clock##* }"; [ "$end" != "-" ] || end=""
    if [ -n "$start" ]; then
      start_utc="$(gate_ledger_utc "$start")" \
        || { gate_ledger_skip "cannot convert remote_start $start to UTC"; return 1; }
    fi
    if [ -n "$end" ]; then
      end_utc="$(gate_ledger_utc "$end")" \
        || { gate_ledger_skip "cannot convert remote_end $end to UTC"; return 1; }
    fi
    if [ -n "$start" ] && [ -n "$end" ]; then wall="$((end - start))"; fi
    if [ -n "${remote_rc:-}" ] && declare -F slot_field >/dev/null; then
      slot_wait="$(slot_field slot_wait)" \
        || { gate_ledger_skip "cannot read slot_wait from $log"; return 1; }
    fi
  fi
  for value in "$wall" "$slot_wait"; do
    case "$value" in
      -) ;;
      ''|*[!0-9]*) gate_ledger_skip "not a measurement: $value"; return 1 ;;
    esac
  done
  row="$(gate_ledger_field "$GATE_ESTATE_LOCK_REQUESTED")${t}$(gate_ledger_field "$GATE_ESTATE_LOCK_ACQUIRED")" \
    && row="$row${t}${start_utc}${t}${end_utc}" \
    && row="$row${t}memos-ng-ios${t}$(gate_ledger_field "$branch")${t}$(gate_ledger_field "$RUN_TOKEN")${t}$mode${t}$rc" \
    && row="$row${t}$wall${t}$slot_wait" \
    || { gate_ledger_skip "cannot compose the row"; return 1; }
  { exec 8>>"$GATE_RUNS_LEDGER"; } 2>/dev/null \
    || { gate_ledger_skip "cannot open the run ledger $GATE_RUNS_LEDGER"; return 1; }
  # Bounded: a ledger somebody holds forever must not keep this run from ending.
  flock -w 120 8 \
    || { gate_ledger_skip "cannot lock the run ledger $GATE_RUNS_LEDGER"; return 1; }
  # Its failure is reported by the function and changes only which log the row names.
  gate_ledger_keep_log
  row="$row${t}$(gate_ledger_field "$GATE_LEDGER_LOG_PATH")${t}$(gate_ledger_field "${host:-}")" \
    || { gate_ledger_skip "cannot compose the row"; return 1; }
  [ "$(printf '%s\n' "$row" | awk -F '\t' '{ print NF }')" = 13 ] \
    || { gate_ledger_skip "the row does not have 13 fields"; return 1; }
  # The header is written only into a new or empty ledger. An existing one keeps its 12-name header
  # and its rows: nothing here rewrites the ledger, so a reader takes the host from field 13 when a
  # row has one, and from its log's "host        :" line otherwise.
  if [ ! -s "$GATE_RUNS_LEDGER" ]; then
    printf 'lock_requested_utc\tlock_acquired_utc\tremote_start_utc\tremote_end_utc\trepo\tbranch\trun_token\tmode\texit\twall_s\tslot_wait_s\tlog_path\thost\n' >&8 \
      || { gate_ledger_skip "cannot write the header of $GATE_RUNS_LEDGER"; return 1; }
  fi
  printf '%s\n' "$row" >&8 \
    || { gate_ledger_skip "cannot append to $GATE_RUNS_LEDGER"; return 1; }
  return 0
}
# Initialized means this run's token-named log exists: the token is unique, so nothing but this run
# can have created it. Before that, an exit cleans up only what it always did (the private copy),
# and writes no row.
gate_run_initialized() { [ -n "${log:-}" ] && [ -e "$log" ]; }
gate_on_signal() { # $1 = the exit code the signal ends the run with
  if gate_run_initialized; then remove_gate_device; release_gate_lock; fi
  exit "$1"
}
gate_on_exit() {
  local rc=$?
  if gate_run_initialized; then remove_gate_device; release_gate_lock; fi
  remove_run_copy
  gate_run_initialized || exit "$rc"
  ( exec 9>&- 7>&-
    gate_ledger_done=0
    trap '[ "$gate_ledger_done" -eq 1 ] || gate_ledger_skip "the ledger append stopped before it finished"' EXIT
    gate_ledger_append "$rc"
    gate_ledger_done=1 ) 2>/dev/null
  exit "$rc"
}
# The log is created here, after every function its exit path calls is defined, and the exit and
# signal traps follow it at once: from the moment this run has a token-named log, every way out —
# a signal during the stamps below included — goes through the cleanup and the run ledger.
trap 'gate_on_exit' EXIT
trap 'gate_on_signal 130' INT
trap 'gate_on_signal 143' TERM
trap 'gate_on_signal 129' HUP
open_run_log
if [ -n "$GATE_ESTATE_LOCK_REQUESTED" ]; then
  say "estate lock : lock_requested=$GATE_ESTATE_LOCK_REQUESTED (taken by this run before its copy was made)"
  say "estate lock : lock_acquired=$GATE_ESTATE_LOCK_ACQUIRED"
fi
# Informational, never read to decide anything: the kernel's flock is the ownership.
if [ -n "$GATE_RUN_LOCK_FILE" ]; then
  printf 'pid=%s token=%s host=%s\n' "$$" "$RUN_TOKEN" "$host" > "$GATE_RUN_LOCK_FILE" 2>/dev/null \
    || say "worktree lock: cannot write this run's line into $GATE_RUN_LOCK_FILE (informational only)"
  say "worktree lock: wait=${GATE_RUN_LOCK_WAIT}s ($GATE_RUN_LOCK_FILE)"
fi
if [ -n "$GATE_HOST_ROUTE" ]; then
  gate_wt_shown="-"
  [ -z "$GATE_RUN_LOCK_WAIT" ] || gate_wt_shown="${GATE_RUN_LOCK_WAIT}s"
  say "route       : host=$host reason=$GATE_HOST_ROUTE worktree_wait=$gate_wt_shown pid=$$ token=$RUN_TOKEN"
fi

# --- (5) provenance ---------------------------------------------------------------------------
{
  printf '=== mac-gate %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host        : %s\n' "$host"
  printf 'repo        : %s\n' "$repo_root"
  printf 'branch      : %s\n' "$branch"
  printf 'HEAD        : %s\n' "$head_sha"
  printf 'HEAD subject: %s\n' "$(git log -1 --pretty=%s)"
  printf 'script      : %s (private copy of %s, sha256 %s)\n' \
    "$GATE_RUN_COPY/mac-gate.sh" "$GATE_SCRIPT_ORIGIN" "$GATE_SCRIPT_SHA256"
  if [ -n "$SIMULATOR" ]; then
    printf 'simulator   : %s (MAC_GATE_SIMULATOR — shared device, no per-run isolation)\n' "$SIMULATOR"
  else
    printf 'simulator   : %s (created on the build host for this run, deleted on exit)\n' "$DEVICE_NAME"
  fi
  printf -- '--- git status --porcelain (full) ---\n'
  git status --porcelain
  printf -- '--- git diff --stat (working tree vs HEAD) ---\n'
  git diff --stat HEAD
  printf -- '--- end provenance ---\n'
} 2>&1 | tee -a "$log"

# --- step bookkeeping -------------------------------------------------------------------------
declare -a STEP_NAMES=() STEP_RCS=()
first_fail=0
# Fields the SUMMARY carries that are measurements, not exit codes (disk=, slot_wait=): they never
# decide the verdict, so they are kept apart from STEP_RCS.
SUMMARY_INFO=""
record() {
  STEP_NAMES+=("$1"); STEP_RCS+=("$2")
  if [ "$2" -ne 0 ] && [ "$first_fail" -eq 0 ]; then first_fail="$2"; fi
}
summary_and_exit() {
  local line="mac-gate SUMMARY:" i
  for i in "${!STEP_NAMES[@]}"; do line="$line ${STEP_NAMES[$i]}=${STEP_RCS[$i]}"; done
  line="$line$SUMMARY_INFO host=${host:--} locallint=${GATE_LOCALLINT_FIELD:--} | exit=$first_fail"
  say "run log     : $log"
  say "script      : sha256 $GATE_SCRIPT_SHA256 (the text of bin/mac-gate.sh this run executed)"
  say "$line"
  exit "$first_fail"
}
# The quick mode's line is a different sentence on purpose. `mac-gate SUMMARY: … | exit=0` is the
# one thing in this repo that means "this change may merge", and a run that skipped the pins, the
# warnings rebuilds and the shipping-bundle read-back must not be able to produce it — not by
# accident, and not by a copy-paste out of a terminal. So the quick mode says what it did (the
# lint, the build and the tests it ran) under a name of its own, and never reaches summary_and_exit.
# A dash means "never got that far": the build host was never asked, or it stopped before saying.
QUICK_LINT_RC="-"
QUICK_BUILD_RC="-"
QUICK_TESTS_RC="-"
quick_summary_and_exit() {
  say "run log     : $log"
  say "script      : sha256 $GATE_SCRIPT_SHA256 (the text of bin/mac-gate.sh this run executed)"
  # The iteration count is part of what the line claims, so it rides on the line itself: a pasted
  # "tests=0" is then never mistaken for N runs when it was one, or for one when it was N.
  say "MAC_GATE_QUICK: lint=$QUICK_LINT_RC build=$QUICK_BUILD_RC tests=$QUICK_TESTS_RC${QUICK_ITERATIONS:+ iterations=$QUICK_ITERATIONS} host=${host:--} locallint=${GATE_LOCALLINT_FIELD:--} | exit=$first_fail"
  say "quick       : NOT a verdict — the merge verdict is a full run of this gate"
  exit "$first_fail"
}
end_run() {
  if [ "$QUICK" -eq 1 ]; then quick_summary_and_exit; fi
  summary_and_exit
}

# --- the local lint's verdict --------------------------------------------------------------------
# Reached by the bootstrap before the estate lock was requested (see there); written into this
# run's copy beside the script, so only this run's own bootstrap can have put it there. The lint's
# lines go into the log whole. A failure ends the run here, before the lane lock and before any
# ssh: no estate lock was taken for it, and the run ledger records it as refused.
say "--- step: locallint ---"
GATE_LOCALLINT_FIELD=-
if [ -r "$GATE_RUN_COPY/locallint.rc" ]; then
  read -r gate_lint_rc gate_lint_secs < "$GATE_RUN_COPY/locallint.rc"
  tee -a "$log" < "$GATE_RUN_COPY/locallint.txt" 9>&- 7>&-
  case "${gate_lint_rc:-}" in 0|1) GATE_LOCALLINT_FIELD="$gate_lint_rc" ;; esac
  say "locallint   : locallint=$GATE_LOCALLINT_FIELD — ran on $(hostname -s) before the estate lock was requested (${gate_lint_secs:-?}s)"
  if [ "$GATE_LOCALLINT_FIELD" = 1 ]; then
    say "locallint   : REFUSED — swift format lint failed on this machine; no estate lock was requested, no lane lock taken and nothing was sent to $host"
    GATE_LEDGER_REFUSED=1
    first_fail=1
    end_run
  fi
else
  say "locallint   : locallint=- — this run was handed no local verdict"
fi

# --- the gate's own integrity check --------------------------------------------------------------
# The classifier decides whether anything gets built at all, which makes it the one part of this
# gate that no build can check. Its suite runs HERE, on every run, fast path or not: a fast path
# taken by a classifier nobody checked is a gate that passes what it never read.
say "--- step: selftest ---"
selftest_rc=0
# NAMED, not counted. A suite that is deleted or loses its execute bit takes its whole subject with
# it, and a step that runs "whatever is in tests/gate" would report selftest=0 for an empty
# directory. These twelve must be there (the local lint's two among them: a lint that stopped
# refusing would only cost the queue time it exists to save, and nothing else would notice): the main-bar freeze's (ADR-0008 is the owner's, and a freeze
# whose test can vanish unnoticed is not one), the mount guard's two (a run on the wrong disk looks
# exactly like a green one), the TestFlight cut's (the one other write path to the Mac) and the
# release-notes rule's (the one file both the cut and the What's new screen read, MEMNG-497) and
# the host router's (MAC_GATE_HOST=auto and the worktree run lock, MEMNG-824).
for selftest_name in fastpath-classify-test.sh warnings-canary-test.sh testcount-test.sh admission-test.sh mainbar-freeze-rule-test.sh mount-guard-test.sh mount-refusal-path-test.sh testflight-cut-test.sh release-notes-rule-test.sh local-lint-test.sh local-lint-refusal-path-test.sh host-routing-test.sh; do
  selftest_script="$repo_root/tests/gate/$selftest_name"
  if [ -x "$selftest_script" ]; then
    "$selftest_script" 2>&1 9>&- 7>&- | tee -a "$log" 9>&- 7>&-
    [ "${PIPESTATUS[0]}" -eq 0 ] || selftest_rc="${PIPESTATUS[0]}"
  else
    say "the gate's own test $selftest_script is missing or not executable"
    selftest_rc=1
  fi
done
# And anything else that ships beside them, so a new suite is never silently ignored.
for selftest_script in "$repo_root"/tests/gate/*-test.sh; do
  case "${selftest_script##*/}" in
    fastpath-classify-test.sh|warnings-canary-test.sh|testcount-test.sh|admission-test.sh|mainbar-freeze-rule-test.sh|mount-guard-test.sh|mount-refusal-path-test.sh|testflight-cut-test.sh|release-notes-rule-test.sh|local-lint-test.sh|local-lint-refusal-path-test.sh|host-routing-test.sh) continue ;;
  esac
  [ -x "$selftest_script" ] || continue
  "$selftest_script" 2>&1 9>&- 7>&- | tee -a "$log" 9>&- 7>&-
  [ "${PIPESTATUS[0]}" -eq 0 ] || selftest_rc="${PIPESTATUS[0]}"
done
record selftest "$selftest_rc"
[ "$first_fail" -eq 0 ] || end_run

# Selftest only: tests/gate/private-copy-test.sh stops a run here, edits the tree it was started
# from underneath it, and lets it go — the proof that the copy above is what runs. Without
# MAC_GATE_SELFTEST_PAUSE_DIR this is nothing, and the wait is bounded so a test that dies cannot
# hold a run for longer than a minute.
if [ -n "$GATE_SELFTEST_PAUSE_DIR" ]; then
  : > "$GATE_SELFTEST_PAUSE_DIR/paused"
  gate_pause_waited=0
  while [ ! -e "$GATE_SELFTEST_PAUSE_DIR/resume" ] && [ "$gate_pause_waited" -lt 600 ]; do
    sleep 0.1
    gate_pause_waited=$((gate_pause_waited + 1))
  done
fi

# --- release-version authority ------------------------------------------------------------------
# Runs HERE, on the controller, because the tags live in this checkout and the mirrored tree on
# the build host carries no .git. The latest v* tag records what shipped (its annotation names
# the build: "X.Y.Z (build N): ..."); the numbers in project.yml must ADVANCE past it — the
# marketing version never below the tagged one, the build strictly greater always. A forgotten
# bump is caught before a wasted archive; a spent build number cannot ship twice. No v* tag yet
# is the bootstrap case and passes with a named line. Ritual: docs/RELEASING.md.
version_at_least() { # $1 >= $2, dotted numerics
  # Split on OWN lines: an IFS set in the same `local` statement does not govern that
  # statement's word-splitting, and the perturbation run caught the strings comparing whole.
  local IFS=. i
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2; do
    [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ] && return 0
    [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ] && return 1
  done
  return 0
}
release_tag="$(git -C "$repo_root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [ -n "$release_tag" ]; then
  tagged_version="${release_tag#v}"
  tagged_build="$(git -C "$repo_root" tag -l "$release_tag" --format='%(contents:subject)' \
    | sed -n 's/.*build \([0-9][0-9]*\).*/\1/p')"
  yml_version="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$repo_root/project.yml" | head -1)"
  yml_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$repo_root/project.yml" | head -1)"
  [ -n "$yml_version" ] && [ -n "$yml_build" ] \
    || die_refuse "release check: could not read version keys from project.yml"
  if ! version_at_least "$yml_version" "$tagged_version"; then
    die_refuse "release check: MARKETING_VERSION $yml_version is below the shipped tag $release_tag"
  fi
  if [ -n "$tagged_build" ] && [ "$yml_build" -le "$tagged_build" ]; then
    die_refuse "release check: build $yml_build does not advance past the shipped build $tagged_build ($release_tag)"
  fi
  say "release     : $yml_version (build $yml_build) advances past $release_tag (build ${tagged_build:-?})"
else
  say "release     : no v* tag yet — bootstrap, nothing to advance past"
fi

# --- the change set, and the fast path -----------------------------------------------------------
# Classified on every run, fast path or not, and written into the artifacts next to the log: the
# evidence has to say what the gate decided to look at, or a PASS cannot be read afterwards.
say "--- step: classify ---"
gate_classify
{
  printf 'gate classification %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'branch  : %s\n' "$branch"
  printf 'HEAD    : %s\n' "$head_sha"
  printf 'base    : %s (merge-base with origin/main)\n' "$CLASSIFY_BASE"
  printf 'verdict : %s\n' "$CLASSIFY_VERDICT"
  printf 'reason  : %s\n' "$CLASSIFY_REASON"
  printf 'changed paths:\n'
  if [ -n "$CLASSIFY_PATHS" ]; then
    printf '%s\n' "$CLASSIFY_PATHS" | sed 's/^/  /'
  else
    printf '  (none)\n'
  fi
} > "$artifacts/classification.txt"
say "classify    : $CLASSIFY_VERDICT — $CLASSIFY_REASON"
say "classify    : base $CLASSIFY_BASE (merge-base with origin/main)"
if [ -n "$CLASSIFY_PATHS" ]; then
  while IFS= read -r classified_path; do
    say "classify    : changed $classified_path"
  done <<< "$CLASSIFY_PATHS"
else
  say "classify    : changed nothing"
fi
say "classify    : written to $artifacts/classification.txt"
record classify 0

if [ "$CLASSIFY_VERDICT" = fastpath ] && [ "$QUICK" -eq 0 ]; then
  # No device was ever created and no lock was ever taken, so nothing is owed back to the build
  # host; cleared here so the exit trap does not ssh over there to delete a device that was
  # only ever a name.
  DEVICE_NAME=""
  say "mac-gate PASS (fast path: docs-only) — base $CLASSIFY_BASE — changed: $(printf '%s' "$CLASSIFY_PATHS" | tr '\n' ' ')"
  say "fast path   : nothing was copied to a build host — $CLASSIFY_REASON"
  printf 'verdict : PASS (fast path: docs-only)\n' >> "$artifacts/classification.txt"
  GATE_LEDGER_FASTPATH=1
  summary_and_exit
fi
# The fast path answers "does this change set owe a build". A quick run is not asking that: it is
# an explicit request to compile and test, and the change set it is asked about is usually one the
# author is in the middle of writing. So it goes to the build host regardless — and, because it is
# not a verdict, skipping it would have saved nothing anyone could merge on.
if [ "$CLASSIFY_VERDICT" = fastpath ]; then
  say "classify    : docs-only, but --quick was asked for a build rather than for a verdict — continuing"
fi

# --- (1b) the build root is the designated image ------------------------------------------------
# The build host's ~/build is meant to be ITS build image (MEMNG-602), keyed on its LocalHostName
# (merkur, mars; any other host refuses). Unmounted, macOS leaves the plain directory and every
# byte lands on the internal disk. So before the first ssh that writes (the preflight's mkdir), the
# guard from this run's private copy (scripts/gate-mount-guard.sh) reads the volume and this repo's
# two subtrees on it, read-only, in report mode: while a valid pending marker
# (~/.config/build-mount-guard/pending on the host) exists, a refusal is reported as
# mountguard=pending:REFUSE and the run goes on; without one it is mount=16 and the run ends here.
# Only one verdict line and one state line that agree with the exit code are an answer: a guard
# that is missing, could not run, timed out or said anything else has proved nothing, and refuses.
# A refusal sends nothing more: the device give-back (remove_gate_device) stays off until this step
# has accepted the answer, so neither the exit trap nor a signal mid-step ssh over to give back a
# device that was never created, and no lock was taken yet.
say "--- step: mount ---"
mount_rc=16
mount_state=enforced
GATE_MOUNT_GUARD_SELF="$GATE_RUN_COPY/scripts/gate-mount-guard.sh"
if [ ! -r "$GATE_MOUNT_GUARD_SELF" ]; then
  say "mount       : REFUSE the guard $GATE_MOUNT_GUARD_SELF is not in this run's copy — nothing was sent"
else
  # The answer lands in a file, never in a command substitution: $(…) strips every trailing
  # newline, so a blank third line would vanish before it is counted and a three-line answer would
  # pass as two (Codex, 2026-10-06). The file keeps every byte the host sent.
  mount_answer="$GATE_RUN_COPY/mount-answer.txt"
  (
    exec 9>&- 7>&-
    { cat "$GATE_MOUNT_GUARD_SELF"; printf '%s\n' 'gate_mount_guard report memos-ng-ios/gate memos-ng-ios/work'; } \
      | timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' > "$mount_answer" 2>&1
  )
  mount_ssh_rc=$?
  # The answer, verbatim and bracketed line by line, so stray whitespace, blank lines and noise show
  # in the log; the `|| [ -n … ]` keeps a last line the host did not terminate.
  while IFS= read -r mount_line || [ -n "$mount_line" ]; do say "mount       : [$mount_line]"; done < "$mount_answer"
  mount_lines="$(awk 'END { print NR }' "$mount_answer")"
  # The WHOLE answer is judged, never the lines that happen to look right: exactly two lines, the
  # verdict and then the state, nothing else (stderr is in it, so noise refuses too); the two agree;
  # and a pending state counts only with marker=valid. The marker states are the ones
  # scripts/gate-mount-guard.sh can print (gate_mg_marker, and not-read outside report mode).
  mount_marker_re='(valid|not-read|missing|unreadable|expired|other-host|unmeasured:(clock|ioreg)|malformed:[A-Za-z0-9._-]+)'
  mount_first="$(sed -n 1p "$mount_answer")"
  mount_second="$(sed -n 2p "$mount_answer")"
  if [ "$mount_ssh_rc" -eq 0 ] && [ "$mount_lines" = 2 ] \
     && printf '%s\n' "$mount_first" | grep -qE '^MOUNT (OK|REFUSE) ' \
     && printf '%s\n' "$mount_second" | grep -qE "^mountguard=(enforced|pending:OK|pending:REFUSE) marker=$mount_marker_re\$"; then
    mount_verdict="${mount_first#MOUNT }"; mount_verdict="${mount_verdict%% *}"
    mount_state="${mount_second%% marker=*}"; mount_state="${mount_state#mountguard=}"
    case "$mount_verdict:$mount_state:${mount_second##* marker=}" in
      OK:enforced:valid) ;;
      OK:enforced:*|OK:pending:OK:valid|REFUSE:pending:REFUSE:valid) mount_rc=0 ;;
    esac
    [ "$mount_rc" -eq 0 ] || mount_state=enforced
  fi
  [ "$mount_rc" -eq 0 ] \
    || say "mount       : REFUSE (guard exit $mount_ssh_rc) — the build root is not proven to be the build host's designated image; nothing was written on the host"
fi
record mount "$mount_rc"
SUMMARY_INFO="$SUMMARY_INFO mountguard=$mount_state"
[ "$mount_rc" -eq 0 ] || end_run
GATE_MOUNT_ACCEPTED=1

# --- (2) resolve the remote target and refuse anything outside the gate root -------------------
# Resolved on the build host, where the path actually exists: lexically (so a `..` in the branch
# name cannot escape) AND physically (so a symlink planted in the gate root cannot either).
surviving_branches=""
reap_skip_reason="origin fetch failed; local refs may be incomplete"
origin_fetch_refspec="$(git config --get-all remote.origin.fetch)" || origin_fetch_refspec=""
if [ "$origin_fetch_refspec" != '+refs/heads/*:refs/remotes/origin/*' ]; then
  ORIGIN_FETCHED=0
  reap_skip_reason="non-standard fetch refspec"
  say "GATE_REAP skipped: $reap_skip_reason"
fi
if [ "$ORIGIN_FETCHED" -eq 1 ]; then
  surviving_refs="$(git for-each-ref refs/heads refs/remotes/origin --format='%(refname)')" \
    || die_refuse "cannot enumerate local and origin branches for lane reaping"
  surviving_branches="$(printf '%s\n' "$surviving_refs" \
    | sed -e '/^refs\/remotes\/origin\/HEAD$/d' -e 's#^refs/heads/##' -e t \
      -e 's#^refs/remotes/origin/##' | sort -u)"
fi
preflight_out="$(
  exec 9>&- 7>&-
  {
    printf "branch='%s'\n" "$(esc "$branch")"
    printf "lock_owner='%s'\n" "$(esc "$LOCK_OWNER")"
    printf "origin_fetched='%s'\n" "$(esc "$ORIGIN_FETCHED")"
    printf "reap_skip_reason='%s'\n" "$(esc "$reap_skip_reason")"
    printf "surviving_branches='%s'\n" "$(esc "$surviving_branches")"
    cat "$GATE_RUN_COPY/scripts/reap-gate-lanes.sh"
    cat "$GATE_RUN_COPY/scripts/gate-work-dir.sh"
    cat "$GATE_RUN_COPY/scripts/gate-root-refusal.sh"
    cat <<'PRE_EOF'
set -uo pipefail
gate_root_raw="$HOME/build/memos-ng-ios/gate"
# The refusal names the part of the path that stopped the mkdir (scripts/gate-root-refusal.sh); the
# fallback keeps it a refusal if that helper did not come along.
mkdir -p "$gate_root_raw" || {
  gate_root_refusal "$gate_root_raw" 2>/dev/null || echo "REFUSE cannot create the gate root $gate_root_raw"
  exit 2
}
gate_root="$(cd "$gate_root_raw" && pwd -P)" || { echo "REFUSE cannot resolve the gate root"; exit 2; }
target_raw="$gate_root/$branch"
# lexical normalisation of . and .. without touching the filesystem
target="$(printf '%s' "$target_raw" | awk -F/ '{
  n = 0
  for (i = 1; i <= NF; i++) {
    if ($i == "." || $i == "") continue
    else if ($i == "..") { if (n > 0) n-- }
    else { n++; a[n] = $i }
  }
  s = ""
  for (i = 1; i <= n; i++) s = s "/" a[i]
  if (s == "") s = "/"
  print s
}')"
[ -n "$target" ] || { echo "REFUSE empty target path"; exit 2; }
[ "$target" != "$gate_root" ] || { echo "REFUSE target is the gate root itself"; exit 2; }
case "$target/" in
  "$gate_root"/*) ;;
  *) echo "REFUSE target $target resolves outside the gate root $gate_root"; exit 2 ;;
esac
case "$target/" in
  */projects/*) echo "REFUSE target $target is inside a projects checkout"; exit 2 ;;
esac
if [ -e "$target" ]; then
  phys="$(cd "$target" 2>/dev/null && pwd -P)" || { echo "REFUSE target exists but is not a directory"; exit 2; }
  case "$phys/" in
    "$gate_root"/*) ;;
    *) echo "REFUSE target symlinks to $phys, outside the gate root $gate_root"; exit 2 ;;
  esac
  if [ -e "$target/.git" ]; then
    echo "REFUSE target $target is a git checkout; the gate directory is a mirror, never a checkout"
    exit 2
  fi
fi
echo "GATE_REAP data volume before:"
df -h "$gate_root" | sed 's/^/GATE_REAP /' || exit 2
if [ "$origin_fetched" -eq 1 ]; then
  survivors_file="$(mktemp "${TMPDIR:-/tmp}/gate-survivors-XXXXXX")" || exit 2
  trap 'rm -f "$survivors_file"' EXIT
  printf '%s\n' "$surviving_branches" > "$survivors_file" || exit 2
  # The work root comes off the resolved gate root, the same sibling the build half will use: a
  # symlinked ~/build or ~/build/memos-ng-ios (the likely answer to a full disk) would otherwise
  # leave the two halves reaping different trees. Resolved, because the reaper compares physical
  # paths and refuses a symlinked root — a work tree moved onto another volume is ordinary here.
  work_root="$(gate_work_root_resolved "$gate_root")" || exit 2
  reap_gate_lanes "$gate_root" "$work_root" "$branch" "$survivors_file" || exit 2
else
  echo "GATE_REAP skipped: $reap_skip_reason"
fi
echo "GATE_REAP data volume after:"
df -h "$gate_root" | sed 's/^/GATE_REAP /' || exit 2
mkdir -p "$target" || { echo "REFUSE cannot create $target"; exit 2; }
# The lock is a directory, because mkdir is the one atomic "claim it or find it claimed" this
# host has in every shell it runs: /bin/bash here is 3.2 and has no flock. It is taken now,
# before a single byte is rsync'd, since the copy is what a concurrent same-branch run destroys.
lock="$target.lock"
if mkdir "$lock" 2>/dev/null; then
  printf '%s\n' "$lock_owner" > "$lock/owner" 2>/dev/null
  # Read back, because the claim is only as good as what the next run will find in there.
  lock_back="$(cat "$lock/owner" 2>/dev/null)"
  if [ "$lock_back" = "$lock_owner" ]; then
    echo "LOCK ACQUIRED"
  else
    echo "LOCK MISMATCH $lock_back"
  fi
else
  echo "LOCK HELD $(cat "$lock/owner" 2>/dev/null | tr -d '\n')"
fi
echo "LOCKDIR $lock"
echo "GATE_ROOT $gate_root"
echo "TARGET $target"
PRE_EOF
  } | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1
)"
preflight_rc=$?
printf '%s\n' "$preflight_out" | tee -a "$log" >/dev/null
while IFS= read -r preflight_line; do
  case "$preflight_line" in GATE_REAP*) say "$preflight_line" ;; esac
done <<< "$preflight_out"
if [ "$preflight_rc" -ne 0 ]; then
  printf '%s\n' "$preflight_out" >&2
  exit 2
fi
# The build host's reply is re-checked here rather than trusted. Exactly one of each line, the
# root has to look like a path, and the target has to be the one this script would have computed.
gate_root="$(printf '%s\n' "$preflight_out" | sed -n 's/^GATE_ROOT //p')"
target="$(printf '%s\n' "$preflight_out" | sed -n 's/^TARGET //p')"
[ -n "$gate_root" ] || die_refuse "the build host did not return a gate root"
[ -n "$target" ] || die_refuse "the build host did not return a gate target"
[ "$(printf '%s\n' "$gate_root" | wc -l)" -eq 1 ] || die_refuse "more than one gate root returned"
[ "$(printf '%s\n' "$target" | wc -l)" -eq 1 ] || die_refuse "more than one gate target returned"
case "$gate_root" in
  /*) ;;
  *) die_refuse "the gate root is not an absolute path: $(printf '%q' "$gate_root")" ;;
esac
case "$gate_root" in
  *[!A-Za-z0-9._/-]*) die_refuse "the gate root contains unexpected characters" ;;
esac
expected_target="$gate_root/$branch"
[ "$target" = "$expected_target" ] \
  || die_refuse "the build host returned $target, not the expected $expected_target"
[ "$target" != "$gate_root" ] || die_refuse "the target is the gate root itself"
case "$target/" in
  "$gate_root"/*) ;;
  *) die_refuse "target $target is outside the gate root $gate_root" ;;
esac
case "/$target/" in
  */../*) die_refuse "target $target contains a '..' segment" ;;
esac
case "$target/" in
  */projects/*) die_refuse "target $target is inside a projects checkout" ;;
esac
say "gate target : $host:$target"

# --- (2b) the gate lock -------------------------------------------------------------------------
# The build host either handed this run the lock or named who holds it. A live holder is a
# refusal, not a wait: two runs of one branch cannot be ordered by patience, and a gate that sits
# silent for ten minutes reads as a hang. A holder that is gone is reaped once, out loud.
lockdir="$(printf '%s\n' "$preflight_out" | sed -n 's/^LOCKDIR //p')"
[ -n "$lockdir" ] || die_refuse "the build host did not return a gate lock path"
[ "$(printf '%s\n' "$lockdir" | wc -l)" -eq 1 ] || die_refuse "more than one gate lock path returned"
[ "$lockdir" = "$target.lock" ] \
  || die_refuse "the build host returned the lock $lockdir, not the expected $target.lock"

if printf '%s\n' "$preflight_out" | grep -q '^LOCK MISMATCH'; then
  die_locked "the gate lock of $branch was written but reads back as somebody else's: $(printf '%s\n' "$preflight_out" | sed -n 's/^LOCK MISMATCH //p')"
elif printf '%s\n' "$preflight_out" | grep -q '^LOCK ACQUIRED$'; then
  LOCK_DIR="$lockdir"
  say "gate lock   : taken ($LOCK_OWNER)"
else
  holder="$(printf '%s\n' "$preflight_out" | sed -n 's/^LOCK HELD //p')"
  holder_host="$(printf '%s\n' "$holder" | sed -n 's/.*host=\([^ ]*\).*/\1/p')"
  holder_pid="$(printf '%s\n' "$holder" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
  # Only this machine's pids can be asked about; a lock from another machine is taken at its word.
  holder_alive=yes
  if [ -n "$holder_pid" ] && [ "$holder_host" = "$(hostname -s)" ] \
     && ! kill -0 "$holder_pid" 2>/dev/null; then
    holder_alive=no
  fi
  if [ "$holder_alive" = yes ]; then
    die_locked "another run of $branch holds the gate lock on $host (${holder:-owner unknown}) — nothing was copied. Wait for it to finish, or clear it with: ssh $host rm -rf '$lockdir'"
  fi

  # A dead controlling pid is only half the question. The tree this lock protects lives on the
  # BUILD HOST, and a remote script whose ssh client was killed is not signalled — it keeps
  # building until a write to the dead connection kills it. Reaping on the pid alone would hand
  # this run an rsync --delete over a tree an orphaned build is still reading. So the build host
  # is asked as well, and it has to answer twice: once about a control it can see (or its silence
  # about this branch proves nothing), once about this branch.
  branch_re="$(printf '%s' "$branch" | sed 's/[.[]/\\&/g')"
  probe_out="$(
    exec 9>&- 7>&-
    {
      printf "lock='%s'\n" "$(esc "$lockdir")"
      printf "branch_re='%s'\n" "$(esc "$branch_re")"
      cat <<'PROBE_EOF'
# The exact question: is the remote half of the run that took this lock still going? It writes
# its pid in here, and it is this host's pid, so this host can answer.
remote_pid="$(cat "$lock/remote-pid" 2>/dev/null | tr -d '[:space:]')"
remote_alive=0
if [ -n "$remote_pid" ] && kill -0 "$remote_pid" 2>/dev/null; then remote_alive=1; fi

# And the wider question, for an orphan that lost its note: anything at all still working inside
# this branch's gate or work tree. A search that finds nothing has to prove it can find
# something, so it starts a process carrying a path of exactly that shape and looks for it first.
control_dir="$HOME/build/memos-ng-ios/gate/PROBECONTROL-$$"
mkdir -p "$control_dir" && : > "$control_dir/live"
tail -f "$control_dir/live" >/dev/null 2>&1 &
control_pid=$!
sleep 1
control_hits="$(pgrep -f "memos-ng-ios/gate/PROBECONTROL-$$/live" | wc -l | tr -d ' ')"
live_hits="$(pgrep -f "memos-ng-ios/(gate|work)/$branch_re(/| |$)" | wc -l | tr -d ' ')"
kill "$control_pid" >/dev/null 2>&1
rm -rf "$control_dir"
echo "PROBE control=$control_hits live=$live_hits remote_pid=${remote_pid:-none} remote_alive=$remote_alive"
PROBE_EOF
    } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' 2>&1
  )"
  probe_rc=$?
  control_hits="$(printf '%s\n' "$probe_out" | sed -n 's/.*control=\([0-9][0-9]*\).*/\1/p')"
  live_hits="$(printf '%s\n' "$probe_out" | sed -n 's/.*live=\([0-9][0-9]*\).*/\1/p')"
  remote_alive="$(printf '%s\n' "$probe_out" | sed -n 's/.*remote_alive=\([0-9]\).*/\1/p')"
  remote_pid="$(printf '%s\n' "$probe_out" | sed -n 's/.*remote_pid=\([^ ]*\).*/\1/p')"
  if [ "$probe_rc" -ne 0 ] || [ -z "$control_hits" ] || [ -z "$live_hits" ] || [ -z "$remote_alive" ]; then
    die_locked "could not ask $host whether a build of $branch is still running, so the lock stays where it is: ${probe_out:-no answer}"
  fi
  if [ "$control_hits" -lt 1 ]; then
    die_locked "the liveness probe on $host could not even see its own control process, so its silence about $branch proves nothing — the lock stays where it is"
  fi
  if [ "$remote_alive" -ne 0 ]; then
    die_locked "the run that took the lock on $branch lost its controlling shell (pid $holder_pid is gone here), but its build is still running on $host as pid $remote_pid — reaping now would rsync --delete the tree out from under it. Let it finish, or clear it with: ssh $host rm -rf '$lockdir'"
  fi
  if [ "$live_hits" -ne 0 ]; then
    die_locked "the lock of $branch names a pid that is gone, but $live_hits process(es) on $host are still working in that branch's gate/work tree — an orphaned build outlives the ssh client that started it, so the lock stays. Let it finish, or clear it with: ssh $host rm -rf '$lockdir'"
  fi

  # The reap itself is one rename, because two runs can reach this point together: mv is atomic,
  # so exactly one of them carries the old lock away and the other finds it gone. rm -rf followed
  # by mkdir is not — the second run's rm would delete the first run's fresh lock.
  takeover_out="$(
    exec 9>&- 7>&-
    {
      printf "lock='%s'\n" "$(esc "$lockdir")"
      printf "owner='%s'\n" "$(esc "$LOCK_OWNER")"
      printf "stamp='%s'\n" "$(esc "$$-$(date -u +%H%M%S)")"
      cat <<'TAKE_EOF'
aside="$lock.reaped-$stamp"
if mv "$lock" "$aside" 2>/dev/null; then
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$owner" > "$lock/owner"
    back="$(cat "$lock/owner" 2>/dev/null)"
    if [ "$back" = "$owner" ]; then
      rm -rf "$aside"
      echo TAKEOVER_OK
    else
      echo "TAKEOVER_LOST the lock reads back as: $back"
    fi
  else
    rm -rf "$aside"
    echo "TAKEOVER_LOST another run claimed it: $(cat "$lock/owner" 2>/dev/null | tr -d '\n')"
  fi
else
  echo "TAKEOVER_LOST another run reaped it first"
fi
TAKE_EOF
    } | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1
  )"
  case "$takeover_out" in
    *TAKEOVER_OK*)
      LOCK_DIR="$lockdir"
      say "gate lock   : reaped a stale lock left by ${holder:-an unknown run} — pid $holder_pid is gone and no build of $branch is running on $host — and took it" ;;
    *)
      die_locked "the stale lock of $branch was claimed by another run first: $takeover_out" ;;
  esac
fi


# --- (3) mirror the worktree ------------------------------------------------------------------
# --- (2c) run admission: room on the build host's disk -----------------------------------------
# The lane lock orders runs of ONE branch; nothing else orders how much disk the host's runs take.
# So before a byte is copied, the run waits until the volume has room for one run's peak plus a
# reserve (scripts/gate-admission.sh). The reading sweeps first — below the threshold, unlocked
# sibling trees go oldest first — and counts what this lane's own trees already hold as room: the
# peak INCLUDES them, and a warm lane grows into its residue rather than beside it. A condition,
# never a timer: the wait ends in admission, or in a refusal with admit=12 (the ceiling) or admit=13
# (three polls that could not read the disk). The load of the host is the simulator admission's
# question, asked where the simulator runs; the load gate that let a run in on a timer is gone.
# The peak allowance (GATE_RUN_PEAK_KB, 12 GiB) rests on a measurement, recorded in 31a04cc: on
# 2026-09-27, 00:51 to 01:24 CEST, one full gate from a lane never built before
# (`MAC_GATE_HOST=merkur.local bin/mac-gate.sh` at 6d6bf81 on fix/wp349-admission, exit 0) was
# sampled from the controller every ~16 s with `df -Pk /` and `du -sk` of
# ~/build/memos-ng-ios/gate/<lane>, ~/build/memos-ng-ios/work/<lane> and the run's simulator device
# directory. As recorded: the largest sampled sum 9.4G, and a bound on the true peak of 11.2G (the
# work tree's final 8.3G, the device's 2.7G and the mirror's 0.1G). The record does not reconcile:
# its parts for the sampled sum (work 7.0G, device 2.7G, mirror 0.1G) add to 9.8G, not 9.4G, and
# the raw samples were not kept. So 12 GiB is a provisional allowance rounded up from the larger
# recorded figure, to be replaced by a re-measurement that keeps its samples. Free space could not
# give the peak: four other lanes moved it during the run.
GATE_ADMISSION_SELF="$GATE_RUN_COPY/scripts/gate-admission.sh"
# shellcheck source=scripts/gate-admission.sh
. "$GATE_ADMISSION_SELF" 2>/dev/null \
  || die_refuse "cannot load the admission helper $GATE_ADMISSION_SELF — nothing was copied"
gate_say() { say "$@"; }
# The admission's poll sleep is a child of this run as well (GATE_SLEEP, set by the helper).
gate_admission_sleep_cmd="$GATE_SLEEP"
gate_admission_sleep() { "$gate_admission_sleep_cmd" "$@" 9>&- 7>&-; }
GATE_SLEEP=gate_admission_sleep
gate_host_available_kb() {
  local out free own
  # The admission calls this inside its own command substitution, a subshell that waits on the
  # ssh below: it lets the estate lock go there. Never in this run's own shell, whose copy IS the
  # lock (BASHPID equals $$ only there, and the fallback keeps it so where BASHPID is unknown).
  [ "${BASHPID:-$$}" = "$$" ] || exec 9>&- 7>&-
  out="$(
    exec 9>&- 7>&-
    {
      cat "$GATE_RUN_COPY/scripts/reap-gate-lanes.sh"
      cat "$GATE_RUN_COPY/scripts/gate-work-dir.sh"
      cat "$GATE_ADMISSION_SELF"
      printf "target='%s'\nbranch='%s'\ngate_root='%s'\nneed='%s'\n" \
        "$(esc "$target")" "$(esc "$branch")" "$(esc "$gate_root")" "$(esc "$GATE_ADMISSION_NEED_KB")"
      cat <<'SPACE_EOF'
work="$(gate_work_dir "$gate_root" "$branch")" || exit 3
gate_pressure_sweep "$target" "$work" "$branch" "$need" "$need"
gate_lane_space "$target" "$work" || exit 3
SPACE_EOF
    } | timeout 600 ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'bash -s' 2>&1
  )" || { printf '%s\n' "$out" | sed -n '/^GATE_HYGIENE/p' >&2; return 1; }
  printf '%s\n' "$out" | sed -n '/^GATE_HYGIENE/p' | while IFS= read -r l; do say "$l" >&2; done
  free="$(printf '%s\n' "$out" | sed -n 's/^FREE_KB \([0-9][0-9]*\) OWN_KB [0-9][0-9]*$/\1/p')"
  own="$(printf '%s\n' "$out" | sed -n 's/^FREE_KB [0-9][0-9]* OWN_KB \([0-9][0-9]*\)$/\1/p')"
  [ -n "$free" ] && [ -n "$own" ] && [ "$(printf '%s\n' "$free" | wc -l)" -eq 1 ] || return 1
  # The first reading is the run's disk= field. This runs inside the admission's command
  # substitution, so it is kept in a file of the run's private copy rather than in a variable.
  [ -e "$GATE_RUN_COPY/.admit-disk" ] \
    || awk -v k="$free" 'BEGIN { printf "%.1f\n", k / 1048576 }' > "$GATE_RUN_COPY/.admit-disk"
  say "admission   : $(gate_kb_h "$free") free on the build host, this lane's trees hold $(gate_kb_h "$own")" >&2
  echo $((free + own))
}
GATE_ADMISSION_NEED_KB=$((GATE_RUN_PEAK_KB + GATE_RESERVE_KB))
gate_run_admission "$GATE_ADMISSION_NEED_KB" gate_host_available_kb
admit_rc=$?
record admit "$admit_rc"
SUMMARY_INFO="$SUMMARY_INFO disk=$(cat "$GATE_RUN_COPY/.admit-disk" 2>/dev/null || echo -)"
[ "$admit_rc" -eq 0 ] || end_run

say "--- step: rsync ---"
rsync -a --delete \
  --exclude '.git' --exclude 'signing.local.yml' \
  --exclude '.build' \
  --exclude 'DerivedData' \
  --exclude '*.xcodeproj' \
  --exclude '*.xcresult' \
  --exclude '.gate-artifacts' \
  -e ssh \
  "$repo_root"/ "$host:$target/" 2>&1 9>&- 7>&- | tee -a "$log" 9>&- 7>&-
record rsync "${PIPESTATUS[0]}"
[ "$first_fail" -eq 0 ] || end_run

# --- (4) the ordered, fail-fast checks on the build host --------------------------------------
say "--- step: remote ---"
# The warm-lane marker the router reads when every host is busy: this branch's lane on this host
# now holds DerivedData. A marker that cannot be written costs that hint and nothing else.
if printf '%s %s %s %s\n' "$host" "$branch" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_TOKEN" \
     > "$artifacts/.lane-host.$RUN_TOKEN" 2>/dev/null \
   && mv -f "$artifacts/.lane-host.$RUN_TOKEN" "$artifacts/lane-host" 2>/dev/null; then
  :
else
  rm -f "${artifacts:?}/.lane-host.${RUN_TOKEN:?}" 2>/dev/null
  say "lane-host   : cannot write $artifacts/lane-host (the warm-lane hint only)"
fi
# Where the remote's own output starts in the log: the run ledger reads the remote's clock from
# here on, and from nothing printed before it.
GATE_REMOTE_LOG_OFFSET="$(wc -c < "$log" | tr -d ' ')" || GATE_REMOTE_LOG_OFFSET="?"
case "$GATE_REMOTE_LOG_OFFSET" in ''|*[!0-9]*) GATE_REMOTE_LOG_OFFSET="?" ;; esac
{
  printf "GATE_TARGET='%s'\n" "$(esc "$target")"
  printf "GATE_ROOT='%s'\n" "$(esc "$gate_root")"
  printf "GATE_SIMULATOR='%s'\n" "$(esc "$SIMULATOR")"
  printf "GATE_DEVICE_NAME='%s'\n" "$(esc "$DEVICE_NAME")"
  printf "GATE_DEVICE_TYPE='%s'\n" "$(esc "$DEVICE_TYPE")"
  printf "GATE_RUN_TOKEN='%s'\n" "$(esc "$RUN_TOKEN")"
  printf "GATE_TEST_BUNDLES='%s'\n" "$(esc "$TEST_BUNDLES")"
  printf "GATE_BRANCH='%s'\n" "$(esc "$branch")"
  printf "GATE_PROJECT='%s'\n" "memos-ng-ios"
  printf "GATE_QUICK='%s'\n" "$(esc "$QUICK")"
  printf "GATE_QUICK_BUNDLE='%s'\n" "$(esc "$QUICK_BUNDLE")"
  printf "GATE_QUICK_ONLY_TESTING='%s'\n" "$(esc "$QUICK_ONLY_TESTING")"
  printf "GATE_QUICK_ITERATIONS='%s'\n" "$(esc "$QUICK_ITERATIONS")"
  cat "$GATE_RUN_COPY/scripts/reap-gate-lanes.sh"
  cat "$GATE_RUN_COPY/scripts/gate-work-dir.sh"
  cat "$GATE_ADMISSION_SELF"
  cat <<'REMOTE_EOF'
set -uo pipefail

# The build host's own clock, read twice: at the first line here and when the run ends. The end
# is stamped once — just before the summary, so the summary's wall= is the run's, or on the way
# out for every exit that has no summary (the ownership refusal right below, the quick run) — and
# the controller's run ledger takes both from these lines.
# A clock that cannot be read says so ("unreadable", t=-, wall=-) rather than print a number.
gate_remote_now() {
  local now
  now="$(date +%s)" || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$now"
}
gate_remote_clock_start() {
  GATE_REMOTE_START="$(gate_remote_now)" || GATE_REMOTE_START="unreadable"
  GATE_REMOTE_END=""
  echo "MAC_GATE_REMOTE_CLOCK start=$GATE_REMOTE_START"
}
gate_remote_clock_end() {
  [ -z "${GATE_REMOTE_END:-}" ] || return 0
  GATE_REMOTE_END="$(gate_remote_now)" || GATE_REMOTE_END="unreadable"
  echo "MAC_GATE_REMOTE_CLOCK end=$GATE_REMOTE_END"
}
gate_remote_t() {
  local now
  case "$GATE_REMOTE_START" in unreadable) printf -- '-'; return 0 ;; esac
  now="$(gate_remote_now)" || { printf -- '-'; return 0; }
  printf '%s' "$((now - GATE_REMOTE_START))"
}
gate_remote_step_line() { # NAME RC — the step line; a timestamp that failed is said out loud
  local t
  t="$(gate_remote_t)"
  echo "MAC_GATE_STEP $1 $2 t=$t"
  [ "$t" != "-" ] || echo "MAC_GATE_REMOTE_CLOCK unreadable (the clock failed at step $1)"
}
gate_remote_wall() {
  case "$GATE_REMOTE_START$GATE_REMOTE_END" in *unreadable*) printf -- '-'; return 0 ;; esac
  printf '%s' "$((GATE_REMOTE_END - GATE_REMOTE_START))"
}
gate_remote_clock_start
trap 'gate_remote_clock_end' EXIT

# The first thing this shell does, before a directory is entered or a byte is removed: check that
# the lock this run was given is still this run's. A controller can be killed between the copy and
# this line, and the lock it left behind can be judged stale and reaped in that moment — in which
# case another run now owns the tree, and the only correct move here is to stop having touched
# nothing. What remains is the few milliseconds between ssh handing this script to bash and this
# check: in that window this shell has mutated nothing, so a reap there costs the reaper nothing
# and costs this run only the run itself.
GATE_LOCK="$GATE_TARGET.lock"
gate_lock_owner="$(cat "$GATE_LOCK/owner" 2>/dev/null)"
case "$gate_lock_owner" in
  *"token=$GATE_RUN_TOKEN"*) ;;
  *)
    echo "remote: the gate lock of this run was taken over while it was starting" \
         "(the lock now reads: ${gate_lock_owner:-gone}) — stopping, nothing was touched"
    exit 4 ;;
esac
# Only now, and only into a lock that answered with this run's token: the note that says a build
# is running on this host, which is what tells the next run not to reap while it is.
printf '%s\n' "$$" > "$GATE_LOCK/remote-pid" 2>/dev/null

export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# xcode-select still points at the Command Line Tools on this host, so the full Xcode is named
# explicitly rather than assumed.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

cd "$GATE_TARGET" || { echo "remote: cannot enter $GATE_TARGET"; exit 2; }
# One chain, so the stamp exists only in a folder this run cleared and created: a clear that failed
# leaves no stamp of this run's beside what an earlier run left, and the run stops here.
rm -rf .gate-artifacts && mkdir -p .gate-artifacts && printf '%s\n' "$GATE_RUN_TOKEN" > .gate-artifacts/run-token || { echo "remote: cannot clear the artifacts folder"; exit 2; }
XCRESULT="$GATE_TARGET/.gate-artifacts/MemosNG.xcresult"
# Build scratch lives OUTSIDE the mirrored tree. Inside it, `swift format lint --recursive .`
# would walk the dependency checkouts SwiftPM drops in DerivedData and lint other people's code;
# keeping it outside also lets the incremental build survive the next `rsync --delete`.
# It is the work/ sibling of the gate root the preflight resolved and this run was handed, never
# a rewritten substring of the gate path: ~/build/memos-ng-ios may resolve anywhere at all.
GATE_WORK="$(gate_work_dir "$GATE_ROOT" "$GATE_BRANCH")" \
  || { echo "remote: cannot derive a work directory"; exit 2; }
[ "$GATE_WORK" != "$GATE_TARGET" ] || { echo "remote: the work directory is the gate target"; exit 2; }
mkdir -p "$GATE_WORK" || { echo "remote: cannot create $GATE_WORK"; exit 2; }
DERIVED="$GATE_WORK/DerivedData"

# --- disk hygiene -------------------------------------------------------------------------------
# Per-branch trees are kept between runs for the incremental build, but a merged branch never
# gates again and nothing else reaps its ~3.6G — the host filled up five times in one day this
# way. So every run stamps its OWN trees (a directory's mtime only moves when direct children
# change, so DerivedData writes deep inside never refresh it — the touch is the bookkeeping),
# then sweeps sibling trees whose stamp is older than three days: still-active branches re-stamp
# far more often than that. Locks are NEVER sweep targets — they are owned by the runs that hold
# them and clean themselves up through the trap; deleting one from the side would strip a live
# run of its serialization.
HYGIENE_GATE_ROOT="${GATE_TARGET%/"$GATE_BRANCH"}"
HYGIENE_WORK_ROOT="${GATE_WORK%/"$GATE_BRANCH"}"
touch "$GATE_TARGET" "$GATE_WORK" 2>/dev/null
for hygiene_root in "${GATE_TARGET%/*/*}" "${GATE_WORK%/*/*}"; do
  find "$hygiene_root" -mindepth 2 -maxdepth 2 -type d -mtime +3 \
    ! -path "$GATE_TARGET" ! -path "$GATE_WORK" ! -name '*.lock*' 2>/dev/null \
    | while IFS= read -r stale; do
        case "$stale" in
          *.lock*) continue ;;
        esac
        gate_lane_is_unlocked "$HYGIENE_GATE_ROOT" "$HYGIENE_WORK_ROOT" "$stale" || continue
        rm -rf "$stale" && echo "GATE_HYGIENE swept stale tree $stale"
      done
done
# Age alone is not enough on a busy day: five concurrent branches at ~3G each filled the host
# to ENOSPC while every tree was hours old. So under pressure the oldest unlocked siblings go too
# (gate_pressure_sweep in scripts/reap-gate-lanes.sh). The 2026-09-05 mid-run ENOSPC needs more
# headroom for DerivedData and warnings rebuilds: 15G low, 20G high.
gate_pressure_sweep "$GATE_TARGET" "$GATE_WORK" "$GATE_BRANCH" 15728640 20971520
# The volume the trees are on, never `/`: the build root is meant to be a volume of its own.
disk_free="$(df -h "$GATE_TARGET" | awk 'NR==2 {print $4}')"
echo "GATE_HYGIENE disk free after sweep: $disk_free"
case "$disk_free" in
  *G*) : ;;
  *) echo "GATE_HYGIENE WARNING: free space is not in the gigabyte range ($disk_free) — a cold build needs ~4G" ;;
esac

# --- the simulator this run gets ----------------------------------------------------------------
# A simulator holds ONE installation per bundle id, so two branches building on the same device
# overwrite each other's app and the loser launches against the winner's frameworks — dyld
# "Symbol not found", a red gate, and nothing wrong with the code. Each run therefore gets a
# device of its own and gives it back. And since two simulator phases of ANY two runs on this host
# fill its disk and its swap (2026-09-28..30), the device exists only inside the host-wide slot
# (scripts/gate-admission.sh): gate_sim_open waits for the slot and the host's conditions, names
# the device in the slot's owner record, creates, boots and prepares it; gate_sim_close stops what
# is left of the run, deletes the device, confirms it gone and gives the slot back — a checked step
# before the summary, repeated by the traps below as an idempotent backstop. A close that cannot
# confirm keeps the slot (state=cleanup-failed) and fails the run with simrelease=1.
GATE_DEVICE_UDID=""
GATE_DESTINATION=""
GATE_SLOT_RC="-"
# The warnings check writes one file into the mirrored tree and takes it away again. It is named
# here, where the give-back below can reach it: a shell killed between writing it and deleting it
# would otherwise leave a source file the gate invented sitting in the tree for the next run to
# lint, build and rsync over.
GATE_CANARY_FILE=""
# Everything this run took on the build host goes back together: the device and the slot, and the
# note in the lock that says a build is still running here. The note is removed only while it is
# still ours.
gate_give_back() {
  [ -z "${GATE_CANARY_FILE:-}" ] || rm -f "$GATE_CANARY_FILE"
  GATE_CANARY_FILE=""
  gate_sim_release
  local rc=$?
  if [ -n "${GATE_LOCK:-}" ] && [ "$(cat "$GATE_LOCK/remote-pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$GATE_LOCK/remote-pid"
  fi
  return $rc
}
trap 'gate_give_back; gate_remote_clock_end' EXIT
trap 'gate_give_back; exit 130' INT
trap 'gate_give_back; exit 143' TERM
trap 'gate_give_back; exit 129' HUP
# An ssh client that went away is not a signal here; the next write is, and it would end this shell
# without a trap. So the rest of the output goes to a file, and the run carries on to its own close.
trap 'gate_on_broken_pipe "$GATE_WORK/remote-after-disconnect.log"' PIPE

# The compile needs no device: every build names this destination.
GATE_BUILD_DESTINATION="generic/platform=iOS Simulator"

gate_sim_open() {
  local shared_udid="" device_pick device_type device_rest device_runtime device_label
  if [ -n "$GATE_SIMULATOR" ]; then
    # A shared device is not created, and never deleted: the slot is still taken for the tests,
    # the record names the device and marks it shared, and the close shuts it down.
    shared_udid="$(gate_read_devices)" || {
      echo "remote: the device list could not be read, so MAC_GATE_SIMULATOR '$GATE_SIMULATOR' cannot be resolved"
      return 2
    }
    shared_udid="$(printf '%s\n' "$shared_udid" | awk -F '\t' -v n="$GATE_SIMULATOR" '$3 == n { print $1 }')"
    [ -n "$shared_udid" ] && [ "$(printf '%s\n' "$shared_udid" | wc -l)" -eq 1 ] || {
      echo "remote: MAC_GATE_SIMULATOR '$GATE_SIMULATOR' does not name exactly one device on this host"
      return 2
    }
    # The claim writes the UDID into the record it renames into place and reads it back, so a
    # slot this run holds always names the device its close must shut down.
    gate_slot_wait_claim "$GATE_PROJECT" "$GATE_BRANCH" "$GATE_RUN_TOKEN" 1 "$shared_udid"
    GATE_SLOT_RC=$?
    [ "$GATE_SLOT_RC" -eq 0 ] || return "$GATE_SLOT_RC"
    GATE_DESTINATION="platform=iOS Simulator,id=$shared_udid"
    echo "MAC_GATE_DEVICE shared '$GATE_SIMULATOR' $shared_udid (MAC_GATE_SIMULATOR is set — no per-run isolation)"
    return 0
  fi
  # Written out and then run, rather than fed to python on a pipe inside "$( … )": the build
  # host's /bin/bash is 3.2, and its command-substitution scanner reads a quoted here-document as
  # shell text — a stray parenthesis or quote inside the program becomes a syntax error before
  # anything runs. Every helper below is spelled this way for that reason.
  cat > "$GATE_WORK/choose-device.py" <<'PY'
import json, re, subprocess, sys

wanted = sys.argv[1].strip() if len(sys.argv) > 1 else ""

proc = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"],
                      capture_output=True, text=True)
if proc.returncode != 0:
    sys.stderr.write(proc.stderr)
    sys.exit(1)

# A runtime's own supportedDeviceTypes is the only honest answer to "can this device type run
# this iOS": the device type list on its own says nothing about which runtimes accept it, and a
# create against a pair the host does not support fails after the gate has already started.
runtimes = [r for r in json.loads(proc.stdout).get("runtimes", [])
            if r.get("isAvailable") and "SimRuntime.iOS-" in r.get("identifier", "")]

def version(runtime):
    return tuple(int(part) for part in re.findall(r"\d+", runtime.get("version", "0")))

runtimes.sort(key=version, reverse=True)

def rank(name):
    # Newest generation first. Within a generation the Pro is preferred, and that is not taste:
    # the hosted-window accessibility probes in MemoEditWiringTests vend an empty tree on some
    # models (iPhone 17e, 2026-08-24) and pass on the Pro. Until that is fixed in the probe, the
    # gate picks the model the suite is known to pass on rather than whichever name sorts first.
    generation = re.match(r"iPhone (\d+)", name)
    if name.endswith(" Pro"):
        variant = 3
    elif name.endswith(" Pro Max"):
        variant = 2
    elif re.fullmatch(r"iPhone \d+", name):
        variant = 1
    else:
        variant = 0
    return (int(generation.group(1)) if generation else 0, variant)

for runtime in runtimes:
    devices = [d for d in runtime.get("supportedDeviceTypes", [])
               if d.get("name", "").startswith("iPhone")]
    if wanted:
        devices = [d for d in devices if d.get("identifier") == wanted]
    if not devices:
        continue
    best = max(devices, key=lambda device: rank(device["name"]))
    print("%s|%s|%s on %s" % (best["identifier"], runtime["identifier"], best["name"],
                              runtime.get("name", runtime["identifier"])))
    sys.exit(0)

sys.stderr.write("no iPhone device type%s is supported by any installed iOS runtime\n"
                 % ((" matching " + wanted) if wanted else ""))
sys.exit(1)
PY
  device_pick="$(/usr/bin/python3 "$GATE_WORK/choose-device.py" "$GATE_DEVICE_TYPE")"
  [ -n "$device_pick" ] || { echo "remote: cannot choose a simulator device type"; return 2; }
  device_type="${device_pick%%|*}"
  device_rest="${device_pick#*|}"
  device_runtime="${device_rest%%|*}"
  device_label="${device_rest##*|}"
  gate_slot_wait_claim "$GATE_PROJECT" "$GATE_BRANCH" "$GATE_RUN_TOKEN" 0 ""
  GATE_SLOT_RC=$?
  [ "$GATE_SLOT_RC" -eq 0 ] || return "$GATE_SLOT_RC"
  # Named in the record BEFORE it exists: a recovery finds it by this name even if this shell dies
  # between the create and writing the UDID down.
  gate_slot_note_device "$GATE_DEVICE_NAME" || { echo "remote: cannot name the device in the slot record"; return 2; }
  GATE_DEVICE_UDID="$(xcrun simctl create "$GATE_DEVICE_NAME" "$device_type" "$device_runtime")"
  GATE_DEVICE_UDID="$(printf '%s' "$GATE_DEVICE_UDID" | tr -d '[:space:]')"
  case "$GATE_DEVICE_UDID" in
    [0-9A-Fa-f]*-*-*-*-*) ;;
    *)
      # Whatever was made under that name goes at the close, which deletes by name.
      echo "remote: could not create the simulator $GATE_DEVICE_NAME ($device_label)"
      GATE_DEVICE_UDID=""
      return 2 ;;
  esac
  gate_slot_note_udid "$GATE_DEVICE_UDID" "$GATE_DEVICE_NAME"
  # Addressed by id, never by name: the name is the thing two runs could collide on.
  GATE_DESTINATION="platform=iOS Simulator,id=$GATE_DEVICE_UDID"
  echo "MAC_GATE_DEVICE created $GATE_DEVICE_NAME $GATE_DEVICE_UDID ($device_label)"
  # It is booted HERE, and waited for. xcodebuild boots a device it needs, but it does
  # not wait for the system inside to finish coming up, and a simulator that is still booting
  # vends an empty accessibility tree: the hosted-window probes in MemoEditWiringTests see no
  # labels at all and the suite fails for a reason that has nothing to do with the code
  # (measured 2026-08-24 on a newly created iPhone 17 Pro — "labels → []"). Nobody saw this while
  # the gate ran on a shared device, because that device had been up for days. A private device
  # is cold every time, so the wait belongs to the gate.
  xcrun simctl bootstatus "$GATE_DEVICE_UDID" -b || {
    echo "remote: the created simulator never finished booting"
    return 2
  }

  # A factory-fresh simulator has accessibility switched OFF — com.apple.Accessibility has
  # neither AccessibilityEnabled nor ApplicationAccessibilityEnabled — and with those absent a
  # hosted UIWindow vends an EMPTY accessibility tree: MemoEditWiringTests reads back no labels
  # at all and fails on the device rather than on the code. The long-lived devices this gate used
  # to share had been switched on at some point, which is the only reason nobody saw it while
  # every run landed on the same device (found 2026-08-24 across two rounds; the model has
  # nothing to do with it).
  #
  # The write goes THROUGH the booted device. Writing the plist under the device's data directory
  # from this side looks like it worked — `defaults read` on that file returns 1 — and changes
  # nothing: the simulator does not read that file, `simctl spawn … defaults read` still answers
  # "does not exist", and the suite still fails. Measured on this host, three devices, one
  # suite: no keys -> fail, host-side file -> fail, spawn write -> pass.
  for a11y_key in AccessibilityEnabled ApplicationAccessibilityEnabled; do
    xcrun simctl spawn "$GATE_DEVICE_UDID" defaults write com.apple.Accessibility "$a11y_key" -bool true
  done
  # Read back from INSIDE the device, which is the only reader whose answer means anything here.
  for a11y_key in AccessibilityEnabled ApplicationAccessibilityEnabled; do
    a11y_value="$(xcrun simctl spawn "$GATE_DEVICE_UDID" defaults read com.apple.Accessibility "$a11y_key" 2>/dev/null | tr -d '[:space:]')"
    [ "$a11y_value" = "1" ] || {
      echo "remote: $a11y_key reads '${a11y_value:-unset}' inside $GATE_DEVICE_NAME —" \
           "hosted-window accessibility would vend an empty tree, so the gate stops here"
      return 2
    }
  done
  echo "MAC_GATE_DEVICE accessibility on ($GATE_DEVICE_NAME: AccessibilityEnabled=1 ApplicationAccessibilityEnabled=1, read back inside the device)"
  return 0
}

# The checked close, before anything reports: 0 when the slot went back, 1 when it did not. Its
# line is the one the controller reads slot=, slot_wait= and simrelease= from.
gate_sim_close() {
  gate_sim_release
  local rc=$?
  echo "MAC_GATE_SLOT slot=$GATE_SLOT_RC slot_wait=$GATE_SLOT_WAITED simrelease=$GATE_SIMRELEASE"
  return $rc
}

# The span every device-bound step runs inside: open, the steps named, close. Its code is the
# slot refusal, else the first failing step's, else the close's.
gate_sim_span() { # STEP_FUNCTION...
  local rc=0 f close_rc
  gate_sim_open
  rc=$?
  if [ "$rc" -eq 0 ]; then
    for f in "$@"; do
      "$f"; rc=$?
      [ "$rc" -eq 0 ] || break
    done
  fi
  gate_sim_close
  close_rc=$?
  [ "$rc" -ne 0 ] || rc="$close_rc"
  return "$rc"
}

# --- the version this gate expects --------------------------------------------------------------
# project.yml is where the version is written, so it is also where the checks below take their
# expectation from. A second copy in this script would be a copy to forget on the next bump, and
# forgetting it reads as a failed gate rather than as an out-of-date script.
cat > "$GATE_WORK/read-marketing-version.py" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError as error:
    sys.stderr.write("cannot read %s: %s\n" % (sys.argv[1], error))
    sys.exit(1)
values = set(re.findall(r'^[ \t]*MARKETING_VERSION:[ \t]*"?([^"\s#]+)"?[ \t]*(?:#.*)?$', text, re.M))
if not values:
    sys.stderr.write("project.yml declares no MARKETING_VERSION\n")
    sys.exit(1)
if len(values) != 1:
    sys.stderr.write("project.yml declares more than one MARKETING_VERSION: %s\n" % sorted(values))
    sys.exit(1)
print(values.pop())
PY
GATE_MARKETING_VERSION="$(/usr/bin/python3 "$GATE_WORK/read-marketing-version.py" project.yml)" \
  || GATE_MARKETING_VERSION=""

first_fail=0
summary=""
step() {
  local name="$1"; shift
  echo "::: $name :::"
  if [ "$first_fail" -ne 0 ]; then
    summary="$summary $name=skipped"
    echo "::: $name skipped (a previous step failed) :::"
    return
  fi
  "$@"
  local rc=$?
  summary="$summary $name=$rc"
  gate_remote_step_line "$name" "$rc"
  if [ "$rc" -ne 0 ] && [ "$first_fail" -eq 0 ]; then first_fail=$rc; fi
}

s_xcodegen() {
  [ -f project.yml ] || { echo "no project.yml in $GATE_TARGET — nothing to generate"; return 3; }
  bin/generate.sh --spec project.yml || return $?
  # The version pair has to move on BOTH targets together — an extension whose CFBundleVersion
  # differs from its host's cannot be installed, and a marketing version that differs between
  # them is a TestFlight build that says two things at once. Checked on the generated project,
  # here, because it costs nothing and the build that would surface it costs ten minutes.
  [ -n "$GATE_MARKETING_VERSION" ] || {
    echo "VERSION FAIL: project.yml does not name exactly one MARKETING_VERSION to expect"
    return 1
  }
  echo "--- version keys in the generated project (expected from project.yml: $GATE_MARKETING_VERSION) ---"
  /usr/bin/python3 - "$GATE_MARKETING_VERSION" <<'PY'
import re, sys

EXPECTED_MARKETING = sys.argv[1]
pbxproj = "MemosNG.xcodeproj/project.pbxproj"
try:
    text = open(pbxproj, encoding="utf-8").read()
except OSError as error:
    print("VERSION FAIL: cannot read %s: %s" % (pbxproj, error))
    sys.exit(1)

marketing = re.findall(r"MARKETING_VERSION = ([^;]+);", text)
current = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text)
print("MARKETING_VERSION values: %s" % (", ".join(marketing) or "(none)"))
print("CURRENT_PROJECT_VERSION values: %s" % (", ".join(current) or "(none)"))

rc = 0
# Two targets carry the pair, each with a Debug and a Release configuration.
if len(marketing) < 4:
    print("VERSION FAIL: expected at least 4 MARKETING_VERSION entries (app + extension, "
          "Debug + Release), found %d" % len(marketing))
    rc = 1
elif set(marketing) != {EXPECTED_MARKETING}:
    print("VERSION FAIL: MARKETING_VERSION is not %s everywhere" % EXPECTED_MARKETING)
    rc = 1
else:
    print("ok: every MARKETING_VERSION is %s" % EXPECTED_MARKETING)

if len(current) < 4:
    print("VERSION FAIL: expected at least 4 CURRENT_PROJECT_VERSION entries, found %d" % len(current))
    rc = 1
elif len(set(current)) != 1:
    print("VERSION FAIL: the two targets disagree on CURRENT_PROJECT_VERSION: %s" % set(current))
    rc = 1
else:
    print("ok: every CURRENT_PROJECT_VERSION is %s" % current[0])

# Positive control in the same read: a setting that must be there, so that a "not found" above
# means absent rather than a regex reading the wrong file.
if re.search(r"PRODUCT_BUNDLE_IDENTIFIER = live\.discomarder\.memosng;", text):
    print("ok (positive control): the app's bundle identifier is in the generated project")
else:
    print("VERSION FAIL: positive control missing — the generated project has no "
          "PRODUCT_BUNDLE_IDENTIFIER = live.discomarder.memosng")
    rc = 1

sys.exit(rc)
PY
}

# The version first, so one run log holds both sides' swift-format (MAC_GATE_LOCALLINT is the
# local one) and the pin in bin/mac-gate.sh can be checked against the live value.
s_format() {
  printf 'MAC_GATE_SWIFTFORMAT version=%s\n' "$(swift format --version 2>&1 | head -1)"
  swift format lint --strict --recursive .
}

s_entitlements() {
  # The privilege boundary this app rests on is not in the Swift: it is two generated plists. The
  # device token lives in a keychain access group the APP declares and the share extension does
  # not, and an app group identifier is itself a keychain access group — so an extension that
  # gained a keychain-access-groups entry, or a token left in the app group, would be readable by
  # the share sheet with nothing in the code to show for it. Checked on the GENERATED files rather
  # than on project.yml: the artefact is what ships.
  local rc=0 app="MemosNG.entitlements" ext="MemosShare.entitlements" f
  for f in "$app" "$ext"; do
    [ -f "$f" ] || { echo "ENTITLEMENT FAIL: $f was not generated"; return 1; }
    echo "--- $f"
    plutil -p "$f"
  done
  # Read by INDEX, because the order is the security property: the first entry of
  # keychain-access-groups is the default access group, and the app writes the token to whichever
  # group that is. A list whose first entry drifted to the app group would put every new token
  # where the share extension can read it.
  local first second
  first="$(plutil -extract keychain-access-groups.0 raw -o - "$app" 2>/dev/null)"
  second="$(plutil -extract keychain-access-groups.1 raw -o - "$app" 2>/dev/null)"
  if [ "$first" = '$(AppIdentifierPrefix)live.discomarder.memosng.credentials' ]; then
    echo "ENTITLEMENT ok: the credential group is FIRST, so it is the default access group"
  else
    echo "ENTITLEMENT FAIL: the first keychain access group is '$first'"; rc=1
  fi
  # A second entry is a defect twice over: iOS provisioning validates every entry against the
  # profile's `TEAMID.*` pattern (a raw `group.…` entry fails automatic signing on device
  # builds), and any extra group widens where an unqualified write could land. The app group's
  # keychain access rides on the application-groups entitlement, checked by the control below.
  if [ -z "$second" ]; then
    echo "ENTITLEMENT ok: keychain-access-groups has exactly one entry"
  else
    echo "ENTITLEMENT FAIL: unexpected second keychain access group '$second'"; rc=1
  fi
  if grep -q 'keychain-access-groups' "$ext"; then
    echo "ENTITLEMENT FAIL: $ext declares a keychain access group; the token would be readable"
    rc=1
  else
    echo "ENTITLEMENT ok: the share extension declares no keychain access group"
  fi
  # A grep that finds nothing proves nothing on its own: both targets DO carry the app group, so
  # this is the control that says the two greps above were run against real files.
  if grep -q 'group.live.discomarder.memosng' "$app" \
    && grep -q 'group.live.discomarder.memosng' "$ext"; then
    echo "ENTITLEMENT ok (positive control): both targets declare the app group"
  else
    echo "ENTITLEMENT FAIL: positive control missing — the app group is not in both files"; rc=1
  fi
  return $rc
}

s_pins() {
  # A rebuild that resolves different dependency versions than the last good build is a different
  # app, and nothing in a green test run would say so. SwiftPM keeps its resolved-versions file
  # INSIDE the project, which is generated and not committed — so the graph is tracked at the repo
  # root instead and bin/generate.sh copies it in. This step asks SwiftPM to resolve against it and
  # reads the file back: SwiftPM rewrites that file whenever the pins cannot satisfy the manifests
  # (a dependency added, a requirement bumped past its pin, a hand edit), so a difference here IS
  # the drift — caught before the build rather than at an archive.
  #
  # Pinning the five direct dependencies in project.yml instead would not have covered it: eight of
  # the thirteen packages the app links are transitive and named in no manifest in this repo, so
  # their versions would still float. Only the resolved graph pins the whole thing.
  local tracked="Package.resolved"
  local resolved="MemosNG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  [ -f "$tracked" ] || { echo "PINS FAIL: $tracked is not in the tree"; return 1; }
  [ -f "$resolved" ] || {
    echo "PINS FAIL: bin/generate.sh did not put the pins in $resolved"
    return 1
  }
  xcodebuild -resolvePackageDependencies \
    -project MemosNG.xcodeproj \
    -scheme MemosNG \
    -derivedDataPath "$DERIVED"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PINS FAIL: package resolution failed (xcodebuild -resolvePackageDependencies exit $rc)"
    return "$rc"
  fi
  # Copied back on every run, pass or fail: on a fail it is the file to adopt, and on a pass it is
  # the evidence of what the build actually resolved.
  cp "$resolved" .gate-artifacts/Package.resolved
  /usr/bin/python3 - "$tracked" "$resolved" <<'PY'
import glob, json, pathlib, re, sys

tracked_path, resolved_path = sys.argv[1], sys.argv[2]


def load(path):
    try:
        return json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("PINS FAIL: cannot read %s: %s" % (path, error))
        sys.exit(1)


def pins(document):
    # Everything that decides WHAT gets compiled: where the package comes from, which version, and
    # the exact commit. Deliberately not originHash — SwiftPM recomputes that on a re-resolve and
    # was observed returning a different value for an unchanged set of manifests (2026-08-25), so
    # a check that failed on it would go red for no reachable reason. `location` covers the case
    # originHash would have caught here: a dependency re-pointed at another repository.
    out = {}
    for pin in document.get("pins", []):
        state = pin.get("state", {})
        out[pin.get("identity", "?")] = (
            state.get("version") or state.get("branch") or "(revision only)",
            state.get("revision", ""),
            pin.get("location", ""),
        )
    return out


def identity(url):
    name = url.strip().strip('"').rstrip("/").rsplit("/", 1)[-1]
    if name.endswith(".git"):
        name = name[: -len(".git")]
    return name.lower()


tracked, resolved = load(tracked_path), load(resolved_path)
t, r = pins(tracked), pins(resolved)
rc = 0

# The control on the comparison below: two files that agreed because both were empty, or because
# the wrong pair was read, would still "match". So the dependencies this project DECLARES are read
# out of the two places that declare them and each one is looked up in what was resolved.
declared = set()
for path in ["project.yml", *sorted(glob.glob("Packages/*/Package.swift"))]:
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for url in re.findall(r'\.package\(\s*url:\s*"([^"]+)"', text):
        declared.add(identity(url))
    for url in re.findall(r"^\s+url:\s*(https://\S+)\s*$", text, re.M):
        declared.add(identity(url))
if not declared:
    print("PINS FAIL: no remote dependency is declared in project.yml or Packages/*/Package.swift"
          " — the control below would pass on any file")
    rc = 1
missing = sorted(declared - set(r))
if missing:
    print("PINS FAIL: declared dependencies absent from the resolved graph: %s" % ", ".join(missing))
    rc = 1
elif declared:
    print("PINS ok (control): all %d declared remote dependencies are in the resolved graph: %s"
          % (len(declared), ", ".join("%s@%s" % (i, r[i][0]) for i in sorted(declared))))

added = sorted(set(r) - set(t))
removed = sorted(set(t) - set(r))
changed = sorted(i for i in set(t) & set(r) if t[i] != r[i])
if added or removed or changed:
    print("PINS FAIL: resolution does not match the tracked %s — this build would not use the "
          "versions this repo ships" % tracked_path)
    for i in changed:
        print("PINS FAIL:   %s: pinned %s (%s) from %s, resolved %s (%s) from %s"
              % (i, t[i][0], t[i][1][:12], t[i][2], r[i][0], r[i][1][:12], r[i][2]))
    for i in added:
        print("PINS FAIL:   %s: resolved at %s, pinned nowhere" % (i, r[i][0]))
    for i in removed:
        print("PINS FAIL:   %s: pinned at %s, no longer part of the graph" % (i, t[i][0]))
    rc = 1
elif tracked.get("version") != resolved.get("version"):
    print("PINS FAIL: the resolved-file format changed (version %s -> %s)"
          % (tracked.get("version"), resolved.get("version")))
    rc = 1
else:
    print("PINS ok: resolution reproduced all %d tracked pins, each at the same commit and from "
          "the same repository: %s"
          % (len(t), ", ".join("%s@%s" % (i, t[i][0]) for i in sorted(t))))

if rc:
    print("PINS FAIL: if this change is intended, re-record the pins from what was just resolved:")
    print("PINS FAIL:   cp .gate-artifacts/Package.resolved Package.resolved   # then commit it")
sys.exit(rc)
PY
}

# -destination-timeout: xcodebuild looks the device up through CoreSimulator with a timeout of
# its own, and under a loaded host (three booted simulators, ~770 simulator processes, load
# average above 300 on 2026-09-28) that lookup outran the default and the run failed with
# "Unable to find a device matching the provided destination specifier" listing NO simulators
# at all — twice on a device this same script had created, booted and read back seconds
# earlier. The device existed; the question was slow. Ten minutes is the wait a loaded host
# needs; it costs nothing when the host is idle.
# The compile, outside the simulator slot: every scheme and test plan the tests below run is built
# here, against the generic simulator destination, so the slotted span compiles nothing.
s_build() {
  # -onlyUsePackageVersionsFromResolvedFile is the second half of the pins step: that step proves
  # the tracked graph and the resolved graph agree, this makes the build itself unable to resolve
  # its way to anything else. Without it a build is always free to move a pin and say nothing.
  xcodebuild build-for-testing \
    -scheme MemosNG \
    -destination "$GATE_BUILD_DESTINATION" \
    -derivedDataPath "$DERIVED" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation
}

# The tests, inside the slot, on the private device, from the products s_build made.
s_tests() {
  rm -rf "$XCRESULT"
  xcodebuild test-without-building \
    -scheme MemosNG \
    -destination "$GATE_DESTINATION" \
    -destination-timeout 600 \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$XCRESULT" \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation
}
s_xcodebuild() { gate_sim_span s_tests; }

s_bundlecheck() {
  # What ships is the BUNDLE, not the spec that produced it. XcodeGen can be given a resource and
  # still not put it where Apple looks, an INFOPLIST_KEY_ can land as the string "NO" where a
  # Boolean is read, and a deprecated key can survive a deletion in the wrong block — none of
  # which a green build says anything about. So the built product is opened and read.
  #
  # WHERE the product is is asked of xcodebuild rather than spelled out here: the configuration
  # and the product name are the project's to change, and a path written down in this script
  # would then point at nothing and read as a broken build instead of an out-of-date gate.
  # Asked of the generic destination: the device is gone by now, and the answer is the product the
  # compile made, which no device changes.
  local settings="$GATE_WORK/build-settings.json" app appex
  xcodebuild -showBuildSettings -json \
    -scheme MemosNG \
    -destination "$GATE_BUILD_DESTINATION" \
    -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation > "$settings" 2>"$GATE_WORK/build-settings.err" || {
      echo "BUNDLE FAIL: xcodebuild -showBuildSettings failed"
      sed -n '1,20p' "$GATE_WORK/build-settings.err"
      return 1
    }
  cat > "$GATE_WORK/read-product-path.py" <<'PY'
import json, sys

path, target = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
# xcodebuild is free to print package-resolution chatter before the JSON, so the array is found
# rather than assumed to start at byte zero.
start = text.find("[")
if start < 0:
    sys.stderr.write("no JSON array in %s\n" % path)
    sys.exit(1)
try:
    entries, _ = json.JSONDecoder().raw_decode(text[start:])
except ValueError as error:
    sys.stderr.write("build settings do not parse: %s\n" % error)
    sys.exit(1)

for entry in entries:
    if entry.get("target") != target:
        continue
    settings = entry.get("buildSettings", {})
    build_dir = settings.get("TARGET_BUILD_DIR")
    product = settings.get("FULL_PRODUCT_NAME")
    if not build_dir or not product:
        sys.stderr.write("target %s declares no TARGET_BUILD_DIR/FULL_PRODUCT_NAME\n" % target)
        sys.exit(1)
    sys.stderr.write("product path from TARGET_BUILD_DIR + FULL_PRODUCT_NAME (%s / %s)\n"
                     % (build_dir, product))
    print(build_dir.rstrip("/") + "/" + product)
    sys.exit(0)

sys.stderr.write("no build settings for target %s (targets: %s)\n"
                 % (target, ", ".join(sorted(e.get("target", "?") for e in entries))))
sys.exit(1)
PY
  app="$(/usr/bin/python3 "$GATE_WORK/read-product-path.py" "$settings" MemosNG)" \
    || { echo "BUNDLE FAIL: cannot read the product path out of the build settings"; return 1; }
  [ -n "$app" ] || { echo "BUNDLE FAIL: empty product path"; return 1; }
  appex="$app/PlugIns/MemosShare.appex"
  echo "--- built product: $app"
  if [ ! -d "$app" ]; then
    echo "BUNDLE FAIL: no built app at $app"
    echo "    built products present:"
    ls -1 "$DERIVED/Build/Products" 2>&1 | sed 's/^/      /'
    return 1
  fi
  [ -d "$appex" ] || { echo "BUNDLE FAIL: no embedded extension at $appex"; return 1; }
  [ -n "$GATE_MARKETING_VERSION" ] || {
    echo "BUNDLE FAIL: project.yml does not name exactly one MARKETING_VERSION to expect"
    return 1
  }
  # The privacy manifests are judged by a verdict of their own, so its refusals can be fed from
  # tests/gate/privacy-manifest-test.sh without a build; this step only hands it each bundle's file.
  local privacy_verdict="$GATE_TARGET/scripts/privacy-manifest-verdict.py"
  [ -f "$privacy_verdict" ] || { echo "BUNDLE FAIL: $privacy_verdict is missing"; return 1; }
  /usr/bin/python3 - "$app" "$appex" "$GATE_MARKETING_VERSION" "$privacy_verdict" <<'PY'
import plistlib, os, subprocess, sys

app, appex = sys.argv[1], sys.argv[2]
# The expectation comes from project.yml, the one place the version is written.
EXPECTED_SHORT_VERSION = sys.argv[3]
PRIVACY_VERDICT = sys.argv[4]
rc = 0

def fail(msg):
    global rc
    print("BUNDLE FAIL: " + msg)
    rc = 1

def load(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)

def check(label, bundle, bundle_id):
    print("--- %s: %s" % (label, bundle))

    info_path = os.path.join(bundle, "Info.plist")
    if not os.path.isfile(info_path):
        fail("%s has no Info.plist" % label)
        return
    try:
        info = load(info_path)
    except Exception as error:
        fail("%s Info.plist does not parse: %s" % (label, error))
        return

    # Positive control, in the same read: a key that MUST be there. Without it, an "absent"
    # verdict below would only prove the reader came back empty.
    got_id = info.get("CFBundleIdentifier")
    if got_id == bundle_id:
        print("  ok (positive control): CFBundleIdentifier = %s" % got_id)
    else:
        fail("%s CFBundleIdentifier is %r, expected %r — the reader is not reading this bundle"
             % (label, got_id, bundle_id))
        return

    short = info.get("CFBundleShortVersionString")
    if short == EXPECTED_SHORT_VERSION:
        print("  ok: CFBundleShortVersionString = %s" % short)
    else:
        fail("%s CFBundleShortVersionString is %r, expected %r"
             % (label, short, EXPECTED_SHORT_VERSION))

    build = info.get("CFBundleVersion")
    if isinstance(build, str) and build.strip():
        print("  ok: CFBundleVersion = %s" % build)
    else:
        fail("%s CFBundleVersion is %r — an extension without one cannot be installed" % (label, build))

    export = info.get("ITSAppUsesNonExemptEncryption")
    if export is False:
        print("  ok: ITSAppUsesNonExemptEncryption = false (a real Boolean)")
    else:
        fail("%s ITSAppUsesNonExemptEncryption is %r, expected the Boolean false" % (label, export))

    if "UIRequiresFullScreen" in info:
        fail("%s still declares UIRequiresFullScreen, which iOS 26 deprecates" % label)
    else:
        print("  ok: UIRequiresFullScreen absent")

    privacy_path = os.path.join(bundle, "PrivacyInfo.xcprivacy")
    # The verdict names every difference itself; the flush keeps its lines after this bundle's.
    sys.stdout.flush()
    verdict_rc = subprocess.call([sys.executable, PRIVACY_VERDICT, label, privacy_path])
    if verdict_rc != 0:
        fail("%s PrivacyInfo.xcprivacy refused by the privacy verdict (exit %d)" % (label, verdict_rc))

check("app", app, "live.discomarder.memosng")
check("extension", appex, "live.discomarder.memosng.share")

# The Settings app's pane as the BUILT app carries it (MEMNG-781): every key the app reads, in
# order — the three keys that were there before are the positive control, so a reader that came
# back empty fails on them first — and the Storage group as specified: each of its two rows of its
# own control type and title, standing under Storage (a keyed row retyped to a group is no row of
# Storage), the switch off by default, the groups in the order Uploads, Storage, About, and the
# footer that promises the next launch.
SETTINGS_KEYS = ["settings.appearance", "uploadOverMobileData", "settings.mediaCacheSize",
                 "settings.clearMediaCacheOnLaunch", "settings.version"]
STORAGE_ROWS = [("settings.mediaCacheSize", "PSTitleValueSpecifier", "Media cache"),
                ("settings.clearMediaCacheOnLaunch", "PSToggleSwitchSpecifier",
                 "Clear media cache on next launch")]
STORAGE_FOOTER = "Cleared the next time the app opens; the switch then turns off again."
try:
    pane = load(os.path.join(app, "Settings.bundle", "Root.plist"))
    rows = pane.get("PreferenceSpecifiers", [])
    keys = [row.get("Key") for row in rows if row.get("Key")]
    if keys == SETTINGS_KEYS:
        print("--- ok: Settings.bundle keys = %s" % ", ".join(keys))
    else:
        fail("Settings.bundle keys are %r, expected %r" % (keys, SETTINGS_KEYS))
    groups, owner, keyed = [], None, {}
    for row in rows:
        # The group a row stands under is the group BEFORE it: a row that is itself a group
        # stands under the one it follows, and is judged by its type below.
        if row.get("Key"):
            keyed[row.get("Key")] = (row, owner)
        if row.get("Type") == "PSGroupSpecifier":
            owner = row
            groups.append(row.get("Title"))
    for key, kind, title in STORAGE_ROWS:
        if key not in keyed:
            fail("Settings.bundle has no %s row" % key)
            continue
        row, group = keyed[key]
        found = (row.get("Type"), row.get("Title"), group.get("Title") if group else None)
        if found == (kind, title, "Storage"):
            print("--- ok: %s is a %s titled %r and stands under Storage" % (key, kind, title))
        else:
            fail("Settings.bundle %s is %r titled %r under %r, expected %s titled %r under Storage"
                 % ((key,) + found + (kind, title)))
    toggle = keyed.get("settings.clearMediaCacheOnLaunch", ({}, None))[0]
    if toggle.get("DefaultValue") is False:
        print("--- ok: settings.clearMediaCacheOnLaunch defaults to false")
    else:
        fail("Settings.bundle settings.clearMediaCacheOnLaunch defaults to %r, expected false"
             % toggle.get("DefaultValue"))
    order = [groups.index(name) if name in groups else -1 for name in ("Uploads", "Storage", "About")]
    if -1 not in order and order[0] < order[1] < order[2]:
        print("--- ok: Settings.bundle groups %s" % ", ".join(str(name) for name in groups))
    else:
        fail("Settings.bundle groups are %r, expected Uploads, Storage, About in that order"
             % groups)
    storage = [row for row in rows
               if row.get("Type") == "PSGroupSpecifier" and row.get("Title") == "Storage"]
    footers = [row.get("FooterText") for row in storage]
    if footers == [STORAGE_FOOTER]:
        print("--- ok: the Storage footer promises the next launch")
    else:
        fail("Settings.bundle Storage footers are %r, expected [%r]" % (footers, STORAGE_FOOTER))
except Exception as error:
    fail("could not read the built app's Settings.bundle/Root.plist: %s" % error)

# An extension's CFBundleVersion must equal its host's or the host will not install.
try:
    host_build = load(os.path.join(app, "Info.plist")).get("CFBundleVersion")
    ext_build = load(os.path.join(appex, "Info.plist")).get("CFBundleVersion")
    if host_build == ext_build:
        print("--- ok: app and extension share CFBundleVersion %s" % host_build)
    else:
        fail("app CFBundleVersion %r != extension %r" % (host_build, ext_build))
except Exception as error:
    fail("could not compare bundle versions: %s" % error)

sys.exit(rc)
PY
}

# Both halves of the warnings mutation below build the same way; only the tree differs.
build_memos_features() { # $1 = where the build log goes; returns xcodebuild's own exit code
  ( cd Packages/MemosFeatures \
    && xcodebuild build \
         -scheme MemosFeatures \
         -configuration Debug \
         -destination 'generic/platform=iOS Simulator' \
         -derivedDataPath "$GATE_WORK/warnings/MemosFeatures" \
         -clonedSourcePackagesDirPath "$GATE_WORK/warnings/spm" \
         -onlyUsePackageVersionsFromResolvedFile \
         -skipPackagePluginValidation ) > "$1" 2>&1
}

s_warnings() {
  # Every package builds clean or not at all — all five, because a warning that no build makes
  # fatal is a warning nobody retires.
  #
  # Four of them declare macOS as well as iOS, so SwiftPM builds them here on the build host and
  # -warnings-as-errors on the command line is the whole mechanism.
  #
  # MemosFeatures cannot be reached that way. Its screens are UIKit and SwiftUI-on-iOS and SwiftPM
  # has no iOS destination: measured on this host 2026-08-25, `swift build` refuses the package at
  # the manifest platform check, and forcing the compiler across with -Xswiftc -sdk/-target ends in
  # "using sysroot for 'MacOSX' but targeting 'iPhone'". So it is built by xcodebuild for the
  # simulator, and the fatality for that build comes from the target's OWN manifest
  # (.treatAllWarnings(as: .error) in Packages/MemosFeatures/Package.swift) rather than from a flag
  # here. Every setting xcodebuild takes from a command line or an xcconfig reaches the
  # dependencies as well, and each way of asking it for warnings-as-errors fails on somebody
  # else's code: SWIFT_TREAT_WARNINGS_AS_ERRORS=YES alone collides with the -suppress-warnings
  # Xcode gives package dependencies; adding SWIFT_SUPPRESS_WARNINGS=NO makes OpenAPIKit's
  # forced-cast warning this gate's failure; scoping both to the simulator SDK only moves it to
  # MarkdownUI's @_implementationOnly warning. A gate that goes red for a warning nobody here can
  # fix is a gate that gets ignored.
  #
  # Each package is its own root here, so SwiftPM would resolve each one's graph afresh from the
  # manifests' lower bounds — and a new upstream tag then reaches this step alone, past the pins
  # the rest of the gate builds against. It did: three tags published 1–3 Sep 2026 (generator
  # 1.13.1, runtime 1.12.1, http-types 1.7.0) put 192 unused-`public import` diagnostics into the
  # generated client while the pinned xcodebuild had none. So the tracked Package.resolved is
  # placed beside each manifest and the build is refused any version it does not name — the same
  # mechanism as -onlyUsePackageVersionsFromResolvedFile on the test build. SwiftPM accepts a
  # file that pins more packages than the root needs (measured on this host 2026-09-03).
  local rc=0 pkg
  for pkg in Packages/MemosAPI Packages/MemosCore Packages/MemosOutbox Packages/MemosShareKit; do
    echo "--- $pkg with -warnings-as-errors (SwiftPM, this host, tracked pins)"
    cp Package.resolved "$pkg/Package.resolved" || { rc=1; continue; }
    swift build --package-path "$pkg" \
      --scratch-path "$GATE_WORK/warnings/$(basename "$pkg")" \
      --only-use-versions-from-resolved-file \
      -Xswiftc -warnings-as-errors || rc=$?
    rm -f "$pkg/Package.resolved"
  done

  echo "--- Packages/MemosFeatures with warnings as errors (xcodebuild, iOS simulator, Debug)"
  # A one-line pre-check, so a manifest that simply lost the declaration says so plainly instead of
  # through a build log.
  if sed 's|//.*||' Packages/MemosFeatures/Package.swift \
     | grep -q 'treatAllWarnings(as: \.error'; then
    echo "ok (pre-check): MemosFeatures declares .treatAllWarnings(as: .error)"
  else
    echo "WARNAERR FAIL (early hint): Packages/MemosFeatures/Package.swift no longer declares" \
         ".treatAllWarnings(as: .error) — the canary build below is the authority on that"
    rc=1
  fi

  # That text is a hint, and only a hint. A declaration can be commented out, moved onto the test
  # target or conditioned away and the build still exits 0 with its warnings merely printed
  # (measured on this host 2026-08-25). Reading the build LOG for the flag was no better: a source
  # file can print whatever sentence a reader is looking for, and two rounds of review found two
  # more ways to write one. So nothing textual is load-bearing here any more.
  #
  # The proof is a controlled mutation judged by EXIT CODES. The target is built as it stands, and
  # then built again with a throwaway file that holds nothing but warnings. If warnings are fatal,
  # that second build cannot compile — so a canary that SURVIVES is the failure, and no source
  # file can spoof a compiler's refusal to produce an object.
  local mf_build_log="$GATE_WORK/warnings/MemosFeatures-build.log"
  local mf_canary_log="$GATE_WORK/warnings/MemosFeatures-canary.log"
  mkdir -p "$GATE_WORK/warnings"
  # Every source of the target is made to compile again: an incremental build that compiles nothing
  # cannot go red for a warning sitting in a file it skipped.
  find Packages/MemosFeatures/Sources -name '*.swift' -exec touch {} +
  # The same pins as the four builds above: xcodebuild reads a package's resolved file from beside
  # its manifest, and the flag in build_memos_features refuses any version it does not name.
  cp Package.resolved Packages/MemosFeatures/Package.resolved \
    || { echo "WARNAERR FAIL: cannot place the tracked pins beside Packages/MemosFeatures"; return 1; }
  build_memos_features "$mf_build_log"
  local real_rc=$?

  # The canary is written at ONE fixed path, and a file already sitting there is not ours to
  # replace: it would be built as part of the target, and whatever its symbols refer to could fail
  # the canary build for a reason that has nothing to do with warnings — which this step would read
  # as the canary doing its job. So an occupied path stops the step instead.
  local canary_path="$GATE_TARGET/Packages/MemosFeatures/Sources/MemosFeatures/GateWarningsCanary.swift"
  local canary_rc=0
  if [ -e "$canary_path" ] || [ -L "$canary_path" ]; then
    echo "WARNAERR FAIL: something already exists at $canary_path, which is where this step writes"
    echo "               its canary. It is never overwritten — a file of somebody else's failing"
    echo "               that build would read as a warning being fatal. Rename it and run again."
    echo "MemosFeatures build exit $real_rc; the canary build did not run, so this step cannot pass"
    cp "$mf_build_log" .gate-artifacts/MemosFeatures-warnings-build.log
    rm -f Packages/MemosFeatures/Package.resolved
    [ "$rc" -ne 0 ] || rc=1
    return $rc
  fi
  # Named before it is written, so the give-back can take it away even if this shell is killed in
  # the middle of the build below.
  GATE_CANARY_FILE="$canary_path"
  cat > "$GATE_CANARY_FILE" <<'SWIFT'
// Written by the gate for one build and deleted again: proof that a warning in this target cannot
// compile. Two warnings that can never be anything but warnings on their own.
#warning("mac-gate canary: a warning in MemosFeatures must be fatal")

private func gateWarningsCanary() {
    let gateWarningsCanaryValue = 1
}
SWIFT
  build_memos_features "$mf_canary_log"
  canary_rc=$?
  rm -f "$GATE_CANARY_FILE"
  GATE_CANARY_FILE=""
  rm -f Packages/MemosFeatures/Package.resolved

  cp "$mf_build_log" .gate-artifacts/MemosFeatures-warnings-build.log
  cp "$mf_canary_log" .gate-artifacts/MemosFeatures-canary-build.log
  # Diagnostics from the real build, for a human reading a failure. Evidence, not verdict.
  grep -E 'error:|warning:|\*\* BUILD' "$mf_build_log" | tail -15
  echo "MemosFeatures build exit $real_rc; canary build exit $canary_rc (logs in .gate-artifacts)"
  local canary_verdict="$GATE_TARGET/scripts/warnings-canary-verdict.sh"
  if [ -x "$canary_verdict" ]; then
    "$canary_verdict" "$real_rc" "$canary_rc" || rc=1
  else
    echo "WARNAERR FAIL: $canary_verdict is missing or not executable, so the two exit codes"
    echo "               cannot be judged and this step proves nothing"
    rc=1
  fi
  return $rc
}

s_deps() {
  local rc=0 pkg
  for pkg in Packages/*/; do
    [ -f "$pkg/Package.swift" ] || continue
    echo "--- swift package show-dependencies: $pkg (tracked pins)"
    # Listed from the same pins the builds used, so the graph this prints is the graph that built.
    cp Package.resolved "$pkg/Package.resolved" || { rc=1; continue; }
    swift package --package-path "$pkg" --scratch-path "$GATE_WORK/scratch/$(basename "$pkg")" \
      --only-use-versions-from-resolved-file show-dependencies || rc=$?
    rm -f "$pkg/Package.resolved"
  done
  # The dependency rule is a property of the manifests, so it is checked on the manifests, with a
  # positive control in the same run: a grep that finds nothing proves nothing on its own.
  echo "--- dependency rule (Features -> Core -> API) ---"
  if grep -n "MemosCore\|MemosFeatures" Packages/MemosAPI/Package.swift; then
    echo "DEPRULE FAIL: MemosAPI depends on a higher layer"; rc=1
  else
    echo "DEPRULE ok: MemosAPI/Package.swift has no MemosCore/MemosFeatures reference"
  fi
  if grep -n "MemosFeatures" Packages/MemosCore/Package.swift; then
    echo "DEPRULE FAIL: MemosCore depends on MemosFeatures"; rc=1
  else
    echo "DEPRULE ok: MemosCore/Package.swift has no MemosFeatures reference"
  fi
  # The outbox is the durability layer: it must stay buildable and readable on its own, which it
  # only does while it names no other layer of this app at all.
  if grep -n "MemosAPI\|MemosCore\|MemosFeatures" Packages/MemosOutbox/Package.swift; then
    echo "DEPRULE FAIL: MemosOutbox names another layer"; rc=1
  else
    echo "DEPRULE ok: MemosOutbox/Package.swift names no other layer"
  fi
  # The share extension may carry no client, no session and no credential, so the package it
  # takes its logic from may name no layer but the outbox. An extension is a separate process
  # with a fraction of the memory and its own entitlements; whatever it links, it ships.
  if grep -n "MemosAPI\|MemosCore\|MemosFeatures" Packages/MemosShareKit/Package.swift; then
    echo "DEPRULE FAIL: MemosShareKit names a layer the share extension may not carry"; rc=1
  else
    echo "DEPRULE ok: MemosShareKit/Package.swift names no layer but MemosOutbox"
  fi
  if grep -n "MemosCore" Packages/MemosFeatures/Package.swift; then
    echo "DEPRULE ok (positive control): MemosFeatures/Package.swift references MemosCore"
  else
    echo "DEPRULE FAIL: positive control missing — MemosFeatures does not reference MemosCore"; rc=1
  fi
  # Every raw Security call lives in ONE file. A delete whose query names no access group matches
  # items in every group the app can reach, which is how the device credential deleted itself;
  # confining those calls to Keychain.swift, where the access group is not optional, is what makes
  # "every query names its group" checkable instead of habitual. Sources only — a test may plant a
  # corrupt item to prove the wrapper raises on it. Like the dependency rule this is a LITERAL
  # text grep, so no other source file may carry the string at all, comments included: prose
  # elsewhere names the statuses in words.
  echo "--- keychain rule (raw SecItem calls live in Keychain.swift) ---"
  local strays
  strays="$(grep -rl 'SecItem' --include='*.swift' Packages/*/Sources Sources \
    | grep -v '^Packages/MemosCore/Sources/MemosCore/Security/Keychain.swift$')"
  if [ -n "$strays" ]; then
    echo "KEYCHAIN FAIL: the Security call prefix appears outside Keychain.swift:"
    echo "$strays"
    rc=1
  else
    echo "KEYCHAIN ok: no raw SecItem call outside Keychain.swift"
  fi
  if grep -q 'SecItemDelete' Packages/MemosCore/Sources/MemosCore/Security/Keychain.swift; then
    echo "KEYCHAIN ok (positive control): Keychain.swift is where SecItemDelete lives"
  else
    echo "KEYCHAIN FAIL: positive control missing — Keychain.swift has no SecItemDelete"; rc=1
  fi
  return $rc
}

s_sharelink() {
  # SwiftUI's built-in share-link control shares a value it is already holding, so a row built from
  # one can only ever hand over something that exists before the tap — which is how a signed
  # household URL was handed to a recipient instead of the file (MEMNG-207). No test in the
  # Features bundle can tell that control from a Button: SwiftUI exposes no view tree, and the
  # accessibility probe reads the same label either way. So it is held the way the dependency rule
  # and the keychain rule are held, by a literal grep with a positive control in the same run. The
  # arithmetic lives in a script of its own because that script's text must carry the literal, and
  # anything under the checked package may not.
  echo "--- share-link rule (no share-link control in the Features layer) ---"
  local sharelink_rule="$GATE_TARGET/scripts/sharelink-rule.sh"
  if [ -x "$sharelink_rule" ]; then
    "$sharelink_rule" "$GATE_TARGET"
    return $?
  fi
  echo "SHARELINK FAIL: $sharelink_rule is missing or not executable, so the Features layer was"
  echo "                never checked and this step proves nothing"
  return 1
}

s_textsel() {
  # A minted token's plaintext is on screen once, and the Copy button hands it over as a pasteboard
  # item that expires (MEMNG-138). SwiftUI's text-selection modifier reopens the lane it closes: the
  # system's own Copy over the same Text, straight to the general pasteboard, past the expiring
  # write, and over a fragment at that. No test in the Features bundle can see an ABSENT modifier —
  # SwiftUI exposes no view tree and the accessibility probe reads the same label either way — so it
  # is held the way the share-link control's absence is held, by a literal grep with a positive
  # control in the same run. The arithmetic lives in a script of its own for the same reason: that
  # script's text must carry the literal, and the files it checks may not.
  echo "--- text-selection rule (the token management screen's secret is not selectable) ---"
  local textsel_rule="$GATE_TARGET/scripts/textselection-rule.sh"
  if [ -x "$textsel_rule" ]; then
    "$textsel_rule" "$GATE_TARGET"
    return $?
  fi
  echo "TEXTSELECTION FAIL: $textsel_rule is missing or not executable, so the token management"
  echo "                    screen was never checked and this step proves nothing"
  return 1
}

s_buttonstyle() {
  # A card on the token management screen is ONE row of a List, and SwiftUI presses a row's
  # default-styled buttons on a tap anywhere in that row — with several in one row, not necessarily
  # the one under the finger, so a tap on a token's name revoked a different token and a tap on a
  # minted token's plaintext pressed Done and took the one look at it away (MEMNG-476, MEMNG-477).
  # The rule is negative because every positive form of it is satisfied by a style that confines
  # nothing: the screen may not name the plain control type at all, and the house component is the
  # only way to put a control on it. The arithmetic lives in a script of its own for the reason the
  # share-link rule's does: that script's text must carry the literal, and the file it checks may
  # not.
  echo "--- token-screen button rule (every control on that screen goes through the house component) ---"
  local buttonstyle_rule="$GATE_TARGET/scripts/managetokens-buttonstyle-rule.sh"
  if [ -x "$buttonstyle_rule" ]; then
    "$buttonstyle_rule" "$GATE_TARGET"
    return $?
  fi
  echo "BUTTONSTYLE FAIL: $buttonstyle_rule is missing or not executable, so the token management"
  echo "                  screen's controls were never checked and this step proves nothing"
  return 1
}

s_picturelist() {
  # The edit sheet decides the memo's whole picture list — which of its own pictures are kept and
  # in which order — and that decision reaches the server only if the screen hosting the sheet
  # forwards it (MEMNG-457). A host that drops it sends a patch with no list: the removal is shown
  # on the row, the sheet closes, and the memo still holds the picture, with nothing in the app to
  # say so. Neither call site can be reached from a test — both are private functions behind a
  # sheet that does not present under test, taking their session from an environment only a
  # SwiftUI body supplies, which is why the `attaching:` forwarding beside them has no witness
  # either. So it is held the way the share-link rule holds its absence: a literal count with a
  # positive control in the same run, in a script of its own whose text may carry the literals the
  # checked files are counted for.
  echo "--- picture-list forwarding rule (each edit host states the sheet's list exactly once) ---"
  local picturelist_rule="$GATE_TARGET/scripts/picturelist-forwarding-rule.sh"
  if [ -x "$picturelist_rule" ]; then
    "$picturelist_rule" "$GATE_TARGET"
    return $?
  fi
  echo "PICTURELIST FAIL: $picturelist_rule is missing or not executable, so neither host was"
  echo "                  checked and this step proves nothing"
  return 1
}

s_mainbar() {
  # The owner froze the main bottom bar as built on 2.2.1 (41) (ADR-0008, MEMNG-690): one app-drawn
  # capsule hosted once over the tab view, the system bar hidden. Each variant it replaced is one
  # line away from coming back, and the render tests that hold its behaviour can be renamed,
  # disabled or deleted like any other test. So the hosting, the hidden system bar, the absence of
  # the rejected variants, three constants and the names of those tests are held by literal counts
  # with positive controls in the same run, in a script of its own whose text may carry the
  # literals the checked files are counted for.
  echo "--- main-bar freeze rule (the bar as the owner froze it, ADR-0008) ---"
  local mainbar_rule="$GATE_TARGET/scripts/mainbar-freeze-rule.sh"
  if [ -x "$mainbar_rule" ]; then
    "$mainbar_rule" "$GATE_TARGET"
    return $?
  fi
  echo "MAINBAR FAIL: $mainbar_rule is missing or not executable, so the frozen bar was never"
  echo "              checked and this step proves nothing"
  return 1
}

s_refusal() {
  # A refusal is judged where the answer arrives and acted on one or more actor hops later, and in
  # between a renewal can replace the credential it was about. The fix is one typed value carrying
  # the epoch of the credential that EARNED the refusal and one decision taken at the effect
  # (MEMNG-270); what this step adds is that a NEW classification or effect site cannot be added
  # without a reviewer seeing it. Two rules, and they are not equal: rule 1 is a literal grep and a
  # HINT, rule 2 is the fence — pinned entry points and pinned call counts. The arithmetic lives in
  # a script of its own for the reason the share-link rule's does: that script's text must carry the
  # literal, and the scope it checks may not.
  echo "--- refusal-sites rule (one typed refusal, an enumerated set of effects) ---"
  local refusal_rule="$GATE_TARGET/scripts/refusal-sites-rule.sh"
  if [ -x "$refusal_rule" ]; then
    "$refusal_rule" "$GATE_TARGET"
    return $?
  fi
  echo "REFUSAL FAIL: $refusal_rule is missing or not executable, so the refusal sites were never"
  echo "              checked and this step proves nothing"
  return 1
}

s_incarnation() {
  # The senders that run off the main actor check the session's incarnation before each request,
  # never its handle, so the boundary they stop at closes when the incarnation ends — and every
  # site that ends an identity has to end it BEFORE it clears or replaces the handle (MEMNG-435).
  # Ordinary main-actor tasks cannot interleave between the two statements, since nothing there
  # suspends; only the synchronous withdrawal callback runs between them, and the callbacks that
  # exist today do not inspect the handle. So it is held by a script of its own, in the idiom of the
  # refusal-sites rule: the pinned sites in SessionStore.swift, each read in order, with a positive
  # control that every pinned site is still found and is the whole set of handle writers. The
  # controls cover the syntax the rule recognises; a write made through a helper is outside them.
  echo "--- incarnation-order rule (the incarnation ends before the handle is cleared) ---"
  local incarnation_rule="$GATE_TARGET/scripts/incarnation-order-rule.sh"
  if [ -x "$incarnation_rule" ]; then
    "$incarnation_rule" "$GATE_TARGET"
    return $?
  fi
  echo "INCARNATION FAIL: $incarnation_rule is missing or not executable, so the order was never"
  echo "                  checked and this step proves nothing"
  return 1
}

s_apicover() {
  # The generated client's filter is inclusion-only: an operation the config does not name is not
  # generated, no build mentions it, and the first sign is a feature nobody can write. That is the
  # same silence this repo already met from the other side (a nullable union dropped from a
  # generated type), so the subtraction the config is derived from — every operationId in the
  # vendored document minus a named exclusion set — is checked here rather than trusted. The
  # arithmetic lives in a script of its own for the reason the other two rules' does: that script
  # carries the exclusion set and its reasons, and the files it checks may not.
  echo "--- openapi-coverage rule (every vendored operation generated or knowingly excluded) ---"
  local coverage_rule="$GATE_TARGET/scripts/openapi-coverage-rule.sh"
  if [ -x "$coverage_rule" ]; then
    "$coverage_rule" "$GATE_TARGET"
    return $?
  fi
  echo "OPENAPI-COVERAGE FAIL: $coverage_rule is missing or not executable, so the generator's"
  echo "                       filter was never checked and this step proves nothing"
  return 1
}

s_notes() {
  # One notes file is read twice: the TestFlight cut sends the archived build's section as "What to
  # Test", and the app's What's new screen shows the running build's section first (MEMNG-497). A
  # version bump that forgot its notes is otherwise caught only by the cut, after the archive, and
  # the build in between would open What's new on an older build's words. So the first version and
  # build key lines of project.yml must head exactly one section of the file, with the count of
  # sections read as the control, in a script of its own like the rules above.
  echo "--- release-notes rule (project.yml's version and build have their section) ---"
  local notes_rule="$GATE_TARGET/scripts/release-notes-rule.sh"
  if [ -x "$notes_rule" ]; then
    "$notes_rule" "$GATE_TARGET"
    return $?
  fi
  echo "NOTES FAIL: $notes_rule is missing or not executable, so the notes were never checked"
  echo "            against the version and this step proves nothing"
  return 1
}

s_testcount() {
  # Swift Testing does not emit XCTest's "Executed N tests" line (a correct Swift Testing bundle
  # reads 0 there), so the per-bundle counts come from the result bundle, which is authoritative
  # for both harnesses. A bundle that EXECUTED zero cases is a failure: a suite that silently stops
  # being built, or one whose every case skipped itself, would otherwise pass the gate.
  [ -d "$XCRESULT" ] || { echo "no result bundle at $XCRESULT"; return 1; }
  xcrun xcresulttool get test-results tests --path "$XCRESULT" --format json \
    > .gate-artifacts/test-results.json || return 1
  /usr/bin/python3 - "$GATE_TEST_BUNDLES" <<'PY'
import json, sys
wanted = sys.argv[1].split()
data = json.load(open(".gate-artifacts/test-results.json"))

# A case that SKIPPED did not run, and this count exists to answer "did each bundle run anything".
# Several suites here skip themselves when their preconditions are absent (no server credentials,
# no device capability), so a bundle counted by its Test Case NODES reports a full suite while
# having executed nothing — the failure this step was written to catch, passing it. Only the
# outcomes that mean a body executed are counted; everything else — Skipped, and any result this
# walker has never been shown — is counted apart and named. The tuple is the quick mode's counter's,
# kept in step by hand: the two are separate heredocs, and only this one is fed a full-gate result
# bundle.
EXECUTED = ("Passed", "Failed", "Expected Failure")

def walk(node, bundle, ran, idle):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind in ("Unit test bundle", "UI test bundle"):
        bundle = name[:-len(".xctest")] if name.endswith(".xctest") else name
        ran.setdefault(bundle, 0)
        idle.setdefault(bundle, 0)
    if kind == "Test Case" and bundle:
        if node.get("result") in EXECUTED:
            ran[bundle] = ran.get(bundle, 0) + 1
        else:
            idle[bundle] = idle.get(bundle, 0) + 1
    for child in node.get("children", []) or []:
        walk(child, bundle, ran, idle)

ran, idle = {}, {}
for root in data.get("testNodes", []) or []:
    walk(root, None, ran, idle)
print("test counts per bundle: " + (", ".join(f"{k}={v}" for k, v in sorted(ran.items())) or "(none)"))
print("skipped or not run: " + (", ".join(f"{k}={v}" for k, v in sorted(idle.items())) or "(none)"))
# Every run that OBTAINED the counts writes them here before any of them is judged — before the
# loop below and before the shell's comparison — so a run that either one FAILS still hands back
# the file a deliberate reduction is re-recorded from, the shape the pins step's Package.resolved
# copy already has. A run that never obtained counts leaves no candidate and exits non-zero: no
# result bundle returns 1 at the `-d "$XCRESULT"` test, a failing `xcresulttool` returns 1 on its
# own line, and JSON this cannot parse or walk raises here, which exits this block non-zero and is
# handed back as the step's `count_rc`. One row per bundle the gate wanted, in that order, because
# the comparison is per bundle and the baseline is required to name exactly this set.
with open(".gate-artifacts/testcount-baseline.tsv", "w") as candidate:
    for bundle in wanted:
        candidate.write("%s\t%d\n" % (bundle, ran.get(bundle, 0)))

rc = 0
for bundle in wanted:
    n = ran.get(bundle, 0)
    skipped = idle.get(bundle, 0)
    print(f"Executed {n} tests in {bundle}")
    if n < 1:
        print(f"TESTCOUNT FAIL: {bundle} executed {n} test cases ({skipped} skipped or not run)")
        rc = 1
sys.exit(rc)
PY
  local count_rc=$? compare_rc verdict baseline
  verdict="$GATE_TARGET/scripts/testcount-verdict.sh"
  baseline="$GATE_TARGET/tests/gate/testcount-baseline.tsv"
  # Running at all is a floor, not a count: a bundle that lost cases still runs something. The
  # counts just written are judged against the tracked baseline, and both halves are reported
  # before either one decides the step, so a failing count never hides what the comparison said.
  if [ -x "$verdict" ]; then
    "$verdict" .gate-artifacts/testcount-baseline.tsv "$baseline"
    compare_rc=$?
  else
    echo "TESTCOUNT FAIL: $verdict is missing or not executable, so the per-bundle counts were"
    echo "                never compared with the tracked baseline and this step proves nothing"
    compare_rc=1
  fi
  [ "$count_rc" -eq 0 ] || return "$count_rc"
  return "$compare_rc"
}

# --- the quick mode's own sequence ----------------------------------------------------------------
# Everything above this line is the preamble both modes share: the lock check, the work
# directories, the disk sweep, this run's private device and its accessibility keys. From here the
# two part company. The quick sequence lints, generates the project (which is also what puts the
# tracked Package.resolved where SwiftPM reads it), compiles the test bundles, and runs the scope it
# was given on the device — nothing else, and each step only if the one before it passed. It ends by
# exiting, so the full gate's steps below are never reached and MAC_GATE_REMOTE_SUMMARY, the line a
# verdict is read from, is never printed.
if [ "${GATE_QUICK:-0}" -eq 1 ]; then
  QUICK_XCRESULT="$GATE_TARGET/.gate-artifacts/MemosNG-quick.xcresult"
  # One scope, already validated on the controller: --only-testing is passed through verbatim,
  # --bundle is the same thing spelled with a bundle name. Empty means every bundle.
  if [ -n "$GATE_QUICK_ONLY_TESTING" ]; then
    quick_scope="$GATE_QUICK_ONLY_TESTING"
  else
    quick_scope="$GATE_QUICK_BUNDLE"
  fi

  s_quick_generate() {
    [ -f project.yml ] || { echo "no project.yml in $GATE_TARGET — nothing to generate"; return 3; }
    bin/generate.sh --spec project.yml
  }

  s_quick_build() {
    # -onlyUsePackageVersionsFromResolvedFile for the same reason the full gate's test build
    # carries it: a lockfile pins only the builds that READ it, and a quick build free to resolve
    # its own way would compile against a graph nothing in this repo names.
    xcodebuild build-for-testing \
      -scheme MemosNG \
      -destination "$GATE_BUILD_DESTINATION" \
      -derivedDataPath "$DERIVED" \
      -onlyUsePackageVersionsFromResolvedFile \
      -skipPackagePluginValidation 2>&1 | tee .gate-artifacts/quick-build.log
    return "${PIPESTATUS[0]}"
  }

  # The tests run inside the simulator slot, on a device that exists only there.
  s_quick_tests() { gate_sim_span s_quick_tests_on_device; }
  s_quick_tests_on_device() {
    rm -rf "$QUICK_XCRESULT"
    set -- xcodebuild test-without-building \
      -scheme MemosNG \
      -destination "$GATE_DESTINATION" \
      -destination-timeout 600 \
      -derivedDataPath "$DERIVED" \
      -resultBundlePath "$QUICK_XCRESULT" \
      -onlyUsePackageVersionsFromResolvedFile \
      -skipPackagePluginValidation
    [ -z "$quick_scope" ] || set -- "$@" "-only-testing:$quick_scope"
    # Repeat the scope, and stop at the first run that fails: xcodebuild's own exit code then says
    # whether ANY iteration failed, and the counter below checks the result bundle shows them all.
    [ -z "$GATE_QUICK_ITERATIONS" ] || set -- "$@" -test-iterations "$GATE_QUICK_ITERATIONS" -run-tests-until-failure
    "$@" 2>&1 | tee .gate-artifacts/quick-test.log
    quick_run_rc="${PIPESTATUS[0]}"
    # A green run of nothing is the failure this counts for. xcodebuild accepts an -only-testing
    # identifier that names no test and reports success, and Swift Testing emits no "Executed N
    # tests" line to contradict it — so the count comes from the result bundle, the same walk the
    # full gate's testcount step uses, scoped to what was asked for.
    if [ ! -d "$QUICK_XCRESULT" ]; then
      echo "QUICK FAIL: no result bundle at $QUICK_XCRESULT, so nothing says a test ran"
      [ "$quick_run_rc" -ne 0 ] || quick_run_rc=1
      return "$quick_run_rc"
    fi
    if ! xcrun xcresulttool get test-results tests --path "$QUICK_XCRESULT" --format json \
         > .gate-artifacts/quick-test-results.json; then
      echo "QUICK FAIL: the result bundle at $QUICK_XCRESULT could not be read"
      [ "$quick_run_rc" -ne 0 ] || quick_run_rc=1
      return "$quick_run_rc"
    fi
    /usr/bin/python3 - "$quick_scope" "$GATE_QUICK_ITERATIONS" <<'QUICKCOUNT_PY'
import json, sys
scope = sys.argv[1]
iterations = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else 0
bundle = scope.split("/")[0] if scope else ""
data = json.load(open(".gate-artifacts/quick-test-results.json"))

# A case that SKIPPED did not run, and this count exists to answer "did anything run". Several
# suites here skip themselves when their preconditions are absent (no server credentials, no
# device capability), so a scope of nothing but those would otherwise come back green having
# exercised no code at all. Only the outcomes that mean a body executed are counted; everything
# else — Skipped, and any result this walker has never been shown — is counted apart and named.
EXECUTED = ("Passed", "Failed", "Expected Failure")

# Under -test-iterations each run of a case is a "Repetition" child — of the case itself, or of each
# argument set's node for a parameterised one. Every such group is one run of N, and each has to
# show all N: a bundle that ran a case once when N were asked for did not honour the option.
def rep_groups(node):
    children = node.get("children", []) or []
    groups = []
    reps = [c.get("result") for c in children if c.get("nodeType") == "Repetition"]
    if reps:
        groups.append(reps)
    for child in children:
        if child.get("nodeType") not in ("Repetition", "Test Case"):
            groups.extend(rep_groups(child))
    return groups

def walk(node, current, ran, idle, runs):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind in ("Unit test bundle", "UI test bundle"):
        current = name[:-len(".xctest")] if name.endswith(".xctest") else name
        ran.setdefault(current, 0)
        idle.setdefault(current, 0)
    if kind == "Test Case" and current:
        if node.get("result") in EXECUTED:
            ran[current] = ran.get(current, 0) + 1
            runs.append((current, name, rep_groups(node) or [[]]))
        else:
            idle[current] = idle.get(current, 0) + 1
    for child in node.get("children", []) or []:
        walk(child, current, ran, idle, runs)

ran, idle, runs = {}, {}, []
for root in data.get("testNodes", []) or []:
    walk(root, None, ran, idle, runs)
print("executed test cases for the quick scope: "
      + (", ".join("%s=%d" % (k, v) for k, v in sorted(ran.items())) or "(none)"))
print("skipped or not run: "
      + (", ".join("%s=%d" % (k, v) for k, v in sorted(idle.items())) or "(none)"))
executed = ran.get(bundle, 0) if bundle else sum(ran.values())
skipped = idle.get(bundle, 0) if bundle else sum(idle.values())
if executed < 1:
    print("QUICK FAIL: %s executed %d test cases (%d skipped or not run)"
          % (scope or "every bundle", executed, skipped))
    sys.exit(1)
print("Executed %d test cases for %s (%d skipped or not run)"
      % (executed, scope or "every bundle", skipped))
if iterations:
    mine = [r for r in runs if not bundle or r[0] == bundle]
    results = [x for _, _, groups in mine for g in groups for x in g]
    failed = [x for x in results if x not in ("Passed", "Expected Failure")]
    if failed:
        print("QUICK FAIL: %d of %d repetitions failed for %s" % (len(failed), len(results), scope))
        sys.exit(1)
    # Every explicit repetition group is held to N, one included: two runs shown when one was
    # asked for is not the run that was asked for. A case with no repetition nodes at all is the
    # plain single-run shape, so it answers N=1 and nothing more.
    short = ["%s=%d" % (name, len(g)) for _, name, groups in mine for g in groups
             if len(g) != iterations and not (iterations == 1 and len(g) == 0)]
    if short:
        print("QUICK FAIL: asked for %d iterations, the result bundle shows %s"
              % (iterations, ", ".join(short)))
        sys.exit(1)
    print("Ran %d iterations of each of %d executed test cases for %s (%d repetitions, all passed)"
          % (iterations, len(mine), scope, len(results)))
QUICKCOUNT_PY
    if [ $? -ne 0 ] && [ "$quick_run_rc" -eq 0 ]; then quick_run_rc=1; fi
    return "$quick_run_rc"
  }

  quick_tests_rc="-"
  quick_build_rc="-"
  # Lint before anything is generated or compiled: it is the same s_format the full gate runs, it
  # reads nothing a build produces, and a run that stops here costs seconds instead of the minutes
  # a build would spend before failing the merge verdict for a reason already known.
  echo "::: lint :::"
  s_format
  quick_lint_rc=$?
  gate_remote_step_line lint "$quick_lint_rc"
  quick_exit="$quick_lint_rc"
  if [ "$quick_lint_rc" -eq 0 ]; then
    echo "::: generate :::"
    s_quick_generate
    quick_build_rc=$?
    gate_remote_step_line generate "$quick_build_rc"
    if [ "$quick_build_rc" -eq 0 ]; then
      echo "::: build :::"
      s_quick_build
      quick_build_rc=$?
      gate_remote_step_line build "$quick_build_rc"
    fi
    if [ "$quick_build_rc" -eq 0 ]; then
      echo "::: tests${quick_scope:+ ($quick_scope)} :::"
      s_quick_tests
      quick_tests_rc=$?
      gate_remote_step_line tests "$quick_tests_rc"
      quick_exit="$quick_tests_rc"
    else
      echo "::: tests skipped (the build failed) :::"
      quick_exit="$quick_build_rc"
    fi
  else
    echo "::: generate, build and tests skipped (the lint failed) :::"
  fi
  echo "MAC_GATE_QUICK_REMOTE: lint=$quick_lint_rc build=$quick_build_rc tests=$quick_tests_rc"
  exit "$quick_exit"
fi

step xcodegen   s_xcodegen
step entitlements s_entitlements
step swiftformat s_format
step pins       s_pins
step build      s_build
step xcodebuild s_xcodebuild
step bundle     s_bundlecheck
step warnaserr  s_warnings
step deps       s_deps
step refusal    s_refusal
step incarnation s_incarnation
step sharelink  s_sharelink
step textsel    s_textsel
step buttonstyle s_buttonstyle
step picturelist s_picturelist
step mainbar    s_mainbar
step apicover   s_apicover
step notes      s_notes
step testcount  s_testcount

# A failed run removes its own package-rebuild trees (scripts/reap-gate-lanes.sh); it never
# changes the verdict.
gate_drop_failed_rebuilds "$GATE_WORK" "$first_fail"
# The slot went back inside the xcodebuild step, before this line, and said so on its own
# MAC_GATE_SLOT line; the traps only repeat the release.
gate_remote_clock_end
echo "MAC_GATE_REMOTE_SUMMARY:$summary wall=$(gate_remote_wall) | exit=$first_fail"
exit "$first_fail"
REMOTE_EOF
} 9>&- 7>&- | ssh -o BatchMode=yes "$host" 'bash -s' 2>&1 9>&- 7>&- | tee -a "$log" 9>&- 7>&-
remote_rc="${PIPESTATUS[1]}"
record remote "$remote_rc"
# The slot's fields, as the build host printed them after its close. A field that is not a run of
# digits is not repeated as a number: "-" says the run never got as far as the slot.
slot_line="$(sed -n 's/^MAC_GATE_SLOT //p' "$log" | tail -1)"
slot_field() {
  local value
  value="$(printf '%s\n' "$slot_line" | sed -n "s/.*$1=\\([^ ]*\\).*/\\1/p")"
  case "$value" in ''|*[!0-9]*) printf -- '-' ;; *) printf '%s' "$value" ;; esac
}
slot_rc="$(slot_field slot)"
simrelease_rc="$(slot_field simrelease)"
# slot= and simrelease= are codes and take part in the verdict; a "-" is only information.
if [ "$slot_rc" = "-" ]; then SUMMARY_INFO="$SUMMARY_INFO slot=-"; else record slot "$slot_rc"; fi
if [ "$simrelease_rc" = "-" ]; then SUMMARY_INFO="$SUMMARY_INFO simrelease=-"; else record simrelease "$simrelease_rc"; fi
SUMMARY_INFO="$SUMMARY_INFO slot_wait=$(slot_field slot_wait)"

# The quick mode's three numbers come from the line the build host printed, read back out of the log
# the stream above was tee'd into. Anything that is not a run of digits is not a number this
# script will repeat: a remote that stopped before it said anything leaves them all as "-", which is
# the honest answer and cannot be misread as a zero.
if [ "$QUICK" -eq 1 ]; then
  quick_remote_line="$(sed -n 's/^MAC_GATE_QUICK_REMOTE: //p' "$log" | tail -1)"
  quick_field() {
    local value
    value="$(printf '%s\n' "$quick_remote_line" | sed -n "s/.*$1=\\([^ ]*\\).*/\\1/p")"
    case "$value" in
      ''|*[!0-9]*) printf -- '-' ;;
      *) printf '%s' "$value" ;;
    esac
  }
  QUICK_LINT_RC="$(quick_field lint)"
  QUICK_BUILD_RC="$(quick_field build)"
  QUICK_TESTS_RC="$(quick_field tests)"
fi

# --- (7) copy the evidence back ---------------------------------------------------------------
say "--- step: copyback ---"
# Both modes end here, through this one block. The copy lands in a staging folder of this run's,
# never in the artifacts folder itself: what it brings is whatever the build host's folder holds,
# and a remote that stopped before clearing that folder leaves the previous run's there, candidate
# and all. First, every staging folder already present is discarded, one line each. Only a run that
# holds this branch's lane lock gets here, so no run of this branch can be mid-copy into one of them:
# what is present can only be a folder an earlier run abandoned (a shared MAC_GATE_ARTIFACTS across
# branches is outside that). This is why the discard lives here and not at startup, which is reached
# before the lock. A discard that fails is this step's failure. The staging folder is named for this
# run's token, so no other run's copy lands in it, and rsync creates it. Its path goes to the log the
# moment the copy returns, so a signal at any later instant leaves the path named. Then the owner
# script promotes the candidate to the documented path only when the staged `run-token` is this
# run's — the remote writes it on the chain that clears its folder — and moves the rest up either
# way, as evidence. A stamp that is not this run's, or a promotion or deletion that script could not
# carry out, fails the copyback step; the step's code is the first non-zero of the discard's, the
# copy's and the script's. Without the script nothing can tell whose candidate it is, so nothing is
# promoted, the step keeps the codes before it, and the staging folder stays for the next run.
copyback_rc=0
for abandoned in "$artifacts"/incoming-*; do
  [ -e "$abandoned" ] || [ -L "$abandoned" ] || continue
  say "discarding abandoned staging $abandoned from an earlier run"
  if ! rm -rf "$abandoned"; then
    say "copyback: could not remove the abandoned staging $abandoned"
    [ "$copyback_rc" -ne 0 ] || copyback_rc=1
  fi
done
rsync -a -e ssh "$host:$target/.gate-artifacts/" "$artifacts/incoming-$RUN_TOKEN/" 2>&1 9>&- 7>&- | tee -a "$log" 9>&- 7>&-
rsync_rc="${PIPESTATUS[0]}"
[ "$copyback_rc" -ne 0 ] || copyback_rc="$rsync_rc"
staging="$artifacts/incoming-$RUN_TOKEN"
say "copyback: staged in $staging (rsync exit $rsync_rc)"
candidate_owner="$GATE_RUN_COPY/scripts/testcount-candidate-owner.sh"
if [ -x "$candidate_owner" ]; then
  "$candidate_owner" "$staging" "$artifacts" "$RUN_TOKEN" 2>&1 9>&- 7>&- | tee -a "$log" 9>&- 7>&-
  owner_rc="${PIPESTATUS[0]}"
  [ "$copyback_rc" -ne 0 ] || copyback_rc="$owner_rc"
else
  say "testcount candidate: not promoted, $candidate_owner is missing or not executable; $staging is kept"
fi
record copyback "$copyback_rc"
say "artifacts   : $artifacts"

end_run
