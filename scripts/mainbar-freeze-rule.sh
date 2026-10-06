#!/usr/bin/env bash
#
# The main-bar freeze: the app's bottom bar stays as the owner accepted it on 2.2.1 (41) (MEMNG-690):
# "perfection - this is exactly how we want it. we should freeze this".
#
# The bar is one app-drawn Liquid Glass capsule (`LeadingMainBar`) hosted once, by `MainTabs` in
# Dock.swift, around every tab, with the system's own tab bar hidden. It took a dozen builds of
# variants to reach — a bar per stack, the system bar minimised on scroll, a bottom accessory, a
# search-role tab, a `BarStyle` switch, the Library's own bottom toolbar — and every one of them is
# a single line away from coming back. What a render test can see of the bar is held by the render
# tests this rule pins by name; what it cannot see, or only sees after it has been rebuilt to look
# for it, is held here as source text:
#
#   1. hosting   — the bar is constructed on exactly one uncommented line in the Features sources,
#                  and that line is in Dock.swift (control: its type declared once, in
#                  LeadingMainBar.swift). The type is internal, so no other module can build one.
#   2. system    — Dock.swift hides the system tab bar and never minimises it; no source shows it
#                  (control: the hiding line itself, counted across the sources).
#   3. variants  — none of the rejected variants' spellings is back in the sources (control: the
#                  bottom safe-area bars of the TabView host and the rooms, at least two).
#   4. constants — the leading inset, the height and the pill's spring, each pinned as the whole
#                  declaration line, so 21 cannot become 210 and still match.
#   5. tests     — the render and table tests that hold the bar's behaviour still exist, each by its
#                  exact `@Test("…")` text: a test renamed, deleted, commented out or given a trait
#                  such as `.disabled` no longer matches (control: each file's `@Test(` count,
#                  which must cover the names pinned in it). Neither file may carry a disabling
#                  or conditional trait, and the @Suite line of the suite the render tests extend
#                  is pinned whole. Checks 1, 2 and 5 also close the evasions a per-line count
#                  leaves: a construction or a tab-bar modifier split across lines.
#
# Every count reads UNCOMMENTED text only: a check a comment can defeat is not a check, and a test
# commented out is a test lost. Swift's two comment forms are removed per file — every `/* … */`
# block first, nesting honoured because Swift nests them, then every `//` line; a `//` inside a
# block must not swallow that block's closing `*/`. A `/*` inside a string literal is the case this
# leaves open, and none of the checked files has one. This script's own text carries every literal
# it counts, which is why it lives in scripts/ and not in the scope it checks.
#
# Changing what this rule pins is a reviewed act: the owner unfreezes the bar, the change edits this
# script beside the source it releases, and an audit of the change sees both.
#
# Usage: mainbar-freeze-rule.sh [<repo-root>]   (default: the current directory)
# Exit:  0 = every check held and every control answered
#        1 = a check or a control failed
#        2 = the inputs were not usable (no such tree, a pinned file missing, text that could not
#            be read), which is never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "MAINBAR FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

sources="$root/Packages/MemosFeatures/Sources"
features="$sources/MemosFeatures"
dock="$features/Dock.swift"
bar="$features/LeadingMainBar.swift"
library="$features/MediaLibraryView.swift"
chrome_tests="$root/Packages/MemosFeatures/Tests/MemosFeaturesTests/LibraryChromeRenderTests.swift"
mode_tests="$root/Packages/MemosCore/Tests/MemosCoreTests/DockModeTests.swift"
# The render tests are an extension of this suite, so its traits are theirs.
owner_tests="$root/Packages/MemosFeatures/Tests/MemosFeaturesTests/MediaImageLoaderTests.swift"

for f in "$dock" "$bar" "$library" "$chrome_tests" "$mode_tests" "$owner_tests"; do
  if [ ! -f "$f" ]; then
    echo "MAINBAR FAIL: $f does not exist — a pinned file that is not there reads exactly like one"
    echo "              that holds nothing, and is refused rather than counted"
    exit 2
  fi
done

