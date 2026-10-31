#!/usr/bin/env bash
#
# sync-openapi.sh — vendor the memos-ng contract artefacts at ONE commit.
#
# The iOS client is generated from memos-ng's `openapi.json`; its Markdown renderer is held to
# memos-ng's `fixtures/markdown-parity.json`; and its Auto memo date is held to
# `fixtures/auto-memo-date.json` and the binaries beside it. All of them describe the same server
# and the same rules at the same moment, so all of them are fetched from the SAME commit and the
# commit is recorded in OPENAPI_SOURCE. Vendoring them independently is how a client drifts from
# its server without anyone noticing.
#
# The guest door's `openapi-guest.json` is vendored from the same commit, VERBATIM, but it is not
# the generator's input: it lands in Fixtures/, which the MemosAPI target excludes, so no guest
# client is generated from it. The guest lane is the hand-rolled `GuestWire` mirror family in
# MemosOutbox, licensed by that package's dependency rule (OutboxWire.swift's header), and this
# document is what its contract test in MemosOutboxTests pins those mirrors against.
#
# The auto-memo-date binaries are vendored by listing the directory AT THE COMMIT rather than from
# a list written here: a fixture added upstream that this script did not know about would
# otherwise be silently absent, and the sha256 test would never miss it — it only checks the files
# it was given.
#
# Only a tagged memos-ng release is vendored, and only one of the app's own major (ADR-0004: the
# app and the server version independently inside a shared API major). The tag is the one place the
# release is written down — the document's info.version reads "dev" — so it is recorded beside the
# commit in OPENAPI_SOURCE and written into VendoredRelease.swift, which the sign-in handshake
# compares with the major the server reports on /health.
#
# Usage:
#   scripts/sync-openapi.sh <memos-ng-full-sha>   (the commit must carry exactly one v<major>.* tag)
#
# Environment:
#   MEMOS_NG_REPO  path to a memos-ng clone that contains the commit (default: ../memos-ng)
#
# Exit codes: 2 = refusal (bad arguments, unusable repo, unknown commit, no single release tag, a
# tag of another major); 1 = a fetch failed.

set -uo pipefail

die() { printf 'sync-openapi: %s\n' "$1" >&2; exit "${2:-2}"; }

sha="${1:-}"
[ -n "$sha" ] || die "usage: scripts/sync-openapi.sh <memos-ng-full-sha>"
# A short SHA is ambiguous and can start matching a different commit as the repo grows; the
# provenance record is only worth keeping if it is exact.
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "expected a full 40-character commit SHA, got '$sha'"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git working tree"
src="${MEMOS_NG_REPO:-$repo_root/../memos-ng}"
[ -d "$src" ] || die "no memos-ng clone at $src (set MEMOS_NG_REPO)"
git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "$src is not a git repository"
git -C "$src" cat-file -e "$sha^{commit}" 2>/dev/null || die "commit $sha is not in $src (fetch it first)"

# The app's version is read the way the gate's release check reads it: every MARKETING_VERSION
# declaration in project.yml, refused unless they all name one value. A first-match read would let
# the app and the share extension disagree and still pick a major.
read_marketing_version() {
  python3 - "$1" <<'PY'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError as error:
    sys.stderr.write("cannot read %s: %s\n" % (sys.argv[1], error))
    sys.exit(1)
values = set(re.findall(r'^[ \t]*MARKETING_VERSION:[ \t]*"?([^"\s#]+)"?[ \t]*(?:#.*)?$', text, re.M))
if not values:
    sys.stderr.write("project.yml declares no MARKETING_VERSION\n")
    sys.exit(1)
if len(values) != 1:
    sys.stderr.write("project.yml declares more than one MARKETING_VERSION: %s\n" % sorted(values))
    sys.exit(1)
print(values.pop())
PY
}

# Refused before anything is fetched, so a refusal never leaves the tree half re-vendored. A tag
# that does not start v<digit> (release-2, nightly) is no release tag at all.
tag=$(git -C "$src" tag --points-at "$sha" --list 'v[0-9]*') || die "cannot list the tags on $sha in $src"
[ -n "$tag" ] || die "commit $sha carries no v<major>.* release tag — only a tagged memos-ng release is vendored"
[ "$(printf '%s\n' "$tag" | wc -l)" -eq 1 ] \
  || die "commit $sha carries more than one release tag: $(printf '%s' "$tag" | tr '\n' ' ')"
