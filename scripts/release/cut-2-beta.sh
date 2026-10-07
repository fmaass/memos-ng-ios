#!/bin/bash
# The one upload: fastlane beta archives, uploads and reads App Store Connect back itself.
# It uploads only on cut-0's proof marker for its exact pair: `fastlane beta` claims that marker first
# (scripts/release/cut-markers.sh, one lock shared with the lane-side cut), so a re-run, a retried
# wrapper or an overlapping cut-2 finds nothing to spend and cannot consume a second build number.
# Remote-stdin: scripts/release/run-cut-2.sh <version> <build> ships it to the build host.
[ "$(hostname -s)" = merkur ] || { echo "REFUSED: cut scripts run on the build host merkur, not $(hostname -s)"; exit 2; }
set -u
version="${1:-}" build="${2:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || { echo "REFUSED: needs <version> <build> as in 'bash -s -- 2.0.0 25', got '$version' '$build'"; exit 2; }
cd ~/projects/memos-ng-ios || exit 10
test -z "$(git status --porcelain)" || { echo "CLONE DIRTY"; git status --short | head; exit 11; }
# The volume is shared with another project's builds and was at 3 GiB this morning. A build that
# fills it fails both; stopping here spends nothing (no archive, no upload, no build number).
avail=$(df -g / | awk 'NR==2 {print $4}'); echo "avail_GiB=$avail"
[ "$avail" -ge 3 ] || { echo "DISK FLOOR: $avail GiB free, need 3"; exit 14; }
# The app target's pair is the first occurrence; the anchor keeps a comment naming a key from counting.
tree_version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
tree_build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
[ "$tree_version" = "$version" ] && [ "$tree_build" = "$build" ] || { echo "REFUSED: asked for $version ($build) but project.yml says ${tree_version:-nothing} (${tree_build:-nothing})"; exit 2; }
set -a; source ~/.config/memosng-ci.env; set +a
export PATH=/opt/homebrew/bin:$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
echo "beta start $(date '+%H:%M %Z') at $(git log --oneline -1)"
fastlane beta </dev/null; rc=$?
echo "beta end $(date '+%H:%M %Z') fastlane_rc=$rc"
exit $rc
