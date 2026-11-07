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
# Stated plainly, because it is the honest boundary: 2b, 2c, 2e and 2f are DECLARATION locks, not
# proofs of reachability. They guarantee that a new effect path cannot be added silently; the
# behavioural half is MemosCoreTests/RefusalEpochTests and MemosOutboxTests/RefusalEpochTests.

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
# Seven: applyEdit's refused arm is the seventh.
pin "'.held(' in OutboxEngine.swift" 7 \
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
# 34: AttemptTermTests, CancelTests, PatchCompletionTests and RecoveryTests each construct one, the
# real repository on a directory of its own. 36: WholeLaneEngineTests adds two — its rig, fed the
# credential predicate, and the legacy-manifest rebase, which no drain is behind. 37: the pilot
# checklist's line-16 witness in MemosCoreTests composes the real outbox, fed the same predicate.
# 38: the composer trip chip's wire witness in MemosFeaturesTests puts a real Post through the
# timeline's enqueue into the real outbox, fed its signed-in provider's predicate. 39: the Settings
# app activation witness in MemosFeaturesTests drains the real outbox after a preference mirror,
# fed its signed-in provider's predicate. 40: the memo actions' outbox witness in MemosCoreTests
# holds a picture through the app's own outbox check, fed its signed-out provider's predicate.
# 41: the retry classes' connectivity witness in MemosOutboxTests (MEMNG-955) composes the real
# outbox behind a stub path, fed `StaticCredentials`' predicate. 42: the transfer ledger's feed
# witness in MemosOutboxTests (MEMNG-947) composes the real outbox, fed `StaticCredentials`'
# predicate. 43: the transfers sheet's fix witness in MemosFeaturesTests runs each fix through the
# real outbox, fed its signed-in provider's predicate. 44: the staging witness in MemosOutboxTests
# (MEMNG-951) composes the real outbox around a capture still taking files, fed its switchable
# provider's predicate. 45: the upload limit witness in MemosCoreTests (MEMNG-956) drains the real
# outbox under a signed-in session's grant, fed its device provider's predicate. 46-47: the
# pending-visibility witnesses in MemosOutboxTests (MEMNG-971) — the patch harness, fed a
# constant-true predicate (no credential under test), and a second repository on the same root
# whose lock always refuses, to prove a refused lease writes nothing. 48: the transfer-notice
# witness in MemosFeaturesTests (MEMNG-949) composes the real outbox to feed the notifier through
# its refresh observer. 49-50: the staging-lane witnesses in MemosOutboxTests (MEMNG-952) — the
# lane's rig and the same root reopened as a relaunch, both with no credential predicate (the lane
# copies from Photos and sends nothing).
# 51: the share sessions' witness in MemosOutboxTests (MEMNG-945) holds the captures a share
# session's registry, wake and start lane are judged against; it presents no credential of the
# app's, so it takes the default predicate. 52: the guest engine witness in MemosOutboxTests
# (MEMNG-1011) drives the real outbox on the guest door's chunk lane, fed `StaticCredentials`'
# predicate. 53: `Outbox.guestLive` composes the trip pass's own queue (MEMNG-1011), fed the GIVEN
# guest provider's predicate. 54: the guest-composed outbox witness in MemosOutboxTests
# (MEMNG-1011) drives it on the door's routes, fed `StaticCredentials`' predicate. 55: the
# guest-capture-needs-a-file witness in MemosOutboxTests (MEMNG-1011) enqueues straight into a
# repository with no credential predicate — the refusal it proves is decided before any send.
# 56-57: the video-over-mobile-data witnesses in MemosOutboxTests (MEMNG-960) — the rig that drives
# the real outbox on mobile data, fed `StaticCredentials`' predicate, and the same root reopened as
# a relaunch to prove the per-capture mark is on the manifest, fed the same predicate.
# 58-60: the chunk-lane retirement witnesses in MemosOutboxTests (MEMNG-546) — a plain and a
# retiring repository over one root, and the whole-lane rig's root reopened as retiring; none
# drains, so none takes a credential predicate.
# 61: the edit-job witness in MemosCoreTests (MEMNG-954) writes the store's edit into a real
# outbox, fed its signed-in test provider's predicate. 62-63: the edit-job reopen witness in
# MemosOutboxTests (MEMNG-954) — a repository and the same root reopened as a relaunch, both with
# no credential predicate (it enqueues straight into the repository and sends nothing). 64: the
# edit-job planner witness in MemosOutboxTests (MEMNG-954) writes one job to ask the planner and
# the request builder about it; it drains nothing, so it takes no credential predicate. 65: the
# one-edit-job-per-memo witness in MemosOutboxTests (MEMNG-954) enqueues twice into a repository to
# prove the second is refused; it drains nothing, so it takes no credential predicate. 66: the
# queued-withdraw relaunch witness in MemosOutboxTests (MEMNG-953) reopens the same root as a
# relaunch, fed the rig's credential predicate, and drains the queued DELETEs under it.
pin "'OutboxRepository(' constructions" 66 \
  "$(grep -rnaF 'OutboxRepository(' "$root/Packages" "$root/Sources" --include='*.swift' 2>/dev/null \
    | grep -vF 'OutboxRepository.' | grep -c .)" \
  "A new repository is credential-scoped or it is not, and only one of those may default the
              stillCurrent predicate — see the classification in the MEMNG-270 design."

