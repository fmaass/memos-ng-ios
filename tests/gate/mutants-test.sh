#!/usr/bin/env bash
#
# The mutant batch's own check: `bin/mac-gate.sh --quick --only-testing <id> --mutants <dir>` proves
# several tests real inside ONE estate-lock hold and ONE simulator span (MEMNG-825).
#
# Every case runs the real gate against a throwaway repository, with ssh and rsync replaced. The
# rsync stand-in really copies, into a directory that plays the build host, and the ssh stand-in
# really RUNS the part of the remote script a quick run executes (the quick sequence, the batch
# driver, the give-back the traps call), with xcodebuild, xcrun and the simulator span faked and the
# real `patch` applying the mutants. The fake build copies the sources into DerivedData and the fake
# test run judges that copy, never the sources: restoring a source without rebuilding leaves the
# mutant's product in place, as it would on the Mac.
#
# What it holds: a clean run plus every mutant caught exits 0 with mutants=N/N; a survivor, a mutant
# that does not compile and one whose failure shows no failed case each exit 17 and are named; a
# failing clean run keeps its own code and runs no mutant; a failing second clean run, and a restore
# that silently did nothing, make the batch unsound; a signal mid-mutant still restores the tree;
# the tree on the build host is byte-identical to the caller's after every batch, read back; the
# a restore and a removal that both fail fence the lane, and later runs refuse (18) until each fenced
# file is verified; the patches are frozen when they are checked; bad patch directories are refused before the estate
# lock is even requested; the combinations the batch cannot honour are refused; the batch leaves no
# test-count candidate and one run-ledger row.
#
# This suite never prints a line that starts with the batch's own line name: every gate log carries
# the selftests' output, and the estate's red-cycle count reads that name at the start of a line.
#
# MAC_GATE_SCRIPT points it at another copy of the gate (used to prove it red against 926c69e).
# Exit: 0 = every case behaved as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }
REAL_RSYNC="$(command -v rsync)" || { echo "FAIL: no rsync on PATH"; exit 1; }
command -v patch >/dev/null 2>&1 || { echo "FAIL: no patch on PATH"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-mutants-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
holder_pid=""
cleanup() {
  [ -z "$holder_pid" ] || { : > "$tmp/release"; wait "$holder_pid" 2>/dev/null; }
  rm -rf "${tmp:?}"
}
trap cleanup EXIT
unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_SIMULATOR MAC_GATE_ARTIFACTS

fails=0
cases=0
ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }
show() { printf '%s\n' "$1" | sed 's/^/     | /'; }

SCOPE="MemosCoreTests/AlphaTests"

# --- the fixture -----------------------------------------------------------------------------------
# A repository shaped like this one in the ways the local half reads (HEAD, origin/main, project.yml
# with the version keys, the named selftests, the helpers), with five product sources a mutant can
# reach, a test source no mutant may touch, and a bin/generate.sh the quick sequence calls.
new_repo() {
  local name="$1" work="$tmp/$1" origin="$tmp/$1.git" f
  git init --quiet --bare "$origin" || return 1
  git init --quiet -b main "$work" || return 1
  git -C "$work" config user.email gate-test@example.invalid
  git -C "$work" config user.name "gate test"
  git -C "$work" config commit.gpgsign false
  git -C "$work" config core.hooksPath "$tmp/no-hooks"
  mkdir -p "$work/docs" "$work/Sources" "$work/tests/gate" "$work/scripts" "$work/bin" \
    "$work/Packages/Thing/Tests/ThingTests"
  printf 'a guide\n' > "$work/docs/guide.md"
  for f in Alpha Beta Gamma Delta Outside; do
    printf 'let %s = 1\nlet %sTwo = 2\n' "$f" "$f" > "$work/Sources/$f.swift"
  done
  printf 'let check = 1\n' > "$work/Packages/Thing/Tests/ThingTests/ThingTests.swift"
  printf '#!/bin/sh\necho "generated (fixture)"\nexit 0\n' > "$work/bin/generate.sh"
  chmod +x "$work/bin/generate.sh"
  printf '.gate-artifacts/\n' > "$work/.gitignore"
  {
    printf 'targets:\n'
    printf '  MemosNG:\n'
    printf '    settings:\n'
    printf '      MARKETING_VERSION: "9.9.9"\n'
    printf '      CURRENT_PROJECT_VERSION: "999"\n'
  } > "$work/project.yml"
  for stub in fastpath-classify-test.sh warnings-canary-test.sh testcount-test.sh admission-test.sh mainbar-freeze-rule-test.sh mount-guard-test.sh mount-refusal-path-test.sh testflight-cut-test.sh release-notes-rule-test.sh local-lint-test.sh local-lint-refusal-path-test.sh host-routing-test.sh mutants-test.sh; do
    printf '#!/bin/sh\necho "%s stub ok"\nexit 0\n' "$stub" > "$work/tests/gate/$stub"
    chmod +x "$work/tests/gate/$stub"
  done
  printf 'gate_lane_is_unlocked() { return 0; }\n' > "$work/scripts/reap-gate-lanes.sh"
  cp "$repo_root/scripts/gate-admission.sh" "$work/scripts/gate-admission.sh" || return 1
  cp "$repo_root/scripts/gate-mount-guard.sh" "$work/scripts/gate-mount-guard.sh" || return 1
  [ ! -e "$repo_root/scripts/mutants-check.sh" ] \
    || cp "$repo_root/scripts/mutants-check.sh" "$work/scripts/mutants-check.sh" || return 1
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  git -C "$work" checkout --quiet -b fix/mutants || return 1
  printf 'let three = 3\n' >> "$work/Sources/Delta.swift"
  git -C "$work" commit --quiet -am "a source change, so this is not a docs-only change set" || return 1
  printf '%s' "$work"
}

# A numbered mutant: the file with one line appended, as a -p1 unified diff.
# $1 = patch dir, $2 = patch file name, $3 = repo, $4 = path in the repo, $5 = the line to append
make_patch() {
  local dir="$1" name="$2" work="$3" path="$4" line="$5" scratch="$tmp/patch-scratch"
  mkdir -p "$dir" "$scratch"
  cp "$work/$path" "$scratch/new"
  printf '%s\n' "$line" >> "$scratch/new"
  (cd "$work" && diff -u --label "a/$path" --label "b/$path" "$path" "$scratch/new") > "$dir/$name"
  [ -s "$dir/$name" ]
}

# --- the build host, played by a directory -------------------------------------------------------
# ssh answers the local half's questions (mount guard, admission, preflight) as quick-mode-test.sh's
# stand-in does, and RUNS the quick part of the remote script against the host directory. rsync
# copies for real, with the host's "<alias>:" prefix mapped onto that directory.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/hostbin" "$dir/host"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in *simctl*) exit 1 ;; esac
script="$(cat)"
case "$script" in
  *'
