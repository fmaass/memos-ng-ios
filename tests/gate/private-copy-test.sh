#!/usr/bin/env bash
#
# The gate runs from a private copy of itself, so a run that has begun cannot be changed by an edit
# to the tree it was started from.
#
# Bash reads a script as it goes, so a run whose file is rewritten underneath it carries on at its
# old byte offset in the NEW text. That is how a full gate once died at its summary line with a
# syntax error and no verdict, after the build host had already finished (2026-09-09): an
# implementer edited bin/mac-gate.sh while a gate launched from the same worktree was still running.
# The guard is that the gate copies itself — and every helper it hands to the build host or runs
# at the end — into a private directory at start and execs the copy, and names the sha256 of the
# text it executed on the line before its verdict.
#
# Each run here stops at a pause the gate only has when MAC_GATE_SELFTEST_PAUSE_DIR names a
# directory, is edited underneath while it waits, and is then let go. The edits are written IN
# PLACE (truncate and rewrite, same inode), which is what reaches a running bash; a rename would
# leave the old file open and prove nothing. Against a gate without the private copy the cases
# below fail: the same-length edit is read at its old offset and printed, the truncation ends the
# run with no summary, and the edited helper is what reaches the build host.
#
# No build host is needed: ssh and rsync are stubbed, and the fixture repository is built here.
# MAC_GATE_SCRIPT points the test at another copy of the gate (used to prove it red).
#
# Exit: 0 = every case behaved as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-private-copy-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
tmp="$(cd "$tmp" && pwd -P)" || exit 1
trap 'rm -rf "$tmp"' EXIT
# The gates this suite starts never queue behind an estate lock a parent gate holds, and their run
# ledger rows land here rather than in the estate's ledger.
unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCK_STAMPS
export MAC_GATE_RUNS_LEDGER="$tmp/gate-runs.tsv"

fails=0
cases=0
ok()  { cases=$((cases + 1)); echo "ok   $1"; }
bad() { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi \
    | awk '{print $1}'
}

SUMMARY_RE='^mac-gate SUMMARY: .* \| exit=[0-9]+$'
SHA_LINE_RE='^script      : sha256 [0-9a-f]{64} '

# The gate under test lives OUTSIDE the fixture repository: an edit to it must not also be a change
# the classifier sees, or the run would owe a full gate for a reason that has nothing to do with
# the edit. It also proves the run resolves the CALLER's repository, not the one its file is in.
gate_dir="$tmp/gate-bin"
mkdir -p "$gate_dir"
cp "$GATE" "$gate_dir/mac-gate.sh" && chmod +x "$gate_dir/mac-gate.sh" || { echo "FAIL: cannot copy $GATE"; exit 1; }
ORIGINAL="$tmp/original-mac-gate.sh"
cp "$gate_dir/mac-gate.sh" "$ORIGINAL"
original_sha="$(sha_of "$ORIGINAL")"
restore_gate() { cat "$ORIGINAL" > "$gate_dir/mac-gate.sh"; }

# Where every run here makes its private copy, so a leftover one can be counted.
run_tmp="$tmp/run-tmp"
mkdir -p "$run_tmp"
leftover_copies() { find "$run_tmp" -maxdepth 1 -name 'mac-gate-run.*' | wc -l | tr -d ' '; }

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
  # The stubs report what they inherited: neither the pause nor the copy's own marker may reach a
  # child, or a gate run BY a selftest would pause, or trust a copy that is not its own.
  for stub in fastpath-classify-test.sh warnings-canary-test.sh testcount-test.sh admission-test.sh mainbar-freeze-rule-test.sh; do
    printf '#!/bin/sh\necho "%s stub ok pause=[${MAC_GATE_SELFTEST_PAUSE_DIR:-}] copy=[${MAC_GATE_RUN_COPY:-}]"\nexit 0\n' \
      "$stub" > "$work/tests/gate/$stub"
    chmod +x "$work/tests/gate/$stub"
  done
  printf 'gate_lane_is_unlocked() { return 0; }\n# helper text: ORIGINAL-REAPER\n' > "$work/scripts/reap-gate-lanes.sh"
  printf '# helper text: ORIGINAL-WORKDIR\n' > "$work/scripts/gate-work-dir.sh"
  printf '# helper text: ORIGINAL-ROOTREFUSAL\n' > "$work/scripts/gate-root-refusal.sh"
  printf '#!/bin/sh\necho "candidate owner: helper text ORIGINAL-OWNER"\nexit 0\n' \
    > "$work/scripts/testcount-candidate-owner.sh"
  chmod +x "$work/scripts/testcount-candidate-owner.sh"
  cp "$repo_root/scripts/gate-admission.sh" "$work/scripts/gate-admission.sh" || return 1
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  printf '%s' "$work"
}

