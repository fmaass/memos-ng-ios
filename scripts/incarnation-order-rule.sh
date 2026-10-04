#!/usr/bin/env bash
#
# The incarnation-order rule: wherever SessionStore installs or clears the session's handle, the
# incarnation that handle belonged to has ended FIRST (MEMNG-435).
#
# The handle is `client` (with `credential`, the token it presents): `activeHandle` is computed from
# it. The incarnation is what an executor that sends from somewhere other than the main actor
# checks before each request (`sendAuthority()`, `sessionIncarnation`) — it never reads the handle.
# So the one ordering that can be observed is the incarnation's, and the earlier it moves the
# earlier that boundary closes. Ordinary main-actor tasks cannot interleave between the two
# statements, since nothing there suspends; the one code that runs between them is the synchronous
# withdrawal callback `endIncarnation` makes, which could witness the order, and the callbacks that
# exist today do not inspect the handle. What a reviewer cannot see is the next site written the
# other way round, which is what this rule exists to catch.
#
# What it reads, in Packages/MemosCore/Sources/MemosCore/Stores/SessionStore.swift:
#   - a HANDLE WRITE is a statement that starts with `client =`, `credential =`, `self.client =` or
#     `self.credential =`, its right-hand side on the same line or the next (a `let credential = …`
#     local is not one, nor is a comparison: `==`, `!=`, `<=`, `>=`);
#   - an END is a statement that starts with a call of `endIncarnation(`, optionally assigned
#     (`let cancelling = endIncarnation(…)`), so the name inside a string or after other code on a
#     line is not one;
#   - the function a line belongs to is the nearest `func` or `init` declaration above it, which is
#     what a reviewer reads too;
#   - a line whose first non-blank characters are `//` is a comment and counts as nothing, so an
#     explanation of the order can never stand in for the order.
#
# The rule: in every pinned function, the first END comes before the first HANDLE WRITE.
#
# The positive control is the other half, because an order check over functions it cannot find
# reads the same as one that holds: every pinned function is declared exactly once, and each still
# holds both an END and a HANDLE WRITE; `endIncarnation` itself is declared exactly once; and the
# functions holding a HANDLE WRITE are exactly the pinned set — a new site that installs or clears
# the handle fails here until it is pinned below, which is the moment its order is looked at.
#
# Two things inside a pinned site it refuses rather than reads, because a pass would be a guess:
# any `#if`, `#elseif`, `#else` or `#endif` line (branches are not evaluated, and an end that one
# configuration leaves out clears the handle there without ending anything), and any `defer` (a
# deferred end runs after the writes below it, whatever line it is written on).
#
# The controls cover the syntax the rule recognises and no more. Outside its guarantee, known and
# deliberately not chased: a `/* … */` block comment; a write made through a helper rather than by
# an assignment in the pinned function itself; a write after another statement on one line
# (`endIncarnation(); client = nil`); a tuple assignment (`(client, credential) = …`); and a
# compound assignment (`credential ??= …`). Those forms are neither read nor refused. The threat
# model is the one in scripts/refusal-sites-rule.sh — a cooperative author's omission.
#
# Usage: incarnation-order-rule.sh [<repo-root>]     (default: the current directory)
# Exit:  0 = the order holds at every pinned site and every control was found
#        1 = the order was broken somewhere, or a control was missing
#        2 = the inputs were not usable (no such tree, the file is absent, or awk failed), which is
#            never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "INCARNATION FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

session_store="$root/Packages/MemosCore/Sources/MemosCore/Stores/SessionStore.swift"
if [ ! -f "$session_store" ]; then
  echo "INCARNATION FAIL: $session_store does not exist — the rule has nothing to check and this"
  echo "                  proves nothing"
  exit 2
fi

# The sites that end an identity, each of them a place the handle is installed or cleared. putBack
# was already written this way, on purpose; the other five were turned round by MEMNG-435.
pinned='park establish failSignIn persist putBack wipeCredential'