gate_mount_guard report '*) echo "MOUNT OK uuid=stub dev=/dev/disk8s1"; echo "mountguard=enforced marker=not-read"; exit 0 ;;
  *'gate_lane_space "$target"'*) echo "FREE_KB 99999999 OWN_KB 0"; exit 0 ;;
  *MAC_GATE_STEP*)
    printf '%s' "$script" > "$STUB_DIR/remote-script.txt"
    runner="$STUB_DIR/runner.sh"
    {
      printf '%s\n' 'set -uo pipefail'
      printf '%s\n' "$script" | grep -E "^GATE_[A-Z_]+='.*'\$"
      printf '%s\n' "$script" | awk '/^gate_mutants_write\(\) \{$/ { f = 1 } f { print } f && /^\} # gate_mutants_write$/ { exit }'
      cat <<'RUNNER_EOF'
GATE_TARGET="$FAKE_HOST$GATE_TARGET"
GATE_ROOT="$FAKE_HOST$GATE_ROOT"
GATE_WORK="$FAKE_HOST/work/$GATE_BRANCH"
DERIVED="$GATE_WORK/DerivedData"
GATE_BUILD_DESTINATION="generic/platform=iOS Simulator"
GATE_DESTINATION="platform=iOS Simulator,id=fake"
export FAKE_RUNNER_PID=$$
s_format() { echo "fake lint"; return 0; }
gate_remote_step_line() { echo "MAC_GATE_STEP $1 $2 t=0"; }
gate_remote_clock_end() { :; }
gate_sim_release() { return 0; }
gate_sim_span() {
  local rc=0 f
  echo "span" >> "$FAKE_HOST/simspans"
  for f in "$@"; do "$f"; rc=$?; [ "$rc" -eq 0 ] || break; done
  echo "MAC_GATE_SLOT slot=0 slot_wait=0 simrelease=0"
  return "$rc"
}
RUNNER_EOF
      printf '%s\n' "$script" | awk '/^gate_give_back\(\) \{$/ { f = 1 } f { print } f && /^\}$/ { exit }'
      printf '%s\n' "$script" | grep -E "^trap 'gate_give_back"
      cat <<'RUNNER_EOF'
mkdir -p "$GATE_WORK" || exit 2
cd "$GATE_TARGET" || exit 2
rm -rf .gate-artifacts && mkdir -p .gate-artifacts && printf '%s\n' "$GATE_RUN_TOKEN" > .gate-artifacts/run-token || exit 2
RUNNER_EOF
      printf '%s\n' "$script" | awk '/^# --- the mutant fence / { f = 1 } f { print } /^# --- end of the mutant fence / { exit }'
      printf '%s\n' "$script" | awk 'index($0, "if [ \"${GATE_QUICK:-0}\" -eq 1 ]; then") == 1 { f = 1 }
                                     /^step xcodegen/ { exit }
                                     f { print }'
    } > "$runner"
    PATH="$STUB_DIR/hostbin:$PATH" FAKE_HOST="$STUB_DIR/host" bash "$runner"
    exit $? ;;
  *gate_root_raw*)
    branch="$(printf '%s\n' "$script" | sed -n "s/^branch='\(.*\)'\$/\1/p" | head -1)"
    root="/Users/gate/build/memos-ng-ios/gate"
    echo "GATE_REAP data volume before: (stub)"
    echo "LOCK ACQUIRED"
    echo "LOCKDIR $root/$branch.lock"
    echo "GATE_ROOT $root"
    echo "TARGET $root/$branch"
    exit 0 ;;
esac
exit 0
SSH_EOF
  cat > "$dir/bin/rsync" <<'RSYNC_EOF'
#!/usr/bin/env bash
# Every argument but "-e ssh" passes through; "<alias>:/path" becomes "$STUB_DIR/host/path".
out=()
skip=0
for a in "$@"; do
  if [ "$skip" -eq 1 ]; then skip=0; continue; fi
  case "$a" in
    -e) skip=1 ;;
    stub-host:*) p="${a#stub-host:}"; mkdir -p "$STUB_DIR/host$(dirname "$p")"; out+=("$STUB_DIR/host$p") ;;
    *) out+=("$a") ;;
  esac
done
exec "$REAL_RSYNC" "${out[@]}"
RSYNC_EOF
  # The build: the sources as they are NOW become the product; a source carrying COMPILE_ERROR does
  # not compile, one carrying KILL_DURING_BUILD has the remote shell signalled mid-build.
  # The test run judges the PRODUCT: BREAKS_TEST or CLEAN_FAILS -> a failed case and rc 65;
  # CRASH_NO_FAIL -> rc 65 with every case passed; a bundle path naming clean-control fails when
  # FAKE_CONTROL_FAILS=1 (state that leaked from a mutant).
  cat > "$dir/hostbin/xcodebuild" <<'XCB_EOF'
#!/usr/bin/env bash
mode="$1"; shift
derived="" bundle=""
while [ $# -gt 0 ]; do
  case "$1" in
    -derivedDataPath) derived="$2"; shift ;;
    -resultBundlePath) bundle="$2"; shift ;;
  esac
  shift