work="$(mktemp -d "${TMPDIR:-/tmp}/mainbar-rule-XXXXXX")" || { echo "MAINBAR FAIL: no temp dir"; exit 2; }
trap 'rm -rf "$work"' EXIT

# The uncommented text of every Swift file under the Features sources, one stripped copy per file
# at the same relative path, so a hit can still be named by the file it came from.
swift_files="$work/files"
find "$sources" -type f -name '*.swift' > "$swift_files" || { echo "MAINBAR FAIL: cannot walk $sources"; exit 2; }
if [ ! -s "$swift_files" ]; then
  echo "MAINBAR FAIL: no Swift file under $sources, so nothing was checked"
  exit 2
fi
# The file goes in on stdin, never as perl's argument: perl -p warns about a file it cannot open and
# still exits 0, which would turn an unreadable source into an empty — and therefore clean — one.
# A redirection that cannot open the file fails the command instead.
strip() { # $1 source file, $2 destination
  LC_ALL=C perl -0777 -pe 's{ ( /\* (?: [^/*]+ | /(?!\*) | \*(?!/) | (?1) )* \*/ ) }{}gsx; s{//[^\n]*}{}g' < "$1" > "$2"
}
plain="$work/plain"
while IFS= read -r f; do
  rel="${f#"$sources"/}"
  mkdir -p "$plain/$(dirname "$rel")" || exit 2
  if ! strip "$f" "$plain/$rel"; then
    echo "MAINBAR FAIL: stripping the comments from $f failed, so nothing was checked"
    exit 2
  fi
done < "$swift_files"
for t in "$chrome_tests" "$mode_tests" "$owner_tests"; do
  if ! strip "$t" "$work/$(basename "$t")"; then
    echo "MAINBAR FAIL: stripping the comments from $t failed, so nothing was checked"
    exit 2
  fi
done
p_dock="$plain/MemosFeatures/Dock.swift"
p_bar="$plain/MemosFeatures/LeadingMainBar.swift"
p_library="$plain/MemosFeatures/MediaLibraryView.swift"
for f in "$p_dock" "$p_bar" "$p_library" "$work/LibraryChromeRenderTests.swift" "$work/DockModeTests.swift"; do
  if [ ! -s "$f" ]; then
    echo "MAINBAR FAIL: $(basename "$f") is empty once its comments are gone, so nothing was checked"
    exit 2
  fi
done

# Uncommented lines matching an extended regex: one count, or the hits named file:line. grep's own
# exit is read, never a pipe's: 1 is "no line", anything above it is a grep that read nothing, and a
# zero from a grep that read nothing would pass every 0-wanted check below. The counts are taken in
# command substitutions, whose exit nobody sees, so a grep that could not run leaves a mark on disk
# that the verdict reads before it says anything.
grep_failed="$work/grep-failed"
grep_or_mark() { # grep arguments; prints grep's output
  local out status
  out="$(grep "$@")"
  status=$?
  if [ "$status" -gt 1 ]; then
    echo "MAINBAR FAIL: grep $* ended with exit $status, so nothing was checked" >&2
    : > "$grep_failed"
  fi
  printf '%s' "$out"
}
count_in() { local n; n="$(grep_or_mark -caE -- "$1" "$2")"; printf '%s' "${n:-0}"; }
hits_tree() { local h; h="$(cd "$plain" && grep_or_mark -rnaE -- "$1" .)"; [ -z "$h" ] || printf '%s\n' "$h" | sed 's|^\./||'; }
count_tree() { local h; h="$(hits_tree "$1")"; if [ -z "$h" ]; then echo 0; else printf '%s\n' "$h" | grep -c ''; fi; }

rc=0
fail() { echo "MAINBAR FAIL: $*"; rc=1; }

