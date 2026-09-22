#!/usr/bin/env bash
#
# The refusal-sites rule: a refusal is named only where one is MINTED, and the effects a refusal can
# drive are an enumerated set that cannot grow without saying so (MEMNG-270).
#
# The class this pins is the one this repository has now met twice: a 401 is classified where the
# answer arrives and acted on one or more actor hops later, and in between a renewal can replace the
# credential the refusal was about. The fix is one typed value carrying the epoch of the credential
# that EARNED the refusal, and one decision taken synchronously at the effect. What a grep can add
# to that is not the decision — it is the guarantee that a NEW site cannot be added without a
# reviewer seeing it.
#
# TWO RULES, AND THEY ARE NOT EQUAL. Say it in this order, because the round-2 text implied they
# were two halves of the same weight and they are not:
#
#   rule 1 is a HINT.  A literal grep cannot be complete against expressions. `if code == 400 + 1`
#                      names nothing this pattern can see, and it never will. What rule 1 buys is
#                      the careless case and a readable diff.
#   rule 2 is the FENCE. What actually stops a response-driven effect from being added silently is
#                      the pinned entry points and the pinned call counts below. Anyone weakening
#                      rule 2 on the grounds that rule 1 covers it has it backwards.
#
# THREAT MODEL, stated once so nothing downstream has to guess it: accidental omission by a
# cooperative author adding a new refusal-classification or effect site — the failure that has
# actually happened here, twice. It is NOT deliberate obfuscation. The fence against a
# response-driven effect is type-level and lives in the code, not here: the private wipe and the
# hold write take the typed refusal as a required parameter, so such an effect cannot be written
# without one. A call hidden behind a method reference counts under neither rule, is known, and is
# deliberately not chased: each further clause buys a narrower evasion and none of them changes the
# type-level fence that already stands.
#
# COMMENTS ARE NOT EXEMPT, in the idiom of scripts/sharelink-rule.sh: a check a comment can defeat
# is not a check, and an allow-list that has to grow to hold explanatory prose is an allow-list that
# stops meaning anything. Prose outside the allow-listed files says "a refusal", "a rejected
# credential", "the server refusing the credential" — which is what it means anyway, and which
# nothing has to keep in step with a status code.
#
# Usage: refusal-sites-rule.sh [<repo-root>]     (default: the current directory)
# Exit:  0 = both rules hold and every control was found
#        1 = a rule was broken, or a control was missing
#        2 = the inputs were not usable (no such tree, or a file the rule reads is absent), which is
#            never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "REFUSAL FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

session_store="$root/Packages/MemosCore/Sources/MemosCore/Stores/SessionStore.swift"
outbox_engine="$root/Packages/MemosOutbox/Sources/MemosOutbox/OutboxEngine.swift"
outbox_refusal="$root/Packages/MemosOutbox/Sources/MemosOutbox/OutboxRefusal.swift"

for required in "$session_store" "$outbox_engine" "$outbox_refusal"; do
  if [ ! -f "$required" ]; then
    echo "REFUSAL FAIL: $required does not exist — the rule has nothing to check and this proves"
    echo "              nothing"
    exit 2
  fi
done

# The six shipping source roots. Tests are deliberately out of scope: a test that scripts a 401 IS
# naming one, and that is its job.
scopes=()
for candidate in \
  "$root/Packages/MemosAPI/Sources" \
  "$root/Packages/MemosCore/Sources" \
  "$root/Packages/MemosFeatures/Sources" \
  "$root/Packages/MemosOutbox/Sources" \
  "$root/Packages/MemosShareKit/Sources" \
  "$root/Sources"; do
  [ -d "$candidate" ] && scopes+=("$candidate")
done
if [ "${#scopes[@]}" -eq 0 ]; then
  echo "REFUSAL FAIL: none of the six source roots exist under '$root', so nothing was walked"
  exit 2
fi

rc=0

# --- control 0: the walk read real files ----------------------------------------------------------
# A grep that finds nothing proves nothing on its own: it reads the same whether the rule holds or
# the mirror arrived empty.
if grep -rlaF 'import Foundation' "$root/Packages/MemosCore/Sources" >/dev/null 2>&1; then
  echo "REFUSAL ok (control 0): the walk read real files under MemosCore/Sources"
else
  echo "REFUSAL FAIL: control 0 — nothing under MemosCore/Sources imports Foundation, so every"
  echo "              grep below found nothing because it read nothing"
  rc=1
