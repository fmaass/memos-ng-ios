#!/usr/bin/env bash
#
# The release-notes rule: the version and build project.yml declares have their section in the one
# notes file.
#
# `Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md` is read twice: the
# TestFlight cut sends the section headed with the archived numbers as the build's "What to Test"
# text (fastlane/lib/release_notes.rb), and the app's What's new screen, opened from the version
# footer on the account sheet, shows the running build's section first. A version bump that forgot
# its notes is caught by the cut only at the very end of a release, after the archive; and a build
# made from such a tree would open What's new on an older build's words. So the pair is checked
# here, on every full gate.
#
# The pair is the FIRST `MARKETING_VERSION:` and the first `CURRENT_PROJECT_VERSION:` key line in
# project.yml — the app target's, which the generate step already holds every target to. A key
# line starts with the key after indentation, so a comment that names a key is not one.
#
# A section is a `## ` line outside a code fence — the same reading the cut's loader takes (a run
# of three or more ` or ~ opens a fence, only a line that is nothing but the same character at
# least as many times closes it, as CommonMark has it, and a heading inside one is text) — and the section for
# the pair is a line exactly `## <version> (<build>)`, trailing whitespace aside. Exactly one is
# wanted: the cut refuses a duplicated section, so the rule does not pass one.
#
# The positive control is the count of sections read: a file that yields none was not the notes
# file, or arrived empty, and a miss in it proves nothing about the pair.
#
# Usage: release-notes-rule.sh [<repo-root>]     (default: the current directory)
# Exit:  0 = the pair has exactly one section, and the control read at least one section
#        1 = the rule was broken (no section for the pair, two of them, or no sections at all)
#        2 = the inputs were not usable (no such tree, a missing file, a pair project.yml does
#            not name), which is never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "NOTES FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

project="$root/project.yml"
notes="$root/Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md"

for input in "$project" "$notes"; do
  if [ ! -f "$input" ]; then
    echo "NOTES FAIL: $input is missing, so the notes were never checked against the version and"
    echo "            this step proves nothing"
    exit 2
  fi
done

first_key() { # $1 key — the first key line's value, quotes and a trailing comment dropped
  sed -n -E "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"[:space:]#]+)\"?[[:space:]]*(#.*)?\$/\\1/p" \
    "$project" | head -n 1
}

version="$(first_key MARKETING_VERSION)"
build="$(first_key CURRENT_PROJECT_VERSION)"

if [ -z "$version" ] || [ -z "$build" ]; then
  echo "NOTES FAIL: $project names no MARKETING_VERSION or no CURRENT_PROJECT_VERSION key line"
  echo "            (read '${version}' and '${build}'), so there is no section to look for"
  exit 2
fi

heading="## $version ($build)"

# Two numbers on one line: the sections read outside fences, and how many of them are the pair's.
counts="$(awk -v heading="$heading" '
  BEGIN { mark = ""; run = 0; sections = 0; hits = 0 }
  {
    line = $0
    sub(/\r$/, "", line)
    if (mark == "" && line ~ /^## /) {
      sections++
      trimmed = line
      sub(/[ \t]+$/, "", trimmed)
      if (trimmed == heading) hits++
      next
    }
    bare = line
    sub(/^[ \t]+/, "", bare)
    if (mark == "") {
      if (bare ~ /^(```|~~~)/) {
        mark = substr(bare, 1, 1)
        run = 0
        while (substr(bare, run + 1, 1) == mark) run++
      }
    } else {
      sub(/[ \t]+$/, "", bare)
      n = 0
      while (substr(bare, n + 1, 1) == mark) n++
      if (n >= run && n == length(bare)) mark = ""
    }
  }
  END { print sections, hits }
' "$notes")"
awk_rc=$?

sections="${counts% *}"
hits="${counts#* }"
case "$awk_rc:$sections:$hits" in
  0:[0-9]*:[0-9]*) ;;
  *)
    echo "NOTES FAIL: reading $notes ended with exit $awk_rc and '$counts', so neither the rule"
    echo "            nor its control was checked"
    exit 2
    ;;
esac

echo "NOTES: project.yml names $version ($build); ReleaseNotes.md has $hits line(s) '$heading', exactly 1 wanted"
echo "NOTES (control): read $sections '## ' section(s) outside code fences, at least 1 wanted"

if [ "$sections" -lt 1 ]; then
  echo "NOTES FAIL: the control read no sections, so the file is not the notes it should be"
  exit 1
fi
if [ "$hits" -ne 1 ]; then
  echo "NOTES FAIL: '$heading' must head exactly one section of $notes (found $hits) — add the"
  echo "            notes for this build, newest first, or keep one section per build"
  exit 1
fi
exit 0
