#!/usr/bin/env bash
#
# The gate's refusal-sites rule, checked against trees this script builds for the purpose.
#
# `scripts/refusal-sites-rule.sh` is a pair of text greps, and a text grep is exactly as trustworthy
# as the evidence that it still bites. A rule nobody has seen fail is not a rule — and this one has
# two halves that fail for different reasons, so each is planted separately: rule 1 (the HINT), and
# rule 2 (the FENCE), which is the half that actually stops a response-driven effect from being
# added silently.
#
# Case (iv) is the one worth reading twice. `if statusCode == 400 + 1 { await
# session.signOutWithoutRevoking() }` names no literal rule 1 can see, and it reaches the wipe. It
# must fail — and it must fail ON RULE 2e's count, so that a future refactor which dropped 2e and
# kept rule 1 would be caught by this suite rather than by an incident.
#
# The last case is the real repository this test ships in: both rules must hold on the tree as it
# stands. Nothing here writes into that tree — every planted site lands in a temporary copy — and
# every temporary tree is removed on exit.
#
# Run it directly (`tests/gate/refusal-sites-rule-test.sh`) or let the gate run it: it is picked up
# by the controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/refusal-sites-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-refusal-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

# A copy of the real tree's Swift, which is the only honest fixture: the rule pins COUNTS that exist
# in this repository, so a synthetic tree would have to restate every one of them and would drift
# from the script the moment a number moved. `Packages` and `Sources` whole, because one pinned
# count — the repository constructions — deliberately spans tests as well as shipping sources. No
# build products, no git, ~5 MB.
new_tree() {
  local name="$1" work="$tmp/$1"
  mkdir -p "$work" || return 1
  cp -R "$repo_root/Packages" "$work/Packages" || return 1
  cp -R "$repo_root/Sources" "$work/Sources" || return 1
  printf '%s' "$work"
}

check() { # $1 label, $2 expected exit, $3 tree root, [$4 a line the output must contain]
  local label="$1" expected="$2" root="$3" needle="${4:-}" out rc
  cases=$((cases + 1))
  out="$("$RULE" "$root" 2>&1)"
  rc=$?
  if [ "$rc" != "$expected" ]; then
    fails=$((fails + 1))
    # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
    if [ "$first_fail" -eq 0 ]; then
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF -e "$needle"; then
    fails=$((fails + 1))
    [ "$first_fail" -ne 0 ] || first_fail=1
    echo "FAIL $label: exit $rc was right, but it failed for the wrong reason"
    echo "     | expected the output to name: $needle"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  [ "$expected" != 0 ] || pass_seen=1
  echo "ok   $label -> exit $rc"
}

core_sources() { printf '%s' "$1/Packages/MemosCore/Sources/MemosCore"; }

# The shape of a healthy tree: this repository's own sources, copied.
w="$(new_tree clean)" || exit 1
check "the tree as it stands, copied" 0 "$w"

# (i) rule 1, the obfuscated literal. The round-1 pattern answered 0 for `0x191`, which is why the
# two hexadecimal spellings are in it.
w="$(new_tree synthetic-hex)" || exit 1
printf 'import Foundation\n\nfunc gateSynthetic(code: Int) {\n    if code == 0x191 { }\n}\n' \
  > "$(core_sources "$w")/Synthetic.swift"
check "a synthetic 0x191 comparison outside the allow-list" 1 "$w" "REFUSAL FAIL: a refusal is named in code"

# (i-b) rule 1's ordinary case, and the one a careless author actually writes.
w="$(new_tree synthetic-literal)" || exit 1
printf 'import Foundation\n\nfunc gateSynthetic(code: Int) {\n    if code == 401 { }\n}\n' \
  > "$(core_sources "$w")/Synthetic.swift"
check "a synthetic 401 comparison outside the allow-list" 1 "$w" "REFUSAL FAIL: a refusal is named in code"

