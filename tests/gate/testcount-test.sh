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
# The write permission a case takes off its folder is given back here too, so a case that dies
# half-way cannot leave a tree `rm -rf` refuses.
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

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

# The cases in (a) to (c) are about the counter, and each of them is given a baseline of its own
# whose rows are the counts that case's fixture executes, so what it asserts is still the thing it
# was written to assert and not an incidental disagreement with a number recorded somewhere else.
# The cases from (d) on are about the comparison, and each one's baseline is built to pin exactly
# one behaviour of it. Mostly that means differing from the fixture in the one way that case is
# about; the equal case at the head of (d) is the one that agrees with its fixture, because the
# floor is met by equality too, and no other case in (d) asks the comparison to accept that.
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
  # total as their baselines, and one of them has still lost a case: a condition on the total
  # passes this and would have hidden the loss. So does one on the average — not because the two
  # are the same number (the total is 20 and the average 10), but because over a fixed pair of
  # bundles the average moves only as the total does, so on this fixture the two give the same
  # verdict. That no other aggregate may decide it either is the rule, not something this fixture
  # shows: a count of bundles at or above their row is 1 of 2 here, and rejects it.
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

  # A count too long to be one is not a number the comparison can use, and bash's own arithmetic
  # says so by failing rather than by answering: a test that errors is neither true nor false, and
  # an `if` reads it as false, which is the answer that passes. So the shape is refused before any
  # comparison is attempted, on either file.
  printf 'MemosCoreTests\t999999999999999999999999999999\n' > "$tmp/baseline-enormous.tsv"
  run_step "$tmp/mixed.json" "MemosCoreTests" "$tmp/baseline-enormous.tsv"
  if [ "$RC" -eq 2 ] && has "TESTCOUNT FAIL" && ! has "TESTCOUNT ok"; then
    ok "a baseline count too long to be a number fails instead of passing on a failed comparison"
  else
    bad "an enormous baseline count was not refused (exit $RC)"; show
  fi

  # The same shape on the other side: a bundle named twice in the list the gate wants gives the
  # counter's candidate two rows for it, and a comparison that read both at once would compare
  # neither.
  run_step "$tmp/mixed.json" "MemosCoreTests MemosCoreTests" "$(baseline dup-observed MemosCoreTests 3)"
  if [ "$RC" -eq 2 ] && has "names MemosCoreTests twice" && ! has "TESTCOUNT ok"; then
    ok "an observed file naming a bundle twice fails"
  else
    bad "a duplicated observed row was accepted (exit $RC)"; show
  fi

  # Bytes that never survive being read as rows. `read` drops a NUL without a word, so the row it
  # hands back validates while the file it came from holds something else; and every row of this
  # format ends in LF, so a file whose last byte is not one is refused for lacking it — which is
  # all its bytes establish, and all the fixture below claims.
  printf 'MemosCoreTests\t3\000\n' > "$tmp/baseline-nul.tsv"
  run_step "$tmp/mixed.json" "MemosCoreTests" "$tmp/baseline-nul.tsv"
  if [ "$RC" -eq 2 ] && has "TESTCOUNT FAIL" && ! has "TESTCOUNT ok"; then
    ok "a baseline holding a byte that is not printable ASCII, TAB or LF fails"
  else
    bad "a baseline with a NUL byte in it was accepted (exit $RC)"; show
  fi

  # The same NUL, in a file long enough to lose the race a short one always wins. A scanner that
  # stops at its first hit closes the pipe under its producer; the producer dies of SIGPIPE and
  # `pipefail` hands back 141, which an `if` reads as "clean", and the file is let through. One row
  # of padding is 40 000 characters, past every pipe buffer either machine has, so the producer is
  # still writing when the hit is found. The verdict script is called directly: the counter cannot
  # be made to write a NUL, and it is the scan that is on trial. The same file without the NUL is
  # the control — the refusal has to be about the byte and not about the size.
  long_name="AbCdEfGhIjKlMnOpQrStUvWxYz"
  while [ "${#long_name}" -lt 40000 ]; do long_name="$long_name$long_name"; done
  long_name="${long_name:0:40000}"
  printf 'MemosCoreTests\t7\n%s\t7\n' "$long_name" > "$tmp/observed-long.tsv"
  printf 'MemosCoreTests\t7\000\n%s\t7\n' "$long_name" > "$tmp/baseline-long-nul.tsv"
  printf 'MemosCoreTests\t7\n%s\t7\n' "$long_name" > "$tmp/baseline-long-clean.tsv"
  long_out="$("$VERDICT" "$tmp/observed-long.tsv" "$tmp/baseline-long-nul.tsv" 2>&1)"; long_rc=$?
  clean_out="$("$VERDICT" "$tmp/observed-long.tsv" "$tmp/baseline-long-clean.tsv" 2>&1)"; clean_rc=$?
  if [ "$clean_rc" -eq 0 ]; then
    ok "a 40 000-character row with no NUL in it passes (control)"
  else
    bad "the long fixture was refused with no NUL in it (exit $clean_rc), so the case below proves nothing"
    printf '%s\n' "$clean_out" | cut -c1-120 | sed 's/^/     | /'
  fi
  if [ "$long_rc" -eq 2 ] && printf '%s\n' "$long_out" | grep -qF "holds a NUL byte"; then
    ok "a NUL in a file too long to be scanned in one buffer still fails"
  else
    bad "a NUL was let through a long file (exit $long_rc) — the scan was answered by a broken pipe, not by the bytes"
    printf '%s\n' "$long_out" | cut -c1-120 | sed 's/^/     | /'
  fi

  printf 'MemosCoreTests\t3' > "$tmp/baseline-unterminated.tsv"
  run_step "$tmp/mixed.json" "MemosCoreTests" "$tmp/baseline-unterminated.tsv"
  if [ "$RC" -eq 2 ] && has "TESTCOUNT FAIL" && ! has "TESTCOUNT ok"; then
    ok "a baseline whose last row has no newline fails"
  else
    bad "an unterminated baseline was accepted (exit $RC)"; show
  fi
