#!/usr/bin/env bash
#
# The gate's local lint, from bootstrap to exit (MEMNG-807): bin/mac-gate.sh run against throwaway
# repositories that carry scripts/local-lint.sh, with a fake `swift` on PATH that answers the lint
# the way a case scripts, and PATH stubs for ssh, rsync and docker that log every call. What is
# checked is what the gate DOES with the local verdict:
#   - a lint failure ends the run before the estate lock is requested and before the lane lock:
#     exit 1, no ssh and no rsync at all, `locallint=1` on the SUMMARY (and on the quick line), the
#     lint's own error lines and MAC_GATE_LOCALLINT in the run's log, and the run ledger says
#     refused, with no estate-lock stamps — while another process holds that very lock;
#   - a pass (`locallint=0`) and a fall-through (`locallint=-`) let the run go on as before, the
#     first having linted before it queued for the lock;
#   - the lint is of the caller's repository root, wherever in it the gate is started;
#   - --classify-only, --help and a run without MAC_GATE_HOST never lint.
# The helper itself is held by tests/gate/local-lint-test.sh.
#
# Run it directly (`tests/gate/local-lint-refusal-path-test.sh`) or let the gate run it: it is one
# of the selftests the gate names. MAC_GATE_SCRIPT points it at another copy of the gate (the
# mutation proofs). Exit: 0 = every case behaved as expected; 1 = at least one did not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }
HELPER="$repo_root/scripts/local-lint.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-locallint-path-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
holder_pid=""
cleanup() {
  [ -z "$holder_pid" ] || kill "$holder_pid" 2>/dev/null
  rm -rf "${tmp:?}"
}
trap cleanup EXIT
# The gates this suite starts never queue behind an estate lock a parent gate holds; the one this
# suite hands them is its own.
unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_SIMULATOR

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

[ -r "$HELPER" ] && ok "scripts/local-lint.sh is present (control)" || bad "$HELPER is missing"

NAMED="$(sed -n 's/^for selftest_name in \(.*\); do$/\1/p' "$GATE")"
if [ "$(printf '%s\n' $NAMED | grep -c -- '-test\.sh$')" -ge 5 ]; then
  ok "the gate's named selftest list was read ($(printf '%s\n' $NAMED | wc -l | tr -d ' ') names) (control)"
else
  bad "no named selftest list could be read from $GATE: [$NAMED]"
fi

# --- the fixture -------------------------------------------------------------------------------------
new_repo() { # $1 = name, $2 = lint|nolint (whether the tree carries scripts/local-lint.sh)
  local name="$1" with="${2:-lint}" work="$tmp/$1" origin="$tmp/$1.git" stub
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
  [ "$with" = nolint ] || cp "$HELPER" "$work/scripts/local-lint.sh" || return 1
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  git -C "$work" checkout --quiet -b fix/lint-case || return 1
  printf 'let two = 2\n' >> "$work/Sources/App.swift"
  git -C "$work" commit --quiet -am "a source change, so this is not a docs-only change set" || return 1
  printf '%s' "$work"
}

# ssh, rsync, docker and swift, replaced. ssh answers the mount guard with a refusal, so a run that
# gets past the local lint stops at the mount step (exit 16) having called the host exactly once.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
script="$(cat)"
case "$script" in
  *'
gate_mount_guard report'*)
    echo "ssh mount" >> "$STUB_DIR/calls"
    printf '%s\n' "MOUNT REFUSE stub: not the image" "mountguard=enforced marker=missing"
    exit 16 ;;
esac
echo "ssh other" >> "$STUB_DIR/calls"
exit 0
SSH_EOF
  cat > "$dir/bin/rsync" <<'RSYNC_EOF'
#!/usr/bin/env bash
echo "rsync" >> "$STUB_DIR/calls"
exit 0
RSYNC_EOF
  # Shadows a real docker, so the fall-through case is the same on every machine.
  cat > "$dir/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_DIR/docker-calls"
exit 1
DOCKER_EOF
  cat > "$dir/bin/swift" <<'SWIFT_EOF'
#!/usr/bin/env bash
case "$*" in
  "format --version")
    [ "${STUB_SWIFT:-}" = absent ] && exit 127
    echo "6.3.3"; exit 0 ;;
  "format lint --strict --recursive .")
    printf 'lint cwd=%s\n' "$PWD" >> "$STUB_DIR/swift-calls"
    echo "lint" >> "$STUB_DIR/order"
    [ -z "${STUB_LINT_OUT:-}" ] || printf '%s\n' "$STUB_LINT_OUT" >&2
    exit "${STUB_LINT_RC:-0}" ;;
esac
echo "swift $*" >> "$STUB_DIR/swift-calls"
exit 64
SWIFT_EOF
  chmod +x "$dir/bin/ssh" "$dir/bin/rsync" "$dir/bin/docker" "$dir/bin/swift"
}

