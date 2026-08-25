#!/usr/bin/env bash
#
# The other half of the gate's integrity check: what scripts/read-warnings-flag.py accepts as
# proof that MemosFeatures was compiled with its warnings fatal.
#
# That reader is the only thing standing between "the build exited 0" and "the warnings were
# fatal", and the two are not the same: with the manifest declaration commented out the build
# still succeeds and merely prints its warnings. A reader that accepts the flag's TEXT anywhere
# under the target's task header can be satisfied by a source file that prints it —
# `#warning("-warnings-as-errors")` — which is the case below that must stay red.
#
# Synthetic logs, because the real one takes a ten-minute build to produce and cannot be made to
# hold the shapes worth refusing.
#
# Exit: 0 = every log classified as expected; 1 = at least one was not.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
READER="$repo_root/scripts/read-warnings-flag.py"
[ -f "$READER" ] || { echo "FAIL: $READER is missing"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-warnflag-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SRC="/gate/Packages/MemosFeatures/Sources/MemosFeatures"
fails=0
cases=0
pass_seen=0

check() { # $1 label, $2 expected rc, $3 log file
  local label="$1" expected="$2" log="$3" out rc
  cases=$((cases + 1))
  out="$(/usr/bin/env python3 "$READER" "$log" 2>&1)"
  rc=$?
  if [ "$rc" = "$expected" ]; then
    [ "$expected" != 0 ] || pass_seen=1
    echo "ok   $label -> exit $rc"
  else
    fails=$((fails + 1))
    echo "FAIL $label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# A real compile of the library module, with the flag where the compiler was actually asked for it.
cat > "$tmp/real.log" <<EOF
SwiftDriver MemosFeatures normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MemosFeatures' from project 'MemosFeatures')
    cd /gate/Packages/MemosFeatures/.swiftpm/xcode
    builtin-SwiftDriver -- $SWIFTC -module-name MemosFeatures -Onone -warnings-as-errors @/work/response.resp
** BUILD SUCCEEDED **
EOF
check "a library-module invocation carrying the flag" 0 "$tmp/real.log"

# The bypass: the declaration is gone, so the invocation does NOT carry the flag — but a source
# file prints its text, and the diagnostic lands under this target's own task header.
cat > "$tmp/bypass.log" <<EOF
SwiftDriver MemosFeatures normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MemosFeatures' from project 'MemosFeatures')
    cd /gate/Packages/MemosFeatures/.swiftpm/xcode
    builtin-SwiftDriver -- $SWIFTC -module-name MemosFeatures -Onone @/work/response.resp
SwiftCompile normal arm64 Compiling\\ Bypass.swift $SRC/Bypass.swift (in target 'MemosFeatures' from project 'MemosFeatures')
$SRC/Bypass.swift:3:2: warning: -warnings-as-errors
** BUILD SUCCEEDED **
EOF
check "a diagnostic printing the flag's text" 1 "$tmp/bypass.log"

# The same trick, wearing the whole invocation: everything a line needs to look like proof, said
# by the compiler instead of to it.
cat > "$tmp/bypass-full.log" <<EOF
SwiftDriver MemosFeatures normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MemosFeatures' from project 'MemosFeatures')
    builtin-SwiftDriver -- $SWIFTC -module-name MemosFeatures -Onone @/work/response.resp
$SRC/Bypass.swift:3:2: warning: $SWIFTC -module-name MemosFeatures -warnings-as-errors
** BUILD SUCCEEDED **
EOF
check "a diagnostic quoting a whole invocation" 1 "$tmp/bypass-full.log"

# The test bundle is not the library. A flag on MemosFeaturesTests says nothing about the module
# that ships.
cat > "$tmp/tests-only.log" <<EOF
SwiftDriver MemosFeaturesTests normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MemosFeaturesTests' from project 'MemosFeatures')
    builtin-SwiftDriver -- $SWIFTC -module-name MemosFeaturesTests -warnings-as-errors @/work/t.resp
SwiftDriver MemosFeatures normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MemosFeatures' from project 'MemosFeatures')
    builtin-SwiftDriver -- $SWIFTC -module-name MemosFeatures -Onone @/work/response.resp
** BUILD SUCCEEDED **
EOF
check "the flag on the test target only" 1 "$tmp/tests-only.log"

# A log that never mentions the target proves nothing — silence is not a pass.
cat > "$tmp/silent.log" <<EOF
SwiftDriver MemosCore normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MemosCore' from project 'MemosCore')
    builtin-SwiftDriver -- $SWIFTC -module-name MemosCore -warnings-as-errors @/work/core.resp
** BUILD SUCCEEDED **
EOF
check "a log with no MemosFeatures task" 1 "$tmp/silent.log"

# The target was there, nothing compiled: an incremental build that did no work cannot be read as
# a build that did it with the flag.
cat > "$tmp/no-compile.log" <<EOF
SwiftDriver MemosFeatures normal arm64 com.apple.xcode.tools.swift.compiler (in target 'MemosFeatures' from project 'MemosFeatures')
    (skipped: up to date)
** BUILD SUCCEEDED **
EOF
check "a task with no compiler invocation" 1 "$tmp/no-compile.log"

if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no log was accepted — a reader that refuses everything would pass this suite"
  fails=$((fails + 1))
fi

echo "gate warnings-flag reader: $((cases - fails)) of $cases logs as expected"
[ "$fails" -eq 0 ] || { echo "WARNFLAG-TEST FAIL: $fails log(s) misread"; exit 1; }
echo "WARNFLAG-TEST ok"