# 2f — the chunk lane's offset HEAD is pinned BY CALLER (MEMNG-630). `resync(` reads a 401 as
# unanswered, which is right for the chunk lane and wrong for a whole-lane file, whose HEAD goes
# through `wholeOffsetHead(` and comes back as the typed refusal. Review re-caught a whole-lane
# function sending its HEAD through `resync(`; the compiler cannot see that, since both take the
# same credentials. So every line naming `resync(` but its declaration — comments included — is
# pinned to the function it sits in, and the set must read exactly the two chunk-lane callers. The
# enclosing function is the nearest declaration line above it, which is what a reviewer reads too.
# The declaration is exempt by its FORM — `func resync(` where a declaration starts, after the
# indentation and modifiers — and only that prefix is: a call whose trailing comment names the
# declaration is still a call, and so is anything after the prefix on the declaration's own line.
expected_resync_callers='private func complete(
public func handle(_ result: ChunkResult) async'
resync_sites="$(
  awk '
    /^[ \t]*((public|private|fileprivate|internal|nonisolated|static|override|final|@[A-Za-z]+)[ \t]+)*func [A-Za-z_]/ {
      decl = $0
      sub(/^[ \t]+/, "", decl)
      sub(/[ \t]*\{[ \t]*$/, "", decl)
    }
    {
      rest = $0
      sub(/^[ \t]*((public|private|fileprivate|internal|nonisolated|static|override|final|@[A-Za-z]+)[ \t]+)*func resync\(/, "", rest)
      if (index(rest, "resync(") > 0) {
        printf "%d\t%s\n", NR, (decl == "" ? "(no enclosing func)" : decl)
      }
    }
  ' "$outbox_engine"
)"
actual_resync_callers="$(printf '%s\n' "$resync_sites" | grep -v '^$' | cut -f2-)"
pin "'resync(' sites in OutboxEngine.swift" 2 \
  "$(printf '%s\n' "$resync_sites" | grep -c .)" \
  "A third is a third HEAD whose 401 is read as unanswered; a whole-lane HEAD goes through
              'wholeOffsetHead(' instead."
if [ "$actual_resync_callers" = "$expected_resync_callers" ]; then
  echo "REFUSAL ok (rule 2f): 'resync(' is called from the two chunk-lane functions and nowhere else"
else
  while IFS="$(printf '\t')" read -r line decl; do
    [ -n "$line" ] || continue
    if ! printf '%s\n' "$expected_resync_callers" | grep -qxF -e "$decl"; then
      echo "REFUSAL FAIL: rule 2f — 'resync(' at OutboxEngine.swift:$line, inside '$decl',"
      echo "              is not a pinned chunk-lane site. A whole-lane HEAD goes through"
      echo "              'wholeOffsetHead(', which hands the 401 back as the typed refusal."
    fi
  done <<EOF
$resync_sites
EOF
  echo "REFUSAL FAIL: rule 2f — the functions calling 'resync(' are not the pinned set."
  echo "              expected:"
  printf '%s\n' "$expected_resync_callers" | sed 's/^/                /'
  echo "              found:"
  printf '%s\n' "$resync_sites" | sed 's/^/                :/'
  rc=1
fi
# The control: the whole lane's own HEAD helper is still what the whole lane calls. Without it a
# `resync(` count that reads 2 would say nothing about where a whole-lane HEAD went. A floor, not a
# pin — a further whole-lane HEAD through it is the right way to write one.
whole_heads="$(grep -aF 'wholeOffsetHead(' "$outbox_engine" | grep -vF 'func ' | grep -c .)"
if [ "$whole_heads" -ge 2 ]; then
  echo "REFUSAL ok (rule 2f control): 'wholeOffsetHead(' is called $whole_heads times"
else
  echo "REFUSAL FAIL: rule 2f control — 'wholeOffsetHead(' is called $whole_heads times in"
  echo "              OutboxEngine.swift, and at least 2 are expected (the whole lane's resume and"
  echo "              askWhereItStands). Where did the whole lane's HEAD go?"
  rc=1
fi

exit $rc