# ssh and rsync, replaced: the disk admission, the preflight and the remote script are answered, and
# every script handed over is recorded, since that is the only place a helper's text can be read.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
case "$*" in
  *simctl*) exit 1 ;;
esac
script="$(cat)"
case "$script" in
  # the run admission's disk reading, known by its call (the remote script carries the helper that
  # defines it, so the helper's own text cannot tell the two apart): room enough, admitted at once
  *'gate_lane_space "$target"'*) echo "FREE_KB 99999999 OWN_KB 0"; exit 0 ;;
  *MAC_GATE_STEP*)
    printf '%s' "$script" > "$STUB_DIR/remote-script.txt"
    exit 0 ;;
  *gate_root_raw*)
    printf '%s' "$script" > "$STUB_DIR/preflight-script.txt"
    branch="$(printf '%s\n' "$script" | sed -n "s/^branch='\(.*\)'\$/\1/p" | head -1)"
    root="/Users/gate/build/memos-ng-ios/gate"
    echo "LOCK ACQUIRED"
    echo "LOCKDIR $root/$branch.lock"
    echo "GATE_ROOT $root"
    echo "TARGET $root/$branch"
    exit 0 ;;
esac
exit 0
SSH_EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/rsync"
  chmod +x "$dir/bin/ssh" "$dir/bin/rsync"
}

# Starts one run in the background, paused. PID and PAUSE are what the caller then uses.
start_paused() {
  local work="$1" stubdir="$2"; shift 2
  PAUSE="$stubdir/pause"
  mkdir -p "$PAUSE"
  ( cd "$work" && env -u MAC_GATE_BRANCH -u MAC_GATE_RUN_COPY \
      "PATH=$stubdir/bin:$PATH" \
      TMPDIR="$run_tmp" \
      MAC_GATE_HOST=stub-host \
      MAC_GATE_ARTIFACTS="$stubdir/artifacts" \
      MAC_GATE_SELFTEST_PAUSE_DIR="$PAUSE" \
      STUB_DIR="$stubdir" \
      "$gate_dir/mac-gate.sh" "$@" > "$stubdir/out.txt" 2>&1 )&
  PID=$!
}
wait_paused() { # $1 = pause dir, $2 = pid; 0 once the run says it is waiting
  local n=0
  while [ ! -e "$1/paused" ]; do
    kill -0 "$2" 2>/dev/null || return 1
    n=$((n + 1)); [ "$n" -le 600 ] || return 1
    sleep 0.1
  done
}
finish() { # $1 = pause dir, $2 = pid; sets RC
  : > "$1/resume"
  wait "$2"; RC=$?
}

new_case() {
  CASE_DIR="$tmp/case-$1"
  mkdir -p "$CASE_DIR"
  make_stubs "$CASE_DIR"
}

# The verdict lines a run printed, and whether the sha line is the one right before SUMMARY.
check_verdict() { # $1 = label, $2 = output file, $3 = expected rc, $4 = rc
  local label="$1" out="$2" want="$3" rc="$4" sha prev
  if [ "$rc" -eq "$want" ]; then ok "$label: exit $rc"
  else bad "$label: expected exit $want, got $rc"; show "$(cat "$out")"; fi
  if [ "$(grep -Ec "$SUMMARY_RE" "$out")" -eq 1 ] && grep -Eq "^mac-gate SUMMARY: .* \| exit=$want\$" "$out"; then
    ok "$label: one mac-gate SUMMARY line, exit=$want"
  else
    bad "$label: no single 'mac-gate SUMMARY: … | exit=$want' line"; show "$(cat "$out")"
  fi
  prev="$(grep -E -B1 "$SUMMARY_RE" "$out" | head -1)"
  sha="$(printf '%s\n' "$prev" | sed -n 's/^script      : sha256 \([0-9a-f]\{64\}\) .*/\1/p')"
  if [ "$sha" = "$original_sha" ]; then
    ok "$label: the line before SUMMARY names the sha256 of the text the run started from"
  else
    bad "$label: the line before SUMMARY does not name sha256 $original_sha"; show "$prev"
  fi
}

