#!/usr/bin/env bash
#
# The quick mode's own check: `bin/mac-gate.sh --quick` is an ITERATION loop, never a verdict.
#
# Two things make that true, and neither is visible in a build log. The first is the line it
# prints: `MAC_GATE_QUICK: lint=<rc> build=<rc> tests=<rc> locallint=<rc|-> | exit=<rc>` is deliberately not the full
# gate's `mac-gate SUMMARY: … | exit=<rc>`, so a quick run can never be pasted into a merge as
# evidence.
# The second is what it refuses: a scope flag without --quick, two scopes at once, a bundle the
# gate does not build, --quick beside --classify-only. Both are checked here, against throwaway
# repositories and PATH stubs for ssh and rsync — no build host, no network, no Mac.
#
# It also holds the pinning rule the quick path could quietly break: every xcodebuild invocation
# that BUILDS or TESTS carries -onlyUsePackageVersionsFromResolvedFile, in the script and in the
# script the quick run sends to the build host. That assertion is run against a sample that is
# known to be missing the flag as well, so a checker that had stopped looking would be caught.
#
# Run it directly (`tests/gate/quick-mode-test.sh`) or let the gate run it: the selftest step
# runs every tests/gate/*-test.sh on every run. MAC_GATE_SCRIPT points it at another copy of the
# gate (used to prove it is red against the commit that has no quick mode).
#
# Exit: 0 = every case behaved as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-quick-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
# The gates this suite starts never queue behind an estate lock a parent gate holds, and their run
# ledger rows land here rather than in the estate's ledger.
unset MAC_GATE_ESTATE_LOCK MAC_GATE_ESTATE_LOCK_STAMPS MAC_GATE_SIMULATOR
export MAC_GATE_RUNS_LEDGER="$tmp/gate-runs.tsv"

fails=0
cases=0
quick_line_seen=0
summary_pattern_control=0

ok()   { cases=$((cases + 1)); echo "ok   $1"; }
bad()  { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }

# The full gate's verdict line, as a pattern. Nothing the quick mode prints may match it, so the
# pattern itself has to be shown to match something — a checker whose regex had rotted would
# otherwise report "no match" about every line ever printed.
# Written as an extended regular expression: in a basic one, GNU grep reads a backslashed pipe as
# alternation, and the pattern would match half of every line it was pointed at.
SUMMARY_RE='^mac-gate SUMMARY: .* \| exit=[0-9]+$'

# --- part 1: the refusals -------------------------------------------------------------------------
# Each one exits 2 AND says which rule it applied. The message is checked because exit 2 is also
# what an unrelated refusal returns (no git tree, no build host): a case that fell through to one
# of those would pass a check that only read the code.
refuse() {
  local label="$1" expected="$2"; shift 2
  local out rc
  out="$(cd "$repo_root" && env -u MAC_GATE_HOST -u MAC_GATE_BRANCH "$GATE" "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne 2 ]; then
    bad "$label: expected exit 2, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  if ! printf '%s\n' "$out" | grep -qF "$expected"; then
    bad "$label: exit 2, but the reason did not name the rule (wanted: $expected)"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  ok "$label -> refused (exit 2)"
}

refuse "--bundle without --quick"            "only mean something with --quick" --bundle MemosCoreTests
refuse "--only-testing without --quick"      "only mean something with --quick" --only-testing MemosCoreTests/StubTransportTests
refuse "both scopes at once"                 "two ways to name one scope"       --quick --bundle MemosCoreTests --only-testing MemosCoreTests/X
refuse "--bundle with an empty value"        "needs a test bundle name"         --quick --bundle ""
refuse "--bundle swallowing the next flag"   "needs a test bundle name"         --quick --bundle --only-testing
refuse "--bundle with no value at all"       "needs a test bundle name"         --quick --bundle
refuse "--only-testing with an empty value"  "needs an xcodebuild test identifier" --quick --only-testing ""
refuse "--only-testing with no value at all" "needs an xcodebuild test identifier" --quick --only-testing
refuse "--quick beside --classify-only"      "ask for different things"         --quick --classify-only
refuse "--classify-only beside --quick"      "ask for different things"         --classify-only --quick
refuse "--bundle naming an unbuilt bundle"   "not one of the test bundles"      --quick --bundle NotABundleTests
# " $TEST_BUNDLES " contains "MemosAPITests MemosCoreTests" as a substring, so a membership test
# written that way accepts a value naming no bundle; a trailing space is the same defect wearing a
# real name.
refuse "--bundle naming two bundles at once" "contains whitespace"                --quick --bundle "MemosAPITests MemosCoreTests"
refuse "--bundle with a trailing space"      "contains whitespace"                --quick --bundle "MemosCoreTests "

