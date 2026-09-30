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

# A fixture that could not be planted leaves the tree it was copied from — a clean one — and a case
# expecting a pass would then pass on a tree that is not the case it names. So a failed plant ends
# the suite, non-zero, before any tree is judged by it.
fixture_failed() { echo "FAIL: the fixture for '$1' could not be planted — nothing was judged"; exit 1; }
plant() { # $1 label, then the arguments python3 takes after '-'; the script arrives on stdin
  local label="$1"
  shift
  python3 - "$@" || fixture_failed "$label"
}

# The shape of a healthy tree: this repository's own sources, copied.
w="$(new_tree clean)" || exit 1
check "the tree as it stands, copied" 0 "$w"

# (i) rule 1, the obfuscated literal. The round-1 pattern answered 0 for `0x191`, which is why the
# two hexadecimal spellings are in it.
w="$(new_tree synthetic-hex)" || exit 1
printf 'import Foundation\n\nfunc gateSynthetic(code: Int) {\n    if code == 0x191 { }\n}\n' \
  > "$(core_sources "$w")/Synthetic.swift" || fixture_failed synthetic-hex
check "a synthetic 0x191 comparison outside the allow-list" 1 "$w" "REFUSAL FAIL: a refusal is named outside"

# (i-b) rule 1's ordinary case, and the one a careless author actually writes.
w="$(new_tree synthetic-literal)" || exit 1
printf 'import Foundation\n\nfunc gateSynthetic(code: Int) {\n    if code == 401 { }\n}\n' \
  > "$(core_sources "$w")/Synthetic.swift" || fixture_failed synthetic-literal
check "a synthetic 401 comparison outside the allow-list" 1 "$w" "REFUSAL FAIL: a refusal is named outside"

# (i-c) a comment is not an exemption. The literal grep is chosen precisely so that the explanation
# of the rule cannot be written using the thing the rule is about — otherwise a classification could
# be reintroduced under a comment that reads like a warning about it. Prose outside the allow-listed
# files says "a refusal", which is what it means.
w="$(new_tree in-a-comment)" || exit 1
printf '\n// A 401 here would end the session.\n' \
  >> "$(core_sources "$w")/Stores/TimelineStore.swift" || fixture_failed in-a-comment
check "the literal inside a comment" 1 "$w" "REFUSAL FAIL: a refusal is named outside"

# (ii) rule 2b — an eighth wipe call. A new way for a response to end a session is a DECLARATION.
w="$(new_tree eighth-wipe)" || exit 1
cat >> "$(core_sources "$w")/Stores/SessionStore.swift" <<'SWIFT' || fixture_failed eighth-wipe

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
cat >> "$(core_sources "$w")/Stores/SessionStore.swift" <<'SWIFT' || fixture_failed handle-overload

extension SessionStore {
    public func handle(_ error: APIError) async {}
}
SWIFT
check "a second 'handle' overload taking something else" 1 "$w" "rule 2c"

# (iv) THE case rule 1 cannot see, and the reason rule 2e exists. `400 + 1` names no literal; the
# call reaches the wipe through the one public path that takes no refusal. It must fail on 2e's
# COUNT, not on the literal.
w="$(new_tree arithmetic-signout)" || exit 1
cat > "$(core_sources "$w")/Synthetic.swift" <<'SWIFT' || fixture_failed arithmetic-signout
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
plant stopped-attaching "$w" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "Packages/MemosAPI/Sources/MemosAPI/BearerAuthMiddleware.swift"
text = p.read_text()
assert "throw CredentialRefusal(" in text
p.write_text(text.replace("throw CredentialRefusal(issuedUnder: epoch)", "return (response, responseBody)"))
PY
check "an allow-listed file that stopped minting the typed value" 1 "$w" "control 2"

# (vi) control 3 — the funnel deleted. Every caller then re-derives the rule.
w="$(new_tree no-funnel)" || exit 1
plant no-funnel "$w" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "Packages/MemosCore/Sources/MemosCore/Stores/SessionStore.swift"
text = p.read_text()
needle = "public func handle(_ refusal: CredentialRefusal) async -> RefusalOutcome"
assert needle in text
p.write_text(text.replace(needle, "func gateSyntheticFunnelGone() async -> RefusalOutcome"))
PY
check "the funnel deleted" 1 "$w" "control 3"

# (viii) rule 2f — a whole-lane function sending its HEAD through the chunk lane's `resync(`, which
# reads a 401 as unanswered instead of as a refusal. This is the defect review re-caught in
# `askWhereItStands` (MEMNG-630), planted back where it was found. It must fail on 2f and name the
# function it landed in.
outbox_engine_in() { printf '%s' "$1/Packages/MemosOutbox/Sources/MemosOutbox/OutboxEngine.swift"; }
w="$(new_tree whole-lane-resync)" || exit 1
plant whole-lane-resync "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
head = "    private func askWhereItStands(_ job: UploadJob, fileID: UUID) async -> WholeFileChange? {\n"
assert text.count(head) == 1
p.write_text(text.replace(head, head + "        _ = await resync(job, fileID: fileID, credentials: credentials)\n"))
PY
check "a whole-lane function calling 'resync(' for its HEAD" 1 "$w" "askWhereItStands"

