#!/usr/bin/env bash
#
# The gate's main-bar freeze rule, checked against trees this script builds for the purpose.
#
# `scripts/mainbar-freeze-rule.sh` holds the bottom bar the owner froze on 2.2.1 (41) (MEMNG-690):
# its one host, the system bar hidden, the rejected variants absent, three constants and the names
# of the tests that hold its behaviour. A rule that cannot go red holds nothing, so each case below
# is a way the freeze is supposed to bite — a second construction, a moved host, the system bar
# shown or minimised, a variant back, a constant moved, a test lost — each on a scratch copy of the
# files the rule reads, taken from the repository this suite ships in.
#
# The last cases are the real repository itself, once alone and six times at once: the rule
# must hold on the tree as it stands, and two runs must not share their scratch. Nothing here writes
# into that tree — every mutant lands in a temporary copy — and every temporary tree is removed on
# exit.
#
# Run it directly (`tests/gate/mainbar-freeze-rule-test.sh`) or let the gate run it: it is one of
# the selftests bin/mac-gate.sh names, so a run without it fails.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/mainbar-freeze-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-mainbar-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'chmod -R u+rwX "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

FEATURES="Packages/MemosFeatures/Sources/MemosFeatures"
CHROME="Packages/MemosFeatures/Tests/MemosFeaturesTests/LibraryChromeRenderTests.swift"
MODES="Packages/MemosCore/Tests/MemosCoreTests/DockModeTests.swift"
OWNER="Packages/MemosFeatures/Tests/MemosFeaturesTests/MediaImageLoaderTests.swift"

# The Features sources and the two test files, copied from the real tree: the rule reads nothing
# else, and a mutant is only as honest as the text it was cut from.
new_tree() { # $1 name
  local work="$tmp/$1"
  mkdir -p "$work/Packages/MemosFeatures/Tests/MemosFeaturesTests" "$work/Packages/MemosCore/Tests/MemosCoreTests" || return 1
  cp -R "$repo_root/Packages/MemosFeatures/Sources" "$work/Packages/MemosFeatures/" || return 1
  cp "$repo_root/$CHROME" "$work/$CHROME" || return 1
  cp "$repo_root/$MODES" "$work/$MODES" || return 1
  cp "$repo_root/$OWNER" "$work/$OWNER" || return 1
  printf '%s' "$work"
}

# A literal replacement in one file of a scratch tree, which must find its target: a mutant whose
# edit matched nothing would be the clean tree under another name, and would "pass" for no reason.
mutate() { # $1 file, $2 perl substitution
  local before after
  before="$(cksum < "$1")"
  LC_ALL=C perl -0777 -pi -e "$2" "$1" || { echo "FAIL: cannot edit $1"; exit 1; }
  after="$(cksum < "$1")"
  [ "$before" != "$after" ] || { echo "FAIL: the mutation '$2' changed nothing in $1"; exit 1; }
}