# --iterations repeats ONE named scope until it fails, so it needs --quick --only-testing, and its
# value is a positive whole number with a ceiling: every iteration holds the host-wide simulator slot.
refuse "--iterations with --quick alone"        "needs --quick --only-testing"   --quick --iterations 5
refuse "--iterations with --bundle"             "needs --quick --only-testing"   --quick --bundle MemosCoreTests --iterations 5
refuse "--iterations with no scope and no quick" "needs --quick --only-testing"  --iterations 5
refuse "--iterations with no value at all"      "needs a positive whole number"  --quick --only-testing MemosCoreTests/X --iterations
refuse "--iterations with an empty value"       "needs a positive whole number"  --quick --only-testing MemosCoreTests/X --iterations ""
refuse "--iterations swallowing the next flag"  "needs a positive whole number"  --quick --iterations --only-testing MemosCoreTests/X
refuse "--iterations zero"                      "not a positive whole number"    --quick --only-testing MemosCoreTests/X --iterations 0
refuse "--iterations negative"                  "needs a positive whole number"  --quick --only-testing MemosCoreTests/X --iterations -3
refuse "--iterations not a number"              "not a positive whole number"    --quick --only-testing MemosCoreTests/X --iterations five
refuse "--iterations a fraction"                "not a positive whole number"    --quick --only-testing MemosCoreTests/X --iterations 1.5
refuse "--iterations with a leading zero"       "not a positive whole number"    --quick --only-testing MemosCoreTests/X --iterations 05
refuse "--iterations with whitespace"           "not a positive whole number"    --quick --only-testing MemosCoreTests/X --iterations "5 "
refuse "--iterations above the ceiling"         "at most 1000"                   --quick --only-testing MemosCoreTests/X --iterations 1001
refuse "--iterations far above the ceiling"     "at most 1000"                   --quick --only-testing MemosCoreTests/X --iterations 99999999999999999999

# --- the fixture ----------------------------------------------------------------------------------
# A repository shaped like this one in the only ways the local half of the gate reads: a HEAD, an
# origin/main to measure against, a project.yml with the version keys, the named selftests and
# the lane reaper the preflight script carries over.
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
  for stub in fastpath-classify-test.sh warnings-canary-test.sh testcount-test.sh admission-test.sh mainbar-freeze-rule-test.sh mount-guard-test.sh mount-refusal-path-test.sh testflight-cut-test.sh release-notes-rule-test.sh local-lint-test.sh local-lint-refusal-path-test.sh host-routing-test.sh mutants-test.sh bump-build-test.sh applinks-rule-test.sh; do
    printf '#!/bin/sh\necho "%s stub ok"\nexit 0\n' "$stub" > "$work/tests/gate/$stub"
    chmod +x "$work/tests/gate/$stub"
  done
  printf 'gate_lane_is_unlocked() { return 0; }\n' > "$work/scripts/reap-gate-lanes.sh"
  cp "$repo_root/scripts/gate-admission.sh" "$work/scripts/gate-admission.sh" || return 1
  cp "$repo_root/scripts/release-version-rule.sh" "$work/scripts/release-version-rule.sh" || return 1
  cp "$repo_root/scripts/gate-mount-guard.sh" "$work/scripts/gate-mount-guard.sh" || return 1
  git -C "$work" add -A >/dev/null || return 1
  git -C "$work" commit --quiet -m "baseline" || return 1
  git -C "$work" remote add origin "$origin"
  git -C "$work" push --quiet origin main || return 1
  printf '%s' "$work"
}

# ssh and rsync, replaced. The ssh stub answers the three questions the local half asks — the disk
# admission, the preflight (gate root, target, lock), and the remote script — and records the remote
# script it was handed, which is the only place the flags sent to the build host can be read.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  # the device give-back: nothing of this run's is on the host, so it answers as it would there
  *simctl*) exit 1 ;;
esac
script="$(cat)"
case "$script" in
  # the build root's mount guard (its call is the line the gate appends to the helper): a healthy mount
  *'
gate_mount_guard report '*) echo "MOUNT OK uuid=stub dev=/dev/disk8s1"; echo "mountguard=enforced marker=not-read"; exit 0 ;;
  # the run admission's disk reading, known by its call (the remote script carries the helper that
  # defines it, so the helper's own text cannot tell the two apart): room enough, admitted at once
  *'gate_lane_space "$target"'*) echo "FREE_KB 99999999 OWN_KB 0"; exit 0 ;;
  *MAC_GATE_STEP*)
    printf '%s' "$script" > "$QUICK_STUB_DIR/remote-script.txt"
    [ -z "${QUICK_STUB_REMOTE_OUT:-}" ] || cat "$QUICK_STUB_REMOTE_OUT"
    exit "${QUICK_STUB_REMOTE_RC:-0}" ;;
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
exit 0
RSYNC_EOF
  chmod +x "$dir/bin/ssh" "$dir/bin/rsync"
}

# One run of the gate against the stubs. OUT and RC are what the case then reads.
run_gate() {
  local work="$1" stubdir="$2"; shift 2
  OUT="$(cd "$work" && env -u MAC_GATE_BRANCH \
    "PATH=$stubdir/bin:$PATH" \
    MAC_GATE_HOST=stub-host \
    MAC_GATE_ARTIFACTS="$stubdir/artifacts" \
    QUICK_STUB_DIR="$stubdir" \
    QUICK_STUB_REMOTE_OUT="${STUB_REMOTE_OUT:-}" \
    QUICK_STUB_REMOTE_RC="${STUB_REMOTE_RC:-0}" \
    "$GATE" "$@" 2>&1)"
  RC=$?
}

# A case's stub directory, its scripted remote transcript, and its expectations in one place.
new_case() {
  local name="$1"
  CASE_DIR="$tmp/case-$name"
  mkdir -p "$CASE_DIR"
  make_stubs "$CASE_DIR"
  rm -f "$CASE_DIR/remote-script.txt"
}

count_lines() { printf '%s\n' "$1" | grep -Ec "$2"; }

