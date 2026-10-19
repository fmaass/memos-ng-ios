#!/usr/bin/env bash
#
# The gate's mount step, from bootstrap to exit: bin/mac-gate.sh, unchanged, run against throwaway
# repositories with PATH stubs for ssh and rsync that log every call. The stub serves the build
# host's mount guard (scripts/gate-mount-guard.sh) the answer a case scripts, so what is checked is
# what the gate DOES with that answer:
#   - a refusal ends the run at once with `mount=16 … | exit=16` (and `| exit=16` on the quick
#     line): exactly one ssh call — the guard's — so no preflight mkdir, no admission, no rsync, no
#     slot claimed, no device created and no leftover-device give-back; the run ledger says refused;
#   - an answer that is not exactly one verdict line and one matching state line, a failed ssh, or
#     a guard missing from the run's private copy is a refusal too;
#   - a valid pending marker's `pending:REFUSE` lets the run go on, and `mountguard=` is still on
#     the SUMMARY after the admission has added its own fields.
# The guard itself is held by tests/gate/mount-guard-test.sh; this suite never runs it.
#
# Run it directly (`tests/gate/mount-refusal-path-test.sh`) or let the gate run it: it is one of
# the selftests the gate names. MAC_GATE_SCRIPT points it at another copy of the gate (the mutation
# proofs). Exit: 0 = every case behaved as expected; 1 = at least one did not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }
HELPER="$repo_root/scripts/gate-mount-guard.sh"
[ -r "$HELPER" ] || { echo "FAIL: $HELPER is missing"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-mount-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
# The gates this suite starts never queue behind an estate lock a parent gate holds, and their run
# ledger rows land here rather than in the estate's ledger.
unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_SIMULATOR

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

# The selftests the gate names, read from the gate itself so the fixture stubs exactly that list.
NAMED="$(sed -n 's/^for selftest_name in \(.*\); do$/\1/p' "$GATE")"
if [ "$(printf '%s\n' $NAMED | grep -c -- '-test\.sh$')" -ge 5 ]; then
  ok "the gate's named selftest list was read ($(printf '%s\n' $NAMED | wc -l | tr -d ' ') names) (control)"
else
  bad "no named selftest list could be read from $GATE: [$NAMED]"
fi

# --- the fixture -------------------------------------------------------------------------------------
# A repository shaped like this one in the only ways the local half of the gate reads, with the
# helpers the run's private copy carries over — the mount guard among them unless $2 says "noguard".
new_repo() {
  local name="$1" guard="${2:-guard}" work="$tmp/$1" origin="$tmp/$1.git" stub
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
  [ "$guard" = noguard ] || cp "$HELPER" "$work/scripts/gate-mount-guard.sh" || return 1
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  git -C "$work" checkout --quiet -b fix/mount-case || return 1
  printf 'let two = 2\n' >> "$work/Sources/App.swift"
  git -C "$work" commit --quiet -am "a source change, so this is not a docs-only change set" || return 1
  printf '%s' "$work"
}

# ssh and rsync, replaced. Every call is logged by kind to $STUB_DIR/calls; the mount guard's call
# is known by the line the gate appends to the helper's text, and its script is kept.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
case "$*" in
  *simctl*) echo "ssh simctl" >> "$STUB_DIR/calls"; exit 1 ;;
esac
script="$(cat)"
case "$script" in
  *'
gate_mount_guard report'*)
    echo "ssh mount" >> "$STUB_DIR/calls"
    printf '%s\n' "$script" > "$STUB_DIR/mount-script.txt"
    [ -z "${STUB_MOUNT_ERR:-}" ] || cat "$STUB_MOUNT_ERR" >&2
    [ -z "${STUB_MOUNT_OUT:-}" ] || cat "$STUB_MOUNT_OUT"
    # The signal case: say the call is in flight, then stay in it a while.
    if [ -n "${STUB_MOUNT_SLEEP:-}" ]; then : > "$STUB_DIR/mount-in-flight"; sleep "$STUB_MOUNT_SLEEP"; fi
    exit "${STUB_MOUNT_RC:-0}" ;;
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