# (viii-b) the same site MOVED rather than added: the chunk lane's second call gone, one in the whole
# lane instead. The count still reads 2, so it is the enclosing-function half of 2f that has to see
# it — a count alone would pass this tree.
w="$(new_tree moved-resync)" || exit 1
plant moved-resync "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
chunk = "asked = await resync(job, fileID: fileID, credentials: credentials)"
head = "    private func askWhereItStands(_ job: UploadJob, fileID: UUID) async -> WholeFileChange? {\n"
assert text.count(chunk) == 1 and text.count(head) == 1
text = text.replace(chunk, "asked = await gateSyntheticChunkHead(job)")
p.write_text(text.replace(head, head + "        _ = await resync(job, fileID: fileID, credentials: credentials)\n"))
PY
check "a chunk-lane 'resync(' moved into the whole lane" 1 "$w" "askWhereItStands"

# (viii-c) comments are not exempt here either: a whole-lane comment that spells the call counts.
w="$(new_tree resync-in-a-comment)" || exit 1
plant resync-in-a-comment "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
head = "    private func askWhereItStands(_ job: UploadJob, fileID: UUID) async -> WholeFileChange? {\n"
assert text.count(head) == 1
p.write_text(text.replace(head, head + "        // resync(job, fileID: fileID, credentials: credentials) would do here.\n"))
PY
check "'resync(' spelled inside a whole-lane comment" 1 "$w" "askWhereItStands"

# (viii-c2) the converse: a real whole-lane call whose trailing comment names the declaration. Only
# the declaration itself is exempt from 2f, and a line is the declaration by where `func resync(`
# starts, not by containing it — otherwise a comment is a way past the rule.
w="$(new_tree resync-behind-a-comment)" || exit 1
plant resync-behind-a-comment "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
head = "    private func askWhereItStands(_ job: UploadJob, fileID: UUID) async -> WholeFileChange? {\n"
assert text.count(head) == 1
call = "        _ = await resync(job, fileID: fileID, credentials: credentials)"
p.write_text(text.replace(head, head + call + "  // func resync(...) returns no typed refusal\n"))
PY
check "a whole-lane 'resync(' call with 'func resync(' in its trailing comment" 1 "$w" "askWhereItStands"

# (viii-d) the positive fixture: a further whole-lane HEAD written the right way, through
# `wholeOffsetHead(`, is not what 2f is about and must pass — the control is a floor, not a pin.
w="$(new_tree whole-lane-right-head)" || exit 1
plant whole-lane-right-head "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
head = "    private func askWhereItStands(_ job: UploadJob, fileID: UUID) async -> WholeFileChange? {\n"
assert text.count(head) == 1
p.write_text(text.replace(
    head, head + "        _ = await wholeOffsetHead(uploadUID: \"\", credentials: credentials)\n"))
PY
check "a further whole-lane HEAD through 'wholeOffsetHead('" 0 "$w"

# (viii-e) 2f's control: the whole lane's own HEAD helper no longer called. Without it a whole-lane
# HEAD has nowhere typed to go, and a count of `resync(` that still reads 2 proves nothing about it.
w="$(new_tree no-whole-head)" || exit 1
plant no-whole-head "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
call = "await wholeOffsetHead("
assert text.count(call) == 2
p.write_text(text.replace(call, "await gateSyntheticHead("))
PY
check "the whole lane's 'wholeOffsetHead(' calls removed" 1 "$w" "rule 2f control"

# (viii-f) the control's floor, one below it: askWhereItStands' HEAD gone, the resume's left.
w="$(new_tree one-whole-head)" || exit 1
plant one-whole-head "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
call = "await wholeOffsetHead("
assert text.count(call) == 2
i = text.rindex(call)
p.write_text(text[:i] + "await gateSyntheticHead(" + text[i + len(call):])
PY
check "one 'wholeOffsetHead(' call left" 1 "$w" "rule 2f control"

# (viii-g) no `resync(` at all: an awk that printed nothing reads exactly like this, and it is not a
# pass — the pin is exact in both directions, as every pin above is.
w="$(new_tree no-resync)" || exit 1
plant no-resync "$(outbox_engine_in "$w")" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
call = "await resync("
assert text.count(call) == 2
p.write_text(text.replace(call, "await gateSyntheticChunkHead("))
PY
check "no 'resync(' call left" 1 "$w" "'resync(' sites in OutboxEngine.swift is 0"

# (viii-h) 2f reads OutboxEngine.swift and nothing else: `resync(` is private there, so another
# file naming one is naming its own and is none of this rule's business.
w="$(new_tree resync-elsewhere)" || exit 1
printf 'import Foundation\n\nfunc gateSyntheticCaller() {\n    resync()\n}\n\nfunc resync() {}\n' \
  > "$(core_sources "$w")/Synthetic.swift" || fixture_failed resync-elsewhere
check "a 'resync(' of another file's own" 0 "$w"

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