# One run of the gate against the stubs: OUT, RC, CALLS, SWIFT_CALLS, ROW and LOG afterwards. The
# estate lock is this case's own file; LOCK_HELD=1 has another process hold it for the whole run.
run_gate() { # $1 = case name, $2 = the directory to start in, then the gate's arguments
  local name="$1" start="$2"; shift 2
  CASE_DIR="$tmp/case-$name"
  mkdir -p "$CASE_DIR"
  make_stubs "$CASE_DIR"
  local t0 t1
  t0="$(date +%s)"
  OUT="$(cd "$start" && env -u MAC_GATE_BRANCH \
    "PATH=$CASE_DIR/bin:$PATH" \
    MAC_GATE_HOST=stub-host \
    MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" \
    MAC_GATE_RUNS_LEDGER="$CASE_DIR/gate-runs.tsv" \
    MAC_GATE_ESTATE_LOCK="${ESTATE_LOCK:-$CASE_DIR/estate.lock}" \
    STUB_DIR="$CASE_DIR" STUB_LINT_RC="${STUB_LINT_RC:-0}" STUB_LINT_OUT="${STUB_LINT_OUT:-}" \
    STUB_SWIFT="${STUB_SWIFT:-}" \
    timeout 120 "$GATE" "$@" 2>&1)"
  RC=$?
  t1="$(date +%s)"
  SECS=$((t1 - t0))
  CALLS="$(cat "$CASE_DIR/calls" 2>/dev/null)"
  SWIFT_CALLS="$(cat "$CASE_DIR/swift-calls" 2>/dev/null)"
  ROW="$(sed -n '2,$p' "$CASE_DIR/gate-runs.tsv" 2>/dev/null)"
  LOG="$(ls "$CASE_DIR/artifacts"/mac-gate-*.log 2>/dev/null | head -1)"
}
summary() { printf '%s\n' "$OUT" | grep -E '^mac-gate SUMMARY: '; }
quick()   { printf '%s\n' "$OUT" | grep -E '^MAC_GATE_QUICK: '; }
row_field() { printf '%s\n' "$ROW" | awk -F '\t' -v i="$1" 'NR == 1 { print $i }'; }
in_log()  { [ -n "$LOG" ] && grep -qF -- "$1" "$LOG"; }