# (i-c) the deviation this rule carries, asserted rather than left implicit: rule 1 reads CODE, so
# the same literal in a comment is NOT a failure. If a later edit restores the comment-inclusive
# clause, this case turns red and its reader is sent to the script's header.
w="$(new_tree in-a-comment)" || exit 1
printf '\n// A 401 here would end the session, and .unauthorized is what it becomes.\n' \
  >> "$(core_sources "$w")/Stores/TimelineStore.swift"
check "the literal in a comment (deliberately not a failure)" 0 "$w"

# (ii) rule 2b — an eighth wipe call. A new way for a response to end a session is a DECLARATION.
w="$(new_tree eighth-wipe)" || exit 1
cat >> "$(core_sources "$w")/Stores/SessionStore.swift" <<'SWIFT'

extension SessionStore {
    func gateSyntheticEighthWipe() async {
        let wiped = await wipeCredential()
        _ = wiped
    }
}
SWIFT
check "an eighth 'await wipeCredential()'" 1 "$w" "'await wipeCredential()' in SessionStore.swift is 8"

# (iii) rule 2c — a second `handle` overload, which is how every call site goes back to deciding for
# itself what a 401 means.
w="$(new_tree handle-overload)" || exit 1
cat >> "$(core_sources "$w")/Stores/SessionStore.swift" <<'SWIFT'

extension SessionStore {
    public func handle(_ error: APIError) async {}
}
SWIFT
check "a second 'handle' overload taking something else" 1 "$w" "rule 2c"

# (iv) THE case rule 1 cannot see, and the reason rule 2e exists. `400 + 1` names no literal; the
# call reaches the wipe through the one public path that takes no refusal. It must fail on 2e's
# COUNT, not on the literal.
w="$(new_tree arithmetic-signout)" || exit 1
cat > "$(core_sources "$w")/Synthetic.swift" <<'SWIFT'
import Foundation

@MainActor
func gateSyntheticArithmeticSignOut(statusCode: Int, session: SessionStore) async {
    if statusCode == 400 + 1 { await session.signOutWithoutRevoking() }
}
SWIFT
check "an arithmetic classification driving the person's-choice wipe" 1 "$w" \
  "production callers of 'signOutWithoutRevoking()' is 3"

# (v) control 2 — an allow-listed file that quietly stops attaching. This is the half a future edit
# cannot pass by accident: being on the allow-list has to cost something.
w="$(new_tree stopped-attaching)" || exit 1
python3 - "$w" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "Packages/MemosAPI/Sources/MemosAPI/BearerAuthMiddleware.swift"
text = p.read_text()
assert "throw CredentialRefusal(" in text
p.write_text(text.replace("throw CredentialRefusal(issuedUnder: epoch)", "return (response, responseBody)"))
PY
check "an allow-listed file that stopped minting the typed value" 1 "$w" "control 2"

# (vi) control 3 — the funnel deleted. Every caller then re-derives the rule.
w="$(new_tree no-funnel)" || exit 1
python3 - "$w" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "Packages/MemosCore/Sources/MemosCore/Stores/SessionStore.swift"
text = p.read_text()
needle = "public func handle(_ refusal: CredentialRefusal) async -> RefusalOutcome"
assert needle in text
p.write_text(text.replace(needle, "func gateSyntheticFunnelGone() async -> RefusalOutcome"))
PY
check "the funnel deleted" 1 "$w" "control 3"

# (vii) an input that is not usable reads exactly like a tree that is clean. It is refused instead:
# a mirror that arrived empty must never come back as a pass.
w="$tmp/no-tree"
mkdir -p "$w/Packages/MemosCore/Sources" || exit 1
check "a tree with no SessionStore" 2 "$w"

check "a path that is not a directory at all" 2 "$tmp/does-not-exist"

# And the repository this suite ships in, which is the point of the whole exercise.
check "the real repository tree" 0 "$repo_root"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no tree was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no tree was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate refusal-sites rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || { echo "REFUSAL-TEST FAIL: $fails tree(s) misjudged"; exit "$first_fail"; }
echo "REFUSAL-TEST ok"