# One record per line: D (declaration), E (end), H (handle write), C (a conditional-compilation
# line) or F (a `defer`), its line number, and the function it belongs to ("-" before the first
# declaration).
records="$(
  awk '
    /^[ \t]*\/\// { next }
    /^[ \t]*((public|private|fileprivate|internal|nonisolated|static|override|final|convenience|required|mutating|@[A-Za-z]+)[ \t]+)*(func[ \t]+[A-Za-z_]|init[(?!<])/ {
      name = $0
      sub(/^[ \t]*((public|private|fileprivate|internal|nonisolated|static|override|final|convenience|required|mutating|@[A-Za-z]+)[ \t]+)*/, "", name)
      sub(/^func[ \t]+/, "", name)
      sub(/[^A-Za-z0-9_].*$/, "", name)
      fn = name
      printf "D\t%d\t%s\n", NR, fn
      next
    }
    /^[ \t]*(((let|var)[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*)?endIncarnation[(]/ {
      printf "E\t%d\t%s\n", NR, (fn == "" ? "-" : fn)
    }
    /^[ \t]*(self[.])?(client|credential)[ \t]*=[^=]/ || /^[ \t]*(self[.])?(client|credential)[ \t]*=$/ {
      printf "H\t%d\t%s\n", NR, (fn == "" ? "-" : fn)
    }
    /^[ \t]*#[ \t]*(if|elseif|else|endif)([^A-Za-z0-9_]|$)/ {
      printf "C\t%d\t%s\n", NR, (fn == "" ? "-" : fn)
    }
    /(^|[^A-Za-z0-9_.])defer[ \t]*([{]|$)/ {
      printf "F\t%d\t%s\n", NR, (fn == "" ? "-" : fn)
    }
  ' "$session_store"
)"
awk_rc=$?
if [ "$awk_rc" -ne 0 ]; then
  echo "INCARNATION FAIL: awk over $session_store ended with exit $awk_rc, so the rule was never"
  echo "                  checked"
  exit 2
fi

rc=0
tab="$(printf '\t')"

# first <kind> <function>: the first line number of that kind in that function, or empty.
first() { printf '%s\n' "$records" | awk -F "$tab" -v k="$1" -v f="$2" '$1 == k && $3 == f { print $2; exit }'; }
count() { printf '%s\n' "$records" | awk -F "$tab" -v k="$1" -v f="$2" '$1 == k && $3 == f { n++ } END { print n + 0 }'; }

# Control: the function whose order is checked is still the one this rule names.
end_decls="$(count D endIncarnation)"
if [ "$end_decls" -eq 1 ]; then
  echo "INCARNATION ok (positive control): 'endIncarnation' is declared once in SessionStore.swift"
else
  echo "INCARNATION FAIL: positive control — 'endIncarnation' is declared $end_decls times in"
  echo "                  SessionStore.swift, and exactly 1 is expected. Renamed? Then every check"
  echo "                  below is looking for a call that can no longer exist."
  rc=1
fi

for site in $pinned; do
  decls="$(count D "$site")"
  if [ "$decls" -ne 1 ]; then
    echo "INCARNATION FAIL: positive control — '$site' is declared $decls times in"
    echo "                  SessionStore.swift, and exactly 1 is expected. A pinned site that"
    echo "                  cannot be found is a site whose order was never checked."
    rc=1
    continue
  fi
  end_line="$(first E "$site")"
  handle_line="$(first H "$site")"
  if [ -z "$end_line" ] || [ -z "$handle_line" ]; then
    echo "INCARNATION FAIL: positive control — '$site' no longer holds both an endIncarnation call"
    echo "                  (found: ${end_line:-none}) and a write of client/credential (found:"
    echo "                  ${handle_line:-none}). Either it stopped being a site, and comes off the"
    echo "                  pinned list in the same change, or the check is reading the wrong text."
    rc=1
    continue
  fi
  conditionals="$(printf '%s\n' "$records" | awk -F "$tab" -v f="$site" '$1 == "C" && $3 == f { printf "%s ", $2 }')"
  if [ -n "$conditionals" ]; then
    echo "INCARNATION FAIL: '$site' holds conditional compilation at SessionStore.swift line(s)"
    echo "                  ${conditionals% }. The rule does not evaluate branches, and an end"
    echo "                  that one configuration leaves out clears the handle there without"
    echo "                  ending anything. Keep #if out of the pinned sites."
    rc=1
    continue
  fi
  deferrals="$(printf '%s\n' "$records" | awk -F "$tab" -v f="$site" '$1 == "F" && $3 == f { printf "%s ", $2 }')"
  if [ -n "$deferrals" ]; then
    echo "INCARNATION FAIL: '$site' holds a defer at SessionStore.swift line(s) ${deferrals% }."
    echo "                  A deferred end runs after the writes below it, whatever line it is"
    echo "                  written on, and the rule does not reason about scope exit. Keep defer"
    echo "                  out of the pinned sites."
    rc=1
    continue
  fi
  if [ "$end_line" -lt "$handle_line" ]; then
    echo "INCARNATION ok: '$site' ends the incarnation (line $end_line) before it writes the handle"
    echo "                (line $handle_line)"
  else
    echo "INCARNATION FAIL: '$site' writes client/credential at SessionStore.swift:$handle_line"
    echo "                  before it ends the incarnation at :$end_line. End it first: an"
    echo "                  executor sending off the main actor checks the incarnation, never the"
    echo "                  handle, so until the incarnation moves it may still send."
    rc=1
  fi
done

# Control: every function that writes the handle is pinned. Without it, a seventh site written the
# wrong way round would pass by never being asked.
unpinned=0
writers="$(printf '%s\n' "$records" | awk -F "$tab" '$1 == "H" { print $3 }' | sort -u)"
for writer in $writers; do
  case " $pinned " in
    *" $writer "*) ;;
    *)
      echo "INCARNATION FAIL: '$writer' writes client/credential in SessionStore.swift and is not a"
      echo "                  pinned site. Pin it in scripts/incarnation-order-rule.sh — and order"
      echo "                  it — or say in the change why it ends no identity."
      printf '%s\n' "$records" | awk -F "$tab" -v f="$writer" '$1 == "H" && $3 == f { print "                  :" $2 }'
      unpinned=1
      ;;
  esac
done
if [ "$unpinned" -ne 0 ]; then
  rc=1
else
  echo "INCARNATION ok (positive control): the functions writing the handle are exactly the pinned"
  echo "                set: $pinned"
fi

exit $rc
