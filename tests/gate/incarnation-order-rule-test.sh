#!/usr/bin/env bash
#
# The gate's incarnation-order rule, checked against trees this script builds for the purpose.
#
# `scripts/incarnation-order-rule.sh` holds an order the test bundles do not exercise: at every site
# that ends an identity, SessionStore ends the incarnation before it clears or replaces the handle
# (MEMNG-435). Ordinary main-actor tasks cannot interleave between the two statements, since nothing
# there suspends; only the synchronous withdrawal callback runs between them, and the callbacks that
# exist today do not inspect the handle. The rule is what holds the order, and a rule that cannot go
# red holds nothing. It covers the syntax it recognises; a write made through a helper is outside
# its guarantee. The cases below are the ways it is supposed to bite — each pinned site turned
# round, a write split over two lines, an end compiled only under `#if` or deferred, an end that is
# only a comment or a string, text that only looks like a write, a site renamed out from under it,
# an end renamed, a site that stopped writing the handle, a new handle writer nobody pinned — first
# on a scratch store built here, then on a copy of the real one with each of its sites turned round.
#
# The last case is the real repository this test ships in: the rule must hold on the tree as it
# stands. Nothing here writes into that tree — every mutation only ever lands in a temporary copy —
# and every temporary tree is removed on exit.
#
# Run it directly (`tests/gate/incarnation-order-rule-test.sh`) or let the gate run it: it is
# picked up by the controller-side selftest step in bin/mac-gate.sh, which runs every
# tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="${INCARNATION_RULE:-$repo_root/scripts/incarnation-order-rule.sh}"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

STORE_PATH="Packages/MemosCore/Sources/MemosCore/Stores/SessionStore.swift"
SITES='park establish failSignIn persist putBack wipeCredential'

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-incarnation-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

# A store with the shape the rule reads: the six sites, each ending the incarnation first, and the
# things that must NOT count as a handle write beside them — a local `let credential`, a `==`
# comparison, a property declaration.
store_body() {
  cat <<'SWIFT'
@Observable
public final class SessionStore {
    private var client: (any APIProtocol)?
    private var credential: PresentedCredential?

    init() {
        let credential = PresentedCredential("x")
        _ = credential
    }

    var isSignedIn: Bool { client == nil ? false : true }

    // Comparisons wrapped onto lines of their own start with the name and are still not writes.
    private func describe() -> String {
        let idle =
            client == nil
        let held =
            credential != nil
        let ordered =
            client <= limit && credential >= limit
        return idle && held && ordered ? "idle" : "busy"
    }

    private func park(_ failure: SessionRestoreFailure) {
        // Withdrawing the client withdraws the authority with it.
        endIncarnation()
        client = nil
        credential = nil
    }

    private func establish(client: any APIProtocol, credential: PresentedCredential) {
        endIncarnation()
        presentedGrant = credential
        self.client = client
        credential.install()
        self.credential = credential
    }

    private func failSignIn(_ error: NativeLoginError) {
        state = .signedOut
        endIncarnation()
        client = nil
        credential = nil
    }

    private func persist(token: String) async -> Int {
        endIncarnation(withdrawingAccount: true)
        client = nil
        credential = nil
        return 0
    }

    private func putBack(_ snapshot: SessionSnapshot) {
        endIncarnation(keeping: snapshot.client == nil ? nil : snapshot.credential)
        client = snapshot.client
        credential = snapshot.credential
    }

    @discardableResult
    private func wipeCredential() async -> Int {
        let cancelling = endIncarnation(withdrawingAccount: true)
        client = nil
        credential = nil
        await cancelling?.value
        return 0
    }

    @discardableResult
    private func endIncarnation(
        withdrawingAccount: Bool = false, keeping kept: PresentedCredential? = nil
    ) -> Task<Void, Never>? {
        nil
    }
}
SWIFT
}

new_tree() { # $1 name
  local work="$tmp/$1"
  mkdir -p "$work/$(dirname "$STORE_PATH")" || return 1
  store_body > "$work/$STORE_PATH"
  printf '%s' "$work"
}

