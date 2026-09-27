#!/bin/bash
# After the upload: read App Store Connect back for <version> (<build>).
# Remote-stdin: scripts/release/run-cut-3.sh <version> <build> ships it to the build host.
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
fastlane verify_attach "version:$version" "build:$build" </dev/null; rc=$?
echo "verify_rc=$rc"
exit $rc