# One run of the gate against the stubs: OUT, RC, CALLS and ROW (the run ledger's row) after it.
run_gate() { # $1 = case name, $2 = repo, then the gate's arguments
  local name="$1" work="$2"; shift 2
  CASE_DIR="$tmp/case-$name"
  mkdir -p "$CASE_DIR"
  make_stubs "$CASE_DIR"
  OUT="$(cd "$work" && env -u MAC_GATE_BRANCH \
    "PATH=$CASE_DIR/bin:$PATH" \
    MAC_GATE_HOST=stub-host \
    MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" \
    MAC_GATE_RUNS_LEDGER="$CASE_DIR/gate-runs.tsv" \
    STUB_DIR="$CASE_DIR" \
    STUB_MOUNT_OUT="${STUB_MOUNT_OUT:-}" STUB_MOUNT_RC="${STUB_MOUNT_RC:-0}" \
    STUB_REMOTE_OUT="${STUB_REMOTE_OUT:-}" \
    "$GATE" "$@" 2>&1)"
  RC=$?
  CALLS="$(cat "$CASE_DIR/calls" 2>/dev/null)"
  ROW="$(sed -n '2,$p' "$CASE_DIR/gate-runs.tsv" 2>/dev/null)"
}
summary() { printf '%s\n' "$OUT" | grep -E '^mac-gate SUMMARY: '; }
row_field() { printf '%s\n' "$ROW" | awk -F '\t' -v i="$1" 'NR == 1 { print $i }'; }

answer() { # $1 = file, then its lines
  local f="$1"; shift
  printf '%s\n' "$@" > "$f"
}
REFUSE_LINE="MOUNT REFUSE diskutil info /Users/fabian/build failed (rc 1): not a mounted volume; recovery once the image is mounted correctly: launchctl kickstart -k gui/501/live.discomarder.merkur-build-image"
answer "$tmp/refuse.txt" "$REFUSE_LINE" "mountguard=enforced marker=missing"
answer "$tmp/pending.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid"
answer "$tmp/garbage.txt" "bash: line 1: gate_mount_guard: command not found"
answer "$tmp/mismatch.txt" "$REFUSE_LINE" "mountguard=enforced marker=not-read"
answer "$tmp/two-states.txt" "MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=enforced marker=not-read" "mountguard=pending:OK marker=valid"
answer "$tmp/quoted.txt" "bash: line 9: MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=enforced marker=not-read"
answer "$tmp/pending-missing.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=missing"
answer "$tmp/pending-expired.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=expired"
answer "$tmp/trailing.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid" "something else"
answer "$tmp/trailing-blank.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid" "" ""
answer "$tmp/second-state.txt" "$REFUSE_LINE" "mountguard=pending:REFUSE marker=valid" "mountguard=bogus"
answer "$tmp/ok-refuse-state.txt" "MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=pending:REFUSE marker=valid"
answer "$tmp/enforced-valid.txt" "MOUNT OK uuid=X dev=/dev/disk8s1" "mountguard=enforced marker=valid"
answer "$tmp/healthy.txt" "MOUNT OK uuid=EE4304C8-021C-489D-B57B-6D846E76B1CF dev=/dev/disk8s1" "mountguard=enforced marker=not-read"
answer "$tmp/noise.txt" "Warning: Permanently added 'stub-host' to the list of known hosts."
answer "$tmp/remote.txt" "MAC_GATE_STEP xcodegen 0" "MAC_GATE_REMOTE_SUMMARY: xcodegen=0 xcodebuild=0 | exit=0"

w="$(new_repo guarded)" || { echo "FAIL: cannot build the fixture"; exit 1; }

# A refusal: the run stops at the mount step, having asked the build host one question.
expect_refused() { # $1 = label, $2 = the verdict line pattern (ERE) the run must end with
  local label="$1" verdict="$2" n
  if [ "$RC" -eq 16 ]; then ok "$label: exit 16"; else bad "$label: exit $RC, expected 16"; show "$OUT"; fi
  n="$(printf '%s\n' "$OUT" | grep -cE "$verdict")"
  if [ "$n" -eq 1 ]; then ok "$label: the run ends with $(printf '%s\n' "$OUT" | grep -E "$verdict")"
  else bad "$label: expected one line matching [$verdict], found $n"; show "$OUT"; fi
  if [ "$CALLS" = "ssh mount" ]; then ok "$label: exactly one ssh call, the guard's — no preflight, admission, rsync, slot or device give-back"
  else bad "$label: the build host was called as [$(printf '%s' "$CALLS" | tr '\n' ',')], expected [ssh mount]"; fi
  if [ "$(row_field 8)" = refused ] && [ "$(row_field 9)" = 16 ]; then ok "$label: the run ledger says mode=refused exit=16"
  else bad "$label: the run ledger row says mode=[$(row_field 8)] exit=[$(row_field 9)]"; show "$ROW"; fi
}

# --- 1: the guard refuses (no valid marker) -------------------------------------------------------
STUB_MOUNT_OUT="$tmp/refuse.txt" STUB_MOUNT_RC=16 run_gate refuse "$w"
expect_refused "guard REFUSE, full run" '^mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- \| exit=16$'
if printf '%s\n' "$OUT" | grep -qF "$REFUSE_LINE"; then ok "guard REFUSE: the guard's own reason and recovery command reach the output"
else bad "guard REFUSE: the guard's refusal line is not in the output"; show "$OUT"; fi
s="$(summary)"
case "$s" in
  *rsync=*|*admit=*|*preflight=*) bad "guard REFUSE: the SUMMARY names a step after the mount step: $s" ;;
  *) ok "guard REFUSE: no rsync=, admit= or later field on the SUMMARY" ;;