fi

# --- (f) the step the gate actually runs ------------------------------------------------------------
# Everything above takes the step apart and runs the halves, which proves the halves. A gate that
# stopped invoking the comparison, or invoked it before the counts it judges were written, would
# leave every case above green and lose exactly what the comparison was added for. So the step's own
# text is read out of the gate and held to both, by the line numbers it holds them in.
step="$tmp/s_testcount.sh"
awk '/^s_testcount\(\) [{]/ { f = 1 } f { print } f && /^[}]/ { exit }' "$GATE" > "$step"
if [ -s "$step" ] && grep -q 'GATE_TEST_BUNDLES' "$step"; then
  ok "the gate's testcount step was read out of $GATE (control)"
  # The call itself, wherever on its line it sits (the step captures its output since MEMNG-742),
  # and never a comment that names it.
  verdict_call="$(awk '!/^[[:space:]]*#/ && /"\$verdict" \.gate-artifacts\/testcount-baseline\.tsv/ { print NR; exit }' "$step")"
  candidate_write="$(grep -n 'testcount-baseline.tsv", "w"' "$step" | head -n1 | cut -d: -f1)"
  if grep -q 'scripts/testcount-verdict.sh' "$step" && [ -n "$verdict_call" ]; then
    ok "the gate's testcount step invokes the baseline comparison"
  else
    bad "the gate's testcount step does not invoke scripts/testcount-verdict.sh — the cases above judge a step the gate does not run"
  fi
  if [ -n "$candidate_write" ] && [ -n "$verdict_call" ] && [ "$candidate_write" -lt "$verdict_call" ]; then
    ok "the candidate counts are written before the comparison is asked to judge them"
  else
    bad "the candidate is not written above the comparison call (write ${candidate_write:-none}, call ${verdict_call:-none}) — a refused run would hand back nothing to re-record from"
  fi
  # The shell's comparison is not the only thing that judges these counts. The counter's own loop
  # fails a bundle that executed nothing, and a candidate written after THAT is written only because
  # the loop happens to fall through to its exit today, not because the step promised it — while
  # the check above stays green, because the write would still precede the verdict call further
  # down. So the write is held above the counter's first judgment
  # too, the line `if n < 1:`. Located with awk rather than `grep -n | head`, which would close the
  # pipe under its own producer.
  python_judgment="$(awk '/if n < 1:/ { print NR; exit }' "$step")"
  if [ -n "$candidate_write" ] && [ -n "$python_judgment" ] && [ "$candidate_write" -lt "$python_judgment" ]; then
    ok "the candidate counts are written before the counter judges them either"
  else
    bad "the candidate is not written above the counter's own judgment (write ${candidate_write:-none}, \`if n < 1:\` ${python_judgment:-none}) — a bundle that executed nothing would leave no candidate"
  fi
else
  bad "no s_testcount function could be read out of $GATE — the two checks it carries proved nothing"
fi

# --- (g) whose candidate reaches the documented path ------------------------------------------------
# The copyback fetches whatever the build host's artifacts folder holds, and that folder is cleared
# only by the remote script: a remote that stopped before clearing it leaves the previous run's
# candidate to be copied back as if it were this one's. So the remote stamps the folder with this
# run's token on the same chain as the clear, the copy lands in a staging folder of this run's, and
# scripts/testcount-candidate-owner.sh promotes the candidate to the documented path only when the
# staged stamp reads exactly that token. Each case below is run against folders built here; every
# case that depends on the decision fails when the decision is inverted.
OWNER="$repo_root/scripts/testcount-candidate-owner.sh"
owner_control=0
tok="0123456789abcdef"
# $1 = a name. Sets A (the artifacts folder) and S (this run's staging folder inside it), with a
# candidate, a build log and a result-bundle directory staged, as a copyback would leave them.
owner_case() {
  A="$tmp/owner-$1/artifacts"
  S="$A/incoming-$tok"
  mkdir -p "$S/MemosNG.xcresult" \
    && printf 'MemosAPITests\t38\n' > "$S/testcount-baseline.tsv" \
    && printf 'build log\n' > "$S/build.log" \
    && printf 'bundle\n' > "$S/MemosNG.xcresult/Info.plist"
}
run_owner() { OUT="$("$OWNER" "$@" 2>&1)"; RC=$?; }
evidence_promoted() { [ -f "$A/build.log" ] && [ -f "$A/MemosNG.xcresult/Info.plist" ]; }
if [ ! -x "$OWNER" ]; then
  bad "$OWNER is missing or not executable, so no copyback could tell this run's candidate from an earlier one's"
