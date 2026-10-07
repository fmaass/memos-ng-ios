#!/usr/bin/env bash
#
# The release cut scripts (scripts/release/cut-*.sh), run here against shims, never against the
# build host.
#
# They are remote-stdin scripts: a run-cut wrapper ships each one to the build host, where it calls
# fastlane with the release credentials. Two things about them can only be proved by running them.
# First, a cut script started anywhere but the build host must stop before it does anything at all
# (MEMNG-550: cut-0 once ran on the controller and died on a missing credentials file, a VOID run).
# Second, the version and build are arguments, judged against the hands-on clone's project.yml, so
# a train that asks about build 25 while the tree still says 24 stops instead of reading back the
# wrong build (MEMNG-570).
#
# Every run gets a fake HOME holding a fake clone (a real git clone of a throwaway bare repo) and a
# PATH whose front is a shim directory: `hostname` answers what the case says, `fastlane`, `df` and
# `ssh` record their arguments and answer on cue. Nothing here reaches the network, the real HOME or
# any checkout, and every temporary tree is removed on exit.
#
# The scripts put /opt/homebrew/bin ahead of PATH, so on a machine where fastlane lives there the
# real one would answer instead of the shim; this suite refuses to run on such a machine.
#
# Run it directly (`tests/gate/cut-scripts-test.sh`) or let the gate run it: it is picked up by the
# controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
REL="$repo_root/scripts/release"
for s in cut-0-unused cut-1-refresh cut-2-beta cut-3-verify run-cut-0 run-cut-1 run-cut-2 run-cut-3; do
  [ -f "$REL/$s.sh" ] || { echo "FAIL: $REL/$s.sh is missing"; exit 1; }
done
if [ -e /opt/homebrew/bin/fastlane ]; then
  echo "FAIL: /opt/homebrew/bin/fastlane exists and the cut scripts put it ahead of the shim; run this suite off the build host"
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-cutscripts-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0

# --- shims ----------------------------------------------------------------------------------------
shims="$tmp/shims"
mkdir -p "$shims" || exit 1
cat > "$shims/hostname" <<'SH'
#!/bin/sh
echo "${FAKE_HOST:?}"
SH
# fastlane records every call; FAKE_FASTLANE picks the answer. `nosuch`: App Store Connect does not
# hold the pair in FAKE_NOSUCH_FOR, so prove_unused proves it (exit 0) and every read-back lane
# answers the no-such-build sentence (exit 1). `found`: the build exists, so prove_unused refuses.
# The proof's own verdict and its marker are the Fastfile's and scripts/release/cut-markers.sh's
# (tests/gate/cut-markers-test.sh); this shim only stands in for their exit code.
cat > "$shims/fastlane" <<'SH'
#!/bin/sh
echo "$*" >> "${FAKE_CALLS:?}/fastlane"
case "${FAKE_FASTLANE:-ok}" in
  nosuch)
    if [ "$1" = prove_unused ]; then echo "[+] UNUSED: ${FAKE_NOSUCH_FOR:?} is not in App Store Connect; proof written"; exit 0; fi
    echo "[!] ASC read-back FAILED for ${FAKE_NOSUCH_FOR:?}: App Store Connect has no such build"; exit 1 ;;
  found)
    echo "ASC read-back: VALID, IN_BETA_TESTING"
    if [ "$1" = prove_unused ]; then echo "[!] NOT PROVEN UNUSED: the build exists"; exit 1; fi
    exit 0 ;;
  *) exit "${FAKE_FASTLANE_RC:-0}" ;;