esac
# What was sent: the helper, byte for byte, then the one call in report mode on this repo's subtrees.
if [ -s "$CASE_DIR/mount-script.txt" ]; then
  sent="$CASE_DIR/mount-script.txt"
  last="$(tail -n 1 "$sent")"
  if [ "$last" = "gate_mount_guard report memos-ng-ios/gate memos-ng-ios/work" ]; then
    ok "the guard is asked in report mode about memos-ng-ios/gate and memos-ng-ios/work"
  else bad "the guard's call is [$last]"; fi
  if head -n "$(wc -l < "$HELPER")" "$sent" | cmp -s - "$HELPER" \
     && [ "$(wc -l < "$sent")" -eq $(( $(wc -l < "$HELPER") + 1 )) ]; then
    ok "the script sent is scripts/gate-mount-guard.sh byte for byte plus that one line"
  else bad "the script sent to the build host is not the helper plus one call"; fi
  if bash -n "$sent" 2>/dev/null; then ok "the script sent parses"; else bad "the script sent does not parse"; fi
else
  bad "the guard's script was never sent"
fi

# --- 2: the same refusal on a quick run --------------------------------------------------------------
STUB_MOUNT_OUT="$tmp/refuse.txt" STUB_MOUNT_RC=16 run_gate refuse-quick "$w" --quick
expect_refused "guard REFUSE, quick run" '^MAC_GATE_QUICK: lint=- build=- tests=- host=stub-host locallint=- \| exit=16$'

# --- 3: answers that are not a well-formed verdict are refusals ---------------------------------------
STUB_MOUNT_OUT="$tmp/garbage.txt" STUB_MOUNT_RC=0 run_gate garbage "$w"
expect_refused "rc 0 without a verdict" '^mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- \| exit=16$'
STUB_MOUNT_OUT="$tmp/mismatch.txt" STUB_MOUNT_RC=0 run_gate mismatch "$w"
expect_refused "rc 0 with MOUNT REFUSE and an enforced state" '^mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- \| exit=16$'
STUB_MOUNT_OUT="$tmp/two-states.txt" STUB_MOUNT_RC=0 run_gate two-states "$w"
expect_refused "rc 0 with two state lines" '^mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- \| exit=16$'
STUB_MOUNT_OUT="$tmp/quoted.txt" STUB_MOUNT_RC=0 run_gate quoted "$w"
expect_refused "rc 0 with the verdict quoted inside another line" '^mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- \| exit=16$'
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=255 run_gate ssh-failed "$w"
expect_refused "a pending answer behind a failed ssh (rc 255)" '^mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- \| exit=16$'

# --- 3b: only the COMPLETE answer counts: two lines, agreeing, pending only with a valid marker -----
R16='^mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- \| exit=16$'
STUB_MOUNT_OUT="$tmp/pending-missing.txt" STUB_MOUNT_RC=0 run_gate pending-missing "$w"
expect_refused "rc 0, REFUSE + pending with marker=missing" "$R16"
STUB_MOUNT_OUT="$tmp/pending-expired.txt" STUB_MOUNT_RC=0 run_gate pending-expired "$w"
expect_refused "rc 0, REFUSE + pending with marker=expired" "$R16"
STUB_MOUNT_OUT="$tmp/trailing.txt" STUB_MOUNT_RC=0 run_gate trailing "$w"
expect_refused "rc 0, a valid pair followed by a garbage line" "$R16"
STUB_MOUNT_OUT="$tmp/trailing-blank.txt" STUB_MOUNT_RC=0 run_gate trailing-blank "$w"
expect_refused "rc 0, a valid pair followed by two blank lines (a third line is a third line)" "$R16"
STUB_MOUNT_OUT="$tmp/second-state.txt" STUB_MOUNT_RC=0 run_gate second-state "$w"
expect_refused "rc 0, a valid pair followed by a second, malformed mountguard= line" "$R16"
STUB_MOUNT_OUT="$tmp/ok-refuse-state.txt" STUB_MOUNT_RC=0 run_gate ok-refuse-state "$w"
expect_refused "rc 0, MOUNT OK with a disagreeing pending:REFUSE state" "$R16"
STUB_MOUNT_OUT="$tmp/enforced-valid.txt" STUB_MOUNT_RC=0 run_gate enforced-valid "$w"
expect_refused "rc 0, MOUNT OK with enforced but marker=valid (the guard never says that)" "$R16"
STUB_MOUNT_ERR="$tmp/noise.txt" STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 run_gate noise "$w"
expect_refused "rc 0, a valid pair with stderr noise mixed in" "$R16"
if printf '%s\n' "$OUT" | grep -qF "Permanently added 'stub-host'"; then ok "the refused answer is quoted in the output, noise included"
else bad "the refused answer was not quoted in the output"; show "$OUT"; fi
STUB_MOUNT_OUT="$tmp/healthy.txt" STUB_MOUNT_RC=0 STUB_REMOTE_OUT="$tmp/remote.txt" run_gate healthy "$w"
case "$(summary)" in
  "mac-gate SUMMARY: selftest=0 classify=0 mount=0 admit=0 "*" mountguard=enforced disk="*" host=stub-host locallint=- | exit=0")
    [ "$RC" -eq 0 ] && ok "the exact healthy pair (MOUNT OK + enforced, not-read) -> mount=0, exit 0" \
      || { bad "the exact healthy pair: exit $RC"; show "$OUT"; } ;;
  *) bad "the exact healthy pair: SUMMARY [$(summary)]"; show "$OUT" ;;
