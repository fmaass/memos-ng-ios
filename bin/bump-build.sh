#!/usr/bin/env bash
# bump-build.sh — set the build number and its TestFlight notes in ONE commit, on a work branch.
#
#   bin/bump-build.sh --build <n> --notes-file <path>
#
# A pure local text edit; it needs no Mac and asks nothing of App Store Connect. The number comes
# from `bin/testflight-cut.sh --resolve-build` (its RESOLVED-BUILD line), the body from a file kept
# OUTSIDE the tree, so no placeholder section is ever tracked. In order:
#   1. refuses (exit 2, nothing written) on the branch `main`, a detached HEAD, a dirty tree, a
#      missing or malformed --build (a whole number without a leading zero), a --build not greater
#      than the current one (a re-run on the same number is a refusal, never a second section), a
#      notes file that is missing, empty or blank, that names a tracker key, that says we/us/our,
#      or whose project.yml does not name exactly two equal build key lines;
#   2. builds both results in a private temporary directory: project.yml with BOTH
#      `CURRENT_PROJECT_VERSION:` key lines set to <n> by an anchored sed (a key line starts with the
#      key after indentation, as scripts/release-notes-rule.sh reads it, so a comment naming the key
#      is never one), every MARKETING_VERSION line left as it was; ReleaseNotes.md with
#      `## <version> (<n>)`, a blank line and the body inserted under the intro, above the first
#      `## ` section outside a code fence;
#   3. re-reads that RESULT the way the cut's loader does (fastlane/lib/release_notes.rb): exactly
#      one section for the pair, not empty, at most 4000 characters (String#length of the section's
#      lines, chomped, joined with "\n", outer whitespace stripped); then refuses a body with a
#      level-1/2 heading outside a fence (the loader would end the section there) or a fence left
#      open (it would swallow every older section);
#   4. writes both files in place, reads the key lines back from the tree, and commits the two files
#      with a message that names the pair. The last line is
#        BUMPED version=<v> build=<n> commit=<sha>
#
# Exit: 0 = committed; 2 = refused, nothing written; 1 = the write or the commit failed after the
# files were touched (both are put back from HEAD first, so the tree is as it was).
set -u
cd "$(dirname "$0")/.." || exit 2

PROJECT=project.yml
NOTES=Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md
NOTES_MAX_CHARACTERS=4000 # the loader's MAX_CHARACTERS, TestFlight's limit on "What to Test"

refuse() { # TOKEN MESSAGE
  printf 'bump-build: REFUSED(%s): %s\n' "$1" "$2" >&2
  exit 2
}
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

build=""
have_build=0
notes_file=""
have_notes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) have_build=1; build="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
    --notes-file) have_notes=1; notes_file="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) refuse usage "unknown argument '$1' (bin/bump-build.sh --build <n> --notes-file <path>)" ;;
  esac
done
[ "$have_build" -eq 1 ] || refuse usage "--build <n> is required (the number --resolve-build answered)"
[ "$have_notes" -eq 1 ] || refuse usage "--notes-file <path> is required (the section's body, kept outside the tree)"

command -v python3 >/dev/null 2>&1 || refuse no-python "python3 is not on PATH; it counts the section as the loader does"

git rev-parse --verify -q HEAD >/dev/null || refuse no-repo "this checkout has no HEAD"
branch="$(git symbolic-ref -q --short HEAD)" || refuse detached "HEAD is detached; bump on a work branch"
[ "$branch" != main ] || refuse on-main "the branch is main; bump on a work branch and land it through the full gate"
porcelain="$(git status --porcelain 2>&1)" || refuse no-repo "git status failed: $porcelain"
[ -z "$porcelain" ] || refuse dirty "the tree is not clean; the bump commit must hold the two files and nothing else"

[[ "$build" =~ ^[1-9][0-9]{0,8}$ ]] || refuse bad-build "--build must be a whole number without a leading zero (got '$build')"