else
  owner_case equal; printf '%s\n' "$tok" > "$S/run-token"
  run_owner "$S" "$A" "$tok"
  if [ "$RC" -eq 0 ] && [ -f "$A/testcount-baseline.tsv" ] && [ -f "$A/run-token" ] \
     && evidence_promoted && [ ! -e "$S" ]; then
    ok "a candidate staged beside this run's stamp is moved to the documented path, the rest with it, the staging folder gone"
    owner_control=1
  else
    bad "a candidate staged beside this run's stamp was not promoted, or the staging folder stayed (exit $RC)"; show
  fi

  # A result bundle an earlier run left at the destination is replaced, not merged into or nested.
  owner_case replace; printf '%s\n' "$tok" > "$S/run-token"
  mkdir -p "$A/MemosNG.xcresult" && printf 'old\n' > "$A/MemosNG.xcresult/old.txt"
  run_owner "$S" "$A" "$tok"
  if [ "$RC" -eq 0 ] && [ -f "$A/MemosNG.xcresult/Info.plist" ] && [ ! -e "$A/MemosNG.xcresult/old.txt" ] \
     && [ ! -e "$A/MemosNG.xcresult/MemosNG.xcresult" ] && [ -f "$A/testcount-baseline.tsv" ]; then
    ok "an earlier run's result bundle at the destination is replaced by this run's, not merged or nested"
  else
    bad "an earlier run's result bundle was merged into or nested under this run's (exit $RC): $(find "$A/MemosNG.xcresult" | tr '\n' ' ')"; show
  fi

  owner_case differs; printf '%s\n' "fedcba9876543210" > "$S/run-token"
  run_owner "$S" "$A" "$tok"
  if [ "$RC" -eq 3 ] && [ ! -e "$A/testcount-baseline.tsv" ] && [ ! -e "$S" ] && evidence_promoted \
     && has "stamp differs" && has "not as this run's"; then
    ok "a candidate staged beside another run's stamp is discarded, the rest promoted as evidence, the reason printed (exit 3)"
  else
    bad "a candidate staged beside another run's stamp reached the documented path, or the rest was not promoted, or no reason was printed (exit $RC)"; show
  fi

  owner_case extra; printf '%s\nsomething else\n' "$tok" > "$S/run-token"
  run_owner "$S" "$A" "$tok"
  if [ "$RC" -eq 3 ] && [ ! -e "$A/testcount-baseline.tsv" ] && has "stamp differs"; then
    ok "a stamp holding this run's token and anything more is not this run's stamp"
  else
    bad "a stamp holding this run's token plus a second line was accepted (exit $RC)"; show
  fi

  owner_case absent
  run_owner "$S" "$A" "$tok"
  if [ "$RC" -eq 3 ] && [ ! -e "$A/testcount-baseline.tsv" ] && [ ! -e "$S" ] && evidence_promoted \
     && has "stamp absent"; then
    ok "a candidate staged with no stamp at all is discarded, the rest promoted, the reason printed (exit 3)"
  else
    bad "a candidate staged with no stamp reached the documented path, or no reason was printed (exit $RC)"; show
  fi

  # A copy that failed before it created the staging folder: nothing to judge, nothing created.
  A="$tmp/owner-nostaging/artifacts"; S="$A/incoming-$tok"; mkdir -p "$A"
  run_owner "$S" "$A" "$tok"
  if [ "$RC" -eq 3 ] && [ -z "$(ls -A "$A")" ] && has "stamp absent"; then
    ok "a staging folder the copy never created is answered as an absent stamp, and nothing is created (exit 3)"
  else
    bad "a missing staging folder was answered with exit $RC or created something: $(ls -A "$A" | tr '\n' ' ')"; show
  fi

  # This run's stamp and no candidate: nothing may be created at the documented path, and the stamp
  # this run wrote is promoted — where an inverted decision shows even with no candidate.
  A="$tmp/owner-stamp-only/artifacts"; S="$A/incoming-$tok"; mkdir -p "$S"; printf '%s\n' "$tok" > "$S/run-token"
  run_owner "$S" "$A" "$tok"
  if [ "$RC" -eq 0 ] && [ "$(ls -A "$A")" = "run-token" ] && has "none came back"; then
    ok "a staging folder holding only this run's stamp promotes the stamp and nothing else, exit 0"
  else
    bad "a staging folder holding only this run's stamp was answered with exit $RC or left: $(ls -A "$A" | tr '\n' ' ')"; show
  fi

  owner_case usage; printf '%s\n' "$tok" > "$S/run-token"
  run_owner "$S" "$A"
  if [ "$RC" -eq 2 ] && [ ! -e "$A/testcount-baseline.tsv" ] && [ -f "$S/testcount-baseline.tsv" ]; then
    ok "a call missing its run token is a usage error that touches nothing (exit 2)"
  else
    bad "a call missing its run token was answered with exit $RC, or moved something"; show
  fi

  # A4: on this run's stamp the candidate is promoted first and alone. The destination is made
  # read-only so that rename fails; nothing else may then be promoted and the staging folder stays.
  owner_case stuck-rename; printf '%s\n' "$tok" > "$S/run-token"
  chmod 555 "$A"
  run_owner "$S" "$A" "$tok"
  chmod 755 "$A"
  if [ "$RC" -eq 1 ] && [ ! -e "$A/testcount-baseline.tsv" ] && [ -f "$S/testcount-baseline.tsv" ] \
     && [ -f "$S/build.log" ] && [ ! -e "$A/build.log" ] && has "$S"; then
    ok "a candidate that cannot be renamed into place fails the script (exit 1), promotes nothing and keeps the staging folder, named"
  else
    bad "a failed candidate rename was answered with exit $RC, or something was promoted, or the staging folder went"; show
  fi

  # A4: on a stamp that is not this run's the candidate is deleted first. The staging folder is made
  # read-only so that deletion fails; nothing may then be promoted.
  owner_case stuck-delete; printf '%s\n' "fedcba9876543210" > "$S/run-token"
  chmod 555 "$S"
  run_owner "$S" "$A" "$tok"
  chmod 755 "$S"
  if [ "$RC" -eq 1 ] && [ -f "$S/testcount-baseline.tsv" ] && [ ! -e "$A/testcount-baseline.tsv" ] \
     && [ ! -e "$A/build.log" ] && has "could NOT be removed"; then
    ok "a candidate not this run's that cannot be deleted fails the script (exit 1) and promotes nothing"
  else
    bad "an undeletable candidate not this run's was answered with exit $RC, or something was promoted"; show
  fi

  # A4: after the candidate, a file of the rest that cannot be moved up is a failure too, and the
  # staging folder stays. An earlier result bundle at the destination that cannot be replaced does it.
  owner_case stuck-rest; printf '%s\n' "$tok" > "$S/run-token"
  mkdir -p "$A/MemosNG.xcresult/Data" && printf 'old\n' > "$A/MemosNG.xcresult/Data/old"
  chmod 555 "$A/MemosNG.xcresult/Data"
  run_owner "$S" "$A" "$tok"
  chmod 755 "$A/MemosNG.xcresult/Data"
  if [ "$RC" -eq 1 ] && [ -d "$S" ] && [ -f "$A/testcount-baseline.tsv" ]; then
    ok "a staged file that cannot be moved up after the candidate fails the script (exit 1) and keeps the staging folder"
  else
    bad "a failed move of the rest was answered with exit $RC, or the staging folder went"; show
  fi