esac

# --- 3c: a signal while the guard's ssh is in flight sends nothing more --------------------------------
CASE_DIR="$tmp/case-signal"; mkdir -p "$CASE_DIR"; make_stubs "$CASE_DIR"
( cd "$w" && exec env -u MAC_GATE_BRANCH "PATH=$CASE_DIR/bin:$PATH" MAC_GATE_HOST=stub-host \
    MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" MAC_GATE_RUNS_LEDGER="$CASE_DIR/gate-runs.tsv" \
    STUB_DIR="$CASE_DIR" STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 STUB_MOUNT_SLEEP=3 \
    "$GATE" ) > "$CASE_DIR/out" 2>&1 &
gate_pid=$!
n=0; while [ ! -e "$CASE_DIR/mount-in-flight" ] && [ "$n" -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
if [ -e "$CASE_DIR/mount-in-flight" ]; then
  kill -TERM "$gate_pid" 2>/dev/null
  wait "$gate_pid"; RC=$?
  CALLS="$(cat "$CASE_DIR/calls" 2>/dev/null)"
  if [ "$RC" -eq 143 ] && [ "$CALLS" = "ssh mount" ]; then
    ok "TERM during the guard's ssh: exit 143 and no further ssh (no device give-back)"
  else bad "TERM during the guard's ssh: exit $RC, calls [$(printf '%s' "$CALLS" | tr '\n' ',')], expected 143 and [ssh mount]"
       show "$(cat "$CASE_DIR/out")"; fi
else
  kill -KILL "$gate_pid" 2>/dev/null; wait "$gate_pid" 2>/dev/null
  bad "the signal case never reached the guard's ssh"; show "$(cat "$CASE_DIR/out")"
fi

# --- 4: a tree without the guard sends nothing and refuses --------------------------------------------
w2="$(new_repo unguarded noguard)" || { echo "FAIL: cannot build the unguarded fixture"; exit 1; }
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 run_gate unguarded "$w2"
if [ "$RC" -eq 16 ] && [ -z "$CALLS" ] \
   && [ "$(summary)" = "mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=- | exit=16" ]; then
  ok "no guard in the run's copy: mount=16, exit 16, and the build host was never called"
else
  bad "no guard in the run's copy: exit $RC, calls [$(printf '%s' "$CALLS" | tr '\n' ',')]"; show "$OUT"
fi

# --- 5: a valid pending marker reports the refusal and the run goes on ---------------------------------
STUB_MOUNT_OUT="$tmp/pending.txt" STUB_MOUNT_RC=0 STUB_REMOTE_OUT="$tmp/remote.txt" run_gate pending "$w"
s="$(summary)"
if [ "$RC" -eq 0 ]; then ok "pending:REFUSE: the run goes on and exits 0"; else bad "pending:REFUSE: exit $RC, expected 0"; show "$OUT"; fi
case "$s" in
  "mac-gate SUMMARY: selftest=0 classify=0 mount=0 admit=0 rsync=0 "*" mountguard=pending:REFUSE disk="*" host=stub-host locallint=- | exit=0")
    ok "pending:REFUSE: mount=0 and mountguard=pending:REFUSE beside the admission's disk= ($s)" ;;
  *) bad "pending:REFUSE: the SUMMARY is [$s]"; show "$OUT" ;;
esac
if [ "$(printf '%s\n' "$CALLS" | head -n 2 | tr '\n' ' ')" = "ssh mount ssh preflight " ]; then
  ok "pending:REFUSE: the guard is the first call, before the preflight"
else bad "pending:REFUSE: the calls began [$(printf '%s' "$CALLS" | tr '\n' ',')]"; fi
if [ "$(row_field 8)" = full ] && [ "$(row_field 9)" = 0 ]; then ok "pending:REFUSE: the run ledger says mode=full exit=0"
else bad "pending:REFUSE: the run ledger row says mode=[$(row_field 8)] exit=[$(row_field 9)]"; fi

echo "mount-refusal-path-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