# --- 1. hosting ------------------------------------------------------------------------------------
# A construction, never the type's name alone (`LeadingMainBar.room`, `LeadingMainBar.BarShape`):
# the name directly followed by `(` or by `.init(`, and not the tail of a longer name.
construct='(^|[^A-Za-z0-9_])LeadingMainBar(\.init)?[[:space:]]*\('
sites="$(hits_tree "$construct")"
n_sites="$(printf '%s' "$sites" | grep -c '')"
echo "MAINBAR 1 hosting: the bar is constructed on $n_sites uncommented line(s) under the Features sources, 1 wanted, in Dock.swift"
[ -z "$sites" ] || printf '%s\n' "$sites" | sed 's/^/                  /'
if [ "$n_sites" -ne 1 ]; then
  fail "the main bar is built on $n_sites line(s); the frozen bar is ONE bar, hosted once by MainTabs"
elif ! printf '%s\n' "$sites" | grep -q '^MemosFeatures/Dock\.swift:'; then
  fail "the one construction of the main bar is not in Dock.swift — the bar has moved host"
fi
# The count above is per line, so a construction split after the name — `LeadingMainBar` on one
# line, its `(` on the next — would escape it. No line may end in the bare name.
split_re='(^|[^A-Za-z0-9_])LeadingMainBar(\.init)?[[:space:]]*$'
n_split="$(count_tree "$split_re")"
echo "MAINBAR 1 hosting: a line ending in the bare name (a construction split across lines) on $n_split uncommented line(s), 0 wanted (control: the $n_sites one-line construction(s) above)"
if [ "$n_split" -ne 0 ]; then
  fail "a construction of the main bar split across lines:"
  hits_tree "$split_re" | sed 's/^/              /'
fi
decl="$(count_in 'struct[[:space:]]+LeadingMainBar([^A-Za-z0-9_]|$)' "$p_bar")"
echo "MAINBAR 1 (control): LeadingMainBar.swift declares the type on $decl uncommented line(s), 1 wanted"
[ "$decl" -eq 1 ] || fail "positive control — LeadingMainBar.swift does not declare the type exactly once, so the count above read the wrong tree"

# --- 2. the system bar stays hidden ----------------------------------------------------------------
hidden_re='\.toolbarVisibility\([[:space:]]*\.hidden[[:space:]]*,[[:space:]]*for:[[:space:]]*\.tabBar[[:space:]]*\)'
hidden_dock="$(count_in "$hidden_re" "$p_dock")"
shown_re='\.(automatic|visible)[[:space:]]*,[[:space:]]*for:[[:space:]]*\.tabBar'
shown="$(count_tree "$shown_re")"
hidden_tree="$(count_tree "$hidden_re")"
never="$(count_in '\.tabBarMinimizeBehavior\([[:space:]]*\.never[[:space:]]*\)' "$p_dock")"
ondown="$(count_in '\.onScrollDown' "$p_dock")"
echo "MAINBAR 2 system: Dock.swift hides the system tab bar on $hidden_dock uncommented line(s), at least 1 wanted"
echo "MAINBAR 2 system: the sources show the system tab bar (.automatic or .visible) on $shown line(s), 0 wanted"
echo "MAINBAR 2 (control): the sources hide it on $hidden_tree line(s), at least 1 wanted"
echo "MAINBAR 2 system: Dock.swift never minimises the tab bar on $never line(s), at least 1 wanted; .onScrollDown on $ondown, 0 wanted"
[ "$hidden_dock" -ge 1 ] || fail "Dock.swift no longer hides the system tab bar — two bars would stand at the foot"
if [ "$shown" -ne 0 ]; then
  fail "a source shows the system tab bar:"
  hits_tree "$shown_re" | sed 's/^/              /'
fi
[ "$hidden_tree" -ge 1 ] || fail "positive control — no source hides the tab bar, so the 0 above read nothing"
# The two counts above are per line, so `.visible,` on one line and `for: .tabBar)` on the next
# would pass both. Every line naming the tab bar must therefore also say `.hidden`: a modifier split
# across lines leaves a `.tabBar` line without it.
tabbar_re='\.tabBar([^A-Za-z0-9_]|$)'
tabbar_hits="$(hits_tree "$tabbar_re")"
tabbar_lines=0; tabbar_hidden=0
if [ -n "$tabbar_hits" ]; then
  tabbar_lines="$(printf '%s\n' "$tabbar_hits" | grep -c '')"
  tabbar_hidden="$(printf '%s\n' "$tabbar_hits" | grep -cF '.hidden')"