fi
if [ "$owner_control" -ne 1 ]; then
  echo "FAIL: no candidate was ever promoted — an owner script that discarded every candidate would pass the cases that discard"
  fails=$((fails + 1))
fi

# The startup cleanup (A1, A5, A6). Driven through the gate itself, from outside any git tree,
# with an explicit artifacts folder and no build host: the run is refused, and the refusal comes
# after the cleanup, so an earlier run's candidate is gone. A staging folder is left exactly as it
# was, and unnamed: startup is reached before the lane lock, so a discard there could take a live
# run's staging mid-copy — abandoned staging is discarded in the copyback instead (below).
start_art="$tmp/startup/artifacts"
mkdir -p "$start_art/incoming-feedfacefeedface"
printf 'MemosAPITests\t1\n' > "$start_art/testcount-baseline.tsv"
printf 'MemosAPITests\t1\n' > "$start_art/incoming-feedfacefeedface/testcount-baseline.tsv"
OUT="$(cd "$tmp/startup" && env -u MAC_GATE_HOST -u MAC_GATE_BRANCH MAC_GATE_ARTIFACTS="$start_art" "$GATE" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [ ! -e "$start_art/testcount-baseline.tsv" ] && has "MAC_GATE_HOST is not set"; then
  ok "a run refused for a missing host has already removed a stale candidate"
else
  bad "a run refused for a missing host left a stale candidate, or refused for another reason (exit $RC)"; show
fi
if [ "$RC" -eq 2 ] && [ -f "$start_art/incoming-feedfacefeedface/testcount-baseline.tsv" ] && ! has "discarding abandoned staging"; then
  ok "a run refused at startup leaves a staging folder untouched and unnamed — it holds no lane lock"
else
  bad "a run refused at startup discarded or named a staging folder it holds no lock over (exit $RC)"; show
fi
# A5: a cleanup that cannot remove the stale candidate refuses on its own line, naming the file, and
# nothing after it runs — the host refusal that would follow never prints.
printf 'MemosAPITests\t1\n' > "$start_art/testcount-baseline.tsv"
chmod 555 "$start_art"
OUT="$(cd "$tmp/startup" && env -u MAC_GATE_HOST -u MAC_GATE_BRANCH MAC_GATE_ARTIFACTS="$start_art" "$GATE" 2>&1)"; RC=$?
chmod 755 "$start_art"
if [ "$RC" -eq 2 ] && [ -f "$start_art/testcount-baseline.tsv" ] \
   && has "stale candidate left in place — not this run's" && has "$start_art/testcount-baseline.tsv" \
   && ! has "MAC_GATE_HOST is not set"; then
  ok "a stale candidate the cleanup cannot remove refuses the run (exit 2), naming it, before anything else runs"