done
case "$mode" in
  build-for-testing)
    echo "fake build-for-testing" >> "$FAKE_HOST/xcodebuild-calls"
    if grep -lq KILL_DURING_BUILD Sources/*.swift 2>/dev/null; then
      kill -TERM "$FAKE_RUNNER_PID"; sleep 1
    fi
    if grep -l COMPILE_ERROR Sources/*.swift >/dev/null 2>&1; then
      echo "error: fake compile error"; exit 65
    fi
    rm -rf "$derived/Products" && mkdir -p "$derived/Products" && cp -R Sources "$derived/Products/Sources" || exit 1
    echo "** TEST BUILD SUCCEEDED **"; exit 0 ;;
  test-without-building)
    echo "fake test ${bundle##*/}" >> "$FAKE_HOST/xcodebuild-calls"
    p="$derived/Products/Sources"
    result=Passed rc=0
    if grep -lq 'BREAKS_TEST\|CLEAN_FAILS' "$p"/*.swift 2>/dev/null; then result=Failed rc=65; fi
    if grep -lq CRASH_NO_FAIL "$p"/*.swift 2>/dev/null; then rc=65; fi
    case "$bundle" in *clean-control*) [ "${FAKE_CONTROL_FAILS:-0}" != 1 ] || { result=Failed; rc=65; } ;; esac
    mkdir -p "$bundle"
    printf '{"testNodes":[{"nodeType":"Test Plan","name":"MemosNG","children":[{"nodeType":"Unit test bundle","name":"MemosCoreTests.xctest","children":[{"nodeType":"Test Suite","name":"AlphaTests","children":[{"nodeType":"Test Case","name":"one()","result":"Passed"},{"nodeType":"Test Case","name":"two()","result":"%s"}]}]}]}]}\n' "$result" > "$bundle/tests.json"
    echo "fake test run rc=$rc"; exit "$rc" ;;
esac
exit 0
XCB_EOF
  cat > "$dir/hostbin/xcrun" <<'XCRUN_EOF'
#!/usr/bin/env bash
path=""
while [ $# -gt 0 ]; do case "$1" in --path) path="$2"; shift ;; esac; shift; done
cat "$path/tests.json"
XCRUN_EOF
  # cp, lying when FAKE_CP_LIES=1: a copy OUT of the byte copy into the tree reports success and
  # copies nothing. Everything else is the real cp.
  cat > "$dir/hostbin/cp" <<'CP_EOF'
#!/usr/bin/env bash
if [ "${FAKE_CP_LIES:-0}" = 1 ]; then
  case "$*" in */mutants/orig/*" "*) case "${@: -1}" in */mutants/orig/*) ;; *) exit 0 ;; esac ;; esac
fi
exec /bin/cp "$@"
CP_EOF
  # rm, failing when FAKE_RM_FAILS=1 for any source in the mirror: the removal that follows a failed
  # restore fails too. Everything else is the real rm.
  cat > "$dir/hostbin/rm" <<'RM_EOF'
#!/usr/bin/env bash
if [ "${FAKE_RM_FAILS:-0}" = 1 ]; then
  for a in "$@"; do case "$a" in */gate/*/Sources/*) exit 1 ;; esac; done
fi
exec /bin/rm "$@"
RM_EOF
  chmod +x "$dir/bin/ssh" "$dir/bin/rsync" "$dir/hostbin/xcodebuild" "$dir/hostbin/xcrun" "$dir/hostbin/cp" "$dir/hostbin/rm"
}

# One gate run. $1 = case name, $2 = repo, then the gate's arguments. Sets OUT RC CASE_DIR ROWS HOST_TREE.
run_gate() {
  local name="$1" work="$2"; shift 2
  CASE_DIR="$tmp/case-$name"
  mkdir -p "$CASE_DIR"
  make_stubs "$CASE_DIR"
  OUT="$(cd "$work" && env -u MAC_GATE_BRANCH \
    "PATH=$CASE_DIR/bin:$PATH" \
    MAC_GATE_HOST=stub-host \
    MAC_GATE_ARTIFACTS="$CASE_DIR/artifacts" \
    MAC_GATE_RUNS_LEDGER="$CASE_DIR/gate-runs.tsv" \
    ${ESTATE_LOCK:+MAC_GATE_ESTATE_LOCK="$ESTATE_LOCK"} \
    STUB_DIR="$CASE_DIR" REAL_RSYNC="$REAL_RSYNC" \
    FAKE_CONTROL_FAILS="${FAKE_CONTROL_FAILS:-0}" FAKE_CP_LIES="${FAKE_CP_LIES:-0}" FAKE_RM_FAILS="${FAKE_RM_FAILS:-0}" \
    TMPDIR="${RUN_TMPDIR:-${TMPDIR:-/tmp}}" \
    timeout 300 "$GATE" "$@" 2>&1)"
  RC=$?
  ROWS="$(sed -n '2,$p' "$CASE_DIR/gate-runs.tsv" 2>/dev/null)"
  HOST_TREE="$CASE_DIR/host/Users/gate/build/memos-ng-ios/gate/fix/mutants"
}
lines() { printf '%s\n' "$OUT" | grep -Ec "$1"; }
has()   { printf '%s\n' "$OUT" | grep -Eq "$1"; }
quick_line() { printf '%s\n' "$OUT" | grep -E '^MAC_GATE_QUICK: '; }
spans() { if [ -f "$CASE_DIR/host/simspans" ]; then wc -l < "$CASE_DIR/host/simspans" | tr -d ' '; else echo 0; fi; }

# The host tree, read back: every source the caller's tree has is byte-identical there, and nothing
# a patch tool leaves behind is lying beside it.
host_tree_clean() { # $1 = repo
  local d
  [ -d "$HOST_TREE/Sources" ] || { echo "no host tree at $HOST_TREE"; return 1; }
  d="$(diff -r "$1/Sources" "$HOST_TREE/Sources" 2>&1)" || { echo "$d"; return 1; }
  d="$(find "$HOST_TREE" \( -name '*.orig' -o -name '*.rej' \) -print)"
  [ -z "$d" ] || { echo "left behind: $d"; return 1; }
  return 0
}

# --- 1: three mutants, all caught ------------------------------------------------------------------
w="$(new_repo caught)" || { echo "FAIL: cannot build the fixture"; exit 1; }
P="$tmp/patches-caught"
make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// BREAKS_TEST alpha'
make_patch "$P" 02-beta.patch "$w" Sources/Beta.swift '// BREAKS_TEST beta'
make_patch "$P" 03-gamma.patch "$w" Sources/Gamma.swift '// BREAKS_TEST gamma'
run_gate caught "$w" --quick --only-testing "$SCOPE" --mutants "$P"
if [ "$RC" -eq 0 ]; then ok "three caught mutants: exit 0"
else bad "three caught mutants: expected exit 0, got $RC"; show "$OUT"; fi
if [ "$(lines '^MAC_GATE_QUICK: lint=0 build=0 tests=0 mutants=3/3 host=stub-host locallint=- \| exit=0$')" -eq 1 ]; then
  ok "three caught mutants: the quick line carries mutants=3/3"
else bad "three caught mutants: no 'mutants=3/3' quick line"; show "$(quick_line)"; fi
n=0
for m in 01-alpha 02-beta 03-gamma; do
  has "^MAC_GATE_MUTANT $m caught tests_rc=65\$" && n=$((n + 1))
done
if [ "$n" -eq 3 ]; then ok "three caught mutants: one caught line per mutant"
else bad "three caught mutants: $n of 3 caught lines"; fi
if [ "$(spans)" = 1 ]; then ok "three caught mutants: ONE simulator span for the whole batch"
else bad "three caught mutants: $(spans) simulator spans"; fi
if [ "$(grep -c '^fake build-for-testing' "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null)" = 5 ] \
   && [ "$(grep -c '^fake test' "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null)" = 5 ]; then
  ok "three caught mutants: five builds and five test runs (clean, three mutants, the clean control)"
else bad "three caught mutants: unexpected build/test calls"; show "$(cat "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null)"; fi
if d="$(host_tree_clean "$w")"; then ok "three caught mutants: the host tree is the caller's tree after the batch (read back)"
else bad "three caught mutants: the host tree is not clean"; show "$d"; fi
missing=""
for f in MemosNG-quick-mutant-clean.xcresult MemosNG-quick-mutant-01.xcresult MemosNG-quick-mutant-03.xcresult \
         MemosNG-quick-mutant-clean-control.xcresult quick-test-01.log quick-test-results-02.json \
         quick-test-clean-control.log mutant-01-build.log mutant-03-build.log clean-control-build.log; do
  [ -n "$(find "$CASE_DIR/artifacts" -name "$f" -print 2>/dev/null | head -1)" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then ok "three caught mutants: every invocation's evidence came back under its own name"
else bad "three caught mutants: evidence missing:$missing"; fi
if [ -z "$(find "$CASE_DIR/artifacts" -name 'testcount-baseline.tsv' -print 2>/dev/null)" ] \
   && [ -n "$(find "$CASE_DIR/artifacts" -name 'run-token' -print 2>/dev/null)" ]; then
  ok "three caught mutants: no test-count candidate anywhere (control: the copyback brought run-token)"
else bad "three caught mutants: a test-count candidate was written, or nothing came back"; fi
if [ "$(printf '%s\n' "$ROWS" | grep -c .)" -eq 1 ] && [ "$(printf '%s\n' "$ROWS" | awk -F '\t' '{ print $8 "/" $9 }')" = "quick/0" ]; then
  ok "three caught mutants: one run-ledger row, mode=quick exit=0"
else bad "three caught mutants: the ledger holds something else"; show "$ROWS"; fi
if ! has '^mac-gate SUMMARY: '; then ok "three caught mutants: no full-gate verdict line"
else bad "three caught mutants: a batch printed a mac-gate SUMMARY line"; fi
if [ -f "$CASE_DIR/remote-script.txt" ] && bash -n "$CASE_DIR/remote-script.txt" 2>/dev/null; then
  ok "three caught mutants: the script sent to the build host parses"
else bad "three caught mutants: the remote script does not parse"; fi
caught_case_dir="$CASE_DIR"

# --- 2: one survivor -------------------------------------------------------------------------------
P="$tmp/patches-survivor"
make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// BREAKS_TEST alpha'
make_patch "$P" 02-outside.patch "$w" Sources/Outside.swift '// HARMLESS'
make_patch "$P" 03-gamma.patch "$w" Sources/Gamma.swift '// BREAKS_TEST gamma'
run_gate survivor "$w" --quick --only-testing "$SCOPE" --mutants "$P"
if [ "$RC" -eq 17 ]; then ok "a survivor: exit 17"
else bad "a survivor: expected exit 17, got $RC"; show "$OUT"; fi
if has '^MAC_GATE_MUTANT 02-outside SURVIVED tests_rc=0$' && has '^MAC_GATE_MUTANT_SURVIVOR 02-outside SURVIVED$' \
   && [ "$(lines '^MAC_GATE_MUTANT_SURVIVOR ')" -eq 1 ]; then
  ok "a survivor: named on its own line, and only it"
else bad "a survivor: not named, or others named too"; fi
if [ "$(lines '^MAC_GATE_QUICK: lint=0 build=0 tests=17 mutants=2/3 host=stub-host locallint=- \| exit=17$')" -eq 1 ]; then
  ok "a survivor: the quick line reads tests=17 mutants=2/3 exit=17"
else bad "a survivor: unexpected quick line"; show "$(quick_line)"; fi
if d="$(host_tree_clean "$w")"; then ok "a survivor: the host tree is clean after the batch (read back)"
else bad "a survivor: the host tree is not clean"; show "$d"; fi
if [ "$(printf '%s\n' "$ROWS" | awk -F '\t' '{ print $8 "/" $9 }')" = "quick/17" ]; then
  ok "a survivor: the ledger row is mode=quick exit=17, not a refusal"
else bad "a survivor: unexpected ledger row"; show "$ROWS"; fi

# --- 3: a mutant that does not compile and one whose failure shows no failed case -----------------
P="$tmp/patches-broken"
make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// BREAKS_TEST alpha'
make_patch "$P" 02-beta.patch "$w" Sources/Beta.swift '// COMPILE_ERROR'
make_patch "$P" 03-gamma.patch "$w" Sources/Gamma.swift '// CRASH_NO_FAIL'
run_gate broken "$w" --quick --only-testing "$SCOPE" --mutants "$P"
if [ "$RC" -eq 17 ] && has '^MAC_GATE_MUTANT 02-beta BROKEN tests_rc=- build_rc=65$' \
   && has '^MAC_GATE_MUTANT 03-gamma INCONCLUSIVE tests_rc=65$' \
   && has '^MAC_GATE_MUTANT_SURVIVOR 02-beta BROKEN$' && has '^MAC_GATE_MUTANT_SURVIVOR 03-gamma INCONCLUSIVE$' \
   && [ "$(lines '^MAC_GATE_QUICK: .* mutants=1/3 ')" -eq 1 ]; then
  ok "BROKEN and INCONCLUSIVE each count as not caught: exit 17, mutants=1/3, both named"
else bad "BROKEN/INCONCLUSIVE: expected exit 17 with both named (got $RC)"; show "$(quick_line)"; fi
if [ "$(grep -c '^fake test MemosNG-quick-mutant-02' "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null)" = 0 ] \
   && [ "$(grep -c '^fake test MemosNG-quick-mutant-03' "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null)" = 1 ]; then
  ok "BROKEN: a mutant that did not build is never tested (control: 03 was)"
else bad "BROKEN: the scope ran on the products of a failed build"; fi
if d="$(host_tree_clean "$w")"; then ok "BROKEN/INCONCLUSIVE: the host tree is clean after the batch (read back)"
else bad "BROKEN/INCONCLUSIVE: the host tree is not clean"; show "$d"; fi

# --- 4: a clean run that fails runs no mutant ------------------------------------------------------
wf="$(new_repo cleanfails)" || { echo "FAIL: cannot build the fixture"; exit 1; }
printf '// CLEAN_FAILS\n' >> "$wf/Sources/Delta.swift"
git -C "$wf" commit --quiet -am "a scope that fails on its own"
P="$tmp/patches-cleanfails"
make_patch "$P" 01-alpha.patch "$wf" Sources/Alpha.swift '// BREAKS_TEST alpha'
make_patch "$P" 02-beta.patch "$wf" Sources/Beta.swift '// BREAKS_TEST beta'
run_gate cleanfails "$wf" --quick --only-testing "$SCOPE" --mutants "$P"
if [ "$RC" -eq 65 ] && [ "$(lines '^MAC_GATE_MUTANT ')" -eq 0 ] \
   && has '^MAC_GATE_MUTANTS_CLEAN_FAILED tests_rc=65$' \
   && [ "$(lines '^MAC_GATE_QUICK: lint=0 build=0 tests=65 mutants=0/2 host=stub-host locallint=- \| exit=65$')" -eq 1 ]; then
  ok "a failing clean run keeps its own code (65), runs no mutant and reads mutants=0/2"
else bad "a failing clean run: expected exit 65 and no mutant run (got $RC)"; show "$(quick_line)"; fi

# --- 5: the second clean run fails -> unsound -------------------------------------------------------
P="$tmp/patches-unsound"
make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// BREAKS_TEST alpha'
FAKE_CONTROL_FAILS=1 run_gate unsound "$w" --quick --only-testing "$SCOPE" --mutants "$P"
if [ "$RC" -eq 65 ] && has '^MAC_GATE_BATCH_UNSOUND build_rc=0 tests_rc=65 manifest=same listing=same$' \
   && [ "$(lines '^MAC_GATE_QUICK: .* tests=65 mutants=1/1 ')" -eq 1 ]; then
  ok "a failing second clean run makes the batch unsound (MAC_GATE_BATCH_UNSOUND, exit 65)"
else bad "a failing second clean run: expected MAC_GATE_BATCH_UNSOUND and exit 65 (got $RC)"; show "$(quick_line)"; fi

# --- 6: a restore that silently did nothing -> the byte compare refuses it, the file leaves the mirror
# The restore compares the bytes it put back with the copy; a file that differs is removed from the
# mirror (no later build of the lane can compile the mutant) and the batch is unsound. The give-back
# on the way out tries again, with the same lying cp, and removes it again.
P="$tmp/patches-cplies"
make_patch "$P" 01-outside.patch "$w" Sources/Outside.swift '// HARMLESS'
FAKE_CP_LIES=1 run_gate cplies "$w" --quick --only-testing "$SCOPE" --mutants "$P"
if [ "$RC" -ne 0 ] && has '^MAC_GATE_BATCH_UNSOUND build_rc=- tests_rc=- manifest=differs listing=differs$' \
   && has "^MUTANTS FAIL: 01-outside's files could not be put back; no further mutant runs$"; then
  ok "a restore that copied nothing makes the batch unsound and builds nothing more (exit $RC)"
else bad "a lying restore: expected an unsound batch with manifest=differs listing=differs (got $RC)"; show "$(quick_line)"; fi
if [ "$(grep -c '^fake build-for-testing' "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null)" = 2 ] \
   && ! grep -q 'clean-control' "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null; then
  ok "a lying restore: no clean-control build or test ran after it (two builds: the scope's, the mutant's)"
else bad "a lying restore: the run built or tested again after a failed restore"; show "$(cat "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null)"; fi
if has '^MUTANTS FAIL: Sources/Outside.swift could not be put back from the copy; removed from the mirror$'; then
  ok "a lying restore: the byte compare saw the copy fail (control: the fake cp really lied)"
else bad "a lying restore: no byte-compare failure, so the fake cp did not lie and the case proves nothing"; fi
if [ ! -e "$HOST_TREE/Sources/Outside.swift" ]; then
  ok "a lying restore: the file that could not be put back is gone from the host tree (read back)"
else bad "a lying restore: the host tree still holds Sources/Outside.swift"; show "$(head -c 300 "$HOST_TREE/Sources/Outside.swift")"; fi

# --- 6b: a mutant that could be neither put back nor removed fences the lane -----------------------
# The restore lies AND the removal fails, and the leftover mutant ends with the caller's size and
# mtime (a skewed clock is enough), so rsync's quick check skips it and a plain build would compile
# the mutant. The batch writes a fence in the lane's work directory; the next run refuses (18) and
# builds nothing; it removes the file once it can, and the run after that, whose rsync wrote it
# again, clears the fence and builds the caller's source.
fence_builds() { grep -c '^fake build-for-testing' "$CASE_DIR/host/xcodebuild-calls" 2>/dev/null || echo 0; }
FENCE_FILE_REL="host/Users/gate/build/memos-ng-ios/gate/fix%2Fmutants%mutant-fence"
P="$tmp/patches-fence"
mkdir -p "$P" "$tmp/patch-scratch"
sed '1s/.*/\/\/BREAKS_TEST_1/' "$w/Sources/Outside.swift" > "$tmp/patch-scratch/fence-new"
(cd "$w" && diff -u --label a/Sources/Outside.swift --label b/Sources/Outside.swift \
  Sources/Outside.swift "$tmp/patch-scratch/fence-new") > "$P/01-outside.patch"
