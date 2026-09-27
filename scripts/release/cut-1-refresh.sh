#!/bin/bash
# Refresh the build host's hands-on clone to origin/main and regenerate the project.
# Remote-stdin: scripts/release/run-cut-1.sh <version> <build> ships it to the build host.
[ "$(hostname -s)" = merkur ] || { echo "REFUSED: cut scripts run on the build host merkur, not $(hostname -s)"; exit 2; }
set -u
version="${1:-}" build="${2:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || { echo "REFUSED: needs <version> <build> as in 'bash -s -- 2.0.0 25', got '$version' '$build'"; exit 2; }
cd ~/projects/memos-ng-ios || exit 10
test -z "$(git status --porcelain)" || { echo "CLONE DIRTY"; git status --short | head; exit 11; }
test "$(git branch --show-current)" = main || { echo "CLONE NOT ON main"; exit 12; }
git pull --ff-only </dev/null || exit 13
git log --oneline -1
grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' project.yml
# Judged after the pull: the tree the train builds is the one that must agree.
# The app target's pair is the first occurrence; the anchor keeps a comment naming a key from counting.
tree_version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
tree_build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
[ "$tree_version" = "$version" ] && [ "$tree_build" = "$build" ] || { echo "REFUSED: asked for $version ($build) but project.yml says ${tree_version:-nothing} (${tree_build:-nothing})"; exit 2; }
export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./bin/generate.sh </dev/null; generate_rc=$?; echo "generate_rc=$generate_rc"
[ "$generate_rc" -eq 0 ] || exit 14
df -g / | awk 'NR==2 {print "avail_GiB=" $4}'