else
  bad "an unremovable stale candidate was answered with exit $RC, or not named, or later checks still ran"; show
fi

# A7, the discard of abandoned staging, taken out of the copyback and run directly: one line per
# folder it discards, every folder gone, and a folder it cannot remove fails the step's code.
discard_src="$(sed -n '/^for abandoned in "\$artifacts"\/incoming-\*; do$/,/^done$/p' "$GATE")"
if [ -z "$discard_src" ]; then
  bad "the copyback's discard loop was not found in the gate, so no case below exercised it"
else
  run_discard() { # $1 = the artifacts folder; sets OUT and RC (the folded copyback code)
    OUT="$(artifacts="$1" log="$1/discard.log" bash -c 'say() { printf "%s\n" "$*"; }; copyback_rc=0
'"$discard_src"'
exit "$copyback_rc"' 2>&1)"; RC=$?
  }
  d_art="$tmp/discard/artifacts"
  mkdir -p "$d_art/incoming-aaaa/MemosNG.xcresult" "$d_art/incoming-bbbb" "$d_art/keep"
  printf 'x\n' > "$d_art/incoming-bbbb/testcount-baseline.tsv"
  run_discard "$d_art"
  lines="$(printf '%s\n' "$OUT" | grep -c '^discarding abandoned staging .* from an earlier run$')"
  if [ "$RC" -eq 0 ] && [ "$lines" -eq 2 ] && has "$d_art/incoming-aaaa" && has "$d_art/incoming-bbbb" \
     && [ ! -e "$d_art/incoming-aaaa" ] && [ ! -e "$d_art/incoming-bbbb" ] && [ -d "$d_art/keep" ]; then
    ok "two abandoned staging folders are discarded with one line each, and nothing else is touched"
  else
    bad "the discard printed $lines line(s) for two folders, or left one, or touched another (exit $RC)"; show
  fi
  mkdir -p "$d_art/incoming-cccc/sub" && printf 'x\n' > "$d_art/incoming-cccc/sub/f"
  chmod 555 "$d_art/incoming-cccc/sub"
  run_discard "$d_art"
  chmod 755 "$d_art/incoming-cccc/sub"
  if [ "$RC" -ne 0 ] && has "could not remove the abandoned staging $d_art/incoming-cccc"; then
    ok "a staging folder the discard cannot remove fails the copyback step's code (exit $RC) and says so"
  else
    bad "a staging folder the discard could not remove left the copyback code at $RC, or said nothing"; show
  fi
fi

# Both halves of the mechanism are in the gate's text, in the order that makes them mean anything.
first_code_line() { grep -n "$1" "$GATE" | grep -v '^[0-9]*:[[:space:]]*#' | head -n1 | cut -d: -f1; }
# The cleanup's own refusals are the first calls in the text; every other refusal comes after it.
art_line="$(first_code_line '\(^\|[[:space:]]\)artifacts="')"
cleanup_line="$(first_code_line 'rm -f "\$artifacts/testcount-baseline.tsv"')"
first_refusal="$(first_code_line 'die_refuse "')"
refuse_line="$(grep -n 'die_refuse "' "$GATE" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'left in place — not this run' | head -n1 | cut -d: -f1)"
loop_line="$(first_code_line '^while \[ \$# -gt 0 \]; do$')"
if [ -n "$art_line" ] && [ -n "$cleanup_line" ] && [ -n "$first_refusal" ] && [ -n "$refuse_line" ] && [ -n "$loop_line" ] \
   && [ "$art_line" -lt "$first_refusal" ] && [ "$art_line" -lt "$cleanup_line" ] && [ "$cleanup_line" -lt "$first_refusal" ] \
   && [ "$cleanup_line" -lt "$refuse_line" ] && [ "$cleanup_line" -lt "$loop_line" ]; then
  ok "the artifacts folder is resolved, then cleaned, before the argument loop and the first refusal (control: first refusal on line $refuse_line)"
else
  bad "the startup order is not resolve, clean, then arguments and refusals (artifacts ${art_line:-none}, cleanup ${cleanup_line:-none}, loop ${loop_line:-none}, refusal ${refuse_line:-none})"
fi
removals="$(grep -v '^[[:space:]]*#' "$GATE" | grep -c 'rm -f "\$artifacts/testcount-baseline.tsv"')"
if [ "$removals" -eq 1 ]; then
  ok "the documented path is removed in exactly one place, the startup cleanup"
else
  bad "the documented path is removed in $removals places — a sweep outside the startup cleanup is back, or the cleanup is gone"
fi
if grep -q "^rm -rf .gate-artifacts && mkdir -p .gate-artifacts && printf '%s\\\\n' \"\$GATE_RUN_TOKEN\" > .gate-artifacts/run-token || " "$GATE" \
   && ! grep -q '^printf .%s\\n. "\$GATE_RUN_TOKEN" > .gate-artifacts/run-token$' "$GATE"; then
  ok "the remote stamp is on the same && chain as the clear, and that chain's failure is handled"
else
  bad "the remote stamp is not on the clear's && chain, or a separate stamp line remains"