# --- a fixture on a docs-only branch: the fast path, which ends in summary_and_exit --------------
w="$(new_repo docs)" || { echo "FAIL: cannot build the fixture"; exit 1; }
git -C "$w" checkout --quiet -b fix/docs-only
printf 'more guide\n' >> "$w/docs/guide.md"
git -C "$w" commit --quiet -am "a docs change"
real_w="$(git -C "$w" rev-parse --show-toplevel)"

# --- case 1: a same-length edit after the pause point --------------------------------------------
# Same length, so a gate reading the file as it goes finds the edit at exactly the offset it would
# have read the original from, and prints it.
new_case same-length
start_paused "$w" "$CASE_DIR"
if wait_paused "$PAUSE" "$PID"; then
  ok "same-length: the run reached the selftest pause"
  copies=("$run_tmp"/mac-gate-run.*/mac-gate.sh)
  if [ "${#copies[@]}" -eq 1 ] && [ -f "${copies[0]}" ] && [ "$(sha_of "${copies[0]}")" = "$original_sha" ]; then
    ok "same-length: while paused, exactly one private copy exists and it is the original text (control)"
  else
    bad "same-length: expected one private copy of the original text under $run_tmp, found: ${copies[*]}"
  fi
  sed 's/mac-gate PASS (fast path/mac-gate XXXX (fast path/' "$ORIGINAL" > "$tmp/edited.sh"
  cat "$tmp/edited.sh" > "$gate_dir/mac-gate.sh"
  if grep -q 'mac-gate XXXX (fast path' "$gate_dir/mac-gate.sh" \
     && [ "$(wc -c < "$gate_dir/mac-gate.sh")" -eq "$(wc -c < "$ORIGINAL")" ]; then
    ok "same-length: the edit landed in the file the run was started from, at the same length (control)"
  else
    bad "same-length: the edit did not land as intended"
  fi
else
  bad "same-length: the run never reached the selftest pause"; show "$(cat "$CASE_DIR/out.txt")"
fi
finish "$PAUSE" "$PID"
check_verdict "same-length" "$CASE_DIR/out.txt" 0 "$RC"
if grep -q '^mac-gate PASS (fast path: docs-only)' "$CASE_DIR/out.txt" \
   && ! grep -q 'mac-gate XXXX' "$CASE_DIR/out.txt"; then
  ok "same-length: the run printed the ORIGINAL text's verdict, not the edit"
else
  bad "same-length: the run printed the edited text"; show "$(grep -n 'fast path' "$CASE_DIR/out.txt")"
fi
if grep -qxF "repo        : $real_w" "$CASE_DIR/out.txt"; then
  ok "same-length: the copy resolved the caller's repository, not the one its file sits in"
else
  bad "same-length: the provenance does not name the caller's repository $real_w"
  show "$(grep '^repo' "$CASE_DIR/out.txt")"
fi
if grep -q 'stub ok pause=\[\] copy=\[\]' "$CASE_DIR/out.txt" \
   && ! grep -q 'stub ok pause=\[[^]]' "$CASE_DIR/out.txt" && ! grep -q 'copy=\[[^]]' "$CASE_DIR/out.txt"; then
  ok "same-length: neither the pause nor the copy marker reached a child process"
else
  bad "same-length: a child inherited the pause or the copy marker"; show "$(grep 'stub ok' "$CASE_DIR/out.txt")"
fi
restore_gate

# --- case 2: two runs at once, and a truncation under both ---------------------------------------
# The file cut down to two lines, so a gate reading as it goes runs out of text and ends without a
# summary. Two runs, so each one's copy is shown to be its own.
new_case truncate-a; dir_a="$CASE_DIR"
new_case truncate-b; dir_b="$CASE_DIR"
start_paused "$w" "$dir_a"; pid_a=$PID; pause_a=$PAUSE
start_paused "$w" "$dir_b"; pid_b=$PID; pause_b=$PAUSE
if wait_paused "$pause_a" "$pid_a" && wait_paused "$pause_b" "$pid_b"; then
  n="$(leftover_copies)"
  if [ "$n" -eq 2 ]; then ok "two runs: two private copies while both are paused"
  else bad "two runs: expected 2 private copies while both are paused, found $n"; fi
  printf '#!/usr/bin/env bash\necho "EDITED TEXT RAN"; exit 97\n' > "$gate_dir/mac-gate.sh"