FAKE_CP_LIES=1 FAKE_RM_FAILS=1 run_gate fence "$w" --quick --only-testing "$SCOPE" --mutants "$P"
fence_builds_1="$(fence_builds)"
if [ "$RC" -ne 0 ] && has '^MUTANTS FAIL: Sources/Outside.swift could not be put back from the copy nor removed' \
   && grep -Eq '^leftover [0-9a-f]{64} Sources/Outside.swift$' "$CASE_DIR/$FENCE_FILE_REL" 2>/dev/null \
   && [ "$(grep -c 'Sources/Outside.swift' "$CASE_DIR/$FENCE_FILE_REL")" = 1 ]; then
  ok "a restore and a removal that both fail write one fence line for the file (exit $RC)"
else bad "a double failure: expected one fence line naming Sources/Outside.swift (got $RC)"; show "$(cat "$CASE_DIR/$FENCE_FILE_REL" 2>/dev/null)"; fi
touch -r "$w/Sources/Outside.swift" "$HOST_TREE/Sources/Outside.swift"
if [ "$(wc -c < "$w/Sources/Outside.swift")" = "$(wc -c < "$HOST_TREE/Sources/Outside.swift")" ] \
   && ! [ "$HOST_TREE/Sources/Outside.swift" -nt "$w/Sources/Outside.swift" ] \
   && ! [ "$HOST_TREE/Sources/Outside.swift" -ot "$w/Sources/Outside.swift" ] \
   && grep -q BREAKS_TEST_1 "$HOST_TREE/Sources/Outside.swift"; then
  ok "a double failure: the leftover mutant has the caller's size and mtime (control: rsync's quick check skips it)"