fi

# --- rule 1 (the HINT): the literal, outside the places allowed to mint a refusal -----------------
# The two obfuscated spellings of 401 are in the pattern because they were not: at b6c5cef the
# round-1 pattern answered 0 for `let x = 0x191`, so it would have let `if code == 0x191 { }`
# through.
pattern='\.unauthorized|(^|[^0-9A-Za-z_])401([^0-9A-Za-z_]|$)|0x191|0o621'

# The definitions and the four lanes' attach points, and nothing else. SessionStore is on it for ONE
# token — §2.5(e)'s `return .revokeFailed(.unauthorized)`, which is a return VALUE and not a
# classification (the raced sign-out has to name the failure it reports); ComposeOutcome is on it
# because its `case .unauthorized:` arm IS a classification and its home is the compose lane.
# The last two are the step-up management lane, whose credential is a short-lived grant and never the
# device's token: a refusal there ends that screen's session by lapsing the grant and reaches nothing
# SessionStore owns, so it is outside the typed device-credential value by design rather than by
# omission. The two controls pinned for them are DECLARATION greps — the grant's `isLive(` and the
# store's `lapse()` — so what they prove is that those declarations are still in their file, not that
# the refusal arm still calls them. The connection is held by behaviour instead: the
# `ManageTokensStoreTests` test `aRefusedGrantAsksAgain` fails if a 401 on a management route stops
# lapsing the grant.
allow_list=(
  "Packages/MemosAPI/Sources/MemosAPI/APIError.swift"
  "Packages/MemosAPI/Sources/MemosAPI/CredentialRefusal.swift"
  "Packages/MemosAPI/Sources/MemosAPI/BearerAuthMiddleware.swift"
  "Packages/MemosCore/Sources/MemosCore/Stores/StoreFailure.swift"
  "Packages/MemosCore/Sources/MemosCore/Stores/SessionStore.swift"
  "Packages/MemosCore/Sources/MemosCore/Stores/ComposeOutcome.swift"
  "Packages/MemosCore/Sources/MemosCore/Media/OriginalMedia.swift"
  "Packages/MemosCore/Sources/MemosCore/Live/MediaEventClient.swift"
  "Packages/MemosOutbox/Sources/MemosOutbox/OutboxRefusal.swift"
  "Packages/MemosOutbox/Sources/MemosOutbox/MemoCompletion.swift"
  "Packages/MemosAPI/Sources/MemosAPI/ManagementGrant.swift"
  "Packages/MemosCore/Sources/MemosCore/Stores/ManageTokensStore.swift"
)

# -a so a file git thinks is binary still answers with file:line: a hit is a failure whatever the
# file is, and a hit nobody can locate is not evidence.
raw_hits="$(grep -rnaE --include='*.swift' "$pattern" "${scopes[@]}" 2>/dev/null)"
grep_rc=$?
if [ "$grep_rc" -ge 2 ] && [ -z "$raw_hits" ]; then
  echo "REFUSAL FAIL: the grep over the source roots ended with exit $grep_rc and read nothing, so"
  echo "              rule 1 was never checked"
  exit 2
fi

# Every line, comment or code — see the header. The path is made relative to the tree so the
# allow-list is one list whatever the tree is called.
stray="$(
  printf '%s\n' "$raw_hits" | awk -v prefix="$root/" -v allowed="$(printf '%s\n' "${allow_list[@]}")" '
    BEGIN { n = split(allowed, list, "\n"); for (i = 1; i <= n; i++) if (list[i] != "") ok[list[i]] = 1 }
    {
      line = $0
      idx = index(line, ":")
      path = substr(line, 1, idx - 1)
      rest = substr(line, idx + 1)
      relative = path
      sub("^" prefix, "", relative)
      if (relative in ok) next
      print relative ":" rest
    }'
)"

if [ -n "$stray" ]; then
  echo "REFUSAL FAIL: a refusal is named outside the places that mint one. A refusal is ONE"
  echo "              typed value carrying the epoch of the credential that earned it"
  echo "              (CredentialRefusal, OutboxRefusal); a site that classifies a 401 of its own"
  echo "              re-derives a decision that has to be taken at the effect, which is the whole"
  echo "              of MEMNG-270. Add the file to this script's allow-list in the same diff if it"
  echo "              is genuinely a new attach point — control 2 then holds it to minting one. Comments
              count: a comment says \"a refusal\" or \"a rejected credential\", which is what it
              means; reword the explanation, do not silence the check."
  printf '%s\n' "$stray"
  rc=1