check() { # $1 label, $2 expected exit, $3 tree root, $4 (optional) a fragment the output must carry
  local label="$1" expected="$2" root="$3" needle="${4:-}" out rc
  cases=$((cases + 1))
  out="$("$RULE" "$root" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ] && { [ -z "$needle" ] || printf '%s\n' "$out" | grep -qF -- "$needle"; }; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    if [ "$first_fail" -eq 0 ]; then
      # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected${needle:+ naming '$needle'}, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

w="$(new_tree clean)" || exit 1
check "the files as they stand" 0 "$w"

# --- 1. hosting ---
w="$(new_tree second-site)" || exit 1
printf '\nstruct Extra: View {\n    var body: some View { LeadingMainBar(shape: nil, selection: .timeline, press: { _ in }, pressLibraryIcon: {}, scope: .all) }\n}\n' \
  >> "$w/$FEATURES/TimelineView.swift"
check "a second construction of the bar" 1 "$w" "constructed on 2 uncommented line(s)"

w="$(new_tree second-site-init)" || exit 1
printf '\nlet extra = LeadingMainBar.init(shape: nil)\n' >> "$w/$FEATURES/MediaLibraryView.swift"
check "a second construction spelled .init(" 1 "$w" "constructed on 2 uncommented line(s)"

w="$(new_tree moved-host)" || exit 1
mutate "$w/$FEATURES/Dock.swift" 's/^(\s+)LeadingMainBar\(/$1LeadingMainBarHost(/m'
printf '\nlet moved = LeadingMainBar(shape: nil)\n' >> "$w/$FEATURES/MediaLibraryView.swift"
check "the one construction moved out of Dock.swift" 1 "$w" "not in Dock.swift"

w="$(new_tree commented-host)" || exit 1
mutate "$w/$FEATURES/Dock.swift" 's/^(\s+)LeadingMainBar\(/$1\/\/ LeadingMainBar(/m'
check "the only construction commented out" 1 "$w" "constructed on 0 uncommented line(s)"

w="$(new_tree no-declaration)" || exit 1
mutate "$w/$FEATURES/LeadingMainBar.swift" 's/^struct LeadingMainBar: View/struct LeadingMainBarRenamed: View/m'
check "the control: the type no longer declared" 1 "$w" "positive control"

# --- 2. the system bar ---
w="$(new_tree tabbar-automatic)" || exit 1
mutate "$w/$FEATURES/Dock.swift" 's/\.toolbarVisibility\(\.hidden, for: \.tabBar\)/.toolbarVisibility(.automatic, for: .tabBar)/'
check "the system tab bar set to .automatic" 1 "$w" "show the system tab bar (.automatic or .visible) on 1"

w="$(new_tree tabbar-visible-elsewhere)" || exit 1
printf '\nlet shown = Text("x").toolbarVisibility(.visible, for: .tabBar)\n' >> "$w/$FEATURES/TimelineView.swift"
check "the system tab bar set to .visible outside Dock.swift" 1 "$w" "show the system tab bar"

w="$(new_tree minimise-on-scroll)" || exit 1
mutate "$w/$FEATURES/Dock.swift" 's/\.tabBarMinimizeBehavior\(\.never\)/.tabBarMinimizeBehavior(.onScrollDown)/'
check "the tab bar minimised on a scroll down" 1 "$w" ".onScrollDown on 1"

# --- 3. the variants ---
w="$(new_tree accessory)" || exit 1
printf '\nlet a = Text("x").tabViewBottomAccessory { Text("y") }\n' >> "$w/$FEATURES/Dock.swift"
check "a bottom accessory back" 1 "$w" "'tabViewBottomAccessory' is back"

w="$(new_tree search-role)" || exit 1
printf '\nlet t = Tab(role: .search) { Text("y") }\n' >> "$w/$FEATURES/Dock.swift"
check "a search-role tab back" 1 "$w" "'role: .search' is back"

w="$(new_tree bottom-toolbar)" || exit 1
printf '\nlet b = Text("x").toolbar { ToolbarItem(placement: .bottomBar) { Text("y") } }\n' >> "$w/$FEATURES/MediaLibraryView.swift"
check "the Library's own bottom toolbar back" 1 "$w" "bottom toolbar again"

w="$(new_tree no-rooms)" || exit 1
mutate "$w/$FEATURES/Dock.swift" 's/\.safeAreaBar\(edge: \.bottom\)/.safeAreaInset(edge: .bottom)/g'
mutate "$w/$FEATURES/MediaLibraryView.swift" 's/\.safeAreaBar\(edge: \.bottom\)/.safeAreaInset(edge: .bottom)/g'
check "the control: the bottom bars gone" 1 "$w" "positive control"

# --- 4. the constants ---
w="$(new_tree inset-changed)" || exit 1
mutate "$w/$FEATURES/LeadingMainBar.swift" 's/static let leadingInset: CGFloat = 21$/static let leadingInset: CGFloat = 16/m'
check "the leading inset changed" 1 "$w" "leadingInset: CGFloat = 21' on 0"

w="$(new_tree inset-prefix)" || exit 1
mutate "$w/$FEATURES/LeadingMainBar.swift" 's/static let leadingInset: CGFloat = 21$/static let leadingInset: CGFloat = 210/m'
check "the leading inset grown a digit (21 is a prefix of 210)" 1 "$w" "leadingInset: CGFloat = 21' on 0"

w="$(new_tree spring-changed)" || exit 1
mutate "$w/$FEATURES/LeadingMainBar.swift" 's/dampingRatio: 0\.7\)/dampingRatio: 0.9)/'
check "the pill's spring changed" 1 "$w" "pillTravel"

w="$(new_tree height-commented)" || exit 1
mutate "$w/$FEATURES/LeadingMainBar.swift" 's/^(\s+)static let height: CGFloat = 62$/$1static let height: CGFloat = 56 \/\/ static let height: CGFloat = 62/m'
check "the height changed with the old line left in a comment" 1 "$w" "height: CGFloat = 62' on 0"

# --- 5. the tests ---
w="$(new_tree test-deleted)" || exit 1
mutate "$w/$CHROME" 's/\@Test\("bubble 2: [^"]*"\)\n//'
check "a pinned render test deleted" 1 "$w" "lost the invariant test \"bubble 2:"

w="$(new_tree test-disabled)" || exit 1
mutate "$w/$CHROME" 's/\@Test\(("one bar 2: [^"]*")\)/\@Test($1, .disabled("later"))/'
check "a pinned render test given a .disabled trait" 1 "$w" "lost the invariant test \"one bar 2:"

w="$(new_tree test-renamed)" || exit 1
mutate "$w/$MODES" "s/folds and unfolds the bar once per direction/folds the bar/"
check "the fold table test renamed" 1 "$w" "DockModeTests.swift has lost the invariant test"

w="$(new_tree test-commented)" || exit 1
mutate "$w/$CHROME" 's/^(\s+)(\@Test\("film a-c: )/$1\/\/ $2/m'
check "a pinned render test commented out" 1 "$w" "lost the invariant test \"film a-c:"

# --- evasions across lines and through the suite (review round 1) ---
w="$(new_tree tabbar-visible-multiline)" || exit 1
printf '\nlet shown = Text("x").toolbarVisibility(.visible,\n    for: .tabBar)\n' >> "$w/$FEATURES/Dock.swift"
check "the system tab bar shown by a modifier split across lines" 1 "$w" "names the tab bar without hiding it"

w="$(new_tree tabbar-split-after-for)" || exit 1
printf '\nlet shown = Text("x").toolbarVisibility(.automatic, for:\n    .tabBar)\n' >> "$w/$FEATURES/TimelineView.swift"
check "the tab bar token on a line of its own" 1 "$w" "names the tab bar without hiding it"

w="$(new_tree split-construction)" || exit 1
printf '\nlet extra = LeadingMainBar\n    (shape: nil)\n' >> "$w/$FEATURES/TimelineView.swift"
check "a construction split after the name" 1 "$w" "split across lines"

w="$(new_tree suite-disabled)" || exit 1
mutate "$w/$MODES" 's/\@Suite\("DockMode"\)/\@Suite("DockMode", .disabled("later"))/'
check "a .disabled trait on DockModeTests' suite" 1 "$w" "disables or conditions its suite"

w="$(new_tree suite-disabled-multiline)" || exit 1
mutate "$w/$MODES" 's/\@Suite\("DockMode"\)/\@Suite(\n    "DockMode",\n    .enabled(if: false))/'
check "a conditional suite trait on a line of its own" 1 "$w" "disabling or conditional trait"

w="$(new_tree chrome-trait)" || exit 1
mutate "$w/$CHROME" 's/\@Test\(("record a-e: [^"]*")\)/\@Test($1, .disabled())/'
check "a .disabled trait on an unpinned render test" 1 "$w" "disabling or conditional trait"

# The render tests extend MediaImageLoaderTests; that suite's traits are theirs.
w="$(new_tree owner-suite-disabled)" || exit 1
mutate "$w/$OWNER" 's/\@Suite\("MediaImageLoader", \.serialized, \.mediaGlobals\)/\@Suite("MediaImageLoader", .serialized, .mediaGlobals, .disabled())/'
check "a .disabled trait on the suite the render tests extend" 1 "$w" "changed its @Suite line"

w="$(new_tree owner-suite-multiline)" || exit 1
mutate "$w/$OWNER" 's/\@Suite\("MediaImageLoader", \.serialized, \.mediaGlobals\)/\@Suite(\n    "MediaImageLoader", .serialized, .mediaGlobals,\n    .enabled(if: false))/'
check "a conditional trait on that suite, on lines of its own" 1 "$w" "changed its @Suite line"

w="$(new_tree owner-missing)" || exit 1
rm "$w/$OWNER" || exit 1
check "the suite the render tests extend missing" 2 "$w" "does not exist"

# --- unusable inputs: refused, never passed ---
w="$(new_tree missing-file)" || exit 1
rm "$w/$MODES" || exit 1
check "a pinned test file missing" 2 "$w" "does not exist"

w="$(new_tree unreadable)" || exit 1
chmod 000 "$w/$FEATURES/Dock.swift" || exit 1
if [ -r "$w/$FEATURES/Dock.swift" ]; then
  echo "skip an unreadable host (this user reads a mode-000 file, so the case cannot be built)"
else
  check "an unreadable host" 2 "$w"
fi

# Any source the rule could not read is a refusal, not a file with nothing in it: an unread file
# outside the three pinned ones would otherwise count as a clean one for every 0-wanted check.
w="$(new_tree unreadable-other)" || exit 1
chmod 000 "$w/$FEATURES/TimelineView.swift" || exit 1
if [ -r "$w/$FEATURES/TimelineView.swift" ]; then
  echo "skip an unreadable source (this user reads a mode-000 file, so the case cannot be built)"
else
  check "an unreadable source that is not a pinned file" 2 "$w" "stripping the comments"
fi

check "not a directory" 2 "$tmp/no-such-tree"

# --- the repository itself, alone and twice at once ---
check "the real repository tree" 0 "$repo_root"
cases=$((cases + 1))
# Runs at once, as two lanes' selftests can be on one controller: each must keep its own scratch.
pids=()
for n in 1 2 3 4 5 6; do
  "$RULE" "$repo_root" > "$tmp/concurrent-$n.out" 2>&1 &
  pids+=("$!")
done
concurrent_rcs=""
concurrent_bad=0
for pid in "${pids[@]}"; do
  wait "$pid"
  status=$?
  concurrent_rcs="$concurrent_rcs $status"
  [ "$status" -eq 0 ] || concurrent_bad=1
done
if [ "$concurrent_bad" -eq 0 ]; then
  echo "ok   six runs at once on the real tree -> exits$concurrent_rcs"
else
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
  echo "FAIL six runs at once on the real tree: exits$concurrent_rcs"
  for n in 1 2 3 4 5 6; do grep 'MAINBAR FAIL' "$tmp/concurrent-$n.out" | sed "s/^/     $n| /"; done
fi

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no tree was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no tree was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate main-bar freeze rule: $((cases - fails)) of $cases trees as expected"
[ "$fails" -eq 0 ] || { echo "MAINBAR-TEST FAIL: $fails tree(s) misjudged"; exit "$first_fail"; }
echo "MAINBAR-TEST ok"