# --- part 2: a quick run that passes ----------------------------------------------------------------
w="$(new_repo quick-pass)" || { echo "FAIL: cannot build the quick-pass fixture"; exit 1; }
git -C "$w" checkout --quiet -b fix/quick-pass
printf 'let two = 2\n' >> "$w/Sources/App.swift"
git -C "$w" commit --quiet -am "a source change, so this is not a docs-only change set"

new_case pass
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
::: lint :::
MAC_GATE_STEP lint 0
::: generate :::
MAC_GATE_STEP generate 0
::: build :::
MAC_GATE_STEP build 0
::: tests :::
test counts for the quick scope: MemosCoreTests=214
MAC_GATE_STEP tests 0
MAC_GATE_QUICK_REMOTE: lint=0 build=0 tests=0
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$w" "$CASE_DIR" --quick

if [ "$RC" -eq 0 ]; then ok "a passing quick run exits 0"
else bad "a passing quick run exits 0 (got $RC)"; printf '%s\n' "$OUT" | sed 's/^/     | /'; fi

n="$(count_lines "$OUT" '^MAC_GATE_QUICK: lint=0 build=0 tests=0 host=stub-host locallint=- \| exit=0$')"
if [ "$n" -eq 1 ]; then quick_line_seen=1; ok "it prints exactly one MAC_GATE_QUICK line"
else bad "expected exactly one 'MAC_GATE_QUICK: lint=0 build=0 tests=0 host=stub-host locallint=- | exit=0' line, found $n"
     printf '%s\n' "$OUT" | sed 's/^/     | /'; fi

n="$(count_lines "$OUT" "$SUMMARY_RE")"
if [ "$n" -eq 0 ]; then ok "it prints no line a full gate's verdict pattern would match"
else bad "a quick run printed $n line(s) matching the full gate's verdict pattern"
     printf '%s\n' "$OUT" | grep -E "$SUMMARY_RE" | sed 's/^/     | /'; fi

# The pattern above proves nothing until it is shown to match the line it was written for.
if printf '%s\n' "mac-gate SUMMARY: selftest=0 classify=0 rsync=0 remote=0 copyback=0 | exit=0" \
   | grep -Eq "$SUMMARY_RE"; then
  summary_pattern_control=1
  ok "the full gate's verdict pattern matches a literal full-gate summary line (control)"
else
  bad "the full gate's verdict pattern matches nothing at all — it proves nothing about the quick line"
fi

# What was sent to the build host. A quick run that had quietly kept `xcodebuild test` would look
# identical from here except in this file.
if [ -s "$CASE_DIR/remote-script.txt" ]; then
  ok "the quick run reached the build host (a remote script was sent)"
  script="$CASE_DIR/remote-script.txt"
  for needle in 'build-for-testing' 'test-without-building'; do
    if grep -q -- "$needle" "$script"; then ok "the remote script runs $needle"
    else bad "the remote script does not run $needle"; fi
  done
  if grep -q 'MAC_GATE_QUICK_REMOTE' "$script"; then ok "the remote script prints MAC_GATE_QUICK_REMOTE"
  else bad "the remote script never prints MAC_GATE_QUICK_REMOTE"; fi
  # The build host's /bin/bash is 3.2 and this script is assembled from a heredoc, so nothing on
  # this machine ever parses it — a stray quote in the quick branch would first be heard as a
  # remote syntax error minutes into a run. It is parsed here instead.
  if bash -n "$script" 2>"$CASE_DIR/parse.err"; then ok "the script sent to the build host parses"
  else bad "the script sent to the build host does not parse"; sed 's/^/     | /' "$CASE_DIR/parse.err"; fi
  # And it has to LEAVE before the full gate's steps: the line a verdict is read from is printed
  # at the end of those, so a quick branch that fell through would print one.
  quick_exit_line="$(grep -n 'exit "\$quick_exit"' "$script" | head -1 | cut -d: -f1)"
  first_step_line="$(grep -n '^step ' "$script" | head -1 | cut -d: -f1)"
  # The echo, not a mention of it: this block's own comments name the line too.
  summary_line="$(grep -n 'echo "MAC_GATE_REMOTE_SUMMARY' "$script" | head -1 | cut -d: -f1)"
  if [ -n "$quick_exit_line" ] && [ -n "$first_step_line" ] && [ -n "$summary_line" ] \
     && [ "$quick_exit_line" -lt "$first_step_line" ] && [ "$quick_exit_line" -lt "$summary_line" ]; then
    ok "the quick branch exits before the full gate's steps and before MAC_GATE_REMOTE_SUMMARY"
  else
    bad "the quick branch does not exit before the full gate's steps (exit at ${quick_exit_line:-none}, first step at ${first_step_line:-none}, summary at ${summary_line:-none})"
  fi
else
  bad "the quick run sent no remote script"
fi

# --- part 2b: what the quick sequence actually DOES ---------------------------------------------------
# Lint runs first there, and a lint error stops the run: no generate, no build, no tests. No grep can
# establish that. The ssh stub above saves the remote script and prints a scripted transcript without
# ever running it, and s_format is in that script anyway for the full path — so a whole-file grep and
# a fed lint= line would both still pass after someone took lint out of the quick block, and neither
# can tell a lint that stops the run from one that only remembers its rc. So the sequence is cut out
# of the saved script and RUN, with its four steps replaced by stubs that say they were called.
quick_seq="$CASE_DIR/quick-sequence.sh"
awk 'index($0, "quick_tests_rc=\"-\"") { f = 1 }
     f { print }
     f && index($0, "exit \"$quick_exit\"") { exit }' \
  "$CASE_DIR/remote-script.txt" > "$quick_seq" 2>/dev/null