else
  echo "REFUSAL ok (rule 1): no refusal literal, in code or comment, outside the ${#allow_list[@]}-file allow-list"
fi

# --- control 2: every allow-listed file exists AND still attaches ---------------------------------
# The half a future edit cannot pass by accident. An attach point that quietly stops attaching fails
# here rather than passing by being silent, and each file's control names what IT is allowed to name
# a refusal for — which is stronger than one blanket string for all of them.
control_for() {
  case "$1" in
    *"/APIError.swift") printf '%s' 'case unauthorized' ;;
    *"/CredentialRefusal.swift") printf '%s' 'public struct CredentialRefusal' ;;
    *"/BearerAuthMiddleware.swift") printf '%s' 'throw CredentialRefusal(' ;;
    *"/StoreFailure.swift") printf '%s' '-> CredentialRefusal?' ;;
    *"/SessionStore.swift") printf '%s' 'refusal.concernsCurrentCredential(of: credential)' ;;
    *"/ComposeOutcome.swift") printf '%s' 'StoreFailure.refusal(' ;;
    *"/OriginalMedia.swift") printf '%s' 'case credentialRefused(' ;;
    *"/MediaEventClient.swift") printf '%s' 'CredentialRefusal(' ;;
    *"/OutboxRefusal.swift") printf '%s' 'public struct OutboxRefusal' ;;
    *"/MemoCompletion.swift") printf '%s' 'OutboxRefusal(' ;;
    *"/ManagementGrant.swift") printf '%s' 'public func isLive(' ;;
    *"/ManageTokensStore.swift") printf '%s' 'private func lapse()' ;;
    *) printf '%s' '' ;;
  esac
}

control_2_ok=1
for allowed in "${allow_list[@]}"; do
  file="$root/$allowed"
  control="$(control_for "$allowed")"
  if [ ! -f "$file" ]; then
    echo "REFUSAL FAIL: control 2 — $allowed is on the allow-list and does not exist"
    rc=1
    control_2_ok=0
    continue
  fi
  if [ -z "$control" ]; then
    echo "REFUSAL FAIL: control 2 — $allowed has no control string in this script, so being on the"
    echo "              allow-list costs it nothing"
    rc=1
    control_2_ok=0
    continue
  fi
  if ! grep -qaF -e "$control" "$file"; then
    echo "REFUSAL FAIL: control 2 — $allowed no longer contains '$control', so it is allow-listed"
    echo "              for a refusal it has stopped attaching to"
    rc=1
    control_2_ok=0
  fi
done
[ "$control_2_ok" -eq 0 ] \
  || echo "REFUSAL ok (control 2): all ${#allow_list[@]} allow-listed files still attach"

# --- control 3: the funnel takes the typed value --------------------------------------------------
funnel='public func handle(_ refusal: CredentialRefusal) async -> RefusalOutcome'
if grep -qaF -e "$funnel" "$session_store"; then
  echo "REFUSAL ok (control 3): SessionStore's funnel takes the typed refusal"
else
  echo "REFUSAL FAIL: control 3 — SessionStore has no"
  echo "              '$funnel'."
  echo "              Deleting the funnel is how every caller goes back to deciding for itself."
  rc=1
fi

# --- rule 2 (the FENCE): the effects are pinned by shape ------------------------------------------
# Stated plainly, because it is the honest boundary: 2b, 2c and 2e are DECLARATION locks, not proofs
# of reachability. They guarantee that a new effect path cannot be added silently; the behavioural
# half is MemosCoreTests/RefusalEpochTests and MemosOutboxTests/RefusalEpochTests.

pin() { # $1 label, $2 expected, $3 actual, $4 why
  if [ "$2" = "$3" ]; then
    echo "REFUSAL ok (rule 2): $1 == $3"
  else
    echo "REFUSAL FAIL: rule 2 — $1 is $3, and this script pins it at $2."
    echo "              $4"
    echo "              Change the number in scripts/refusal-sites-rule.sh in the SAME diff, where a"
    echo "              reviewer reads it beside the new path."
    rc=1
  fi
}

# 2a — the wipe is unreachable from outside. The compiler already enforces `private`; this confirms
# it is still declared that way and that no other file names it.
pin "SessionStore's 'private func wipeCredential'" 1 \
  "$(grep -caF 'private func wipeCredential' "$session_store")" \
  "The wipe is private so that nothing outside this file can reach it."