else bad "a double failure: the leftover does not carry the mutant's bytes under the caller's size and mtime, so the case proves nothing"; fi
FAKE_RM_FAILS=1 run_gate fence "$w" --quick --only-testing "$SCOPE"
if [ "$RC" -eq 18 ] && [ "$(fence_builds)" = "$fence_builds_1" ] \
   && has "^MAC_GATE_MUTANT_FENCE REFUSE Sources/Outside.swift still holds a mutant's bytes and cannot be removed" \
   && has "^MAC_GATE_MUTANT_FENCE REFUSE .*/gate/fix%2Fmutants%mutant-fence exit=18: " \
   && [ "$(lines '^MAC_GATE_QUICK: lint=- build=- tests=- host=stub-host locallint=- \| exit=18$')" -eq 1 ] \
   && printf '%s\n' "$ROWS" | tail -1 | grep -q "$(printf '\trefused\t18\t')"; then
  ok "the next run refuses on the fence with 18, names the file and the fence, builds nothing (ledger: refused)"
else bad "a fenced lane: expected exit 18 and no build (got $RC)"; show "$(grep -E 'MAC_GATE_MUTANT_FENCE|^MAC_GATE_QUICK' <<<"$OUT")"; fi
# A fence the run cannot read whole is never taken for verified: unreadable, then cut short.
cp "$CASE_DIR/$FENCE_FILE_REL" "$tmp/fence-saved"
chmod 000 "$CASE_DIR/$FENCE_FILE_REL"
run_gate fence "$w" --quick --only-testing "$SCOPE"
chmod 600 "$CASE_DIR/$FENCE_FILE_REL"
if [ "$RC" -eq 18 ] && [ "$(fence_builds)" = "$fence_builds_1" ] && has '^MAC_GATE_MUTANT_FENCE REFUSE .* the fence cannot be read whole' \
   && cmp -s "$tmp/fence-saved" "$CASE_DIR/$FENCE_FILE_REL" && grep -q BREAKS_TEST_1 "$HOST_TREE/Sources/Outside.swift"; then
  ok "an unreadable fence refuses (18), builds nothing and is kept as it was"
