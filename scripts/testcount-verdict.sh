#!/usr/bin/env bash
#
# The per-bundle test count, judged against the floor the repository records for it.
#
# The gate's counter answers one question: did each bundle RUN anything. A bundle that lost half
# its cases still answers yes. So the counts it wrote are compared here with the row the tracked
# baseline holds for each bundle — below its row is a loss and fails, equal or above passes, and a
# rise is never asked to re-record anything.
#
# Both files have the same shape, one row per bundle, `<bundle><TAB><count>`, no header, LF
# endings, which is what makes a deliberate reduction a copy of the run's own candidate over the
# tracked file rather than a number somebody typed.
#
# A baseline that cannot answer is never a pass: absent, unreadable, holding a byte that is not
# printable ASCII, TAB or LF, cut off without its final newline, a row that is not that shape, a
# count too long to be a count, a bundle named twice, a bundle the run measured and the baseline
# does not name, or a row naming a bundle the run did not measure. A count that is missing is not
# a zero — a zero is a claim, and in those cases nobody made it. The counts the run itself wrote
# are held to the same shape, because a comparison is only as good as the worse of its two files.
#
# Usage: testcount-verdict.sh <observed counts> <tracked baseline>
# Exit:  0 = every bundle the run measured is at or above its baseline row
#        1 = at least one is below its row, or has no row (each one is named)
#        2 = the inputs could not be read as counts at all, which is never a pass
set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "TESTCOUNT FAIL: expected two files (observed counts, tracked baseline), got $#"
  exit 2
fi

observed="$1"
baseline="$2"

# Prints the rows it accepted; every row it refuses is named on stderr, and one refusal is enough
# to make the whole file unusable.
validate() { # $1 = file, $2 = what to call it in a failure
  local file="$1" what="$2" line name count rc=0 n=0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "TESTCOUNT FAIL: the $what $file is missing or unreadable, so the counts were never compared" >&2
    return 2
  fi
  # The bytes before the rows. `read` drops a NUL without a word, so a file holding one hands back
  # a row that validates while the file itself says something else, and a file whose last byte is
  # not LF was cut off mid-write, which makes its last count a number nobody finished writing.
  if LC_ALL=C od -An -tx1 "$file" | grep -q ' 00'; then
    echo "TESTCOUNT FAIL: the $what $file holds a NUL byte, so its rows are not its bytes" >&2
    return 2
  fi
  if LC_ALL=C grep -q '[^[:print:][:space:]]' "$file"; then
    echo "TESTCOUNT FAIL: the $what $file holds a byte that is not printable ASCII, TAB or LF" >&2
    return 2
  fi
  if [ -s "$file" ] && [ "$(tail -c1 "$file" | od -An -tx1 | tr -d '[:space:]')" != "0a" ]; then
    echo "TESTCOUNT FAIL: the $what $file does not end in a newline, so its last row was cut off" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      *$'\r'*)
        echo "TESTCOUNT FAIL: the $what $file line $n ends with a carriage return; the rows are LF" >&2
        rc=2; continue ;;
    esac
    name="${line%%$'\t'*}"
    count="${line#*$'\t'}"
    if [ "$name" = "$line" ] || [ -z "$name" ] || [ -z "$count" ] || [ "${count#*$'\t'}" != "$count" ]; then
      echo "TESTCOUNT FAIL: the $what $file line $n is not <bundle> TAB <count>: '$line'" >&2
      rc=2; continue
    fi
    case "$name" in
      *[[:space:]]*)
        echo "TESTCOUNT FAIL: the $what $file line $n names a bundle with a space in it: '$name'" >&2
        rc=2; continue ;;
    esac
    # Digits are not enough. The comparison below is bash arithmetic, and arithmetic on a number
    # bash cannot hold FAILS the test rather than answering it — which an `if` reads as false, the
    # one answer that passes. Nine digits is past every count this repository could ever run.
    case "$count" in
      *[!0-9]*)
        echo "TESTCOUNT FAIL: the $what $file gives $name the count '$count', which is not a number" >&2
        rc=2; continue ;;
      ??????????*)
        echo "TESTCOUNT FAIL: the $what $file gives $name a count of ${#count} digits, which is not a" >&2
        echo "                number of test cases and not one the comparison could take" >&2
        rc=2; continue ;;
    esac
    printf '%s\t%s\n' "$name" "$count"
  done < "$file"
  return "$rc"
}

observed_rows="$(validate "$observed" "observed counts")"
observed_rc=$?
baseline_rows="$(validate "$baseline" "baseline")"
baseline_rc=$?
if [ "$observed_rc" -ne 0 ] || [ "$baseline_rc" -ne 0 ]; then
  exit 2
fi
if [ -z "$observed_rows" ]; then
  echo "TESTCOUNT FAIL: $observed holds no counts, so there is nothing for the baseline to be compared with"
  exit 2
fi

names_of() { printf '%s\n' "$1" | cut -f1; }
count_in() { printf '%s\n' "$1" | awk -F'\t' -v b="$2" '$1 == b { print $2 }'; }

# A bundle named twice is two answers where the comparison takes one: whichever row it read, the
# other was a number nobody applied, and a comparison that took both at once would be arithmetic on
# two lines, which fails rather than answering. Either file can hold it.
duplicated=0
name_twice() { # $1 = rows, $2 = what to call the file, $3 = the file
  local bundle
  for bundle in $(names_of "$1" | sort | uniq -d); do
    echo "TESTCOUNT FAIL: the $2 $3 names $bundle twice, so one of those rows is a number nobody applied"
    duplicated=1
  done
}
name_twice "$observed_rows" "observed counts" "$observed"
name_twice "$baseline_rows" "baseline" "$baseline"
[ "$duplicated" -eq 0 ] || exit 2

# A row for a bundle this run never measured is a baseline written for a different bundle list,
# and the counts under it were compared with nothing.
surplus=0
for bundle in $(names_of "$baseline_rows"); do
  if [ -z "$(count_in "$observed_rows" "$bundle")" ]; then
    echo "TESTCOUNT FAIL: the baseline $baseline holds a row for $bundle, which this run did not measure"
    surplus=1
  fi
done
[ "$surplus" -eq 0 ] || exit 2

rc=0
summary=""
for bundle in $(names_of "$observed_rows"); do
  n="$(count_in "$observed_rows" "$bundle")"
  floor="$(count_in "$baseline_rows" "$bundle")"
  if [ -z "$floor" ]; then
    echo "TESTCOUNT FAIL: $bundle has no row in the baseline $baseline, so its $n cases were compared with nothing"
    rc=1
    continue
  fi
  # Both operands are one validated row's count: at most nine digits, and neither file names this
  # bundle twice, so this test answers rather than failing and being read as a pass.
  if [ "$n" -lt "$floor" ]; then
    echo "TESTCOUNT FAIL: $bundle executed $n cases, below the $floor its baseline row records"
    rc=1
    continue
  fi
  summary="$summary${summary:+, }$bundle $n>=$floor"
done

if [ "$rc" -ne 0 ]; then
  echo "TESTCOUNT FAIL: if this reduction is intended, re-record the baseline from what this run counted:"
  echo "TESTCOUNT FAIL:   cp .gate-artifacts/testcount-baseline.tsv tests/gate/testcount-baseline.tsv   # then commit it"
else
  echo "TESTCOUNT ok: every bundle is at or above its baseline row: $summary"
fi
exit "$rc"