# The extraction's own control: two anchors that stopped matching, or a step that left the sequence,
# would otherwise make every case below pass by running nothing. Each step is looked for as a whole
# line and nothing else, because the sequence's own comments name the steps too — a control a
# comment can satisfy is not a control.
seq_names_all=1
for needle in s_format s_quick_generate s_quick_build s_quick_tests; do
  grep -Eq "^[[:space:]]*$needle[[:space:]]*$" "$quick_seq" || seq_names_all=0
done
if [ -s "$quick_seq" ] && [ "$seq_names_all" -eq 1 ]; then
  ok "the quick sequence was cut out of the remote script and names all four of its steps (control)"
else
  bad "the quick sequence extracted from the remote script is empty or does not name all four steps"
  sed 's/^/     | /' "$quick_seq" 2>/dev/null
fi

# One run of the extracted sequence. The stubs announce themselves on stdout, so the ORDER they were
# called in is read back from the same stream the sequence's own lines come out of.
run_quick_sequence() { # $1 = the rc the lint stub returns; sets SEQ_OUT, SEQ_RC, SEQ_CALLS
  SEQ_OUT="$(QUICK_SEQ_LINT_RC="$1" bash -c '
    set -uo pipefail
    quick_scope=""
    s_format()         { echo "CALL:format";   return "$QUICK_SEQ_LINT_RC"; }
    s_quick_generate() { echo "CALL:generate"; return 0; }
    s_quick_build()    { echo "CALL:build";    return 0; }
    s_quick_tests()    { echo "CALL:tests";    return 0; }
    . "$1"
  ' _ "$quick_seq" 2>&1)"
  SEQ_RC=$?
  SEQ_CALLS="$(printf '%s\n' "$SEQ_OUT" | sed -n 's/^CALL://p' | tr '\n' ' ')"
  SEQ_CALLS="${SEQ_CALLS% }"
}

if [ -s "$quick_seq" ]; then
  run_quick_sequence 1
  if [ "$SEQ_CALLS" = "format" ] && [ "$SEQ_RC" -eq 1 ] \
     && printf '%s\n' "$SEQ_OUT" | grep -q '^MAC_GATE_QUICK_REMOTE: lint=1 build=- tests=-$'; then
    ok "a failed lint stops the quick sequence: only lint ran, it reports lint=1 build=- tests=- and exits 1"
  else
    bad "a failed lint did not stop the quick sequence (steps: ${SEQ_CALLS:-none}, exit $SEQ_RC)"
    printf '%s\n' "$SEQ_OUT" | sed 's/^/     | /'
  fi

  run_quick_sequence 0
  if [ "$SEQ_CALLS" = "format generate build tests" ] && [ "$SEQ_RC" -eq 0 ]; then
    ok "a clean lint is followed by generate, build and tests, in that order"
  else
    bad "a clean lint was not followed by generate, build and tests (steps: ${SEQ_CALLS:-none}, exit $SEQ_RC)"
    printf '%s\n' "$SEQ_OUT" | sed 's/^/     | /'
  fi
fi