[ -f "$notes_file" ] && [ -r "$notes_file" ] || refuse notes-missing "no readable notes file at '$notes_file'"
grep -q '[^[:space:]]' "$notes_file" || refuse notes-empty "the notes file '$notes_file' is empty or blank"
if grep -nE 'MEMNG-[0-9]+' "$notes_file" >&2; then
  refuse tracker-key "the notes name a tracker key (the lines above); testers never see those"
fi
if grep -niE '\b(we|us|our)\b' "$notes_file" >&2; then
  refuse voice "the notes say we/us/our (the lines above); the notes are first person singular"
fi

[ -f "$PROJECT" ] && [ -f "$NOTES" ] || refuse bad-project "$PROJECT or $NOTES is missing"
# The same reading as scripts/release-notes-rule.sh: a key line is the key after indentation.
key_values() { # FILE KEY
  sed -n -E "s/^[[:space:]]*$2:[[:space:]]*\"?([^\"[:space:]#]+)\"?[[:space:]]*(#.*)?\$/\\1/p" "$1"
}
version="$(key_values "$PROJECT" MARKETING_VERSION | head -n 1)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse bad-project "$PROJECT names no MARKETING_VERSION key line (read '$version')"
builds="$(key_values "$PROJECT" CURRENT_PROJECT_VERSION | paste -sd ' ' -)"
[[ "$builds" =~ ^([0-9]+)\ ([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] ||
  refuse bad-project "$PROJECT must name exactly two equal CURRENT_PROJECT_VERSION key lines (read '$builds')"
current="${BASH_REMATCH[1]}"
[ "$build" -gt "$current" ] || refuse build-not-greater "--build $build is not greater than the current build $current"

work="$(mktemp -d "${TMPDIR:-/tmp}/bump-build.XXXXXX")" || refuse no-temp "cannot create a temporary directory"
trap 'rm -rf "${work:?}"' EXIT

sed -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?([[:space:]]*(#.*)?)\$/\\1\"$build\"\\2/" \
  "$PROJECT" > "$work/project.yml" || refuse no-temp "cannot write the new $PROJECT"
[ "$(key_values "$work/project.yml" CURRENT_PROJECT_VERSION | paste -sd ' ' -)" = "$build $build" ] ||
  refuse bad-project "the rewritten $PROJECT does not name $build on exactly two key lines"
[ "$(grep -n MARKETING_VERSION "$PROJECT")" = "$(grep -n MARKETING_VERSION "$work/project.yml")" ] ||
  refuse bad-project "the rewrite would change a MARKETING_VERSION line"

heading="## $version ($build)"
verdict="$(python3 -I - "$NOTES" "$notes_file" "$heading" "$work/notes.md" "$NOTES_MAX_CHARACTERS" <<'PY'
import re, sys

notes_path, body_path, heading, out_path, limit = sys.argv[1:6]
limit = int(limit)
# The loader's readings (fastlane/lib/release_notes.rb): FENCE, SECTION_END, Ruby's String#strip.
# Ruby's \s is ASCII whitespace only; Python's would also take U+2028 and the other Unicode spaces.
FENCE = re.compile(r"\A[ \t\n\v\f\r]*(`{3,}|~{3,})")
SECTION_END = re.compile(r"\A#{1,2}([ \t\n\v\f\r]|\Z)")
RUBY_SPACE = " \t\n\v\f\r\0"

def refuse(token, message):
    print(f"REFUSE {token} {message}")
    sys.exit(0)

def fence_after(line, fence):
    if fence is None:
        m = FENCE.match(line)
        return m.group(1) if m else None
    closing = line.strip(RUBY_SPACE)
    closes = len(closing) >= len(fence) and closing.replace(fence[0], "") == ""
    return None if closes else fence

def raw_lines_of(text):  # Ruby each_line: split after every "\n" and nowhere else
    parts = text.split("\n")
    return [part + "\n" for part in parts[:-1]] + ([parts[-1]] if parts[-1] else [])

def lines_of(text):  # Ruby each_line + chomp (one trailing "\r\n", "\n" or "\r")
    out = []
    for raw in raw_lines_of(text):
        if raw.endswith("\r\n"):
            raw = raw[:-2]
        elif raw.endswith("\n") or raw.endswith("\r"):
            raw = raw[:-1]
        out.append(raw)
    return out

with open(notes_path, encoding="utf-8", newline="") as f:
    notes = f.read()
with open(body_path, encoding="utf-8", newline="") as f:
    body = f.read()

# The insertion point: the first "## " line outside a fence, as scripts/release-notes-rule.sh reads.
raw_lines = raw_lines_of(notes)
fence = None
anchor = None
for i, raw in enumerate(raw_lines):
    line = lines_of(raw)[0] if raw else raw
    if fence is None and line.startswith("## "):
        anchor = i
        break
    fence = fence_after(line, fence)
if anchor is None:
    refuse("no-section-anchor", "the notes file has no '## ' section outside a fence to insert above")

body_text = body.rstrip("\r\n") + "\n"
result = "".join(raw_lines[:anchor]) + heading + "\n\n" + body_text + "\n" + "".join(raw_lines[anchor:])

# The RESULT, read back as the loader reads it.
found = []
current = None
fence = None
for line in lines_of(result):
    if fence is None and SECTION_END.match(line.rstrip(RUBY_SPACE)):
        current = [] if line.rstrip(RUBY_SPACE) == heading else None
        if current is not None:
            found.append(current)
        continue
    fence = fence_after(line, fence)
    if current is not None:
        current.append(line)
if len(found) != 1:
    refuse("duplicate-section", f"the result holds {len(found)} sections '{heading}'; exactly one is wanted")
section = "\n".join(found[0]).strip(RUBY_SPACE)
if not section:
    refuse("empty-section", f"the section '{heading}' would be empty before the next heading")
if len(section) > limit:
    refuse("too-long", f"the section '{heading}' is {len(section)} characters; TestFlight takes at most {limit}")

# The body alone: a heading outside a fence ends the section early, an open fence swallows the rest.
fence = None
for n, line in enumerate(lines_of(body), 1):
    if fence is None and SECTION_END.match(line.rstrip(RUBY_SPACE)):
        refuse("body-heading", f"line {n} of the body is a level-1/2 heading, which would end the section")
    fence = fence_after(line, fence)
if fence is not None:
    refuse("unclosed-fence", f"the body leaves a {fence} fence open, which would swallow every older section")

with open(out_path, "w", encoding="utf-8", newline="") as f:
    f.write(result)
print(f"OK {len(section)}")
PY
)" || refuse notes-check "the notes check did not run (python3 exit $?; an unreadable or non-UTF-8 file)"
case "$verdict" in
  "OK "*) ;;
  "REFUSE "*) v="${verdict#REFUSE }"; refuse "${v%% *}" "${v#* }" ;;
  *) refuse notes-check "the notes check gave no verdict ('$verdict')" ;;
esac

put_back() { git checkout -q -- "$PROJECT" "$NOTES"; }
if ! { cat "$work/project.yml" > "$PROJECT" && cat "$work/notes.md" > "$NOTES"; }; then
  put_back
  echo "bump-build: FAILED: writing $PROJECT or $NOTES failed; both are back at HEAD" >&2
  exit 1
fi
if [ "$(key_values "$PROJECT" CURRENT_PROJECT_VERSION | paste -sd ' ' -)" != "$build $build" ]; then
  put_back
  echo "bump-build: FAILED: $PROJECT did not read back $build on both key lines; both files are back at HEAD" >&2
  exit 1
fi
if ! git add -- "$PROJECT" "$NOTES" ||
  ! git commit -q -m "Set the build to $version ($build) with its TestFlight notes" \
    -m "The cut uploads exactly the pair project.yml names, and the notes rule wants that pair's section: both change in this one commit, so a tree with one and not the other never exists." \
    -- "$PROJECT" "$NOTES"; then
  git reset -q -- "$PROJECT" "$NOTES"
  put_back
  echo "bump-build: FAILED: the commit failed; both files are back at HEAD" >&2
  exit 1
fi
echo "BUMPED version=$version build=$build commit=$(git rev-parse HEAD)"
