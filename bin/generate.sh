#!/usr/bin/env bash
# Canonical project generation. XcodeGen (2.46) has no optional includes, so a missing
# per-machine signing.local.yml is stubbed with an empty spec that merges nothing.
# Real device signing: cp signing.local.yml.example signing.local.yml, fill in the team id.
#
# It also puts the committed dependency pins back. SwiftPM reads its resolved-versions file from
# INSIDE the project — MemosNG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm — and that
# project is generated, not committed, so on a fresh clone there is nothing to resolve against and
# every rebuild is free to pick up whatever versions are current. Pinning the five direct
# dependencies in project.yml would not have covered it: the app links thirteen packages, and the
# other eight are transitive and named in no manifest in this repo. So the whole resolved graph is
# tracked at the repo root and copied in here, before anything resolves.
#
# After a deliberate dependency change the pins have to be re-recorded: the gate leaves the file
# it resolved in .gate-artifacts/Package.resolved — copy that over Package.resolved and commit it.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f signing.local.yml ] || printf '{}\n' > signing.local.yml
xcodegen generate "$@"

PINS="Package.resolved"
PINS_IN_PROJECT="MemosNG.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ ! -f "$PINS" ]; then
  echo "PINS FAIL: $PINS is missing. It is a tracked file; without it SwiftPM resolves every"
  echo "PINS FAIL: dependency afresh and this build is not the one the repo ships."
  echo "PINS FAIL: restore it with: git checkout -- $PINS"
  exit 1
fi
[ -d MemosNG.xcodeproj ] || {
  echo "PINS FAIL: xcodegen produced no MemosNG.xcodeproj — there is nothing to put the pins in"
  exit 1
}
mkdir -p "$(dirname "$PINS_IN_PROJECT")"
cp "$PINS" "$PINS_IN_PROJECT"
echo "pins: restored $(grep -c '"identity"' "$PINS" || true) pinned packages into $PINS_IN_PROJECT"
