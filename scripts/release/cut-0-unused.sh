#!/bin/bash
# Before the one upload: App Store Connect must NOT already hold <version> (<build>).
# fastlane prove_unused answers 0 only when App Store Connect has no such build AND the proof marker
# (~/.memosng-cut/unused-<version>-<build>) was written; anything else (a build found, an API error,
# a spent claim of the pair) stops. That marker is the only thing `fastlane beta` uploads on, so an
# upload can never spend a build number nobody proved unused, and one proof buys exactly one upload.
# Remote-stdin: scripts/release/run-cut-0.sh <version> <build> ships it to the build host.
[ "$(hostname -s)" = merkur ] || { echo "REFUSED: cut scripts run on the build host merkur, not $(hostname -s)"; exit 2; }
set -u
version="${1:-}" build="${2:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || { echo "REFUSED: needs <version> <build> as in 'bash -s -- 2.0.0 25', got '$version' '$build'"; exit 2; }
cd ~/projects/memos-ng-ios || exit 10
# The app target's pair is the first occurrence; the anchor keeps a comment naming a key from counting.
tree_version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
tree_build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
[ "$tree_version" = "$version" ] && [ "$tree_build" = "$build" ] || { echo "REFUSED: asked for $version ($build) but project.yml says ${tree_version:-nothing} (${tree_build:-nothing})"; exit 2; }
set -a; source ~/.config/memosng-ci.env; set +a
export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# The proof is the Fastfile's, shared with the lane-side cut: prove_unused reads App Store Connect
# back and, only on "no such build", writes the marker through scripts/release/cut-markers.sh.
out=$(fastlane prove_unused "version:$version" "build:$build" </dev/null 2>&1); rc=$?
echo "$out" | grep -E 'ASC read-back|no such build|NOT PROVEN|UNUSED|REFUSED|cut-markers' | tail -5
echo "prove_rc=$rc"
if [ $rc -eq 0 ]; then
  echo "UNUSED: $version ($build) is not in App Store Connect"; exit 0
fi
echo "NOT PROVEN UNUSED — stop"; exit 20