# --- the pinning rule -------------------------------------------------------------------------------
# Every xcodebuild that builds or tests reads the resolved file, or the build is free to resolve
# its way past a pin and say nothing. Checked over whole invocations, continuation lines included.
cat > "$tmp/pinflag.awk" <<'AWK_EOF'
function emit() {
  total++
  if (buf !~ /onlyUsePackageVersionsFromResolvedFile/) {
    bad++
    print "MISSING " buf
  }
  buf = ""; collecting = 0
}
function quoted(prefix,   i, n) {
  # An xcodebuild inside a quoted string is prose — a refusal message, an echo, a help line — not
  # a command. An odd number of double quotes before it is what says so.
  n = 0
  for (i = 1; i <= length(prefix); i++) if (substr(prefix, i, 1) == "\"") n++
  return n % 2
}
{
  line = $0
  if (line ~ /^[ \t]*#/) next
  if (collecting) {
    buf = buf " " line
    if (line !~ /\\[ \t]*$/) emit()
    next
  }
  if (match(line, /xcodebuild[ \t]+[A-Za-z][A-Za-z-]*/)) {
    if (quoted(substr(line, 1, RSTART - 1))) next
    piece = substr(line, RSTART, RLENGTH)
    split(piece, part, /[ \t]+/)
    cmd = part[2]
    if (cmd == "build" || cmd == "test" || cmd == "archive" \
        || cmd == "build-for-testing" || cmd == "test-without-building") {
      buf = line; collecting = 1
      if (line !~ /\\[ \t]*$/) emit()
    }
  }
}
END { print "TOTAL " total + 0; print "BAD " bad + 0 }
AWK_EOF

pinflag_check() { # $1 = file; prints "TOTAL n" / "BAD n" and the offenders
  awk -f "$tmp/pinflag.awk" "$1"
}

pin_out="$(pinflag_check "$GATE")"
pin_total="$(printf '%s\n' "$pin_out" | sed -n 's/^TOTAL //p')"
pin_bad="$(printf '%s\n' "$pin_out" | sed -n 's/^BAD //p')"
if [ "${pin_total:-0}" -ge 4 ] && [ "${pin_bad:-1}" -eq 0 ]; then
  ok "every building xcodebuild invocation in the gate carries -onlyUsePackageVersionsFromResolvedFile ($pin_total invocations)"
else
  bad "the gate has $pin_total building xcodebuild invocation(s), ${pin_bad:-?} without -onlyUsePackageVersionsFromResolvedFile (expected >= 4 and none)"
  printf '%s\n' "$pin_out" | grep '^MISSING' | sed 's/^/     | /'
fi

# The same check, run on a sample that IS missing the flag: a checker that had stopped reading
# would report a clean gate either way.
{
  printf 'xcodebuild test \\\n'
  printf '  -scheme MemosNG \\\n'
  printf '  -destination "x"\n'
} > "$tmp/unpinned-sample.sh"
neg_out="$(pinflag_check "$tmp/unpinned-sample.sh")"
if [ "$(printf '%s\n' "$neg_out" | sed -n 's/^BAD //p')" -eq 1 ]; then
  ok "the pinning check reports a sample that is missing the flag (control)"
else
  bad "the pinning check passed a sample that is missing the flag — it proves nothing"
  printf '%s\n' "$neg_out" | sed 's/^/     | /'
fi

# And the other way: a line that only TALKS about xcodebuild is not an invocation, so a checker
# that counted prose would report offenders the gate could never fix.
printf 'die_refuse "--only-testing needs an xcodebuild test identifier"\n' > "$tmp/prose-sample.sh"
prose_out="$(pinflag_check "$tmp/prose-sample.sh")"
if [ "$(printf '%s\n' "$prose_out" | sed -n 's/^TOTAL //p')" -eq 0 ]; then
  ok "the pinning check reads a quoted mention of xcodebuild as prose, not as an invocation"
else
  bad "the pinning check counted a quoted mention of xcodebuild as an invocation"
  printf '%s\n' "$prose_out" | sed 's/^/     | /'
fi

if [ -s "$CASE_DIR/remote-script.txt" ]; then
  rem_out="$(pinflag_check "$CASE_DIR/remote-script.txt")"
  rem_total="$(printf '%s\n' "$rem_out" | sed -n 's/^TOTAL //p')"
  rem_bad="$(printf '%s\n' "$rem_out" | sed -n 's/^BAD //p')"
  if [ "${rem_total:-0}" -ge 2 ] && [ "${rem_bad:-1}" -eq 0 ]; then
    ok "both xcodebuild invocations sent to the build host carry the resolved-file flag"
  else
    bad "the remote script sent $rem_total building xcodebuild invocation(s), ${rem_bad:-?} without the resolved-file flag (expected >= 2 and none)"
    printf '%s\n' "$rem_out" | grep '^MISSING' | sed 's/^/     | /'
  fi
fi

# --- part 3: a quick run whose build fails ----------------------------------------------------------
new_case buildfail
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
::: lint :::
MAC_GATE_STEP lint 0
::: generate :::
MAC_GATE_STEP generate 0
::: build :::
error: cannot find 'nope' in scope
MAC_GATE_STEP build 65
::: tests skipped (the build failed) :::
MAC_GATE_QUICK_REMOTE: lint=0 build=65 tests=-
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=65 run_gate "$w" "$CASE_DIR" --quick

if [ "$RC" -eq 65 ]; then ok "a failing build exits with the build's own code"
else bad "a failing build should exit 65, got $RC"; printf '%s\n' "$OUT" | sed 's/^/     | /'; fi
n="$(count_lines "$OUT" '^MAC_GATE_QUICK: lint=0 build=65 tests=- host=stub-host locallint=- \| exit=65$')"
if [ "$n" -eq 1 ]; then ok "a failing build reports lint=0 build=65 tests=- host=stub-host locallint=- | exit=65"
else bad "expected 'MAC_GATE_QUICK: lint=0 build=65 tests=- host=stub-host locallint=- | exit=65', found $n such line(s)"
     printf '%s\n' "$OUT" | sed 's/^/     | /'; fi
n="$(count_lines "$OUT" "$SUMMARY_RE")"
[ "$n" -eq 0 ] && ok "a failing quick run still prints no verdict line" \
  || bad "a failing quick run printed $n verdict-shaped line(s)"

# --- part 3b: a quick run whose lint fails ------------------------------------------------------------
# The other half of the stop, read from the outside: the local half repeats the lint rc the build host
# reported, says nothing was built or tested, and exits with the lint's own code.
new_case lintfail
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
::: lint :::
Sources/App.swift:1:1: error: [Indentation] unexpected indentation
MAC_GATE_STEP lint 1
::: generate, build and tests skipped (the lint failed) :::
MAC_GATE_QUICK_REMOTE: lint=1 build=- tests=-
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=1 run_gate "$w" "$CASE_DIR" --quick

n="$(count_lines "$OUT" '^MAC_GATE_QUICK: lint=1 build=- tests=- host=stub-host locallint=- \| exit=1$')"
if [ "$RC" -eq 1 ] && [ "$n" -eq 1 ]; then
  ok "a failing lint reports lint=1 build=- tests=- host=stub-host locallint=- | exit=1"
else
  bad "expected exit 1 and one 'lint=1 build=- tests=- host=stub-host locallint=- | exit=1' line, got exit $RC and $n line(s)"
  printf '%s\n' "$OUT" | sed 's/^/     | /'
fi
n="$(count_lines "$OUT" "$SUMMARY_RE")"
[ "$n" -eq 0 ] && ok "a lint-failed quick run still prints no verdict line" \
  || bad "a lint-failed quick run printed $n verdict-shaped line(s)"

# --- part 4: a remote that stopped before it said anything ------------------------------------------
# The lock this run held was reaped while it was starting (exit 4). Nothing was built, so there is
# no rc to report — and reporting one would be worse than reporting none.
new_case nolines
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
remote: the gate lock of this run was taken over while it was starting
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=4 run_gate "$w" "$CASE_DIR" --quick
n="$(count_lines "$OUT" '^MAC_GATE_QUICK: lint=- build=- tests=- host=stub-host locallint=- \| exit=4$')"
if [ "$RC" -eq 4 ] && [ "$n" -eq 1 ]; then
  ok "a remote that reported no step reads lint=- build=- tests=- host=stub-host locallint=- | exit=4"
else
  bad "expected exit 4 and one 'lint=- build=- tests=- host=stub-host locallint=- | exit=4' line, got exit $RC and $n line(s)"
  printf '%s\n' "$OUT" | sed 's/^/     | /'
fi

# --- part 5: --bundle carries a scope to the build host ---------------------------------------------
new_case scope
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
MAC_GATE_STEP lint 0
MAC_GATE_STEP generate 0
MAC_GATE_STEP build 0
MAC_GATE_STEP tests 0
MAC_GATE_QUICK_REMOTE: lint=0 build=0 tests=0
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$w" "$CASE_DIR" --quick --bundle MemosCoreTests
if [ "$RC" -eq 0 ] && grep -q "GATE_QUICK_BUNDLE='MemosCoreTests'" "$CASE_DIR/remote-script.txt" 2>/dev/null \
   && grep -q -- '-only-testing:' "$CASE_DIR/remote-script.txt" 2>/dev/null; then
  ok "--bundle reaches the build host as an -only-testing scope"
else
  bad "--bundle did not reach the build host as a scope (exit $RC)"
  printf '%s\n' "$OUT" | sed 's/^/     | /'
fi

# --- part 5b: --iterations carries a repeat count to the build host and onto the quick line ----------
new_case iterations
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
MAC_GATE_STEP lint 0
MAC_GATE_STEP generate 0
MAC_GATE_STEP build 0
MAC_GATE_STEP tests 0
MAC_GATE_QUICK_REMOTE: lint=0 build=0 tests=0
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$w" "$CASE_DIR" \
  --quick --only-testing MemosCoreTests/LiveWriteTests --iterations 50
if [ "$RC" -eq 0 ] && grep -q "GATE_QUICK_ITERATIONS='50'" "$CASE_DIR/remote-script.txt" 2>/dev/null; then
  ok "--iterations reaches the build host as GATE_QUICK_ITERATIONS"
else
  bad "--iterations did not reach the build host (exit $RC)"
  printf '%s\n' "$OUT" | sed 's/^/     | /'
fi
# The flags themselves, on the line that appends them — a comment naming them is not the append.
if grep -Eq '^[[:space:]]*\[ -z "\$GATE_QUICK_ITERATIONS" \] \|\| set -- "\$@" -test-iterations "\$GATE_QUICK_ITERATIONS" -run-tests-until-failure$' \
     "$CASE_DIR/remote-script.txt" 2>/dev/null; then
  ok "the remote quick test command appends -test-iterations N -run-tests-until-failure"
else
  bad "the remote quick test command does not append -test-iterations and -run-tests-until-failure"
fi
n="$(count_lines "$OUT" '^MAC_GATE_QUICK: lint=0 build=0 tests=0 iterations=50 host=stub-host locallint=- \| exit=0$')"
if [ "$n" -eq 1 ]; then ok "the quick line names the iteration count it ran with"
else bad "expected one 'MAC_GATE_QUICK: lint=0 build=0 tests=0 iterations=50 host=stub-host locallint=- | exit=0' line, found $n"
     printf '%s\n' "$OUT" | sed 's/^/     | /'; fi
# Without the option nothing changes: no iterations field, an empty count sent.
if grep -q "GATE_QUICK_ITERATIONS=''" "$tmp/case-scope/remote-script.txt" 2>/dev/null; then
  ok "a run without --iterations sends an empty count"
else
  bad "a run without --iterations did not send an empty GATE_QUICK_ITERATIONS"
fi

# --- part 6: a docs-only change set does not short-circuit a quick run ------------------------------
# The fast path is a VERDICT about a change set. A quick run is not a verdict, it is a request to
# compile and test — so it goes to the build host whatever the change set looks like.
d="$(new_repo quick-docs)" || { echo "FAIL: cannot build the quick-docs fixture"; exit 1; }
git -C "$d" checkout --quiet -b fix/quick-docs
printf 'more guide\n' >> "$d/docs/guide.md"
git -C "$d" commit --quiet -am "docs only"

new_case docs
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
MAC_GATE_STEP lint 0
MAC_GATE_STEP generate 0
MAC_GATE_STEP build 0
MAC_GATE_STEP tests 0
MAC_GATE_QUICK_REMOTE: lint=0 build=0 tests=0
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$d" "$CASE_DIR" --quick
if [ "$RC" -eq 0 ] && [ -s "$CASE_DIR/remote-script.txt" ] \
   && ! printf '%s\n' "$OUT" | grep -q 'fast path: docs-only'; then
  ok "a docs-only change set still reaches the build host under --quick"
else
  bad "a docs-only --quick run took the fast path or never reached the build host (exit $RC)"
  printf '%s\n' "$OUT" | sed 's/^/     | /'
fi

# --- part 7: the full gate is untouched -------------------------------------------------------------
# The same fixture, the same stubs, no --quick: the verdict line comes back and the quick line does
# not. This is the other half of the separation — and its verdict line is a second, live control on
# the pattern used above.
new_case fullgate
cat > "$CASE_DIR/remote.txt" <<'REMOTE_EOF'
MAC_GATE_STEP xcodegen 0
MAC_GATE_REMOTE_SUMMARY: xcodegen=0 xcodebuild=0 | exit=0
REMOTE_EOF
STUB_REMOTE_OUT="$CASE_DIR/remote.txt" STUB_REMOTE_RC=0 run_gate "$w" "$CASE_DIR"
n="$(count_lines "$OUT" "$SUMMARY_RE")"
q="$(count_lines "$OUT" '^MAC_GATE_QUICK: ')"
if [ "$RC" -eq 0 ] && [ "$n" -eq 1 ] && [ "$q" -eq 0 ]; then
  ok "the full gate still prints its verdict line and no quick line"
else
  bad "the full gate printed $n verdict line(s) and $q quick line(s) (exit $RC); expected 1 and 0"
  printf '%s\n' "$OUT" | sed 's/^/     | /'
fi

# --- part 8: a skipped case is not an executed case -------------------------------------------------
# The counter the build host runs, taken out of the gate and asked the question directly. It exists
# to answer "did anything actually run": xcodebuild reports success for a scope whose every case
# skipped itself, and several suites here skip when their preconditions are absent — so a scope of
# nothing but skips must be a failure, and one real case among them must not.
counter="$tmp/quick-count.py"
awk '/<<.QUICKCOUNT_PY./{f=1;next} f && /^QUICKCOUNT_PY$/{f=0} f{print}' "$GATE" > "$counter"
counter_control=0
if [ -s "$counter" ] && grep -q 'nodeType' "$counter" && grep -q 'QUICK FAIL' "$counter"; then
  counter_control=1
  ok "the executed-test counter was found in the gate and extracted (control)"
else
  bad "no executed-test counter could be extracted from $GATE — the cases below would prove nothing"
fi

# The shape `xcrun xcresulttool get test-results tests --format json` emits: a tree of nodes, each
# with a nodeType, and a Test Case carrying its own result.
write_fixture() { # $1 = file, $2... = "<case name>|<result>" (none = a bundle that ran nothing)
  local out="$1"; shift
  {
    printf '{"testNodes":[{"nodeType":"Test Plan","name":"MemosNG","children":['
    printf '{"nodeType":"Unit test bundle","name":"MemosCoreTests.xctest","children":['
    printf '{"nodeType":"Test Suite","name":"LiveWriteTests","children":['
    local first=1 entry
    for entry in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"nodeType":"Test Case","name":"%s","result":"%s"}' "${entry%%|*}" "${entry##*|}"
    done
    printf ']}]}]}]}\n'
  } > "$out"
}

