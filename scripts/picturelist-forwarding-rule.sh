#!/usr/bin/env bash
#
# The picture-list forwarding rule: each screen that saves an edit hands the store the picture list
# the sheet stated, and does it exactly once.
#
# The sheet decides the memo's whole picture list — which of its own pictures are kept, in which
# order, and where the files going up in the same save sit among them — and that list reaches the
# server only if the host forwards it. A host that drops it sends a patch with no list at all: the
# removal is shown on the row, the sheet closes, and the memo still holds the picture. Nothing in
# the app would say so, and the sheet would have lied on the one screen somebody was watching.
#
# It is a source-text rule and not a test because neither call site can be reached from one: both
# are `private func`s behind a `.sheet` that does not present under test, and that sheet is the
# fence whichever way the host reads its session — the timeline's `@Environment` is non-optional
# and only a SwiftUI body can supply it, the detail screen's is optional and guarded — the same
# reason the `attaching:` forwarding beside it has never had a witness either. A seam cut into
# production code to let a test in would change the screens this rule exists to hold still.
#
# The fence is EXACTLY ONE uncommented occurrence per host, not "at least one". Two would mean a
# second save path had grown beside the first, which is precisely the kind of drift that leaves one
# of the two silently listless. Comments do not count: a check a comment can defeat is not a check,
# which is also why this script lives in scripts/, where its own text may carry the literals the
# checked files are counted for.
#
# The positive control is the other half. A count of one proves nothing on its own if the file it
# read was the wrong file, or a stub, or arrived empty: the same run requires `attaching:` — the
# forwarding on both of those lines, which this rule did not introduce — to appear at least once in
# each host. A file that has lost that has lost the save call altogether, so the fence above
# would be reading a screen that no longer saves anything.
#
# Both counts read UNCOMMENTED text only. Swift has two comment forms and both are removed first:
# every `/* … */` block, nesting honoured because Swift nests them, then every `//` line. The order
# matters — a `//` inside a block must not swallow that block's closing `*/`. A `/*` inside a
# string literal is the case this leaves open, and neither host has one.
#
# Usage: picturelist-forwarding-rule.sh [<repo-root>]   (default: the current directory)
# Exit:  0 = both hosts forward the list exactly once and both controls answered
#        1 = a host forwards it not at all or more than once, or a control failed
#        2 = the inputs were not usable (no such tree, a host missing, or text that could not be
#            read), which is never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "PICTURELIST FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

sources="$root/Packages/MemosFeatures/Sources/MemosFeatures"
hosts=("$sources/TimelineView.swift" "$sources/MemoDetailView.swift")

for host in "${hosts[@]}"; do
  if [ ! -f "$host" ]; then
    echo "PICTURELIST FAIL: $host does not exist — a host that is not there reads exactly like a"
    echo "                  host that forwards nothing, and is refused rather than counted"
    exit 2
  fi
done

rc=0

for host in "${hosts[@]}"; do
  name="$(basename "$host")"

  uncommented="$(perl -0777 -pe 's{ ( /\* (?: [^/*]+ | /(?!\*) | \*(?!/) | (?1) )* \*/ ) }{}gsx; s{//[^\n]*}{}g' "$host" 2>/dev/null)"
  strip_rc=$?
  if [ "$strip_rc" -ne 0 ] || [ -z "$uncommented" ]; then
    echo "PICTURELIST FAIL: stripping the comments from $host ended with exit $strip_rc or left"
    echo "                  nothing, so neither the rule nor its control was checked"
    exit 2
  fi

  # -a so a file git thinks is binary still answers with a count rather than "Binary file matches",
  # because a hit nobody can locate is not evidence.
  listing="$(printf '%s\n' "$uncommented" | grep -caF 'listing: submission.pictures')"
  attaching="$(printf '%s\n' "$uncommented" | grep -caF 'attaching:')"

  echo "PICTURELIST: $name forwards the stated list on $listing uncommented line(s), 1 wanted"
  echo "PICTURELIST (control): $name names the upload forwarding on $attaching uncommented line(s), at least 1 wanted"

  if [ "$listing" -ne 1 ]; then
    echo "PICTURELIST FAIL: $name does not hand the store the picture list the sheet stated on"
    echo "                  exactly one line. None means a save that shows a removal and does not"
    echo "                  send it; more than one means a second save path has grown beside the"
    echo "                  first. Comments do not count: reword the explanation, do not silence"
    echo "                  the check."
    rc=1
  fi
  if [ "$attaching" -lt 1 ]; then
    echo "PICTURELIST FAIL: positive control — $name no longer names the upload forwarding at all,"
    echo "                  so the count above was read from a file that does not save an edit and"
    echo "                  proves nothing either way"
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  echo "PICTURELIST ok: both hosts forward the sheet's picture list exactly once, and both controls answered"
fi

exit $rc