# Holds a lock file from another process until release_lock; the holder writes "released" to the
# order file of the case named in $2 just before it lets go.
hold_lock() { # $1 = lock file, $2 = order file
  : > "$tmp/holding"
  rm -f "$tmp/holding" "$tmp/release"
  ( exec 8>>"$1"; flock 8 || exit 1; : > "$tmp/holding"
    n=0; while [ ! -e "$tmp/release" ] && [ "$n" -lt 1200 ]; do sleep 0.1; n=$((n + 1)); done
    echo "released" >> "$2" ) &
  holder_pid=$!
  n=0; while [ ! -e "$tmp/holding" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  [ -e "$tmp/holding" ]
}
release_lock() { : > "$tmp/release"; wait "$holder_pid" 2>/dev/null; holder_pid=""; }

ERR_LINE="Sources/App.swift:1:101: error: [LineLength] line is too long"
w="$(new_repo linted)" || { echo "FAIL: cannot build the fixture"; exit 1; }

# --- 1: a lint failure refuses before the estate lock, while another process holds that lock --------
lock1="$tmp/estate-1.lock"
mkdir -p "$tmp/case-refuse/artifacts"
# A candidate another run of this worktree is still promoting: this run never took the estate lock
# that serialises its removal, so it must leave the file exactly as it was.
printf 'MemosCoreTests\t999\nanother run\t1\n' > "$tmp/case-refuse/artifacts/testcount-baseline.tsv"
cp "$tmp/case-refuse/artifacts/testcount-baseline.tsv" "$tmp/candidate-before.tsv"
if hold_lock "$lock1" "$tmp/case-refuse/order"; then ok "another process holds the estate lock (control)"
else bad "the lock holder never took the lock"; fi
ESTATE_LOCK="$lock1" STUB_LINT_RC=1 STUB_LINT_OUT="$ERR_LINE" run_gate refuse "$w"
release_lock
if [ "$RC" -eq 1 ]; then ok "lint failure: exit 1, the lint's own code"; else bad "lint failure: exit $RC, expected 1"; show "$OUT"; fi
if cmp -s "$tmp/candidate-before.tsv" "$tmp/case-refuse/artifacts/testcount-baseline.tsv"; then
  ok "lint failure: a test-count candidate present before the run is byte-identical after it (no lock, nothing cleared)"
else bad "lint failure: the candidate at the documented path was removed or changed by a run that held no estate lock"; fi
if [ "$(summary)" = "mac-gate SUMMARY: host=stub-host locallint=1 | exit=1" ]; then ok "lint failure: the run ends with 'mac-gate SUMMARY: host=stub-host locallint=1 | exit=1'"
else bad "lint failure: SUMMARY [$(summary)]"; show "$OUT"; fi
if [ -z "$CALLS" ]; then ok "lint failure: no ssh and no rsync — the build host was never contacted"
else bad "lint failure: the build host was called as [$(printf '%s' "$CALLS" | tr '\n' ',')]"; fi
if [ "$SECS" -lt 60 ]; then ok "lint failure: refused in ${SECS}s while the estate lock was held elsewhere — it never queued"
else bad "lint failure: took ${SECS}s with the lock held elsewhere (it waited for the lock)"; fi
if in_log "$ERR_LINE" && in_log "MAC_GATE_LOCALLINT rc=1 local=native version=6.3.3 mac=6.3.0"; then
  ok "lint failure: the lint's error line and MAC_GATE_LOCALLINT rc=1 (both versions) are in the run's log"
else bad "lint failure: the run's log ($LOG) lacks the error line or the MAC_GATE_LOCALLINT line"; show "$OUT"; fi
if [ -n "$LOG" ] && ! grep -q 'lock_requested=\|lock_acquired=' "$LOG" && grep -q 'locallint' "$LOG"; then
  ok "lint failure: no estate-lock stamp in the log (control: the log names locallint)"
else bad "lint failure: the log carries an estate-lock stamp, or no log"; fi
if [ "$(row_field 8)" = refused ] && [ "$(row_field 9)" = 1 ] && [ "$(row_field 1)" = - ] && [ "$(row_field 2)" = - ]; then
  ok "lint failure: the run ledger says mode=refused exit=1, lock_requested=- lock_acquired=-"
else bad "lint failure: the row says mode=[$(row_field 8)] exit=[$(row_field 9)] lock=[$(row_field 1)][$(row_field 2)]"; show "$ROW"; fi

# --- 2: the same on a quick run ------------------------------------------------------------------------
STUB_LINT_RC=1 STUB_LINT_OUT="$ERR_LINE" run_gate refuse-quick "$w" --quick
if [ "$RC" -eq 1 ] && [ "$(quick)" = "MAC_GATE_QUICK: lint=- build=- tests=- host=stub-host locallint=1 | exit=1" ] && [ -z "$CALLS" ]; then
  ok "lint failure, quick: exit 1, 'MAC_GATE_QUICK: lint=- build=- tests=- host=stub-host locallint=1 | exit=1', no host contact"
else bad "lint failure, quick: exit $RC, line [$(quick)], calls [$(printf '%s' "$CALLS" | tr '\n' ',')]"; show "$OUT"; fi
if [ "$(row_field 8)" = refused ] && [ "$(row_field 9)" = 1 ]; then ok "lint failure, quick: the run ledger says mode=refused exit=1"
else bad "lint failure, quick: the row says mode=[$(row_field 8)] exit=[$(row_field 9)]"; fi
if in_log "--- step: locallint ---" && ! in_log "--- step: selftest ---"; then
  ok "lint failure, quick: the run ended at the locallint step, before the selftests (control: the step is in the log)"
else bad "lint failure, quick: the log does not end at the locallint step"; fi

# --- 3: a pass goes on — and it linted BEFORE it queued for the held lock ---------------------------
lock3="$tmp/estate-3.lock"
mkdir -p "$tmp/case-pass/artifacts"
printf 'MemosCoreTests\t999\n' > "$tmp/case-pass/artifacts/testcount-baseline.tsv"
hold_lock "$lock3" "$tmp/case-pass/order" || bad "the lock holder never took the second lock"
( sleep 3; : > "$tmp/release" ) &
ESTATE_LOCK="$lock3" STUB_LINT_RC=0 run_gate pass "$w"
release_lock
if [ "$RC" -eq 16 ] && [ "$(summary)" = "mac-gate SUMMARY: selftest=0 classify=0 mount=16 mountguard=enforced host=stub-host locallint=0 | exit=16" ]; then
  ok "lint pass: the run goes on to the mount step, and the SUMMARY carries locallint=0 before '| exit='"
else bad "lint pass: exit $RC, SUMMARY [$(summary)]"; show "$OUT"; fi
if [ "$(tr '\n' ' ' < "$tmp/case-pass/order")" = "lint released " ]; then
  ok "lint pass: the lint ran while another process still held the estate lock (order: lint, released)"
else bad "lint pass: the order was [$(tr '\n' ' ' < "$tmp/case-pass/order")], expected [lint released]"; fi
if [ ! -e "$tmp/case-pass/artifacts/testcount-baseline.tsv" ]; then
  ok "lint pass: the earlier candidate is cleared as before, under the estate lock (control for the case above)"
else bad "lint pass: the earlier candidate survived a run that took the estate lock"; fi
if in_log "lock_acquired=" && in_log "MAC_GATE_LOCALLINT rc=0 "; then ok "lint pass: the run then took the estate lock (lock_acquired stamped)"
else bad "lint pass: no lock_acquired stamp or no MAC_GATE_LOCALLINT rc=0 in the log"; fi
if [ "$(row_field 8)" = refused ] && [ "$(row_field 9)" = 16 ]; then ok "lint pass: the mount refusal is still recorded as itself (mode=refused exit=16)"
else bad "lint pass: the row says mode=[$(row_field 8)] exit=[$(row_field 9)]"; fi

# --- 4: no tool: the run falls through and says so ---------------------------------------------------
STUB_SWIFT=absent run_gate fallthrough "$w" --quick
if [ "$RC" -eq 16 ] && [ "$(quick)" = "MAC_GATE_QUICK: lint=- build=- tests=- host=stub-host locallint=- | exit=16" ] && in_log "fell through"; then
  ok "fall-through: the run goes on as before, 'locallint=-' on the quick line, and the log says it fell through"
else bad "fall-through: exit $RC, line [$(quick)]"; show "$OUT"; fi
if [ -z "$SWIFT_CALLS" ]; then ok "fall-through: no lint ran"; else bad "fall-through: swift was asked [$SWIFT_CALLS]"; fi
if grep -q '^docker image inspect swift:6.3' "$tmp/case-fallthrough/docker-calls" 2>/dev/null \
   && ! grep -qE '^docker (pull|run)' "$tmp/case-fallthrough/docker-calls"; then
  ok "fall-through: docker was asked for the image and nothing was pulled or run"
else bad "fall-through: docker calls [$(tr '\n' ',' < "$tmp/case-fallthrough/docker-calls" 2>/dev/null)]"; fi

# --- 5: a tree without the helper falls through and names it -----------------------------------------
w2="$(new_repo unlinted nolint)" || { echo "FAIL: cannot build the second fixture"; exit 1; }
STUB_LINT_RC=1 run_gate nohelper "$w2"
if [ "$RC" -eq 16 ] && [ -z "$SWIFT_CALLS" ] && in_log "scripts/local-lint.sh" && in_log "fell through"; then
  ok "no helper in the tree: no lint, the run goes on, and the log names the missing scripts/local-lint.sh"
else bad "no helper in the tree: exit $RC, swift [$SWIFT_CALLS]"; show "$OUT"; fi

# --- 6: the caller's repository root is what is linted, from any directory in it ---------------------
STUB_LINT_RC=1 STUB_LINT_OUT="$ERR_LINE" run_gate subdir "$w/docs" --quick
if [ "$SWIFT_CALLS" = "lint cwd=$w" ] && [ "$RC" -eq 1 ]; then
  ok "scope: started in docs/, the lint ran in the repository root ($w) and refused"
else bad "scope: exit $RC, swift calls [$SWIFT_CALLS], expected [lint cwd=$w]"; fi

# --- 7: --classify-only and --help never lint ---------------------------------------------------------
STUB_LINT_RC=1 run_gate classify "$w" --classify-only
if [ -z "$SWIFT_CALLS" ] && [ "$RC" -eq 10 ]; then ok "--classify-only: no lint, and the classification answers as before (10)"
else bad "--classify-only: exit $RC, swift [$SWIFT_CALLS]"; show "$OUT"; fi
STUB_LINT_RC=1 run_gate help "$w" --help
if [ -z "$SWIFT_CALLS" ] && [ "$RC" -eq 0 ]; then ok "--help: no lint, exit 0"
else bad "--help: exit $RC, swift [$SWIFT_CALLS]"; fi

# --- 8: a run without MAC_GATE_HOST is refused by the copy, and lints nothing first ------------------
CASE_DIR="$tmp/case-nohost"; mkdir -p "$CASE_DIR"; make_stubs "$CASE_DIR"
OUT="$(cd "$w" && env -u MAC_GATE_HOST -u MAC_GATE_BRANCH "PATH=$CASE_DIR/bin:$PATH" STUB_DIR="$CASE_DIR" \
  STUB_LINT_RC=1 MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" timeout 60 "$GATE" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [ ! -e "$CASE_DIR/swift-calls" ] && printf '%s\n' "$OUT" | grep -qF 'MAC_GATE_HOST is not set'; then
  ok "no MAC_GATE_HOST: refused (2) for the missing host, and no lint ran first"
else bad "no MAC_GATE_HOST: exit $RC, swift [$(cat "$CASE_DIR/swift-calls" 2>/dev/null)]"; show "$OUT"; fi

echo "local-lint-refusal-path-test: $cases cases, $fails failed"
[ "$fails" -eq 0 ]