else
  bad "two runs: a run never reached the selftest pause"
fi
finish "$pause_a" "$pid_a"; rc_a=$RC
finish "$pause_b" "$pid_b"; rc_b=$RC
check_verdict "truncated, run A" "$dir_a/out.txt" 0 "$rc_a"
check_verdict "truncated, run B" "$dir_b/out.txt" 0 "$rc_b"
if grep -q 'EDITED TEXT RAN' "$dir_a/out.txt" "$dir_b/out.txt"; then bad "two runs: the truncated text ran"
else ok "two runs: the truncated text never ran"; fi
copy_a="$(sed -n 's/^script      : \(.*\/mac-gate-run\.[^/]*\)\/mac-gate\.sh (private copy.*/\1/p' "$dir_a/out.txt")"
copy_b="$(sed -n 's/^script      : \(.*\/mac-gate-run\.[^/]*\)\/mac-gate\.sh (private copy.*/\1/p' "$dir_b/out.txt")"
if [ -n "$copy_a" ] && [ -n "$copy_b" ] && [ "$copy_a" != "$copy_b" ]; then
  ok "two runs: each named a private copy of its own"
else
  bad "two runs: the private copies were not distinct (A=${copy_a:-none} B=${copy_b:-none})"
fi
restore_gate

n="$(leftover_copies)"
if [ "$n" -eq 0 ]; then ok "no private copy is left behind by the runs that finished"
else bad "$n private cop(ies) left under $run_tmp"; fi

# --- case 3: a helper the gate hands to the build host, edited mid-run ---------------------------
# The quick mode, because it reaches the preflight and the remote script, which both carry the lane
# reaper and the work-root derivation, and the preflight the gate-root refusal; the edit lands after
# the run has begun and before either is assembled.
w2="$(new_repo helpers)" || { echo "FAIL: cannot build the helpers fixture"; exit 1; }
git -C "$w2" checkout --quiet -b fix/helpers
printf 'let two = 2\n' >> "$w2/Sources/App.swift"
git -C "$w2" commit --quiet -am "a source change"
new_case helpers
start_paused "$w2" "$CASE_DIR" --quick
if wait_paused "$PAUSE" "$PID"; then
  printf 'gate_lane_is_unlocked() { return 0; }\n# helper text: EDITED-REAPER!\n' > "$w2/scripts/reap-gate-lanes.sh"
  printf '# helper text: EDITED-WORKDIR!\n' > "$w2/scripts/gate-work-dir.sh"
  printf '# helper text: EDITED-ROOTREFUSAL!\n' > "$w2/scripts/gate-root-refusal.sh"
else
  bad "helpers: the run never reached the selftest pause"
fi
finish "$PAUSE" "$PID"
for sent in preflight-script.txt remote-script.txt; do
  if [ ! -s "$CASE_DIR/$sent" ]; then
    bad "helpers: no $sent reached the stubbed build host"; show "$(cat "$CASE_DIR/out.txt")"
  elif grep -q 'ORIGINAL-REAPER' "$CASE_DIR/$sent" && grep -q 'ORIGINAL-WORKDIR' "$CASE_DIR/$sent" \
       && ! grep -q 'EDITED-' "$CASE_DIR/$sent"; then
    ok "helpers: $sent carries the helpers as they were when the run began"
  else
    bad "helpers: $sent carries the edited helpers"; show "$(grep -n 'helper text' "$CASE_DIR/$sent")"
  fi
done
if [ -s "$CASE_DIR/preflight-script.txt" ] && grep -q 'ORIGINAL-ROOTREFUSAL' "$CASE_DIR/preflight-script.txt" \
   && ! grep -q 'EDITED-ROOTREFUSAL' "$CASE_DIR/preflight-script.txt"; then
  ok "helpers: the preflight carries the gate-root refusal as it was when the run began"
else
  bad "helpers: the preflight does not carry the original gate-root refusal"
  show "$(grep -n 'helper text' "$CASE_DIR/preflight-script.txt" 2>&1)"
