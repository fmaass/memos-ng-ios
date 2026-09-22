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
# Running at all is a floor, not a count. A bundle that lost half its cases still runs something,
# so the step also judges each bundle's executed count against the row the tracked baseline holds
# for it: below its row fails, equal or above passes. That arithmetic is scripts/testcount-verdict.sh,
# and everything a baseline cannot answer — absent, unreadable, malformed, short of a bundle the
# gate wanted, or naming one it did not — fails too, because a missing input that read as a zero
# would make every bundle look healthy.
#
# The counter is taken out of the gate and run directly, against fixtures written here and against
# an excerpt of a real result bundle (tests/gate/fixtures/testcount-xcresult-excerpt.json: the
# MemosAPITests and MemosShareKitTests subtrees of a full gate run, verbatim, one of which carries
# two genuinely skipped cases), and the verdict script is fed the candidate the counter just wrote.
# No xcrun, no result bundle, no Mac — it runs on the machine you are working from.
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
VERDICT="$repo_root/scripts/testcount-verdict.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-testcount-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
counter_control=0
verdict_control=0
pass_seen=0

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

# The other half of the step. Without it nothing below compares anything, so its absence is a
# failure of this suite rather than a set of cases quietly skipped.
if [ -x "$VERDICT" ]; then
  verdict_control=1
  ok "the baseline comparison $VERDICT is present and executable (control)"
else
  bad "$VERDICT is missing or not executable — no case below would compare a count with a baseline"
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

# Two bundles in one result tree, each with a run of passed cases: for the comparison it is the
# counts that matter and not the names, and one bundle cannot answer for another.
write_pair_fixture() { # $1 = file, $2/$3 = a bundle and how many cases it passed, $4/$5 = the other
  local out="$1" i
  {
    printf '{"testNodes":[{"nodeType":"Test Plan","name":"MemosNG","children":['
    printf '{"nodeType":"Unit test bundle","name":"%s.xctest","children":[' "$2"
    for i in $(seq 1 "$3"); do
      [ "$i" -eq 1 ] || printf ','
      printf '{"nodeType":"Test Case","name":"a%d()","result":"Passed"}' "$i"
    done
    printf ']},{"nodeType":"Unit test bundle","name":"%s.xctest","children":[' "$4"
    for i in $(seq 1 "$5"); do
      [ "$i" -eq 1 ] || printf ','
      printf '{"nodeType":"Test Case","name":"b%d()","result":"Passed"}' "$i"
    done
    printf ']}]}]}\n'
  } > "$out"
}

baseline() { # $1 = a name for the file, then <bundle> <count> pairs; prints the path it wrote
  local f="$tmp/baseline-$1.tsv"; shift
  : > "$f"
  while [ "$#" -ge 2 ]; do
    printf '%s\t%s\n' "$1" "$2" >> "$f"
    shift 2
  done
  printf '%s' "$f"
}

run_counter() { # $1 = results json, $2 = the space-separated bundles the gate demands
  local dir="$tmp/counter-run"
  rm -rf "$dir"; mkdir -p "$dir/.gate-artifacts"
  cp "$1" "$dir/.gate-artifacts/test-results.json" || return 1
  CANDIDATE="$dir/.gate-artifacts/testcount-baseline.tsv"
  OUT="$(cd "$dir" && python3 "$counter" "$2" 2>&1)"
  RC=$?
}

# The step as the gate assembles it: the counter writes the candidate counts, the verdict script
# judges that candidate against a baseline, and the step's exit is the first non-zero of the two.
# Reading only one of them would let a case be answered by the half it was not about.
run_step() { # $1 = results json, $2 = the bundles the gate demands, $3 = the baseline file
  local counter_out counter_rc verdict_out verdict_rc
  run_counter "$1" "$2"
  counter_out="$OUT"; counter_rc="$RC"
  verdict_out="$("$VERDICT" "$CANDIDATE" "$3" 2>&1)"
  verdict_rc=$?
  # The suite's positive control on the comparison: a verdict that refused every baseline it was
  # ever shown would satisfy each failing case below and prove nothing about the passing ones.
  [ "$verdict_rc" -ne 0 ] || pass_seen=1
  RC="$verdict_rc"
  [ "$counter_rc" -eq 0 ] || RC="$counter_rc"
  OUT="$counter_out
$verdict_out"
}

has() { printf '%s\n' "$OUT" | grep -qF "$1"; }
show() { printf '%s\n' "$OUT" | sed 's/^/     | /'; }

