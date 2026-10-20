#!/usr/bin/env bash
#
# The release-version authority: the numbers in project.yml advance past the latest v* tag.
#
# Runs on the CONTROLLER (bin/mac-gate.sh copies it into the run's private copy, GATE_RUN_HELPERS),
# because the tags live in the checkout and the mirrored tree on the build host carries no .git.
# The latest v* tag reachable from HEAD records what shipped (its annotation names the build:
# "X.Y.Z (build N): ..."); the numbers in project.yml must ADVANCE past it — the marketing version
# never below the tagged one, the build strictly greater always. A forgotten bump is caught before
# a wasted archive. No v* tag yet is the bootstrap case and passes with a named line.
# Ritual: docs/RELEASING.md.
#
# Usage: release-version-rule.sh <repo-root>
# Exit:  0 = passed; stdout is the gate's `release     :` line
#        1 = refused; stdout is the reason, which the gate refuses with
#        2 = the inputs were not usable (no such tree, version keys unreadable); stdout says which
set -u
root="${1:-}"
[ -n "$root" ] && [ -f "$root/project.yml" ] || {
  echo "release check: no project.yml under '${root}'"
  exit 2
}

version_at_least() { # $1 >= $2, dotted numerics
  # Split on OWN lines: an IFS set in the same `local` statement does not govern that
  # statement's word-splitting, and the perturbation run caught the strings comparing whole.
  local IFS=. i
  local -a a b
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for i in 0 1 2; do
    [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ] && return 0
    [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ] && return 1
  done
  return 0
}

release_tag="$(git -C "$root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [ -z "$release_tag" ]; then
  echo "release     : no v* tag yet — bootstrap, nothing to advance past"
  exit 0
fi
tagged_version="${release_tag#v}"
tagged_build="$(git -C "$root" tag -l "$release_tag" --format='%(contents:subject)' \
  | sed -n 's/.*build \([0-9][0-9]*\).*/\1/p')"
yml_version="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$root/project.yml" | head -1)"
yml_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$root/project.yml" | head -1)"
if [ -z "$yml_version" ] || [ -z "$yml_build" ]; then
  echo "release check: could not read version keys from project.yml"
  exit 2
fi
# A project.yml byte-identical to the tag's is no release candidate: it is the work between a tag
# and the next cut, and its build number cannot advance yet, because the cut assigns it
# (bin/testflight-cut.sh --resolve-build, then bin/bump-build.sh). Judged on the WORKING TREE file,
# the one the gate rsyncs. A tag without the file, or any other `git show` failure, compares as
# changed (pipefail), so it meets the strict checks below. What stops a spent number from
# shipping twice is the cut's own proof and claim (fastlane prove_unused, cut-markers.sh claim).
set -o pipefail
if git -C "$root" show "$release_tag:project.yml" 2>/dev/null | cmp -s - "$root/project.yml"; then
  echo "release     : $yml_version (build $yml_build) unchanged since $release_tag — project.yml is byte-identical to the tag's, not a release candidate"
  exit 0
fi
set +o pipefail
if ! version_at_least "$yml_version" "$tagged_version"; then
  echo "release check: MARKETING_VERSION $yml_version is below the shipped tag $release_tag"
  exit 1
fi
if [ -n "$tagged_build" ] && [ "$yml_build" -le "$tagged_build" ]; then
  echo "release check: build $yml_build does not advance past the shipped build $tagged_build ($release_tag)"
  exit 1
fi
echo "release     : $yml_version (build $yml_build) advances past $release_tag (build ${tagged_build:-?})"
exit 0