fi
copy_line="$(first_code_line '^rsync -a -e ssh "\$host:\$target/.gate-artifacts/" "\$artifacts/incoming-\$RUN_TOKEN/"')"
staged_line="$(first_code_line '^say "copyback: staged in ')"
owner_line="$(first_code_line '^  "\$candidate_owner" "\$staging" "\$artifacts" "\$RUN_TOKEN"')"
record_line="$(first_code_line '^record copyback "\$copyback_rc"$')"
if [ -n "$copy_line" ] && [ -n "$staged_line" ] && [ -n "$owner_line" ] && [ -n "$record_line" ] \
   && [ "$copy_line" -lt "$staged_line" ] && [ "$staged_line" -lt "$owner_line" ] && [ "$owner_line" -lt "$record_line" ] \
   && grep -q '^staging="\$artifacts/incoming-\$RUN_TOKEN"$' "$GATE" \
   && grep -q '^  owner_rc="\${PIPESTATUS\[0\]}"$' "$GATE"; then
  ok "the copy lands in incoming-<token>, the staging line follows it, the owner script follows that, and the step records its exit last"
else
  bad "the copyback order is not rsync to incoming-, staged line, owner call, record (rsync ${copy_line:-none}, staged ${staged_line:-none}, owner ${owner_line:-none}, record ${record_line:-none})"
fi
discard_line="$(first_code_line '^for abandoned in "\$artifacts"/incoming-\*; do$')"
n_discard="$(grep -v '^[[:space:]]*#' "$GATE" | grep -c 'incoming-\*')"
ret_line="$(first_code_line '^remote_rc="\${PIPESTATUS\[1\]}"$')"
if [ -n "$discard_line" ] && [ -n "$ret_line" ] && [ -n "$copy_line" ] && [ -n "$loop_line" ] && [ "$n_discard" -eq 1 ] \
   && [ "$discard_line" -gt "$ret_line" ] && [ "$discard_line" -lt "$copy_line" ] && [ "$discard_line" -gt "$loop_line" ]; then
  ok "abandoned staging is discarded in the copyback, after the remote returns and before this run's copy, and nowhere else"
else
  bad "the staging discard is not the one loop between the remote's return and the copy (discard ${discard_line:-none}, count $n_discard, remote ${ret_line:-none}, rsync ${copy_line:-none}, argument loop ${loop_line:-none})"
fi
# A3: one copyback serves both modes. One copy of the artifacts folder, one owner call, one record,
# all at the top level, and no top-level exit between the remote's return and the copy.
n_copy="$(grep -v '^[[:space:]]*#' "$GATE" | grep -c 'rsync .*\.gate-artifacts/"')"
n_owner="$(grep -v '^[[:space:]]*#' "$GATE" | grep -c '"\$candidate_owner" "')"
n_record="$(grep -c '^record copyback ' "$GATE")"
remote_ret="$(first_code_line '^remote_rc="\${PIPESTATUS\[1\]}"$')"
early_exit=""
if [ -n "$remote_ret" ] && [ -n "$copy_line" ]; then
  early_exit="$(sed -n "${remote_ret},${copy_line}p" "$GATE" | grep -nE '^(exit|end_run|summary_and_exit|quick_summary_and_exit)\b' | head -n1)"
fi
if [ "$n_copy" -eq 1 ] && [ "$n_owner" -eq 1 ] && [ "$n_record" -eq 1 ] && [ -n "$remote_ret" ] && [ -n "$copy_line" ] \
   && [ -z "$early_exit" ]; then
  ok "quick and full runs reach the one copyback: one rsync, one owner call, one record, no exit after the remote returns (control: remote returns on line $remote_ret)"
else
  bad "the copyback is not one block both modes reach (rsync $n_copy, owner $n_owner, record $n_record, remote ${remote_ret:-none}, early exit: ${early_exit:-none})"
fi

# --- (h) every refusal names its reason, on the stream the step's own lines take --------------------
# Three full gates (2026-10-09, -10-11, -10-17) ended `MAC_GATE_STEP testcount 2` with nothing at all
# between the counter's `Executed N tests` lines and the step line — no reason, not even the
# verdict's `TESTCOUNT ok` — and an unchanged rerun passed. A step that fails without saying why is
# a failure nobody can act on. So the comparison half of the step is read out of the gate as text —
# everything in s_testcount after the counter's heredoc — and run here against a real verdict fed
# each input it refuses, and against stand-in verdicts that refuse the way no input can make the real
# one refuse: silently, on stderr alone, killed, or naming a reason only in the middle of a line.
# Every one of them must leave a line STARTING `TESTCOUNT FAIL:` on the step's stdout, and the step
# must still return the verdict's own exit code. Stdout, not "somewhere in the log": the build host's
# stderr reaches the controller on a separate ssh channel, in no order against the step's own lines,
# so a reason that travels there can land under some other step, or after the summary.
frag="$tmp/compare-step.sh"
{
  echo 'set -uo pipefail'
  echo 'compare_step() {'
  echo '  true # the counter half passed; what follows is the step text after its heredoc'
  awk '/^s_testcount\(\) [{]/ { f = 1 } f && p { print } f && /^PY$/ { p = 1 } f && /^[}]/ { exit }' "$GATE"
} > "$frag"

