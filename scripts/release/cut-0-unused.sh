#!/bin/bash
# Before the one upload: App Store Connect must NOT already hold <version> (<build>).
# The read-back lane answers a build that does not exist with a fixed sentence and a non-zero
# exit at once; that sentence is the PASS here. Anything else (a build found, an API error) stops.
# Its proof marker (~/.memosng-cut/unused-<version>-<build>) is the only thing cut-2 uploads on, so an
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
out=$(fastlane verify_attach "version:$version" "build:$build" </dev/null 2>&1); rc=$?
echo "$out" | grep -E 'ASC read-back|no such build|VALID|IN_BETA' | tail -5
echo "verify_rc=$rc"
if [ $rc -ne 0 ] && echo "$out" | grep -qF "ASC read-back FAILED for $version ($build): App Store Connect has no such build"; then
  mkdir -p ~/.memosng-cut && printf '%s %s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(git rev-parse HEAD)" > ~/.memosng-cut/"unused-$version-$build" || { echo "NOT PROVEN UNUSED — cannot write the proof marker"; exit 20; }
  echo "UNUSED: $version ($build) is not in App Store Connect"; exit 0
fi
echo "NOT PROVEN UNUSED — stop"; exit 20