esac
SH
# macOS df -g; GNU df has no -g, so the scripts' disk floor reads this instead.
cat > "$shims/df" <<'SH'
#!/bin/sh
echo "Filesystem 1G-blocks Used Available Capacity Mounted"
echo "/dev/disk3s1 460 360 ${FAKE_DF_AVAIL:-100} 79% /"
SH
# ssh runs the remote command line here, the way the remote shell would parse it.
cat > "$shims/ssh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
host="$1"; shift
printf '%s|%s\n' "$host" "$*" >> "${FAKE_CALLS:?}/ssh"
exec bash -c "$*"
SH
chmod 755 "$shims"/*

# --- fake build host clone ------------------------------------------------------------------------
# new_home NAME VERSION BUILD: a HOME whose ~/projects/memos-ng-ios is a clean clone on main with a
# project.yml shaped like the real one — comments naming both keys first (two of them commented-out
# pairs, which read exactly like a pair to an unanchored match), the app target's pair, then a second
# target's pair that must never be the one read.
new_home() {
  local name="$1" v="$2" b="$3" h="$tmp/$1/home"
  mkdir -p "$h/.config" "$tmp/$name/calls" || return 1
  printf 'KEY_ID=not-a-credential\n' > "$h/.config/memosng-ci.env"
  printf '[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$h/.gitconfig"
  HOME="$h" git init -q --bare "$tmp/$name/origin.git" || return 1
  HOME="$h" git clone -q "$tmp/$name/origin.git" "$h/projects/memos-ng-ios" 2>/dev/null || return 1
  write_yml "$h/projects/memos-ng-ios/project.yml" "$v" "$b"
  mkdir -p "$h/projects/memos-ng-ios/bin"
  printf '#!/bin/sh\necho generate >> "${FAKE_CALLS:?}/generate"\nexit "${FAKE_GENERATE_RC:-0}"\n' > "$h/projects/memos-ng-ios/bin/generate.sh"
  chmod 755 "$h/projects/memos-ng-ios/bin/generate.sh"
  ( cd "$h/projects/memos-ng-ios" && HOME="$h" git checkout -q -b main 2>/dev/null; HOME="$h" git add -A \
      && HOME="$h" git commit -qm init && HOME="$h" git push -q origin main 2>/dev/null \
      && HOME="$h" git branch -q --set-upstream-to=origin/main ) || return 1
  printf '%s' "$h"
}
write_yml() { # $1 path, $2 version, $3 build
  cat > "$1" <<YML
targets:
  MemosNG:
    settings:
      base:
        # CURRENT_PROJECT_VERSION from \$CI_BUILD_NUMBER, so that no hand edit is needed here.
        # MARKETING_VERSION: "0.0.1"
        # CURRENT_PROJECT_VERSION: "1"
        MARKETING_VERSION: "$2"
        CURRENT_PROJECT_VERSION: "$3"
  MemosShare:
    settings:
      base:
        MARKETING_VERSION: "9.9.9"
        CURRENT_PROJECT_VERSION: "99"
YML
}

# run_cut HOST HOME SCRIPT [ARGS...]: the remote-stdin form, `bash -s -- ARGS < SCRIPT`.
run_cut() {
  local host="$1" h="$2" script="$3"; shift 3
  rm -f "$h/../calls/"*
  out="$(cd "$tmp" && env HOME="$h" PATH="$shims:$PATH" FAKE_HOST="$host" FAKE_CALLS="$h/../calls" \
    bash -s -- "$@" < "$REL/$script.sh" 2>&1)"
  rc=$?
  fl="$(cat "$h/../calls/fastlane" 2>/dev/null)"
  gen="$(cat "$h/../calls/generate" 2>/dev/null)"
}

# expect LABEL RC FASTLANE-CALLS GENERATE-CALLS [TEXT]: judge the last run_cut. FASTLANE-CALLS is
# the exact recorded argument line (empty = never called); TEXT, when given, must be in the output.
expect() {
  local label="$1" want_rc="$2" want_fl="$3" want_gen="$4" want_text="${5:-}" why=""
  cases=$((cases + 1))
  [ "$rc" = "$want_rc" ] || why="exit $rc, expected $want_rc"
  [ "$fl" = "$want_fl" ] || why="${why:+$why; }fastlane saw '$fl', expected '$want_fl'"
  [ "$gen" = "$want_gen" ] || why="${why:+$why; }generate saw '$gen', expected '$want_gen'"
  if [ -n "$want_text" ] && ! printf '%s\n' "$out" | grep -qF -- "$want_text"; then
    why="${why:+$why; }output lacks '$want_text'"
  fi
  if [ -z "$why" ]; then
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    if [ "$first_fail" -eq 0 ]; then
      case "$rc" in ''|*[!0-9]*|0) first_fail=1 ;; *) first_fail=$rc ;; esac
    fi
    echo "FAIL $label: $why"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

CUTS="cut-0-unused cut-1-refresh cut-2-beta cut-3-verify"
# The proof and claim markers are the Fastfile's now (prove_unused, beta -> cut-markers.sh): the
# shell scripts must never write, move or remove one. plant_proof stands in for a proof that exists.
plant_proof() { mkdir -p "$1/.memosng-cut" && echo "20260927T060000Z 0000000" > "$1/.memosng-cut/unused-$2-$3"; }
clear_proofs() { rm -rf "$1/.memosng-cut"; }
no_markers() { [ ! -e "$1/.memosng-cut" ]; }
# fact LABEL CMD...: one case judged by a command's own status.
fact() {
  local label="$1"; shift
  cases=$((cases + 1))
  if "$@"; then echo "ok   $label"; else
    fails=$((fails + 1)); [ "$first_fail" -ne 0 ] || first_fail=1; echo "FAIL $label"; fi
}
# What an agreeing 2.0.0 (25) run hands on, per script: the fastlane line and the generate marker.
want_fl() { case "$1" in cut-0-unused) echo "prove_unused version:$2 build:$3" ;; cut-3-verify) echo "verify_attach version:$2 build:$3" ;; cut-2-beta) echo beta ;; *) echo "" ;; esac; }
want_gen() { case "$1" in cut-1-refresh) echo generate ;; *) echo "" ;; esac; }
# With fastlane answering 0, prove_unused proved the pair, so every script passes.
want_rc() { echo 0; }

h25="$(new_home t25 2.0.0 25)" || { echo "FAIL: cannot build the fake clone"; exit 1; }
h24="$(new_home t24 1.5.5 24)" || { echo "FAIL: cannot build the fake clone"; exit 1; }

# --- (a) off the build host: exit 2 before anything, even with a pair the tree agrees with --------
for s in $CUTS; do
  run_cut jupiter "$h25" "$s" 2.0.0 25
  expect "$s off-host (jupiter), agreeing pair" 2 "" "" "REFUSED: cut scripts run on the build host merkur, not jupiter"
  # The host is the first question: with no arguments either, the refusal is the host's.
  run_cut merkur.local "$h25" "$s"
  expect "$s off-host (merkur.local is not the short name), no arguments" 2 "" "" "REFUSED: cut scripts run on the build host merkur, not merkur.local"
done

# --- (b) on the build host: the pair is judged before fastlane ------------------------------------
for s in $CUTS; do
  run_cut merkur "$h25" "$s"
  expect "$s no arguments" 2 "" "" "REFUSED: needs <version> <build>"
  run_cut merkur "$h25" "$s" 2.0.0
  expect "$s version without a build" 2 "" "" "REFUSED: needs <version> <build>"
  run_cut merkur "$h25" "$s" 2.0 25
  expect "$s malformed version 2.0" 2 "" "" "REFUSED: needs <version> <build>"
  run_cut merkur "$h25" "$s" 2.0.0 25a
  expect "$s malformed build 25a" 2 "" "" "REFUSED: needs <version> <build>"
  run_cut merkur "$h25" "$s" '2.0.0;true' 25
  expect "$s version carrying a shell word" 2 "" "" "REFUSED: needs <version> <build>"
  run_cut merkur "$h25" "$s" 1.5.5 24
  expect "$s last train's pair against a 2.0.0 (25) tree" 2 "" "" "project.yml says 2.0.0 (25)"
  run_cut merkur "$h25" "$s" 2.0.0 24
  expect "$s build disagrees" 2 "" "" "project.yml says 2.0.0 (25)"
  run_cut merkur "$h25" "$s" 2.0.1 25
  expect "$s version disagrees" 2 "" "" "project.yml says 2.0.0 (25)"
  run_cut merkur "$h25" "$s" 9.9.9 99
  expect "$s the second target's pair is not the app's" 2 "" "" "project.yml says 2.0.0 (25)"
  run_cut merkur "$h25" "$s" 2.0.0 25
  expect "$s agreeing pair 2.0.0 25" "$(want_rc "$s")" "$(want_fl "$s" 2.0.0 25)" "$(want_gen "$s")"
  run_cut merkur "$h24" "$s" 1.5.5 24
  expect "$s agreeing pair 1.5.5 24 (build 24's behaviour)" "$(want_rc "$s")" "$(want_fl "$s" 1.5.5 24)" "$(want_gen "$s")"
done
# cut-0 and cut-3 hand fastlane's own exit code on: cut-3 as its exit, cut-0 into its verdict.
FAKE_FASTLANE_RC=7 run_cut merkur "$h25" cut-3-verify 2.0.0 25
expect "cut-3-verify passes fastlane's exit code on" 7 "verify_attach version:2.0.0 build:25" "" "verify_rc=7"

# cut-1 judges the tree AFTER its pull: a clone still at 24 whose origin moved to 25 is at 25.
hpull="$(new_home pull 2.0.0 24)" || { echo "FAIL: cannot build the fake clone"; exit 1; }
( other="$tmp/pull/other" && HOME="$hpull" git clone -q "$tmp/pull/origin.git" "$other" 2>/dev/null \
    && write_yml "$other/project.yml" 2.0.0 25 && cd "$other" && HOME="$hpull" git commit -qam bump \
    && HOME="$hpull" git push -q origin main 2>/dev/null ) || { echo "FAIL: cannot move the fake origin"; exit 1; }
run_cut merkur "$hpull" cut-1-refresh 2.0.0 25
expect "cut-1-refresh reads project.yml after its pull" 0 "" generate "generate_rc=0"

# The original stops stay where they were.
printf 'x\n' > "$h25/projects/memos-ng-ios/stray"
run_cut merkur "$h25" cut-2-beta 2.0.0 25
expect "cut-2-beta dirty clone" 11 "" "" "CLONE DIRTY"
rm -f "$h25/projects/memos-ng-ios/stray"
FAKE_DF_AVAIL=2 run_cut merkur "$h25" cut-2-beta 2.0.0 25
expect "cut-2-beta disk floor" 14 "" "" "DISK FLOOR: 2 GiB free, need 3"

# --- (c) cut-0's verdict is prove_unused's exit code: 0 = UNUSED, anything else = 20 -------------
clear_proofs "$h25"
FAKE_FASTLANE=nosuch FAKE_NOSUCH_FOR="2.0.0 (25)" run_cut merkur "$h25" cut-0-unused 2.0.0 25
expect "cut-0 prove_unused proves 2.0.0 (25)" 0 "prove_unused version:2.0.0 build:25" "" "UNUSED: 2.0.0 (25) is not in App Store Connect"
fact "  ...and the script itself writes no marker (the Fastfile's cut-markers.sh does)" no_markers "$h25"
FAKE_FASTLANE=nosuch FAKE_NOSUCH_FOR="1.5.5 (24)" run_cut merkur "$h24" cut-0-unused 1.5.5 24
expect "cut-0 prove_unused proves 1.5.5 (24)" 0 "prove_unused version:1.5.5 build:24" "" "UNUSED: 1.5.5 (24) is not in App Store Connect"
FAKE_FASTLANE=found run_cut merkur "$h25" cut-0-unused 2.0.0 25
expect "cut-0 the build exists" 20 "prove_unused version:2.0.0 build:25" "" "NOT PROVEN UNUSED"
FAKE_FASTLANE=ok FAKE_FASTLANE_RC=1 run_cut merkur "$h25" cut-0-unused 2.0.0 25
expect "cut-0 prove_unused refuses (a spent claim, an API error)" 20 "prove_unused version:2.0.0 build:25" "" "NOT PROVEN UNUSED"
FAKE_FASTLANE=ok FAKE_FASTLANE_RC=20 run_cut merkur "$h25" cut-0-unused 2.0.0 25
expect "cut-0 any non-zero is 20" 20 "prove_unused version:2.0.0 build:25" "" "prove_rc=20"
fact "  ...and no refusal leaves a marker behind" no_markers "$h25"
# The read-back lane is still cut-3's; its no-such-build answer is a failure there.
FAKE_FASTLANE=nosuch FAKE_NOSUCH_FOR="2.0.0 (25)" run_cut merkur "$h25" cut-3-verify 2.0.0 25
expect "cut-3 hands the read-back's exit on" 1 "verify_attach version:2.0.0 build:25" "" "verify_rc=1"

# --- (e) the claim is beta's: cut-2 reaches beta whatever the markers say, and never touches them -
clear_proofs "$h25"
run_cut merkur "$h25" cut-2-beta 2.0.0 25
expect "cut-2 without a proof marker still hands the claim to beta" 0 beta "" "beta end"
fact "  ...and makes no marker" no_markers "$h25"
plant_proof "$h25" 2.0.0 25
FAKE_FASTLANE_RC=1 run_cut merkur "$h25" cut-2-beta 2.0.0 25
expect "cut-2 hands beta's refusal (no unspent proof, a failed upload) on" 1 beta "" "fastlane_rc=1"
fact "  ...and leaves a planted proof where it was" test -f "$h25/.memosng-cut/unused-2.0.0-25"
fact "  ...unspent" sh -c '! ls "$1"/.memosng-cut/spent-* >/dev/null 2>&1' _ "$h25"
clear_proofs "$h25"

# cut-1: a failed generate stops the train at once; nothing after it runs.
FAKE_GENERATE_RC=42 run_cut merkur "$h25" cut-1-refresh 2.0.0 25
expect "cut-1 with a failing generate" 14 "" generate "generate_rc=42"
fact "  ...and stops before the disk line" sh -c '! printf "%s\n" "$1" | grep -q avail_GiB' _ "$out"

# --- (d) the wrappers: the pair travels after --, the log is private, the marker carries the rc ---
logs="$tmp/logs"
mkdir -p "$logs"
wrap() { # $1 N, then the wrapper's arguments; FAKE_HOST=merkur is what the "remote" end sees.
  local n="$1"; shift
  rm -f "$h25/../calls/"* "$logs"/*
  out="$(cd "$tmp" && env HOME="$h25" PATH="$shims:$PATH" FAKE_HOST=merkur FAKE_CALLS="$h25/../calls" \
    CUT_LOG_DIR="$logs" FAKE_FASTLANE=nosuch FAKE_NOSUCH_FOR="2.0.0 (25)" \
    bash "$REL/run-cut-$n.sh" "$@" 2>&1)"
  rc=$?
  fl="$(cat "$h25/../calls/fastlane" 2>/dev/null)"
  gen="$(cat "$h25/../calls/generate" 2>/dev/null)"
}
for n in 0 1 2 3; do
  case $n in 0) s=cut-0-unused ;; 1) s=cut-1-refresh ;; 2) s=cut-2-beta ;; 3) s=cut-3-verify ;; esac
  wrap $n 2.0.0 25
  # The fastlane shim answers "no such build" with exit 1, which cut-2 and cut-3 hand straight on.
  wfl="$(want_fl $s 2.0.0 25)"; case $n in 2|3) wrc=1 ;; *) wrc=0 ;; esac
  expect "run-cut-$n.sh 2.0.0 25 reaches $s on the build host" $wrc "$wfl" "$(want_gen $s)" "rc=$wrc log=$logs/cut-$n-2.0.0-25-"
  cases=$((cases + 1)); why=""
  [ "$(cat "$h25/../calls/ssh" 2>/dev/null)" = "merkur.local|bash -s -- 2.0.0 25" ] || why="ssh saw '$(cat "$h25/../calls/ssh" 2>/dev/null)'"
  log="$(ls "$logs"/cut-$n-2.0.0-25-* 2>/dev/null)"
  [ -n "$log" ] && [ -n "$(find "$log" -perm 0600 2>/dev/null)" ] || why="${why:+$why; }log '$log' missing or not mode 600"
  [ "$(cat "$logs/cut-$n.done" 2>/dev/null)" = "$wrc $log" ] || why="${why:+$why; }cut-$n.done reads '$(cat "$logs/cut-$n.done" 2>/dev/null)'"
  if [ $n = 0 ] && ! grep -qF "UNUSED: 2.0.0 (25) is not in App Store Connect" "$log" 2>/dev/null; then why="${why:+$why; }log lacks the UNUSED line"; fi
  if [ -z "$why" ]; then echo "ok   run-cut-$n.sh ssh line, private log, done marker"; else
    fails=$((fails + 1)); [ "$first_fail" -ne 0 ] || first_fail=1; echo "FAIL run-cut-$n.sh: $why"; fi
  wrap $n '2.0.0 25;true' 25
  expect "run-cut-$n.sh refuses a malformed pair before ssh" 2 "" "" "REFUSED: usage: run-cut-$n.sh"
  [ ! -e "$h25/../calls/ssh" ] || { fails=$((fails + 1)); [ "$first_fail" -ne 0 ] || first_fail=1; echo "FAIL run-cut-$n.sh called ssh on a malformed pair"; }
done
rm -f "$h25/../calls/"*
out="$(cd "$tmp" && env -u CUT_LOG_DIR HOME="$h25" PATH="$shims:$PATH" FAKE_CALLS="$h25/../calls" bash "$REL/run-cut-0.sh" 2.0.0 25 2>&1)"; rc=$?
fl=""; gen=""
# Judged as one fact: a non-zero exit AND no ssh call; either alone is not the refusal.
if [ "$rc" -ne 0 ] && [ ! -e "$h25/../calls/ssh" ]; then rc=refused; fi
expect "run-cut-0.sh without CUT_LOG_DIR stops before ssh" refused "" "" "CUT_LOG_DIR"

# Two runs in the same second (a retry racing the first, or two lanes) keep two logs: the clock is
# pinned by a date shim, so a log named by the second alone would be one file truncated twice.
mkdir -p "$tmp/samesecond"
printf '#!/bin/sh\necho 20260927T060000Z\n' > "$tmp/samesecond/date"
chmod 755 "$tmp/samesecond/date"
rm -f "$h25/../calls/"* "$logs"/*
for _ in 1 2; do
  ( cd "$tmp" && env HOME="$h25" PATH="$tmp/samesecond:$shims:$PATH" FAKE_HOST=merkur FAKE_CALLS="$h25/../calls" \
      CUT_LOG_DIR="$logs" FAKE_FASTLANE=nosuch FAKE_NOSUCH_FOR="2.0.0 (25)" \
      bash "$REL/run-cut-0.sh" 2.0.0 25 >/dev/null 2>&1 )
done
cases=$((cases + 1))
n_logs=0 n_full=0
for f in "$logs"/cut-0-2.0.0-25-*; do
  [ -f "$f" ] || continue
  n_logs=$((n_logs + 1))
  if grep -qF "UNUSED: 2.0.0 (25)" "$f"; then n_full=$((n_full + 1)); fi
done
if [ "$n_logs" = 2 ] && [ "$n_full" = 2 ]; then echo "ok   run-cut-0.sh twice in one second keeps two whole logs"; else
  fails=$((fails + 1)); [ "$first_fail" -ne 0 ] || first_fail=1
  echo "FAIL run-cut-0.sh twice in one second: $n_logs log(s), $n_full holding the verdict, expected 2 and 2"; fi

# --- verdict --------------------------------------------------------------------------------------
echo "gate cut scripts: $((cases - fails)) of $cases cases as expected"
[ "$fails" -eq 0 ] || { echo "CUT-SCRIPTS-TEST FAIL: $fails case(s) misjudged"; exit "$first_fail"; }
echo "CUT-SCRIPTS-TEST ok"