fi
echo "MAINBAR 2 system: lines naming the tab bar $tabbar_lines, of them saying .hidden $tabbar_hidden; equal and at least 1 wanted"
if [ "$tabbar_lines" -lt 1 ] || [ "$tabbar_lines" -ne "$tabbar_hidden" ]; then
  fail "a line names the tab bar without hiding it (or none names it at all):"
  printf '%s\n' "$tabbar_hits" | grep -vF '.hidden' | sed 's/^/              /'
fi
[ "$never" -ge 1 ] || fail "Dock.swift no longer pins the tab bar's minimise behaviour to .never"
[ "$ondown" -eq 0 ] || fail "Dock.swift minimises the tab bar on a scroll down, the rejected system fold"

# --- 3. no rejected variant comes back -------------------------------------------------------------
for literal in 'tabViewBottomAccessory' 'role: .search' 'BarStyle'; do
  re="$(printf '%s' "$literal" | sed 's/[.]/\\./g')"
  n="$(count_tree "$re")"
  echo "MAINBAR 3 variants: '$literal' on $n uncommented line(s) under the Features sources, 0 wanted"
  if [ "$n" -ne 0 ]; then
    fail "'$literal' is back — a rejected bar variant:"
    hits_tree "$re" | sed 's/^/              /'
  fi
done
bottombar="$(count_in 'placement:[[:space:]]*\.bottomBar' "$p_library")"
echo "MAINBAR 3 variants: 'placement: .bottomBar' on $bottombar uncommented line(s) in MediaLibraryView.swift, 0 wanted"
[ "$bottombar" -eq 0 ] || fail "MediaLibraryView.swift has a bottom toolbar again — the scope row is the main bar's"
rooms="$(count_tree '\.safeAreaBar\(edge:[[:space:]]*\.bottom\)')"
echo "MAINBAR 3 (control): 'safeAreaBar(edge: .bottom)' on $rooms uncommented line(s) under the Features sources, at least 2 wanted"
[ "$rooms" -ge 2 ] || fail "positive control — fewer than two bottom safe-area bars (the TabView host and the rooms), so the 0s above read the wrong tree"

# --- 4. the frozen constants -----------------------------------------------------------------------
# Whole declaration lines, leading and trailing blanks aside.
trimmed="$work/bar-trimmed"
sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$p_bar" > "$trimmed"
for decl_line in \
  'static let leadingInset: CGFloat = 21' \
  'static let height: CGFloat = 62' \
  'static let pillTravel = Spring(response: 0.35, dampingRatio: 0.7)'; do
  n="$(grep_or_mark -cxF -- "$decl_line" "$trimmed")"; n="${n:-0}"
  echo "MAINBAR 4 constants: '$decl_line' on $n uncommented line(s) in LeadingMainBar.swift, at least 1 wanted"
  [ "$n" -ge 1 ] || fail "LeadingMainBar.swift no longer declares '$decl_line' — a frozen constant moved"
done