run_counter() { # $1 = fixture, $2 = scope, $3 = the --iterations count (optional)
  local dir="$tmp/counter-run"
  rm -rf "$dir"; mkdir -p "$dir/.gate-artifacts"
  cp "$1" "$dir/.gate-artifacts/quick-test-results.json"
  OUT="$(cd "$dir" && python3 "$counter" "$2" "${3:-}" 2>&1)"
  RC=$?
}

# A run with -test-iterations: each Test Case carries one Repetition child per run.
# $1 = file, $2... = "<case name>|<case result>|<repetition results, comma-separated or empty>"
write_rep_fixture() {
  local out="$1"; shift
  {
    printf '{"testNodes":[{"nodeType":"Test Plan","name":"MemosNG","children":['
    printf '{"nodeType":"Unit test bundle","name":"MemosCoreTests.xctest","children":['
    printf '{"nodeType":"Test Suite","name":"UnreachableRecoveryTests","children":['
    local first=1 entry name rest result reps rep rfirst
    for entry in "$@"; do
      name="${entry%%|*}"; rest="${entry#*|}"; result="${rest%%|*}"; reps="${rest#*|}"
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"nodeType":"Test Case","name":"%s","result":"%s","children":[' "$name" "$result"
      rfirst=1
      if [ -n "$reps" ]; then
        local i=0
        for rep in ${reps//,/ }; do
          i=$((i + 1))
          [ "$rfirst" -eq 1 ] || printf ','
          rfirst=0
          printf '{"nodeType":"Repetition","name":"Repetition %d","result":"%s"}' "$i" "$rep"
        done
      fi
      printf ']}'
    done
    printf ']}]}]}]}\n'
  } > "$out"
}

if [ "$counter_control" -eq 1 ]; then
  # The finding itself: a suite that skips itself without its preconditions.
  write_fixture "$tmp/skipped-only.json" "writesAMemo()|Skipped" "writesAnAttachment()|Skipped"
  run_counter "$tmp/skipped-only.json" MemosCoreTests/LiveWriteTests
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'QUICK FAIL' \
     && printf '%s\n' "$OUT" | grep -q 'MemosCoreTests/LiveWriteTests' \
     && printf '%s\n' "$OUT" | grep -q '2 skipped'; then
    ok "a scope whose every case skipped is a failure naming the scope and the skips"
  else
    bad "a skipped-only scope did not fail with the scope and the skip count (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  write_fixture "$tmp/passed-only.json" "writesAMemo()|Passed"
  run_counter "$tmp/passed-only.json" MemosCoreTests/LiveWriteTests
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'Executed 1 test cases'; then
    ok "a scope with one passing case is not a failure"
  else
    bad "a passing scope was rejected (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  # One real case among the skips is enough; and a failing case ran, whatever it decided.
  write_fixture "$tmp/mixed.json" "a()|Skipped" "b()|Passed" "c()|Skipped"
  run_counter "$tmp/mixed.json" MemosCoreTests/LiveWriteTests
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'Executed 1 test cases'; then
    ok "one executed case among skips passes, and the skips are still counted apart"
  else
    bad "a mixed scope did not count only the executed case (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  write_fixture "$tmp/failed-only.json" "a()|Failed"
  run_counter "$tmp/failed-only.json" MemosCoreTests/LiveWriteTests
  if [ "$RC" -eq 0 ]; then
    ok "a failing case counts as executed (the test result is xcodebuild's verdict, not this count's)"
  else
    bad "a failing case was counted as not executed (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  write_fixture "$tmp/empty.json"
  run_counter "$tmp/empty.json" MemosCoreTests/LiveWriteTests
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'QUICK FAIL'; then
    ok "a bundle that ran nothing at all is a failure"
  else
    bad "an empty result bundle was not a failure (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  # With no scope, --quick alone, the whole bundle is the question.
  write_fixture "$tmp/skipped-noscope.json" "a()|Skipped"
  run_counter "$tmp/skipped-noscope.json" ""
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'every bundle'; then
    ok "an unscoped run of nothing but skips is a failure naming every bundle"
  else
    bad "an unscoped skipped-only run was not a failure (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  # --iterations: the result bundle has to SHOW the runs that were asked for, every one passing.
  S=MemosCoreTests/UnreachableRecoveryTests
  write_rep_fixture "$tmp/reps-ok.json" "a()|Passed|Passed,Passed,Passed"
  run_counter "$tmp/reps-ok.json" "$S" 3
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'Ran 3 iterations of each of 1 executed test cases'; then
    ok "three asked, three passing repetitions shown: not a failure, and the count is printed"
  else
    bad "a run showing every asked-for repetition was rejected or not described (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  write_rep_fixture "$tmp/reps-failed.json" "a()|Failed|Passed,Passed,Failed"
  run_counter "$tmp/reps-failed.json" "$S" 3
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'QUICK FAIL: 1 of 3 repetitions failed'; then
    ok "a failure in any one repetition fails the count"
  else
    bad "a failed repetition did not fail the count (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  write_rep_fixture "$tmp/reps-ignored.json" "a()|Passed|"
  run_counter "$tmp/reps-ignored.json" "$S" 3
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'QUICK FAIL: asked for 3 iterations'; then
    ok "a bundle that shows no repetitions when 3 were asked for is a failure (iterations not honoured)"
  else
    bad "a run that ignored --iterations was not a failure (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  write_rep_fixture "$tmp/reps-short.json" "a()|Passed|Passed,Passed,Passed" "b()|Passed|Passed,Passed"
  run_counter "$tmp/reps-short.json" "$S" 3
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'QUICK FAIL: asked for 3 iterations'; then
    ok "one case short of the asked-for repetitions fails the count (off by one)"
  else
    bad "a case one repetition short was not a failure (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  # One iteration is a plain run: no repetition nodes are owed.
  write_rep_fixture "$tmp/reps-one.json" "a()|Passed|"
  run_counter "$tmp/reps-one.json" "$S" 1
  if [ "$RC" -eq 0 ]; then ok "--iterations 1 with no repetition nodes is not a failure"
  else bad "--iterations 1 was failed for showing no repetitions (exit $RC)"
       printf '%s\n' "$OUT" | sed 's/^/     | /'; fi

  # One iteration asked, two runs shown: an explicit repetition group is held to N at N=1 too.
  write_rep_fixture "$tmp/reps-one-two.json" "a()|Passed|Passed,Passed"
  run_counter "$tmp/reps-one-two.json" "$S" 1
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'QUICK FAIL: asked for 1 iterations'; then
    ok "--iterations 1 with two repetitions shown is a failure (explicit groups are held to N)"
  else
    bad "--iterations 1 with two passing repetitions was not a failure (exit $RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi

  # And without --iterations the repetition check never runs, whatever the bundle shows.
  run_counter "$tmp/reps-failed.json" "$S"
  if [ "$RC" -eq 0 ]; then ok "without --iterations the count does not judge repetitions (xcodebuild's rc does)"
  else bad "without --iterations the count judged repetitions (exit $RC)"
       printf '%s\n' "$OUT" | sed 's/^/     | /'; fi
fi

# --- verdict ----------------------------------------------------------------------------------------
if [ "$counter_control" -ne 1 ]; then
  echo "FAIL: the executed-test counter was never extracted, so no case above exercised it"
  fails=$((fails + 1))
fi
if [ "$quick_line_seen" -ne 1 ]; then
  echo "FAIL: no case ever saw a MAC_GATE_QUICK line — this suite proves nothing about a quick mode that prints none"
  fails=$((fails + 1))
fi
if [ "$summary_pattern_control" -ne 1 ]; then
  echo "FAIL: the full gate's verdict pattern was never shown to match anything"
  fails=$((fails + 1))
fi

echo "gate quick mode: $((cases - fails)) of $cases checks as expected"
[ "$fails" -eq 0 ] || { echo "QUICK-MODE-TEST FAIL: $fails check(s) failed"; exit 1; }
echo "QUICK-MODE-TEST ok"