else bad "an unreadable fence: expected exit 18 with the fence kept (got $RC)"; show "$(grep -E 'MAC_GATE_MUTANT_FENCE|^MAC_GATE_QUICK' <<<"$OUT")"; fi
printf '%s' "$(cat "$tmp/fence-saved")" > "$CASE_DIR/$FENCE_FILE_REL"
run_gate fence "$w" --quick --only-testing "$SCOPE"
if [ "$RC" -eq 18 ] && [ "$(fence_builds)" = "$fence_builds_1" ] && has '^MAC_GATE_MUTANT_FENCE REFUSE .* the fence cannot be read whole' \
   && [ -e "$CASE_DIR/$FENCE_FILE_REL" ] && grep -q BREAKS_TEST_1 "$HOST_TREE/Sources/Outside.swift"; then
  ok "a fence cut short of its last newline refuses (18) and builds nothing"
else bad "a truncated fence: expected exit 18 with the fence kept (got $RC)"; show "$(grep -E 'MAC_GATE_MUTANT_FENCE|^MAC_GATE_QUICK' <<<"$OUT")"; fi
cp "$tmp/fence-saved" "$CASE_DIR/$FENCE_FILE_REL"
# A sweep that takes the lane's work directory does not take the fence with it.
rm -rf "${CASE_DIR:?}/host/work/fix/mutants"
FAKE_RM_FAILS=0 run_gate fence "$w" --quick --only-testing "$SCOPE"
if [ "$RC" -eq 18 ] && [ "$(fence_builds)" = "$fence_builds_1" ] \
   && has "^MAC_GATE_MUTANT_FENCE REFUSE Sources/Outside.swift still held a mutant's bytes; removed from the mirror" \
   && [ ! -e "$HOST_TREE/Sources/Outside.swift" ] \
   && grep -qx 'removed - Sources/Outside.swift' "$CASE_DIR/$FENCE_FILE_REL" 2>/dev/null; then
  ok "a fenced run that can remove the leftover does, still refuses with 18 and marks it removed (read back)"
else bad "a fenced lane: the leftover was not removed and marked (got $RC)"; show "$(cat "$CASE_DIR/$FENCE_FILE_REL" 2>/dev/null)"; fi
d=""
run_gate fence "$w" --quick --only-testing "$SCOPE"
if [ "$RC" -eq 0 ] && has '^MAC_GATE_MUTANT_FENCE cleared ' && [ ! -e "$CASE_DIR/$FENCE_FILE_REL" ] \
   && [ "$(lines '^MAC_GATE_QUICK: lint=0 build=0 tests=0 host=stub-host locallint=- \| exit=0$')" -eq 1 ] \
   && d="$(host_tree_clean "$w")"; then
  ok "the run after the removal finds its rsync's copy, clears the fence and passes on the caller's source"
else bad "a fenced lane: the run after the removal did not clear the fence and pass (got $RC)"; show "$d"; show "$(grep -E 'MAC_GATE_MUTANT_FENCE|^MAC_GATE_QUICK' <<<"$OUT")"; fi
# The usual double failure keeps the patch's mtime, so the next rsync rewrites the file: that run
# verifies the rewrite by its bytes and clears the fence without refusing.
FAKE_CP_LIES=1 FAKE_RM_FAILS=1 run_gate fence2 "$w" --quick --only-testing "$SCOPE" --mutants "$P"
fence2_first="$RC"
d=""
run_gate fence2 "$w" --quick --only-testing "$SCOPE"
if [ "$fence2_first" -ne 0 ] && [ "$RC" -eq 0 ] && has '^MAC_GATE_MUTANT_FENCE verified Sources/Outside.swift: rewritten since' \
   && [ ! -e "$CASE_DIR/$FENCE_FILE_REL" ] && d="$(host_tree_clean "$w")"; then
  ok "a leftover the next rsync rewrote is verified by its bytes, the fence cleared without a refusal"
else bad "a rewritten leftover: expected the fence verified and cleared with exit 0 (got $fence2_first then $RC)"; show "$d"; fi
# A fence line the script cannot read is never taken for verified: the run refuses and keeps it.
printf 'leftover\n' > "$CASE_DIR/$FENCE_FILE_REL"
run_gate fence2 "$w" --quick --only-testing "$SCOPE"
if [ "$RC" -eq 18 ] && has "^MAC_GATE_MUTANT_FENCE REFUSE a fence line this script cannot read" \
   && grep -qx 'leftover  ' "$CASE_DIR/$FENCE_FILE_REL" 2>/dev/null; then
  ok "a fence line that names no file refuses the run (18) and stays in the fence"
else bad "a malformed fence line: expected exit 18 with the line kept (got $RC)"; show "$(cat "$CASE_DIR/$FENCE_FILE_REL" 2>/dev/null)"; fi
# The fence's name is no lane's: a branch `plain` gates beside a lane named `plain.mutant-fence`
# (a valid branch) without finding a fence, and passes.
wp="$(new_repo plainlane)" && git -C "$wp" branch -q -m fix/mutants plain
mkdir -p "$tmp/case-plainlane/host/Users/gate/build/memos-ng-ios/gate/plain.mutant-fence/Sources"
run_gate plainlane "$wp" --quick --only-testing "$SCOPE"
if [ "$RC" -eq 0 ] && [ "$(lines '^MAC_GATE_MUTANT_FENCE')" -eq 0 ] \
   && [ "$(lines '^MAC_GATE_QUICK: lint=0 build=0 tests=0 host=stub-host locallint=- \| exit=0$')" -eq 1 ]; then
  ok "a lane named <branch>.mutant-fence is not taken for that branch's fence (exit 0, no fence line)"