fi
prev="$(grep -B1 '^MAC_GATE_QUICK: ' "$CASE_DIR/out.txt" | head -1)"
if printf '%s\n' "$prev" | grep -Eq "$SHA_LINE_RE"; then
  ok "helpers: a quick run names its script's sha256 on the line before MAC_GATE_QUICK"
else
  bad "helpers: the line before MAC_GATE_QUICK is not the sha line"; show "$prev"
fi

# --- case 3b: the helper the gate runs at its end, edited mid-run -------------------------------
# The copyback runs the test-count candidate's owner from the private copy; both modes end there,
# and this case uses a full run on a branch of its own. The edit lands while the run waits at the
# pause.
git -C "$w2" checkout --quiet -b fix/owner
new_case owner
start_paused "$w2" "$CASE_DIR"
if wait_paused "$PAUSE" "$PID"; then
  printf '#!/bin/sh\necho "candidate owner: helper text EDITED-OWNER!"\nexit 0\n' \
    > "$w2/scripts/testcount-candidate-owner.sh"
else
  bad "owner: the run never reached the selftest pause"
fi
finish "$PAUSE" "$PID"
if grep -q '^--- step: copyback ---' "$CASE_DIR/out.txt"; then
  ok "owner: the full run reached its copyback (control)"
else
  bad "owner: the full run never reached its copyback"; show "$(cat "$CASE_DIR/out.txt")"
fi
if grep -q 'helper text ORIGINAL-OWNER' "$CASE_DIR/out.txt" && ! grep -q 'EDITED-OWNER' "$CASE_DIR/out.txt"; then
  ok "owner: the copyback ran the candidate owner as it was when the run began"
else
  bad "owner: the copyback did not run the original candidate owner"
  show "$(grep -n 'candidate' "$CASE_DIR/out.txt")"
fi
git -C "$w2" checkout --quiet scripts/testcount-candidate-owner.sh

# --- case 4: a marker from outside is not a private copy -----------------------------------------
# The copy knows it is one by the directory it runs from. A caller exporting that marker at the
# directory the gate really lives in must get a fresh copy — and its directory must survive, since
# the copy's directory is what a run removes when it ends.
new_case marker
printf 'keep me\n' > "$gate_dir/sentinel"
( cd "$w" && env -u MAC_GATE_BRANCH "PATH=$CASE_DIR/bin:$PATH" TMPDIR="$run_tmp" \
    MAC_GATE_HOST=stub-host MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" STUB_DIR="$CASE_DIR" \
    MAC_GATE_RUN_COPY="$gate_dir" "$gate_dir/mac-gate.sh" > "$CASE_DIR/out.txt" 2>&1 )
RC=$?
check_verdict "foreign marker" "$CASE_DIR/out.txt" 0 "$RC"
if [ -f "$gate_dir/sentinel" ] && [ -f "$gate_dir/mac-gate.sh" ]; then
  ok "foreign marker: the directory it named was left alone"
else
  bad "foreign marker: the directory named by an outside MAC_GATE_RUN_COPY was removed"
fi
if grep -Eq '^script      : .*/mac-gate-run\.[^/]+/mac-gate\.sh \(private copy' "$CASE_DIR/out.txt"; then
  ok "foreign marker: the run made and used its own private copy"
else
  bad "foreign marker: the run did not run from a private copy"; show "$(grep '^script' "$CASE_DIR/out.txt")"
fi

# --- case 5: a refusal before the run's traps are set leaves no copy either ----------------------
( cd "$w" && env -u MAC_GATE_HOST -u MAC_GATE_RUN_COPY TMPDIR="$run_tmp" "$gate_dir/mac-gate.sh" \
    > "$tmp/refused.txt" 2>&1 )
RC=$?
if [ "$RC" -eq 2 ] && grep -q 'MAC_GATE_HOST is not set' "$tmp/refused.txt"; then
  ok "an early refusal still refuses (exit 2, names MAC_GATE_HOST)"
else
  bad "an early refusal: expected exit 2 naming MAC_GATE_HOST, got $RC"; show "$(cat "$tmp/refused.txt")"
fi
n="$(leftover_copies)"
if [ "$n" -eq 0 ]; then ok "no private copy is left behind by any run, the refused one included"
else bad "$n private cop(ies) left under $run_tmp"; fi

echo "gate private copy: $((cases - fails)) of $cases checks passed"
[ "$fails" -eq 0 ]
