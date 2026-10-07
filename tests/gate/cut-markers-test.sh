#!/usr/bin/env bash
# cut-markers-test.sh — holds scripts/release/cut-markers.sh, the ONE site of the build-number proof
# (`prove`) and claim (`claim`) that both TestFlight trains share, to its contract:
#
#   - a claim needs an unspent proof for its exact pair, and spends it by renaming it;
#   - once any spent-<v>-<b>-* exists, neither a proof nor a claim of that pair is ever accepted;
#   - proof and claim run under ONE lock, and `prove` re-checks the spent markers INSIDE it, so a
#     claim that lands between a proof's App Store Connect query and its write makes the write
#     refuse instead of publishing a fresh proof (replayed here deterministically);
#   - two claims racing one proof end with exactly one spent marker and one refusal;
#   - a held lock is waited for, and at the ceiling the refusal names the lock path.
#
# Every case runs against a fixture directory through MEMOSNG_CUT_DIR (never ~/.memosng-cut) and
# holds the lock, when a case needs it held, with flock(1) from a background subshell. Run it
# directly (`tests/gate/cut-markers-test.sh`) or let the gate run it: the controller-side selftest
# step in bin/mac-gate.sh runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case as expected; 1 otherwise.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
cm="$repo_root/scripts/release/cut-markers.sh"
command -v flock >/dev/null 2>&1 || { echo "FAIL: flock(1) is not on PATH; this suite needs it to hold the lock"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-cutmarkers-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
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

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
V=2.2.2
N=43
d=""
case_no=0
fresh() { case_no=$((case_no + 1)); d="$tmp/cut.$case_no"; mkdir -p "$d"; }
# cm_run VERB ARGS…: one call with the fixture dir; output in $out, exit in $rc.
cm_run() {
  out="$(env -u MEMOSNG_CUT_LOCK_WAIT_S MEMOSNG_CUT_DIR="$d" bash "$cm" "$@" 2>&1)"
  rc=$?
}
unused() { if [ -f "$d/unused-$1-$2" ]; then echo 1; else echo 0; fi; }
nspent() { local n=0 f; for f in "$d"/spent-"$1"-"$2"-*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
says() { if printf '%s\n' "$out" | grep -qF -- "$1"; then echo 1; else echo 0; fi; }
# hold / release: a background subshell holds the fixture's lock until released.
hold() {
  rm -f "$tmp/holder.ready" "$tmp/holder.release"
  ( exec 8>>"$d/.lock"; flock 8; : > "$tmp/holder.ready"
    while [ ! -e "$tmp/holder.release" ]; do sleep 0.05; done ) &
  holder_pid=$!
  local i=0
  while [ ! -e "$tmp/holder.ready" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$tmp/holder.ready" ] || fail hold "the holder never took the lock"
}
release() { : > "$tmp/holder.release"; wait "$holder_pid" 2>/dev/null; holder_pid=""; }
# bg NAME VERB ARGS…: a call in the background; its output lands in $tmp/NAME.out, its exit in
# $tmp/NAME.rc. wait_for_waiting NAME: until that call says it is waiting for the lock.
bg() {
  local name="$1"; shift
  ( env -u MEMOSNG_CUT_LOCK_WAIT_S MEMOSNG_CUT_DIR="$d" bash "$cm" "$@" > "$tmp/$name.out" 2>&1
    echo $? > "$tmp/$name.rc" ) &
}
wait_for_waiting() {
  local i=0
  while ! grep -q 'waiting for the lock' "$tmp/$1.out" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  check_eq "$2/is-waiting" 1 "$(grep -c 'waiting for the lock' "$tmp/$1.out" 2>/dev/null)"
}
bg_rc() { local i=0; while [ ! -s "$tmp/$1.rc" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done; cat "$tmp/$1.rc" 2>/dev/null; }

[ -f "$cm" ] || fail script "missing $cm"

# --- usage: the pair becomes a file name, so it is held to the release shape first ---
fresh
cm_run;                              check_eq usage/no-args 2 "$rc"
cm_run prove "$V" "$N";              check_eq usage/prove-without-sha 2 "$rc"
cm_run prove "$V" "$N" "${SHA1:0:12}"; check_eq usage/prove-short-sha 2 "$rc"
cm_run prove 2.2 "$N" "$SHA1";       check_eq usage/bad-version 2 "$rc"
cm_run claim "$V" 43a;               check_eq usage/bad-build 2 "$rc"
cm_run claim "$V/../x" "$N";         check_eq usage/path-in-version 2 "$rc"
cm_run spend "$V" "$N";              check_eq usage/unknown-verb 2 "$rc"
check_eq usage/nothing-written 0 "$(ls "$d" | grep -c .)"
out="$(MEMOSNG_CUT_DIR="$d" MEMOSNG_CUT_LOCK_WAIT_S=x bash "$cm" prove "$V" "$N" "$SHA1" 2>&1)"; rc=$?
check_eq usage/bad-lock-wait 2 "$rc"

# --- a claim without a proof refuses ---
fresh
cm_run claim "$V" "$N"
check_eq claim-unproven/exit 20 "$rc"
check_eq claim-unproven/says 1 "$(says 'no unspent proof')"
check_eq claim-unproven/no-spent 0 "$(nspent "$V" "$N")"

# --- prove -> claim -> prove: a spent number is never proved again ---
fresh
cm_run prove "$V" "$N" "$SHA1"
check_eq prove/exit 0 "$rc"
check_eq prove/format 1 "$(grep -cE "^[0-9]{8}T[0-9]{6}Z $SHA1\$" "$d/unused-$V-$N" 2>/dev/null)"
check_eq prove/one-line 1 "$(wc -l < "$d/unused-$V-$N" 2>/dev/null | tr -d ' ')"
cm_run claim "$V" "$N"
check_eq claim/exit 0 "$rc"
check_eq claim/unused-gone 0 "$(unused "$V" "$N")"
check_eq claim/one-spent 1 "$(nspent "$V" "$N")"
check_eq claim/spent-name 1 "$(ls "$d" | grep -cE "^spent-$V-$N-[0-9]{8}T[0-9]{6}Z\$")"
check_eq claim/spent-keeps-proof 1 "$(cat "$d"/spent-"$V"-"$N"-* 2>/dev/null | grep -c "$SHA1")"
cm_run prove "$V" "$N" "$SHA2"
check_eq reprove/exit 20 "$rc"
check_eq reprove/says-spent 1 "$(says "spent-$V-$N-")"
check_eq reprove/no-unused 0 "$(unused "$V" "$N")"

# --- prove -> prove (one marker, the second overwrites) -> claim -> claim refuses ---
fresh
cm_run prove "$V" "$N" "$SHA1"; check_eq prove-twice/first 0 "$rc"
cm_run prove "$V" "$N" "$SHA2"; check_eq prove-twice/second 0 "$rc"
check_eq prove-twice/one-marker 1 "$(ls "$d" | grep -c "^unused-")"
check_eq prove-twice/latest-sha 1 "$(grep -c "$SHA2" "$d/unused-$V-$N" 2>/dev/null)"
check_eq prove-twice/no-temp-left 0 "$(ls -A "$d" | grep -vcE '^(unused-|spent-|\.lock$)')"
cm_run claim "$V" "$N"; check_eq claim-once/exit 0 "$rc"
cm_run claim "$V" "$N"
check_eq claim-twice/exit 20 "$rc"
check_eq claim-twice/says 1 "$(says 'no unspent proof')"
check_eq claim-twice/one-spent 1 "$(nspent "$V" "$N")"

# --- a pair is its own: neighbours never satisfy or block it (boundary: 4 vs 43) ---
fresh
cm_run prove "$V" 4 "$SHA1"
cm_run claim "$V" "$N"
check_eq neighbour/proof-of-4-is-not-43 20 "$rc"
cm_run claim "$V" 4; check_eq neighbour/claim-4 0 "$rc"
cm_run prove "$V" "$N" "$SHA1"
check_eq neighbour/spent-4-does-not-block-43 0 "$rc"
cm_run claim "$V" "$N"; check_eq neighbour/claim-43 0 "$rc"
cm_run prove "$V" 4 "$SHA1"; check_eq neighbour/spent-4-blocks-4 20 "$rc"
cm_run prove 2.2.3 "$N" "$SHA1"; check_eq neighbour/other-version 0 "$rc"
fresh
printf '20261007T000000Z %s\n' "$SHA1" > "$d/spent-$V-$N-20261007T000000Z"
cm_run prove "$V" 4 "$SHA1"; check_eq neighbour/spent-43-does-not-block-4 0 "$rc"
cm_run claim "$V" 4; check_eq neighbour/spent-43-does-not-block-claim-4 0 "$rc"

# --- a claim refuses while a spent marker exists, even beside a hand-placed proof ---
fresh
printf '20261007T000000Z %s\n' "$SHA1" > "$d/spent-$V-$N-20261007T000000Z"
printf '20261007T000001Z %s\n' "$SHA1" > "$d/unused-$V-$N"
cm_run claim "$V" "$N"
check_eq claim-spent/exit 20 "$rc"
check_eq claim-spent/proof-untouched 1 "$(unused "$V" "$N")"
check_eq claim-spent/still-one-spent 1 "$(nspent "$V" "$N")"

# --- the replayed race (plan Decision 2): a proof's App Store Connect query has answered "no such
# build" and its `prove` is waiting for the lock; meanwhile a claim of the existing proof finishes.
# The waiting `prove` must refuse instead of publishing a fresh proof the claim already consumed.
fresh
printf '20261007T000000Z %s\n' "$SHA1" > "$d/unused-$V-$N"
hold
bg race prove "$V" "$N" "$SHA2"
wait_for_waiting race race
mv "$d/unused-$V-$N" "$d/spent-$V-$N-20261007T000001Z"   # exactly what a finished claim leaves
release
check_eq race/prove-refused 20 "$(bg_rc race)"
check_eq race/no-fresh-proof 0 "$(unused "$V" "$N")"
check_eq race/says-spent 1 "$(grep -c "spent-$V-$N-" "$tmp/race.out")"

# --- a held lock is waited for, then the work is done ---
fresh
hold
bg waits prove "$V" "$N" "$SHA1"
wait_for_waiting waits contended
check_eq contended/not-yet 0 "$(unused "$V" "$N")"
release
check_eq contended/exit 0 "$(bg_rc waits)"
check_eq contended/proved 1 "$(unused "$V" "$N")"

# --- two claims on one proof: exactly one spends it ---
fresh
printf '20261007T000000Z %s\n' "$SHA1" > "$d/unused-$V-$N"
hold
bg claimA claim "$V" "$N"
bg claimB claim "$V" "$N"
wait_for_waiting claimA two-claims-A
wait_for_waiting claimB two-claims-B
release
ra="$(bg_rc claimA)"; rb="$(bg_rc claimB)"
check_eq two-claims/one-won-one-refused "0 20" "$(printf '%s\n%s\n' "$ra" "$rb" | sort -n | paste -sd ' ' -)"
check_eq two-claims/one-spent 1 "$(nspent "$V" "$N")"
check_eq two-claims/no-proof-left 0 "$(unused "$V" "$N")"
check_eq two-claims/loser-says 1 "$(cat "$tmp/claimA.out" "$tmp/claimB.out" | grep -c 'no unspent proof')"
# Unheld, the same race still yields one winner (no harness ordering at all).
fresh
printf '20261007T000000Z %s\n' "$SHA1" > "$d/unused-$V-$N"
bg freeA claim "$V" "$N"; bg freeB claim "$V" "$N"
ra="$(bg_rc freeA)"; rb="$(bg_rc freeB)"
check_eq two-claims-unheld/one-won-one-refused "0 20" "$(printf '%s\n%s\n' "$ra" "$rb" | sort -n | paste -sd ' ' -)"
check_eq two-claims-unheld/one-spent 1 "$(nspent "$V" "$N")"

# --- the ceiling: a lock held past MEMOSNG_CUT_LOCK_WAIT_S refuses, naming the lock path ---
fresh
hold
out="$(MEMOSNG_CUT_DIR="$d" MEMOSNG_CUT_LOCK_WAIT_S=1 bash "$cm" prove "$V" "$N" "$SHA1" 2>&1)"; rc=$?
check_eq ceiling/exit 75 "$rc"
check_eq ceiling/names-lock 1 "$(says "$d/.lock")"
check_eq ceiling/no-proof 0 "$(unused "$V" "$N")"
out="$(MEMOSNG_CUT_DIR="$d" MEMOSNG_CUT_LOCK_WAIT_S=1 bash "$cm" claim "$V" "$N" 2>&1)"; rc=$?
check_eq ceiling-claim/exit 75 "$rc"
release

# --- the default directory is ~/.memosng-cut ---
fh="$tmp/home"
mkdir -p "$fh"
out="$(env -u MEMOSNG_CUT_DIR HOME="$fh" bash "$cm" prove "$V" "$N" "$SHA1" 2>&1)"; rc=$?
check_eq default-dir/exit 0 "$rc"
check_eq default-dir/marker 1 "$( [ -f "$fh/.memosng-cut/unused-$V-$N" ] && echo 1 || echo 0)"

# --- no flock(1) at all: refused, naming the install (skipped where Homebrew's exists) ---
if [ -e /opt/homebrew/bin/flock ]; then
  pass "no-flock/skipped (this host has /opt/homebrew/bin/flock)"
else
  nf="$tmp/noflock"
  mkdir -p "$nf"
  for t in mkdir date mv rm; do ln -s "$(command -v "$t")" "$nf/$t"; done
  fresh
  out="$(env PATH="$nf" MEMOSNG_CUT_DIR="$d" "$(command -v bash)" "$cm" prove "$V" "$N" "$SHA1" 2>&1)"; rc=$?
  check_eq no-flock/exit 3 "$rc"
  check_eq no-flock/names-install 1 "$(says 'brew install flock')"
  check_eq no-flock/no-proof 0 "$(unused "$V" "$N")"
  # control: the same restricted PATH plus flock works, so the refusal above is flock's absence
  ln -s "$(command -v flock)" "$nf/flock"
  out="$(env PATH="$nf" MEMOSNG_CUT_DIR="$d" "$(command -v bash)" "$cm" prove "$V" "$N" "$SHA1" 2>&1)"; rc=$?
  check_eq no-flock/control-with-flock 0 "$rc"
fi

# --- static: bash 3.2 has no {fd} redirection, and the script never prints xtrace ---
if [ -f "$cm" ]; then
  check_eq static/no-named-fd 0 "$(grep -cE '\{[a-z_]+\}[<>]' "$cm")"
  check_eq static/no-xtrace 0 "$(grep -cE 'set -[a-z]*x|bash -x' "$cm")"
  check_eq static/homebrew-fallback 1 "$(grep -c '/opt/homebrew/bin/flock' "$cm" | awk '{print ($1 >= 1)}')"
  check_eq static/parses 0 "$(bash -n "$cm" > /dev/null 2>&1; echo "$?")"
fi

echo "cut-markers-test: $passes passed, $fails failed"
[ "$fails" -eq 0 ] || { echo "CUT-MARKERS-TEST FAIL"; exit 1; }
echo "CUT-MARKERS-TEST ok"