else bad "a lane whose name looks like a fence: expected exit 0 and no fence line (got $RC)"; show "$(grep -E 'MAC_GATE_MUTANT_FENCE|^MAC_GATE_QUICK' <<<"$OUT")"; fi
call_line="$(grep -n '^gate_mutant_fence_check || exit' "$CASE_DIR/remote-script.txt" | head -1 | cut -d: -f1)"
quick_block_line="$(grep -nF 'if [ "${GATE_QUICK:-0}" -eq 1 ]; then' "$CASE_DIR/remote-script.txt" | head -1 | cut -d: -f1)"
if [ -n "$call_line" ] && [ -n "$quick_block_line" ] && [ "$call_line" -lt "$quick_block_line" ]; then
  ok "the remote script checks the fence before either mode builds (line $call_line < $quick_block_line)"
else bad "the remote script does not check the fence before the quick and full sequences (call ${call_line:-none})"; fi

# --- 7: a signal mid-mutant still restores the tree ------------------------------------------------
P="$tmp/patches-signal"
make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// BREAKS_TEST alpha'
make_patch "$P" 02-beta.patch "$w" Sources/Beta.swift '// KILL_DURING_BUILD'
run_gate signal "$w" --quick --only-testing "$SCOPE" --mutants "$P"
if [ "$RC" -ne 0 ] && grep -q KILL_DURING_BUILD "$CASE_DIR/host/work/fix/mutants/mutants/02-beta.patch" 2>/dev/null; then
  ok "a TERM during mutant 02's build ends the run non-zero (exit $RC)"
else bad "a TERM mid-mutant: expected a non-zero exit after mutant 02 reached the host (got $RC)"; show "$(quick_line)"; fi
if d="$(host_tree_clean "$w")"; then ok "a TERM mid-mutant: the give-back restored the tree (read back)"
else bad "a TERM mid-mutant: the mutant stayed in the host tree"; show "$d"; fi