[[ "$tag" =~ ^v([0-9]+)(\..*)?$ ]] || die "release tag '$tag' on $sha is not v<major>[.<minor>...]"
tag_major=$((10#${BASH_REMATCH[1]})) || die "cannot read the major of '$tag'"
marketing_version=$(read_marketing_version "$repo_root/project.yml") \
  || die "cannot read the app's MARKETING_VERSION from $repo_root/project.yml"
[[ "$marketing_version" =~ ^([0-9]+)(\..*)?$ ]] \
  || die "the app's MARKETING_VERSION '$marketing_version' does not start with a major"
app_major=$((10#${BASH_REMATCH[1]})) || die "cannot read the major of '$marketing_version'"
[ "$tag_major" -eq "$app_major" ] \
  || die "release tag $tag is major $tag_major, but the app ($marketing_version) is major $app_major — vendor a release of the app's own major"

api_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/openapi.json"
schema_doc_dest="$repo_root/docs/markdown-parity.schema.md"
fixture_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/Fixtures/markdown-parity.json"
guest_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/Fixtures/openapi-guest.json"
capture_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/Fixtures/auto-memo-date.json"
capture_dir="$repo_root/Packages/MemosAPI/Sources/MemosAPI/Fixtures/auto-memo-date"
provenance="$repo_root/Packages/MemosAPI/OPENAPI_SOURCE"
release_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/VendoredRelease.swift"
mkdir -p "$(dirname "$api_dest")" "$(dirname "$fixture_dest")" "$(dirname "$schema_doc_dest")" \
  "$capture_dir" || die "cannot create the destination directories"

# Every fixed path is looked up at the commit before anything is written, so a release that predates
# one of them (openapi-guest.json first shipped in v2.10.0) is refused with the tree untouched rather
# than left half re-vendored by a fetch that fails midway.
for path in openapi.json openapi-guest.json fixtures/markdown-parity.json \
  fixtures/markdown-parity.schema.md fixtures/auto-memo-date.json; do
  git -C "$src" cat-file -e "$sha:$path" 2>/dev/null \
    || die "$path is not in $sha ($tag) — that release cannot be vendored whole"
done

fetch() {
  local path="$1" dest="$2"
  git -C "$src" show "$sha:$path" > "$dest.tmp" || { rm -f "$dest.tmp"; die "cannot read $path at $sha" 1; }
  [ -s "$dest.tmp" ] || { rm -f "$dest.tmp"; die "$path is empty at $sha" 1; }
  mv "$dest.tmp" "$dest"
  printf '  %-28s <- %s\n' "$(basename "$dest")" "$path"
}

echo "syncing from $src at $sha"
fetch openapi.json "$api_dest"
fetch openapi-guest.json "$guest_dest"
fetch fixtures/markdown-parity.json "$fixture_dest"
fetch fixtures/markdown-parity.schema.md "$schema_doc_dest"
fetch fixtures/auto-memo-date.json "$capture_dest"

# The binaries the artefact names, whatever they are at this commit. A file that vanished upstream
# is removed here too — a stale fixture left in the tree is a case the artefact no longer describes
# and the sha256 test no longer covers.
capture_files=$(git -C "$src" ls-tree --name-only "$sha" fixtures/auto-memo-date/) \
  || die "cannot list fixtures/auto-memo-date/ at $sha" 1
[ -n "$capture_files" ] || die "fixtures/auto-memo-date/ is empty at $sha" 1
find "$capture_dir" -type f -exec rm -f {} + || die "cannot empty $capture_dir" 1
vendored_binaries=""
while IFS= read -r path; do
  name="$(basename "$path")"
  fetch "$path" "$capture_dir/$name"
  vendored_binaries="$vendored_binaries Sources/MemosAPI/Fixtures/auto-memo-date/$name"
done <<EOF
$capture_files
EOF

{
  echo "# Provenance of the memos-ng artefacts vendored into this package."
  echo "# Written by scripts/sync-openapi.sh — do not edit by hand."
  echo "repo=memos-ng"
  echo "commit=$sha"
  echo "tag=$tag"
  echo "subject=$(git -C "$src" log -1 --pretty=%s "$sha")"
  echo "committed=$(git -C "$src" log -1 --pretty=%cI "$sha")"
  echo "files=Sources/MemosAPI/openapi.json Sources/MemosAPI/Fixtures/openapi-guest.json Sources/MemosAPI/Fixtures/markdown-parity.json docs/markdown-parity.schema.md Sources/MemosAPI/Fixtures/auto-memo-date.json$vendored_binaries"
} > "$provenance" || die "cannot write $provenance" 1

echo "recorded $provenance:"
sed 's/^/  /' "$provenance"

{
  echo "// Written by scripts/sync-openapi.sh — do not edit by hand."
  echo "public enum VendoredRelease {"
  echo "    public static let tag = \"$tag\""
  echo "    public static let apiMajor = $tag_major"
  echo "}"
} > "$release_dest.tmp" || { rm -f "$release_dest.tmp"; die "cannot write $release_dest" 1; }
mv "$release_dest.tmp" "$release_dest" || die "cannot move $release_dest into place" 1
echo "recorded $release_dest ($tag, apiMajor $tag_major)"