# $1 = a name, $2 = the verdict to install ('-' installs none), $3 = observed counts file ('-' none),
# $4 = baseline file ('-' none). OUT is the step's stdout, ERR its stderr, RC its exit code.
compare_case() {
  local d="$tmp/compare/$1"
  rm -rf "${d:?}"; mkdir -p "$d/run/.gate-artifacts" "$d/target/scripts" "$d/target/tests/gate"
  [ "$2" = - ] || { cp "$2" "$d/target/scripts/testcount-verdict.sh"; chmod +x "$d/target/scripts/testcount-verdict.sh"; }
  [ "$3" = - ] || cp "$3" "$d/run/.gate-artifacts/testcount-baseline.tsv"
  [ "$4" = - ] || cp "$4" "$d/target/tests/gate/testcount-baseline.tsv"
  OUT="$(cd "$d/run" && GATE_TARGET="$d/target" bash -c '. "$1" && compare_step' compare "$frag" 2>"$d/stderr")"
  RC=$?
  ERR="$(cat "$d/stderr")"
}
# How many lines of OUT start with the reason prefix. Counted with a loop over the text, not a
# `printf | grep -q` pipeline, whose early exit would hand pipefail a SIGPIPE status instead.
fail_lines() {
  local line n=0
  while IFS= read -r line; do
    case "$line" in 'TESTCOUNT FAIL:'*) n=$((n + 1)) ;; esac
  done <<< "$OUT"
  printf '%s' "$n"
}
# $1 = a name, $2 = the exit code the step must return, $3 = (optional) words of the verdict's own
# reason that must be on that stdout too — not only the step's fallback line
expect_reason() {
  local own=1 own_said=""
  case "$OUT" in *"${3:-}"*) ;; *) own=0 ;; esac
  [ -z "${3:-}" ] || own_said=", own reason [$3] on stdout: $own"
  if [ "$RC" -eq "$2" ] && [ "$(fail_lines)" -ge 1 ] && [ "$own" -eq 1 ]; then
    ok "$1: the step exits $RC and its stdout names the reason"
  else
    bad "$1: the step exited $RC (wanted $2) with $(fail_lines) TESTCOUNT FAIL: line(s) on its stdout$own_said"
    show; printf '%s\n' "$ERR" | sed 's/^/   2>| /'
  fi
}

if [ -s "$frag" ] && grep -q 'scripts/testcount-verdict.sh' "$frag" && grep -q 'return "\$compare_rc"' "$frag"; then
  ok "the comparison half of s_testcount was read out of $GATE (control)"
else
  bad "the comparison half of s_testcount could not be read out of $GATE — the cases below judge nothing"
fi

good_obs="$(baseline h-obs MemosAPITests 3 MemosCoreTests 5)"
good_base="$(baseline h-base MemosAPITests 3 MemosCoreTests 5)"
bad_dir="$tmp/h-bad"; mkdir -p "$bad_dir"
printf 'MemosAPITests\t3\nMemosCoreTests\t5\0\n'      > "$bad_dir/nul.tsv"
printf 'MemosAPITests\t3\nMemosCoreTests\t5\001\n'    > "$bad_dir/ctrl.tsv"
printf 'MemosAPITests\t3\nMemosCoreTests\t5'          > "$bad_dir/no-lf.tsv"
printf 'MemosAPITests\t3\nMemosCoreTests\t5\r\n'      > "$bad_dir/cr.tsv"
printf 'MemosAPITests\t3\nMemosCoreTests 5\n'         > "$bad_dir/shape.tsv"
printf 'MemosAPITests\t3\nMemos CoreTests\t5\n'       > "$bad_dir/space.tsv"
printf 'MemosAPITests\t3\nMemosCoreTests\tfive\n'     > "$bad_dir/word.tsv"
printf 'MemosAPITests\t3\nMemosCoreTests\t1234567890\n' > "$bad_dir/long.tsv"
: > "$bad_dir/empty.tsv"
printf 'MemosAPITests\t3\nMemosAPITests\t3\nMemosCoreTests\t5\n' > "$bad_dir/twice.tsv"
surplus_base="$(baseline h-surplus MemosAPITests 3 MemosCoreTests 5 MemosOutboxTests 1)"
below_base="$(baseline h-below MemosAPITests 3 MemosCoreTests 6)"
short_base="$(baseline h-short MemosAPITests 3)"

# The real verdict, through every exit it has. Each one reaches `exit 2` (or `exit 1`) by a different
# line, and the validate() refusals print from inside a command substitution, on stderr.
compare_case pass "$VERDICT" "$good_obs" "$good_base"
case "$OUT" in *'TESTCOUNT ok:'*) pass_said=1 ;; *) pass_said=0 ;; esac
if [ "$RC" -eq 0 ] && [ "$(fail_lines)" -eq 0 ] && [ "$pass_said" -eq 1 ]; then
  ok "a run at its baseline passes the step with TESTCOUNT ok and no reason line (control)"
else
  bad "a run at its baseline did not pass cleanly (exit $RC, $(fail_lines) TESTCOUNT FAIL: line(s))"; show