wipe_elsewhere="$(grep -rlaF 'wipeCredential' "${scopes[@]}" --include='*.swift' 2>/dev/null \
  | grep -vF "$session_store" || true)"
if [ -n "$wipe_elsewhere" ]; then
  echo "REFUSAL FAIL: rule 2a — 'wipeCredential' is named outside SessionStore.swift:"
  printf '%s\n' "$wipe_elsewhere"
  rc=1
else
  echo "REFUSAL ok (rule 2a): 'wipeCredential' is named in SessionStore.swift and nowhere else"
fi

# 2b — a pinned call count, which makes a new wipe path a DECLARATION.
pin "'await wipeCredential()' in SessionStore.swift" 7 \
  "$(grep -caF 'await wipeCredential()' "$session_store")" \
  "An eighth call is an eighth way a response can end a session."
# The receiver varies — six read 'job.held(' and 'current.held(' — so the grep is on the method.
pin "'.held(' in OutboxEngine.swift" 6 \
  "$(grep -caF '.held(' "$outbox_engine")" \
  "A new hold is a new way a refusal can strand a capture behind a 'sign in again'."
# And the other half of the hold, which MOVED to OutboxRefusal when the status mapping did: the
# sentences a hold is written with are minted there and nowhere else.
pin "'.hold(' in OutboxRefusal.swift" 3 \
  "$(grep -caF '.hold(' "$outbox_refusal")" \
  "A fourth hold disposition is a fourth status that strands a capture."

# 2c — the session-ending entry points are an exact set. A new public path into the wipe, or a
# `handle` overload taking something other than the typed value, fails here.
expected_entry_points='public func signOut() async -> SignOutOutcome
public func signOutWithoutRevoking() async
public func handle(_ refusal: CredentialRefusal) async -> RefusalOutcome'
actual_entry_points="$(
  grep -oE 'public func (handle|signOut|signOutWithoutRevoking)\([^)]*\)[^{]*' "$session_store" \
    | sed 's/[[:space:]]*$//'
)"
if [ "$actual_entry_points" = "$expected_entry_points" ]; then
  echo "REFUSAL ok (rule 2c): the session-ending entry points are the pinned set"
else
  echo "REFUSAL FAIL: rule 2c — SessionStore's session-ending entry points are not the pinned set."
  echo "              expected:"
  printf '%s\n' "$expected_entry_points" | sed 's/^/                /'
  echo "              found:"
  printf '%s\n' "$actual_entry_points" | sed 's/^/                /'
  rc=1
fi

# 2e — the person's-choice entry points are pinned BY CALLER, not by signature. Precisely because
# `signOutWithoutRevoking()` takes no refusal — it is a person's own choice on a screen, and
# demanding a refusal there would be a fabricated one — it is the one wipe path an arithmetic
# classification could drive without failing anything above.
#
# `func ` is filtered out because a protocol REQUIREMENT is not a call: without that filter the
# first count reads 3, not 2.
count_calls() { grep -rnaF -e "$1" "${scopes[@]}" --include='*.swift' 2>/dev/null | grep -vF 'func ' | grep -c . ; }
pin "production callers of 'signOutWithoutRevoking()'" 2 "$(count_calls 'signOutWithoutRevoking()')" \
  "A third caller is a third screen — or a response — that can forget a live token."
pin "production callers of '.signOut()'" 1 "$(count_calls '.signOut()')" \
  "A second caller is a second place the revoke's outcome has to be read correctly."
pin "'PresentedCredential(' in SessionStore.swift" 3 \
  "$(grep -caF 'PresentedCredential(' "$session_store")" \
  "A fourth credential — installed or not — decides whether its refusals end the session, and
              forgetting install() on a new path is FAIL-OPEN."
pin "'self.credential = ' in SessionStore.swift" 1 \
  "$(grep -caF 'self.credential = ' "$session_store")" \
  "A second assignment is a second moment a credential becomes this device's."
pin "'OutboxRepository(' constructions" 32 \
  "$(grep -rnaF 'OutboxRepository(' "$root/Packages" "$root/Sources" --include='*.swift' 2>/dev/null \
    | grep -vF 'OutboxRepository.' | grep -c .)" \
  "A new repository is credential-scoped or it is not, and only one of those may default the
              stillCurrent predicate — see the classification in the MEMNG-270 design."

exit $rc