# Every case below is given a baseline of its own, whose rows are the counts that case's fixture
# executes, so what it asserts is still the thing it was written to assert and not an incidental
# disagreement with a number recorded somewhere else.
if [ "$counter_control" -eq 1 ] && [ "$verdict_control" -eq 1 ]; then
  # --- (a) a bundle mixing every outcome ----------------------------------------------------------
  # Three cases ran (one passed, one failed, one failed as it was expected to) and two skipped.
  write_fixture "$tmp/mixed.json" MemosCoreTests \
    "a()|Passed" "b()|Skipped" "c()|Failed" "d()|Skipped" "e()|Expected Failure"
  run_step "$tmp/mixed.json" "MemosCoreTests" "$(baseline mixed MemosCoreTests 3)"
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
  run_step "$tmp/failed-only.json" "MemosCoreTests" "$(baseline failed-only MemosCoreTests 1)"
  if [ "$RC" -eq 0 ] && has "Executed 1 tests in MemosCoreTests"; then
    ok "a failing case counts as executed"
  else
    bad "a failing case was not counted as executed (exit $RC)"; show
  fi

  write_fixture "$tmp/xfail-only.json" MemosCoreTests "a()|Expected Failure"
  run_step "$tmp/xfail-only.json" "MemosCoreTests" "$(baseline xfail-only MemosCoreTests 1)"
  if [ "$RC" -eq 0 ] && has "Executed 1 tests in MemosCoreTests"; then
    ok "an expected failure counts as executed"
  else
    bad "an expected failure was not counted as executed (exit $RC)"; show
  fi

  # --- (b) a bundle whose every case skipped ------------------------------------------------------
  write_fixture "$tmp/skipped-only.json" MemosAPITests \
    "writesAMemo()|Skipped" "writesAnAttachment()|Skipped" "readsItBack()|Skipped"
  run_step "$tmp/skipped-only.json" "MemosAPITests" "$(baseline skipped-only MemosAPITests 0)"
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
  run_step "$tmp/unknown-only.json" "MemosAPITests" "$(baseline unknown-only MemosAPITests 0)"
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
  run_step "$tmp/two-bundles.json" "MemosCoreTests MemosAPITests" \
    "$(baseline two-bundles MemosCoreTests 1 MemosAPITests 0)"
  if [ "$RC" -eq 1 ] && has "TESTCOUNT FAIL: MemosAPITests" \
     && ! printf '%s\n' "$OUT" | grep -q 'TESTCOUNT FAIL: MemosCoreTests'; then
    ok "with one bundle short of executions the step fails, naming only that bundle"
  else
    bad "a mixed pair of bundles was not judged per bundle (exit $RC)"; show
  fi

  # A bundle the gate demands and the results never mention is still a failure — the case this
  # step has always caught, unchanged.
  run_step "$tmp/failed-only.json" "MemosCoreTests MemosOutboxTests" \
    "$(baseline absent-bundle MemosCoreTests 1 MemosOutboxTests 0)"
  if [ "$RC" -eq 1 ] && has "TESTCOUNT FAIL: MemosOutboxTests"; then
    ok "a bundle absent from the results is still a failure"
  else
    bad "an absent bundle was not a failure (exit $RC)"; show
  fi

  # --- (c) an excerpt of a real result bundle -----------------------------------------------------
  if [ -f "$EXCERPT" ]; then
    run_step "$EXCERPT" "MemosAPITests MemosShareKitTests" \
      "$(baseline excerpt MemosAPITests 38 MemosShareKitTests 18)"
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

  # --- (d) the count judged against the tracked baseline ------------------------------------------
  # Equal is the shape of a healthy run, and one of the two cases here that expect the comparison
  # to accept anything at all: without them a verdict script that refused every input would
  # satisfy all the rest.
  run_step "$tmp/mixed.json" "MemosCoreTests" "$(baseline equal MemosCoreTests 3)"
  if [ "$RC" -eq 0 ] && ! has "TESTCOUNT FAIL"; then
    ok "a bundle whose count equals its baseline row passes"
  else
    bad "an equal count did not pass (exit $RC)"; show
  fi

  # A branch that adds tests is the ordinary case. It passes, and it is never asked to re-record
  # the baseline for having done so.
  run_step "$tmp/mixed.json" "MemosCoreTests" "$(baseline risen MemosCoreTests 2)"
  if [ "$RC" -eq 0 ] && ! has "TESTCOUNT FAIL"; then
    ok "a bundle whose count rose above its baseline row passes"
  else
    bad "a risen count did not pass (exit $RC)"; show
  fi

  # The loss this comparison exists for. Both numbers belong on the line: without them nobody
  # reading a failed gate can tell a deliberate reduction from a suite that stopped being built.
  run_step "$tmp/mixed.json" "MemosCoreTests" "$(baseline fallen MemosCoreTests 4)"
  if [ "$RC" -eq 1 ] \
     && has "TESTCOUNT FAIL: MemosCoreTests executed 3 cases, below the 4 its baseline row records"; then
    ok "a bundle whose count fell fails, naming the bundle, the baseline and the observed count"
  else
    bad "a fallen count did not fail with both numbers (exit $RC)"; show
  fi

  # Each bundle is judged on its own row and nothing else. Here the two bundles sum to the same
  # total as their baselines, and one of them has still lost a case: any aggregate — a total, an
  # average, a count of bundles at or above — passes this and would have hidden the loss.
  write_pair_fixture "$tmp/mixed-direction.json" MemosCoreTests 9 MemosAPITests 11
  run_step "$tmp/mixed-direction.json" "MemosCoreTests MemosAPITests" \
    "$(baseline mixed-direction MemosCoreTests 10 MemosAPITests 10)"
  if [ "$RC" -eq 1 ] \
     && has "TESTCOUNT FAIL: MemosCoreTests executed 9 cases, below the 10 its baseline row records" \
     && ! has "TESTCOUNT FAIL: MemosAPITests"; then
    ok "one bundle below and one above is a failure naming only the one that fell"
  else
    bad "a fallen bundle was excused by a risen one (exit $RC)"; show
  fi

  # --- (e) a baseline that cannot answer ----------------------------------------------------------
  # Absent, unreadable, malformed, short of a bundle the gate wanted, or naming one it did not:
  # each of these is a baseline that says nothing, and a step that let one of them through would
  # report every bundle healthy at the moment it had stopped looking.
  run_step "$tmp/mixed.json" "MemosCoreTests" "$tmp/baseline-that-was-never-written.tsv"
  if [ "$RC" -eq 2 ] && has "TESTCOUNT FAIL" && has "baseline-that-was-never-written.tsv"; then
    ok "an absent baseline fails, naming the path it looked for"
  else
    bad "an absent baseline did not fail (exit $RC)"; show
  fi

  mkdir -p "$tmp/baseline-is-a-directory.tsv"
  run_step "$tmp/mixed.json" "MemosCoreTests" "$tmp/baseline-is-a-directory.tsv"
  if [ "$RC" -eq 2 ] && has "TESTCOUNT FAIL"; then
    ok "a baseline path that is not a readable file fails"
  else
    bad "an unreadable baseline did not fail (exit $RC)"; show
  fi

  write_pair_fixture "$tmp/pair-3-3.json" MemosCoreTests 3 MemosAPITests 3
  run_step "$tmp/pair-3-3.json" "MemosCoreTests MemosAPITests" \
    "$(baseline short MemosAPITests 3)"
  if [ "$RC" -eq 1 ] && has "TESTCOUNT FAIL: MemosCoreTests has no row in the baseline"; then
    ok "a baseline short of a bundle the gate wanted fails, naming that bundle"
  else
    bad "a baseline missing a bundle's row did not fail (exit $RC)"; show
  fi

  run_step "$tmp/pair-3-3.json" "MemosCoreTests MemosAPITests" \
    "$(baseline surplus MemosCoreTests 3 MemosAPITests 3 MemosOutboxTests 5)"
  if [ "$RC" -eq 2 ] && has "holds a row for MemosOutboxTests, which this run did not measure"; then
    ok "a baseline row for a bundle the gate did not want fails, naming that row"
  else
    bad "a surplus baseline row did not fail (exit $RC)"; show
  fi

  printf 'MemosCoreTests 3\n' > "$tmp/baseline-untabbed.tsv"
  run_step "$tmp/mixed.json" "MemosCoreTests" "$tmp/baseline-untabbed.tsv"
  if [ "$RC" -eq 2 ] && has "TESTCOUNT FAIL"; then
    ok "a baseline row that is not <bundle> TAB <count> fails"
  else
    bad "an untabbed baseline row was accepted (exit $RC)"; show
  fi

  printf 'MemosCoreTests\tthree\n' > "$tmp/baseline-unnumbered.tsv"
  run_step "$tmp/mixed.json" "MemosCoreTests" "$tmp/baseline-unnumbered.tsv"
  if [ "$RC" -eq 2 ] && has "TESTCOUNT FAIL"; then
    ok "a baseline count that is not a number fails"
  else
    bad "a non-numeric baseline count was accepted (exit $RC)"; show
  fi

  # Two rows for one bundle: whichever of them the comparison read, the other one was a number
  # nobody applied.
  run_step "$tmp/mixed.json" "MemosCoreTests" "$(baseline duplicate MemosCoreTests 3 MemosCoreTests 4)"
  if [ "$RC" -eq 2 ] && has "names MemosCoreTests twice"; then
    ok "a baseline naming a bundle twice fails"
  else
    bad "a duplicated baseline row was accepted (exit $RC)"; show
  fi
fi

# --- verdict ----------------------------------------------------------------------------------------
if [ "$counter_control" -ne 1 ]; then
  echo "FAIL: the per-bundle test counter was never extracted, so no case above exercised it"
  fails=$((fails + 1))
fi
if [ "$verdict_control" -ne 1 ]; then
  echo "FAIL: $VERDICT was never run, so no case above compared a count with a baseline"
  fails=$((fails + 1))
fi
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no baseline was ever accepted — a comparison that refused every input would pass this suite"
  fails=$((fails + 1))
fi

echo "gate test count: $((cases - fails)) of $cases checks as expected"
[ "$fails" -eq 0 ] || { echo "TESTCOUNT-TEST FAIL: $fails check(s) failed"; exit 1; }
echo "TESTCOUNT-TEST ok"