fi
compare_case obs-missing "$VERDICT" - "$good_base";              expect_reason "the run's counts are missing" 2 "is missing or unreadable"
compare_case base-missing "$VERDICT" "$good_obs" -;              expect_reason "the baseline is missing" 2 "is missing or unreadable"
compare_case nul "$VERDICT" "$good_obs" "$bad_dir/nul.tsv";       expect_reason "the baseline holds a NUL byte" 2 "holds a NUL byte"
compare_case ctrl "$VERDICT" "$good_obs" "$bad_dir/ctrl.tsv";     expect_reason "the baseline holds a control byte" 2 "not printable ASCII"
compare_case no-lf "$VERDICT" "$good_obs" "$bad_dir/no-lf.tsv";   expect_reason "the baseline does not end in LF" 2 "does not end in a newline"
compare_case cr "$VERDICT" "$good_obs" "$bad_dir/cr.tsv";         expect_reason "a baseline row ends in CR" 2 "carriage return"
compare_case shape "$VERDICT" "$good_obs" "$bad_dir/shape.tsv";   expect_reason "a baseline row is not <bundle> TAB <count>" 2 "is not <bundle> TAB <count>"
compare_case space "$VERDICT" "$good_obs" "$bad_dir/space.tsv";   expect_reason "a baseline bundle has a space in it" 2 "with a space in it"
compare_case word "$VERDICT" "$good_obs" "$bad_dir/word.tsv";     expect_reason "a baseline count is not a number" 2 "which is not a number"
compare_case long "$VERDICT" "$good_obs" "$bad_dir/long.tsv";     expect_reason "a baseline count is ten digits" 2 "a count of 10 digits"
compare_case obs-shape "$VERDICT" "$bad_dir/shape.tsv" "$good_base"; expect_reason "a row of the run's counts is malformed" 2 "the observed counts"
compare_case obs-empty "$VERDICT" "$bad_dir/empty.tsv" "$good_base"; expect_reason "the run's counts are empty" 2 "holds no counts"
compare_case obs-twice "$VERDICT" "$bad_dir/twice.tsv" "$good_base"; expect_reason "the run's counts name a bundle twice" 2 "names MemosAPITests twice"
compare_case base-twice "$VERDICT" "$good_obs" "$bad_dir/twice.tsv"; expect_reason "the baseline names a bundle twice" 2 "names MemosAPITests twice"
compare_case surplus "$VERDICT" "$good_obs" "$surplus_base";      expect_reason "the baseline names a bundle the run did not measure" 2 "which this run did not measure"
compare_case below "$VERDICT" "$good_obs" "$below_base";          expect_reason "a bundle is below its row" 1 "below the 6 its baseline row records"
compare_case no-row "$VERDICT" "$good_obs" "$short_base";         expect_reason "a bundle has no row" 1 "has no row in the baseline"
# The NUL scan that cannot answer: no input makes `grep -c` print nothing, so a grep that does is
# put first on the PATH the verdict inherits, for that one call; every other grep is passed through.
real_grep="$(command -v grep)"
mkdir -p "$tmp/h-path"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "-c" ] && exit 2\nexec "%s" "$@"\n' "$real_grep" > "$tmp/h-path/grep"
chmod +x "$tmp/h-path/grep"
PATH="$tmp/h-path:$PATH" compare_case nul-scan "$VERDICT" "$good_obs" "$good_base"
expect_reason "the NUL scan cannot answer" 2 "could not be scanned for NUL bytes"

# Verdicts that refuse in ways no input makes the real one refuse.
stub() { # $1 = a name, $2 = its body; prints the path
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$tmp/h-stub-$1.sh"
  printf '%s' "$tmp/h-stub-$1.sh"
}
compare_case silent "$(stub silent 'exit 2')" "$good_obs" "$good_base"
expect_reason "a verdict that exits 2 printing nothing (the 2026-10-09 shape)" 2 "exited 2 without naming a reason"
compare_case stderr-only "$(stub stderr-only 'echo "TESTCOUNT FAIL: said on stderr only" >&2; exit 2')" "$good_obs" "$good_base"
expect_reason "a verdict whose only reason is on stderr" 2 "said on stderr only"
compare_case killed "$(stub killed 'kill -KILL $$')" "$good_obs" "$good_base"
expect_reason "a verdict killed before it printed" 137 "exited 137 without naming a reason"
compare_case mid-line "$(stub mid-line 'echo "note: a TESTCOUNT FAIL: line would go here"; exit 2')" "$good_obs" "$good_base"
expect_reason "a verdict that names the prefix only in the middle of a line" 2
compare_case other-rc "$(stub other-rc 'echo "counting..."; exit 3')" "$good_obs" "$good_base"
expect_reason "a verdict that exits 3 after unrelated output" 3
# One reason is one line: a verdict that named its reason first is not given a second one.
compare_case first-line "$(stub first-line 'echo "TESTCOUNT FAIL: the first line"; exit 2')" "$good_obs" "$good_base"
if [ "$RC" -eq 2 ] && [ "$(fail_lines)" -eq 1 ]; then
  ok "a verdict that named its reason on its first line gets no second reason line"
else
  bad "a verdict that named its reason on its first line: exit $RC, $(fail_lines) TESTCOUNT FAIL: line(s) (wanted 2 and 1)"; show
fi
# A verdict the step cannot run is the step's own refusal, and keeps exit 1.
compare_case no-verdict - "$good_obs" "$good_base"
expect_reason "no verdict script at all" 1

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
