#!/usr/bin/env bash
#
# The gate's warnings check for MemosFeatures rests on two exit codes, and this is the arithmetic
# that reads them: the real build must PASS, and a build of the same target with a file that holds
# nothing but warnings must FAIL. The second one is the whole point — a canary that survives means
# the target's warnings are not fatal, whatever any log says about it.
#
# Exit codes only, so there is no text here for a source file to imitate. Fed by hand below, and
# by the build host in bin/mac-gate.sh.
#
# Exit: 0 = every pair judged as expected; 1 = at least one was not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
VERDICT="$repo_root/scripts/warnings-canary-verdict.sh"
[ -x "$VERDICT" ] || { echo "FAIL: $VERDICT is missing or not executable"; exit 1; }

fails=0
cases=0
pass_seen=0

check() { # $1 label, $2 expected exit, $3 real build rc, $4 canary build rc
  local label="$1" expected="$2" out rc
  cases=$((cases + 1))
  out="$("$VERDICT" "$3" "$4" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ]; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    echo "FAIL $label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# The shape of a healthy gate: the target builds, and the canary cannot.
check "real 0, canary 65 (warnings fatal)" 0 0 65
# The canary survived. That is the whole failure this check exists for: the build was green and the
# warnings were not fatal.
check "real 0, canary 0 (canary survived)" 1 0 0
# A broken build is not proof of anything either way.
check "real 1, canary 65" 1 1 65
check "real 1, canary 0" 1 1 0
# A signal is not a warning verdict: a canary build that was killed, or that broke on anything
# other than its diagnostics, proves nothing and must not pass.
check "real 0, canary 143 (killed)" 1 0 143
check "real 0, canary 70 (broke elsewhere)" 1 0 70
# Nonsense in, refusal out — never a pass.
check "a missing argument" 2 0 ""
check "a non-numeric argument" 2 0 "sixty-five"

if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no pair was accepted — a verdict that refuses everything would pass this suite"
  fails=$((fails + 1))
fi

echo "gate warnings canary verdict: $((cases - fails)) of $cases pairs as expected"
[ "$fails" -eq 0 ] || { echo "CANARY-VERDICT-TEST FAIL: $fails pair(s) misjudged"; exit 1; }
echo "CANARY-VERDICT-TEST ok"
