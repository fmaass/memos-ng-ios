#!/usr/bin/env bash
#
# The full gate's per-bundle test count, asked the one question it exists to answer: did each
# bundle actually RUN anything?
#
# xcodebuild reports success for a bundle whose every case skipped itself, and several suites here
# skip when their preconditions are absent (no server credentials, no device capability). A count
# that increments on every Test Case node therefore reads a bundle that executed nothing as a
# bundle that ran its whole suite — the exact failure this step was written to catch. So only the
# outcomes that mean a body executed are counted (Passed, Failed, Expected Failure, the same tuple
# the quick mode's counter uses), everything else is counted apart, and a bundle with zero executed
# cases fails the step naming itself and its skips.
#
# The counter is taken out of the gate and run directly, against fixtures written here and against
# an excerpt of a real result bundle (tests/gate/fixtures/testcount-xcresult-excerpt.json: the
# MemosAPITests and MemosShareKitTests subtrees of a full gate run, verbatim, one of which carries
# two genuinely skipped cases). No xcrun, no result bundle, no Mac — it runs on the machine you are
# working from.
#
# Run it directly (`tests/gate/testcount-test.sh`) or let the gate run it: the selftest step runs
# every tests/gate/*-test.sh on every run. MAC_GATE_SCRIPT points it at another copy of the gate,
# which is how it was shown red against the commit that counted skipped cases as run.
#
# Exit: 0 = every case behaved as expected; 1 = at least one did not (the failures are named).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
GATE="${MAC_GATE_SCRIPT:-$repo_root/bin/mac-gate.sh}"
[ -x "$GATE" ] || { echo "FAIL: $GATE is not an executable file"; exit 1; }
EXCERPT="$here/fixtures/testcount-xcresult-excerpt.json"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-testcount-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
counter_control=0

ok()  { cases=$((cases + 1)); echo "ok   $1"; }
bad() { cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $1"; }

# --- the counter, extracted -----------------------------------------------------------------------
# Anchored on the invocation line rather than on the heredoc word, because the gate spells several
# of its Python heredocs 'PY' and a checker that grabbed the first of them would be testing the
# device chooser.
counter="$tmp/testcount.py"
delim="$(grep -m1 -o 'GATE_TEST_BUNDLES" <<.[A-Za-z_]*.' "$GATE" | sed "s/.*<<'\{0,1\}//; s/'\{0,1\}$//")"
if [ -n "$delim" ]; then
  awk -v d="$delim" '
    !f && /GATE_TEST_BUNDLES" <</ { f = 1; next }
    f && $0 == d { f = 0 }
    f { print }
  ' "$GATE" > "$counter"
fi
if [ -s "$counter" ] && grep -q 'nodeType' "$counter" && grep -q 'TESTCOUNT FAIL' "$counter"; then
  counter_control=1
  ok "the per-bundle test counter was found in the gate and extracted (control)"
else
  bad "no per-bundle test counter could be extracted from $GATE — the cases below would prove nothing"
fi

# The shape `xcrun xcresulttool get test-results tests --format json` emits: a tree of nodes, each
# with a nodeType, and a Test Case carrying its own result. A real run names its bundles without
# the .xctest suffix; the walker accepts either, so the fixtures below use the suffixed spelling
# and the vendored excerpt carries the real one.
write_fixture() { # $1 = file, $2 = bundle, $3... = "<case name>|<result>"
  local out="$1" bundle="$2"; shift 2
  {
    printf '{"testNodes":[{"nodeType":"Test Plan","name":"MemosNG","children":['
    printf '{"nodeType":"Unit test bundle","name":"%s.xctest","children":[' "$bundle"
    printf '{"nodeType":"Test Suite","name":"SomeTests","children":['
    local first=1 entry
    for entry in "$@"; do
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"nodeType":"Test Case","name":"%s","result":"%s"}' "${entry%%|*}" "${entry##*|}"
    done
    printf ']}]}]}]}\n'
  } > "$out"
}

run_counter() { # $1 = results json, $2 = the space-separated bundles the gate demands
  local dir="$tmp/counter-run"
  rm -rf "$dir"; mkdir -p "$dir/.gate-artifacts"
  cp "$1" "$dir/.gate-artifacts/test-results.json" || return 1
  OUT="$(cd "$dir" && python3 "$counter" "$2" 2>&1)"
  RC=$?
}

has() { printf '%s\n' "$OUT" | grep -qF "$1"; }
show() { printf '%s\n' "$OUT" | sed 's/^/     | /'; }