# --- 8: refusals before the estate lock, while another process holds it ----------------------------
hold_lock() { # $1 = lock file
  rm -f "$tmp/holding" "$tmp/release"
  ( exec 8>>"$1"; flock 8 || exit 1; : > "$tmp/holding"
    n=0; while [ ! -e "$tmp/release" ] && [ "$n" -lt 1800 ]; do sleep 0.1; n=$((n + 1)); done ) &
  holder_pid=$!
  n=0; while [ ! -e "$tmp/holding" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  [ -e "$tmp/holding" ]
}
release_lock() { : > "$tmp/release"; wait "$holder_pid" 2>/dev/null; holder_pid=""; }

lock="$tmp/estate.lock"
if hold_lock "$lock"; then ok "another process holds the estate lock (control for the refusals below)"
else bad "the lock holder never took the lock"; fi
refuse_before_lock() { # $1 = label, $2 = expected reason, $3 = patch dir, then extra gate args
  local label="$1" expected="$2" dir="$3" t0 t1 name ftmp; shift 3
  name="refuse-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')"
  # A candidate an earlier run left: a run refused before the lock may not clear it (it holds no
  # lock against a run of the same worktree promoting one), and its frozen copy goes with it.
  mkdir -p "$tmp/case-$name/artifacts" "$tmp/case-$name/tmp"
  printf 'MemosCoreTests\t1\n' > "$tmp/case-$name/artifacts/testcount-baseline.tsv"
  ftmp="$tmp/case-$name/tmp"
  t0="$(date +%s)"
  ESTATE_LOCK="$lock" RUN_TMPDIR="$ftmp" run_gate "$name" "$w" \
    --quick --only-testing "$SCOPE" --mutants "$dir" "$@"
  t1="$(date +%s)"
  if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF -- "$expected" && [ $((t1 - t0)) -lt 60 ] \
     && [ ! -e "$CASE_DIR/gate-runs.tsv" ] && [ ! -e "$CASE_DIR/remote-script.txt" ] \
     && [ -f "$CASE_DIR/artifacts/testcount-baseline.tsv" ] \
     && [ -z "$(ls -A "$ftmp")" ]; then
    ok "$label -> refused before the estate lock (exit 2, $((t1 - t0))s, no ledger row, nothing sent, earlier candidate kept, nothing frozen left)"
  else
    bad "$label: expected exit 2 naming '$expected' before the lock (got $RC after $((t1 - t0))s)"; show "$OUT"
  fi
}
# A removed line the file does not have: context mismatches would be absorbed by patch's fuzz.
P="$tmp/r-noapply"; mkdir -p "$P"
printf -- '--- a/Sources/Alpha.swift\n+++ b/Sources/Alpha.swift\n@@ -1 +1 @@\n-let Nothing = 0\n+let Nothing = 1\n' > "$P/01-alpha.patch"
refuse_before_lock "a patch that does not apply" "does not apply" "$P"
P="$tmp/r-twice"; make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// x'
make_patch "$P" 02-alpha.patch "$w" Sources/Alpha.swift '// y'
refuse_before_lock "two patches on one file" "touched by two patches" "$P"
# The same file spelled twice: git resolves Sources//Alpha.swift to Sources/Alpha.swift, so a check
# keyed on the spelling would count two files. A path that is not in canonical form is refused.
P="$tmp/r-twice-spelled"; make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// x'
make_patch "$P" 02-alpha.patch "$w" Sources/Alpha.swift '// y'
sed -i.bak 's#^\(---\|+++\) \([ab]\)/Sources/Alpha.swift#\1 \2/Sources//Alpha.swift#' "$P/02-alpha.patch" && rm -f "$P/02-alpha.patch.bak"
grep -q '^+++ b/Sources//Alpha.swift' "$P/02-alpha.patch" || bad "the doubled-slash patch was not written (control)"
refuse_before_lock "one file under two spellings" "not in canonical form" "$P"
P="$tmp/r-tests"; make_patch "$P" 01-check.patch "$w" Packages/Thing/Tests/ThingTests/ThingTests.swift '// x'
refuse_before_lock "a patch under a Tests directory" "under a Tests directory" "$P"
P="$tmp/r-create"; mkdir -p "$P"
printf -- '--- /dev/null\n+++ b/Sources/New.swift\n@@ -0,0 +1 @@\n+let new = 1\n' > "$P/01-new.patch"
refuse_before_lock "a patch that creates a file" "only modify existing files" "$P"
P="$tmp/r-five"
for m in 01-alpha:Alpha 02-beta:Beta 03-gamma:Gamma 04-delta:Delta 05-outside:Outside; do
  make_patch "$P" "${m%%:*}.patch" "$w" "Sources/${m##*:}.swift" '// x'
done
refuse_before_lock "a fifth patch" "at most 4 patches" "$P"
P="$tmp/r-name"; make_patch "$P" 1-alpha.patch "$w" Sources/Alpha.swift '// x'
refuse_before_lock "a patch not named NN-<name>.patch" "not named NN-<name>.patch" "$P"
P="$tmp/r-term"; make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift 'MAC_GATE_MUTANT_PATCH_x'
refuse_before_lock "a patch holding the heredoc terminator's prefix" "heredoc terminator" "$P"
P="$tmp/r-empty"; mkdir -p "$P"
refuse_before_lock "an empty patch directory" "at least one patch" "$P"
refuse_before_lock "a patch directory that does not exist" "is not a directory" "$tmp/r-nothing-here"
P="$tmp/r-escape"; mkdir -p "$P"
printf -- '--- a/../outside.swift\n+++ b/../outside.swift\n@@ -1 +1,2 @@\n let x = 1\n+// x\n' > "$P/01-escape.patch"
refuse_before_lock "a patch naming a path outside the tree" "outside the tree" "$P"
release_lock

# --- 9: combinations the batch cannot honour (refused by the copy) ---------------------------------
P="$tmp/patches-ok"; make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// BREAKS_TEST alpha'
refuse_combo() { # $1 = label, $2 = expected reason, then the gate's arguments
  local label="$1" expected="$2"; shift 2
  run_gate "combo-$(printf '%s' "$label" | tr -c 'a-z0-9' '-')" "$w" "$@"
  if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF -- "$expected" && [ ! -e "$CASE_DIR/remote-script.txt" ]; then
    ok "$label -> refused (exit 2, nothing sent)"
  else bad "$label: expected exit 2 naming '$expected' (got $RC)"; show "$OUT"; fi
}
refuse_combo "--mutants without --quick"        "--mutants needs --quick --only-testing" --mutants "$P"
refuse_combo "--mutants with --quick alone"     "--mutants needs --quick --only-testing" --quick --mutants "$P"
refuse_combo "--mutants beside --bundle"        "--mutants and --bundle"                 --quick --bundle MemosCoreTests --mutants "$P"
refuse_combo "--mutants beside --iterations"    "--mutants and --iterations"             --quick --only-testing "$SCOPE" --iterations 2 --mutants "$P"
refuse_combo "--mutants given twice"            "--mutants given twice"                  --quick --only-testing "$SCOPE" --mutants "$P" --mutants "$P"
refuse_combo "--mutants with no value"          "--mutants needs a directory"            --quick --only-testing "$SCOPE" --mutants

# --- 10: the patches are frozen when they are checked ----------------------------------------------
# The run is started while another process holds the estate lock; once its check has frozen the
# patch, the patch in <dir> is rewritten into a mutant that would SURVIVE. What reaches the host,
# and what the run reports, must still be the patch as it was checked.
P="$tmp/patches-frozen"
make_patch "$P" 01-alpha.patch "$w" Sources/Alpha.swift '// BREAKS_TEST alpha'
cp "$P/01-alpha.patch" "$tmp/frozen-original.patch"
mkdir -p "$tmp/frozen-tmp"
if hold_lock "$lock"; then
  ( ESTATE_LOCK="$lock" RUN_TMPDIR="$tmp/frozen-tmp" run_gate frozen "$w" --quick --only-testing "$SCOPE" --mutants "$P"
    printf '%s\n' "$RC" > "$tmp/frozen-rc"; printf '%s\n' "$OUT" > "$tmp/frozen-out" ) &
  bg=$!
  n=0
  while [ -z "$(find "$tmp/frozen-tmp" -name .frozen -print 2>/dev/null)" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
  if [ -n "$(find "$tmp/frozen-tmp" -name .frozen -print 2>/dev/null)" ]; then ok "the queued run froze its patches before the lock (control)"
  else bad "the queued run never showed a frozen patch set"; fi
  make_patch "$tmp/patches-edited" 01-alpha.patch "$w" Sources/Outside.swift '// HARMLESS'
  cp "$tmp/patches-edited/01-alpha.patch" "$P/01-alpha.patch"
  release_lock
  wait "$bg"
  RC="$(cat "$tmp/frozen-rc" 2>/dev/null || echo none)"; OUT="$(cat "$tmp/frozen-out" 2>/dev/null)"
  CASE_DIR="$tmp/case-frozen"
  if cmp -s "$tmp/frozen-original.patch" "$CASE_DIR/host/work/fix/mutants/mutants/01-alpha.patch"; then
    ok "an edit to <dir> during the wait never reached the host: it received the checked bytes"
  else bad "the host received something other than the patch as it was checked"; fi
  if [ "$RC" = 0 ] && has '^MAC_GATE_MUTANT 01-alpha caught tests_rc=65$'; then
    ok "the run reported the checked mutant (caught), not the edited one"
  else bad "the frozen run: expected exit 0 with 01-alpha caught (got $RC)"; show "$(quick_line)"; fi
  if [ -z "$(find "$tmp/frozen-tmp" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ]; then
    ok "the frozen run left nothing in its temporary directory"
  else bad "the frozen run left files behind"; show "$(ls -la "$tmp/frozen-tmp")"; fi
else
  bad "the lock holder never took the lock for the frozen case"
fi

# --- 11: a run without --mutants is untouched -----------------------------------------------------
run_gate plain "$w" --quick --only-testing "$SCOPE"
if [ "$RC" -eq 0 ] && [ "$(lines '^MAC_GATE_QUICK: lint=0 build=0 tests=0 host=stub-host locallint=- \| exit=0$')" -eq 1 ] \
   && [ "$(lines 'mutants=|^MAC_GATE_MUTANT')" -eq 0 ] && [ "$(spans)" = 1 ]; then
  ok "a quick run without --mutants: the old quick line, no mutant field and no mutant line"
else bad "a quick run without --mutants changed (got $RC)"; show "$(quick_line)"; fi

# --- verdict ---------------------------------------------------------------------------------------
[ -n "${caught_case_dir:-}" ] || { echo "FAIL: the batch case never ran"; fails=$((fails + 1)); }
echo "gate mutant batch: $((cases - fails)) of $cases checks as expected"
[ "$fails" -eq 0 ] || { echo "MUTANTS-TEST FAIL: $fails check(s) failed"; exit 1; }
echo "MUTANTS-TEST ok"