# Turns ONE site round: its first end is taken out and put back after the last handle write of the
# same function. The function boundaries are read exactly the way the rule reads them.
reverse_site() { # $1 file, $2 function
  local file="$1" site="$2" out="$1.reversed"
  awk -v site="$site" '
    function decl_name(line,  n) {
      n = line
      sub(/^[ \t]*((public|private|fileprivate|internal|nonisolated|static|override|final|convenience|required|mutating|@[A-Za-z]+)[ \t]+)*/, "", n)
      sub(/^func[ \t]+/, "", n)
      sub(/[^A-Za-z0-9_].*$/, "", n)
      return n
    }
    function is_decl(line) {
      return line ~ /^[ \t]*((public|private|fileprivate|internal|nonisolated|static|override|final|convenience|required|mutating|@[A-Za-z]+)[ \t]+)*(func[ \t]+[A-Za-z_]|init[(?!<])/
    }
    function is_comment(line) { return line ~ /^[ \t]*\/\// }
    function is_end(line) { return line ~ /^[ \t]*(((let|var)[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*)?endIncarnation[(]/ }
    function is_handle(line) {
      return line ~ /^[ \t]*(self[.])?(client|credential)[ \t]*=[^=]/ || line ~ /^[ \t]*(self[.])?(client|credential)[ \t]*=$/
    }
    NR == FNR {
      if (!is_comment($0) && is_decl($0)) fn = decl_name($0)
      if (fn == site && !is_comment($0)) {
        if (end_at == 0 && is_end($0)) end_at = FNR
        if (is_handle($0)) last_handle = FNR
      }
      next
    }
    FNR == 1 && (end_at == 0 || last_handle == 0 || last_handle < end_at) {
      print "reverse_site: " site " has no end before a handle write to turn round" > "/dev/stderr"
      failed = 1
      exit 1
    }
    FNR == end_at { held = $0; next }
    { print }
    FNR == last_handle { print held }
    END { if (failed) exit 1 }
  ' "$file" "$file" > "$out" && mv "$out" "$file"
}

check() { # $1 label, $2 expected exit, $3 tree root
  local label="$1" expected="$2" root="$3" out rc
  cases=$((cases + 1))
  out="$("$RULE" "$root" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ]; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    if [ "$first_fail" -eq 0 ]; then
      # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# Every site in order, with the non-writes beside them.
w="$(new_tree clean)" || exit 1
check "every site ending the incarnation first" 0 "$w"

# THE case this rule exists for, at each site in turn: the handle cleared (or replaced) before the
# incarnation ends.
for site in $SITES; do
  w="$(new_tree "reversed-$site")" || exit 1
  reverse_site "$w/$STORE_PATH" "$site" || exit 1
  check "scratch store with '$site' turned round" 1 "$w"
done

# A comment is not an end. The real call moved below the writes, a commented one left above them.
w="$(new_tree end-only-in-a-comment)" || exit 1
reverse_site "$w/$STORE_PATH" park || exit 1
sed -i.bak 's|^        // Withdrawing the client withdraws the authority with it.$|        // endIncarnation()|' \
  "$w/$STORE_PATH" || exit 1
check "an end above the writes that is only a comment" 1 "$w"

# Nor is the name inside a string: only a statement that starts with the call counts.
w="$(new_tree end-only-in-a-string)" || exit 1
reverse_site "$w/$STORE_PATH" failSignIn || exit 1
sed -i.bak 's|^        state = .signedOut$|        log("endIncarnation() comes next")|' "$w/$STORE_PATH" || exit 1
check "an end above the writes that is only inside a string" 1 "$w"

# A renamed site must not pass by never being found.
w="$(new_tree site-renamed)" || exit 1
sed -i.bak 's|private func park(|private func parkSession(|' "$w/$STORE_PATH" || exit 1
check "a pinned site renamed" 1 "$w"

# A renamed end must not pass by never being called: there is nothing left for the order to name.
w="$(new_tree end-renamed)" || exit 1
sed -i.bak 's|endIncarnation(|finishIncarnation(|' "$w/$STORE_PATH" || exit 1
check "the end renamed everywhere" 1 "$w"

# A site that stopped writing the handle is either no longer a site, and comes off the list in the
# same change, or the rule is reading the wrong text — never a silent pass.
w="$(new_tree site-without-a-write)" || exit 1
sed -i.bak '/^        client = snapshot.client$/d; /^        credential = snapshot.credential$/d' \
  "$w/$STORE_PATH" || exit 1
check "a pinned site that no longer writes the handle" 1 "$w"

# A seventh writer nobody pinned, even one written the right way round: it is a new site, and it is
# looked at by being pinned.
w="$(new_tree unpinned-writer)" || exit 1
sed -i.bak '0,/^    @discardableResult$/s|^    @discardableResult$|    private func reset() {\n        endIncarnation()\n        client = nil\n    }\n\n    @discardableResult|' \
  "$w/$STORE_PATH" || exit 1
check "a new function writing the handle that is not pinned" 1 "$w"

# A write whose right-hand side starts on the next line is still a write. Turned round in a pinned
# site, it must be read as that site's first write, not passed over for the later one.
w="$(new_tree multiline-write-reversed)" || exit 1
python3 - "$w/$STORE_PATH" <<'PY' || exit 1
import sys
p = sys.argv[1]
s = open(p).read()
a = """        endIncarnation()
        client = nil
        credential = nil
    }

    private func establish("""
b = """        client =
            nil
        endIncarnation()
        credential = nil
    }

    private func establish("""
assert s.count(a) == 1
open(p, "w").write(s.replace(a, b))
PY
check "a pinned site whose first write is split over two lines, turned round" 1 "$w"

# And a function whose ONLY handle write is split that way is still a writer nobody pinned.
w="$(new_tree multiline-unpinned-writer)" || exit 1
sed -i.bak '0,/^    @discardableResult$/s|^    @discardableResult$|    private func drop() {\n        endIncarnation()\n        credential =\n            nil\n    }\n\n    @discardableResult|' \
  "$w/$STORE_PATH" || exit 1
check "a new function whose only handle write is split over two lines" 1 "$w"

# An end that only one build configuration compiles is not an end: a release build would clear the
# handle without ending anything. The rule does not evaluate branches; any conditional-compilation
# line inside a pinned site fails it closed.
w="$(new_tree end-under-if-debug)" || exit 1
python3 - "$w/$STORE_PATH" <<'PY' || exit 1
import sys
p = sys.argv[1]
s = open(p).read()
a = """        // Withdrawing the client withdraws the authority with it.
        endIncarnation()
        client = nil
        credential = nil
"""
b = """        #if DEBUG
        endIncarnation()
        #endif
        client = nil
        credential = nil
"""
assert s.count(a) == 1
open(p, "w").write(s.replace(a, b))
PY
check "a pinned site whose end is compiled only under #if DEBUG" 1 "$w"

# A deferred end runs AFTER the writes below it, whatever line it is written on. The rule does not
# reason about scope exit; any `defer` inside a pinned site fails it closed.
w="$(new_tree deferred-end)" || exit 1
python3 - "$w/$STORE_PATH" <<'PY' || exit 1
import sys
p = sys.argv[1]
s = open(p).read()
a = """        // Withdrawing the client withdraws the authority with it.
        endIncarnation()
        client = nil
"""
b = """        defer {
            endIncarnation()
        }
        client = nil
"""
assert s.count(a) == 1
open(p, "w").write(s.replace(a, b))
PY
check "a pinned site whose end is deferred past its writes" 1 "$w"

# Text that only looks like a write must not fail the rule: the name inside a string after a `;`,
# and a tuple assignment to ANOTHER object's members of the same names.
add_unpinned() { # $1 tree name, $2 body line (sed replacement text)
  local w
  w="$(new_tree "$1")" || return 1
  sed -i.bak "0,/^    @discardableResult\$/s|^    @discardableResult\$|    private func drop() {\n$2\n    }\n\n    @discardableResult|" \
    "$w/$STORE_PATH" || return 1
  grep -qF "$2" "$w/$STORE_PATH" || return 1
  printf '%s' "$w"
}
w="$(add_unpinned string-with-a-write '        logger.debug("cleanup; client = nil")')" || exit 1
check "a string holding '; client = nil'" 0 "$w"
w="$(add_unpinned another-objects-members \
  '        (credentialStore.client, credentialStore.credential) = (nil, nil)')" || exit 1
check "a tuple assignment to another object's .client/.credential" 0 "$w"

# A handle write in ANOTHER file is outside the rule's scope, by design: the handle is SessionStore's
# private state, so no other file can write it.
w="$(new_tree other-file)" || exit 1
printf 'func elsewhere() {\n    client = nil\n}\n' > "$w/$(dirname "$STORE_PATH")/TimelineStore.swift" || exit 1
check "a same-named write in another file" 0 "$w"

# An empty store is not a store whose sites are all in order.
w="$(new_tree empty-store)" || exit 1
: > "$w/$STORE_PATH" || exit 1
check "an empty SessionStore.swift" 1 "$w"

# A store that is not there reads exactly like one that is clean. It is refused instead.
w="$(new_tree missing-store)" || exit 1
rm "$w/$STORE_PATH" || exit 1
check "a tree with no SessionStore.swift" 2 "$w"
check "a root that is not a directory" 2 "$tmp/no-such-root"

# The real store, each of its sites turned round in a copy: the rule bites on the text it guards,
# not only on the scratch shape above.
for site in $SITES; do
  w="$tmp/real-reversed-$site"
  mkdir -p "$w/$(dirname "$STORE_PATH")" || exit 1
  cp "$repo_root/$STORE_PATH" "$w/$STORE_PATH" || exit 1
  reverse_site "$w/$STORE_PATH" "$site" || exit 1
  check "the real SessionStore.swift with '$site' turned round" 1 "$w"
done

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

echo "gate incarnation-order rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || { echo "INCARNATION-TEST FAIL: $fails tree(s) misjudged"; exit "$first_fail"; }
echo "INCARNATION-TEST ok"