if [ "$counter_control" -eq 1 ]; then
  # --- (a) a bundle mixing every outcome ----------------------------------------------------------
  # Three cases ran (one passed, one failed, one failed as it was expected to) and two skipped.
  write_fixture "$tmp/mixed.json" MemosCoreTests \
    "a()|Passed" "b()|Skipped" "c()|Failed" "d()|Skipped" "e()|Expected Failure"
  run_counter "$tmp/mixed.json" "MemosCoreTests"
  if [ "$RC" -eq 0 ] && has "Executed 3 tests in MemosCoreTests" \
     && has "test counts per bundle: MemosCoreTests=3"; then
    ok "a mixed bundle counts only its executed cases (3 of 5)"
  else
    bad "a mixed bundle did not count 3 executed cases (exit $RC)"; show
  fi
  if has "skipped or not run: MemosCoreTests=2"; then
    ok "the skips are counted apart and named"
  else
    bad "the two skipped cases were never reported apart"; show
  fi

  # A failing case ran: whether the suite passes is xcodebuild's verdict, not this count's.
  write_fixture "$tmp/failed-only.json" MemosCoreTests "a()|Failed"
  run_counter "$tmp/failed-only.json" "MemosCoreTests"
  if [ "$RC" -eq 0 ] && has "Executed 1 tests in MemosCoreTests"; then
    ok "a failing case counts as executed"
  else
    bad "a failing case was not counted as executed (exit $RC)"; show
  fi

  write_fixture "$tmp/xfail-only.json" MemosCoreTests "a()|Expected Failure"
  run_counter "$tmp/xfail-only.json" "MemosCoreTests"
  if [ "$RC" -eq 0 ] && has "Executed 1 tests in MemosCoreTests"; then
    ok "an expected failure counts as executed"
  else
    bad "an expected failure was not counted as executed (exit $RC)"; show
  fi

  # --- (b) a bundle whose every case skipped ------------------------------------------------------
  write_fixture "$tmp/skipped-only.json" MemosAPITests \
    "writesAMemo()|Skipped" "writesAnAttachment()|Skipped" "readsItBack()|Skipped"
  run_counter "$tmp/skipped-only.json" "MemosAPITests"
  if [ "$RC" -eq 1 ] && has "TESTCOUNT FAIL" && has "MemosAPITests" && has "3 skipped"; then
    ok "a bundle whose every case skipped fails, naming the bundle and the skip count"
  else
    bad "a skipped-only bundle did not fail with its name and skip count (exit $RC)"; show
  fi
  if ! printf '%s\n' "$OUT" | grep -q 'Executed 3 tests'; then
    ok "a skipped case is never reported as executed"
  else
    bad "the skipped cases were reported as executed"; show
  fi

  # A result this walker has never been shown is not an execution either.
  write_fixture "$tmp/unknown-only.json" MemosAPITests "a()|Sandwich"
  run_counter "$tmp/unknown-only.json" "MemosAPITests"
  if [ "$RC" -eq 1 ] && has "TESTCOUNT FAIL" && has "1 skipped"; then
    ok "an unrecognised result is counted apart, not as an execution"
  else
    bad "an unrecognised result was treated as executed (exit $RC)"; show
  fi

  # One bundle short and one healthy: the failure names only the bundle that ran nothing, and the
  # step still fails.
  {
    printf '{"testNodes":[{"nodeType":"Test Plan","name":"MemosNG","children":['
    printf '{"nodeType":"Unit test bundle","name":"MemosCoreTests.xctest","children":['
    printf '{"nodeType":"Test Case","name":"a()","result":"Passed"}]},'
    printf '{"nodeType":"Unit test bundle","name":"MemosAPITests.xctest","children":['
    printf '{"nodeType":"Test Case","name":"b()","result":"Skipped"}]}'
    printf ']}]}\n'
  } > "$tmp/two-bundles.json"
  run_counter "$tmp/two-bundles.json" "MemosCoreTests MemosAPITests"
  if [ "$RC" -eq 1 ] && has "TESTCOUNT FAIL: MemosAPITests" \
     && ! printf '%s\n' "$OUT" | grep -q 'TESTCOUNT FAIL: MemosCoreTests'; then
    ok "with one bundle short of executions the step fails, naming only that bundle"
  else
    bad "a mixed pair of bundles was not judged per bundle (exit $RC)"; show
  fi

  # A bundle the gate demands and the results never mention is still a failure — the case this
  # step has always caught, unchanged.
  run_counter "$tmp/failed-only.json" "MemosCoreTests MemosOutboxTests"
  if [ "$RC" -eq 1 ] && has "TESTCOUNT FAIL: MemosOutboxTests"; then
    ok "a bundle absent from the results is still a failure"
  else
    bad "an absent bundle was not a failure (exit $RC)"; show
  fi

  # --- (c) an excerpt of a real result bundle -----------------------------------------------------
  if [ -f "$EXCERPT" ]; then
    run_counter "$EXCERPT" "MemosAPITests MemosShareKitTests"
    if [ "$RC" -eq 0 ] && has "Executed 38 tests in MemosAPITests" \
       && has "Executed 18 tests in MemosShareKitTests"; then
      ok "the real excerpt counts 38 and 18 executed cases (40 and 18 nodes)"
    else
      bad "the real excerpt was not counted as 38 and 18 executed cases (exit $RC)"; show
    fi
    if has "skipped or not run: MemosAPITests=2"; then
      ok "the real excerpt's two skipped cases are counted apart"
    else
      bad "the real excerpt's skipped cases were not counted apart"; show
    fi
  else
    bad "the vendored excerpt $EXCERPT is missing — the real-shape cases proved nothing"
  fi
fi

# --- verdict ----------------------------------------------------------------------------------------
if [ "$counter_control" -ne 1 ]; then
  echo "FAIL: the per-bundle test counter was never extracted, so no case above exercised it"
  fails=$((fails + 1))
fi

echo "gate test count: $((cases - fails)) of $cases checks as expected"
[ "$fails" -eq 0 ] || { echo "TESTCOUNT-TEST FAIL: $fails check(s) failed"; exit 1; }
echo "TESTCOUNT-TEST ok"
