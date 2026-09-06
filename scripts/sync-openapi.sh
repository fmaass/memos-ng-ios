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
# The auto-memo-date binaries are vendored by listing the directory AT THE COMMIT rather than from
# a list written here: a fixture added upstream that this script did not know about would
# otherwise be silently absent, and the sha256 test would never miss it — it only checks the files
# it was given.
#
# Usage:
#   scripts/sync-openapi.sh <memos-ng-full-sha>
#
# Environment:
#   MEMOS_NG_REPO  path to a memos-ng clone that contains the commit (default: ../memos-ng)
#
# Exit codes: 2 = refusal (bad arguments, unusable repo, unknown commit); 1 = a fetch failed.

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

api_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/openapi.json"
schema_doc_dest="$repo_root/docs/markdown-parity.schema.md"
fixture_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/Fixtures/markdown-parity.json"
capture_dest="$repo_root/Packages/MemosAPI/Sources/MemosAPI/Fixtures/auto-memo-date.json"
capture_dir="$repo_root/Packages/MemosAPI/Sources/MemosAPI/Fixtures/auto-memo-date"
provenance="$repo_root/Packages/MemosAPI/OPENAPI_SOURCE"
mkdir -p "$(dirname "$api_dest")" "$(dirname "$fixture_dest")" "$(dirname "$schema_doc_dest")" \
  "$capture_dir" || die "cannot create the destination directories"

fetch() {
  local path="$1" dest="$2"
  git -C "$src" show "$sha:$path" > "$dest.tmp" || { rm -f "$dest.tmp"; die "cannot read $path at $sha" 1; }
  [ -s "$dest.tmp" ] || { rm -f "$dest.tmp"; die "$path is empty at $sha" 1; }
  mv "$dest.tmp" "$dest"
  printf '  %-28s <- %s\n' "$(basename "$dest")" "$path"
}

echo "syncing from $src at $sha"
fetch openapi.json "$api_dest"
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
  echo "subject=$(git -C "$src" log -1 --pretty=%s "$sha")"
  echo "committed=$(git -C "$src" log -1 --pretty=%cI "$sha")"
  echo "files=Sources/MemosAPI/openapi.json Sources/MemosAPI/Fixtures/markdown-parity.json docs/markdown-parity.schema.md Sources/MemosAPI/Fixtures/auto-memo-date.json$vendored_binaries"
} > "$provenance" || die "cannot write $provenance" 1

echo "recorded $provenance:"
sed 's/^/  /' "$provenance"