# --- 5. the invariant tests ------------------------------------------------------------------------
check_tests() { # $1 stripped file, $2 its name, then the display names pinned in it
  local file="$1" name="$2" total n pinned=0
  shift 2
  for title in "$@"; do
    pinned=$((pinned + 1))
    n="$(grep_or_mark -cF -- "@Test(\"$title\")" "$file")"; n="${n:-0}"
    echo "MAINBAR 5 tests: $name @Test(\"$title\") on $n uncommented line(s), at least 1 wanted"
    [ "$n" -ge 1 ] || fail "$name has lost the invariant test \"$title\" (renamed, deleted, commented out or given a trait)"
  done
  total="$(grep_or_mark -cF '@Test(' "$file")"; total="${total:-0}"
  # A trait on the suite disables every pinned test while each @Test line survives, and a trait
  # argument may sit on a line of its own. Neither file uses a disabling or conditional trait
  # anywhere, so none may appear: not on a @Suite( line, and not on any other uncommented line.
  local suites suite_off traits_off
  suites="$(grep_or_mark -cF '@Suite(' "$file")"; suites="${suites:-0}"
  suite_off="$(grep_or_mark -cE '@Suite\(.*(\.disabled|\.enabled\(if:)' "$file")"; suite_off="${suite_off:-0}"
  traits_off="$(grep_or_mark -cE '\.disabled([^A-Za-z0-9_]|$)|\.enabled\([[:space:]]*if:' "$file")"; traits_off="${traits_off:-0}"
  echo "MAINBAR 5 tests: $name @Suite( lines with .disabled or .enabled(if: $suite_off, 0 wanted; such a trait on any uncommented line $traits_off, 0 wanted (control: $suites @Suite( line(s), 0 is a file with no suite macro)"
  [ "$suite_off" -eq 0 ] || fail "$name disables or conditions its suite, and with it every pinned test"
  [ "$traits_off" -eq 0 ] || fail "$name carries a disabling or conditional trait — the pinned tests may not run"
  echo "MAINBAR 5 (control): $name holds $total uncommented @Test( line(s), at least the $pinned pinned"
  [ "$total" -ge "$pinned" ] || fail "positive control — $name holds fewer tests than this rule pins, so it is not the file the names were read from"
}
check_tests "$work/LibraryChromeRenderTests.swift" LibraryChromeRenderTests.swift \
  "one bar: a single main-bar marker through every switch, the capsule's frame unmoved" \
  "one bar 2: the bar around the tabs fades the content under it where 40's bar did" \
  "leading 6: the row's icon gives the capsule back where the grid stands" \
  "leading 7: the foot of every scrolling root clears the leading bar" \
  "bubble 1: the selection pill stands under the tab pressed, and none on the scope row" \
  "bubble 2: the folded capsule draws no pill; unfolded, the pill is back" \
  "bubble 3: a held press swells the tab under it, and the release lets it go" \
  "film a-c: the Timeline's fold and unfold, the leading edge held" \
  "film d-f: the Library's morph and the tabs pressed"
check_tests "$work/DockModeTests.swift" DockModeTests.swift \
  "a run of the reader's travel folds and unfolds the bar once per direction"

# LibraryChromeRenderTests.swift declares no suite: its tests extend MediaImageLoaderTests, whose
# one @Suite line is in MediaImageLoaderTests.swift. A trait added there — on that line or on a
# line of its own — disables every pinned render test, so the line is pinned whole.
owner_suite='@Suite("MediaImageLoader", .serialized, .mediaGlobals)'
sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$work/MediaImageLoaderTests.swift" > "$work/owner-trimmed"
n_owner="$(grep_or_mark -cxF -- "$owner_suite" "$work/owner-trimmed")"; n_owner="${n_owner:-0}"
n_ext="$(grep_or_mark -cE '^[[:space:]]*extension[[:space:]]+MediaImageLoaderTests[[:space:]]*\{' "$work/LibraryChromeRenderTests.swift")"; n_ext="${n_ext:-0}"
echo "MAINBAR 5 tests: MediaImageLoaderTests.swift '$owner_suite' on $n_owner uncommented line(s), at least 1 wanted"
echo "MAINBAR 5 (control): LibraryChromeRenderTests.swift extends MediaImageLoaderTests on $n_ext uncommented line(s), at least 1 wanted"
[ "$n_owner" -ge 1 ] || fail "the suite that owns the render tests changed its @Suite line — a trait there disables every pinned render test"
[ "$n_ext" -ge 1 ] || fail "positive control — the render tests no longer extend MediaImageLoaderTests, so the suite pinned above is not theirs"

if [ -e "$grep_failed" ]; then
  echo "MAINBAR FAIL: a count above came from a grep that could not run, so this verdict is refused"
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  echo "MAINBAR ok: the main bar is hosted once in Dock.swift, the system bar stays hidden, no rejected variant is back, the constants and the invariant tests stand, and every control answered"
fi
exit $rc
