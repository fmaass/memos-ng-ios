#!/usr/bin/env bash
#
# sync-openapi.sh — vendor the memos-ng contract artefacts at ONE commit.
#
# The iOS client is generated from memos-ng's `openapi.json`, and its Markdown renderer is held to
# memos-ng's `fixtures/markdown-parity.json`. Both describe the same server at the same moment, so
# both are fetched from the SAME commit and the commit is recorded in OPENAPI_SOURCE. Vendoring
# them independently is how a client drifts from its server without anyone noticing.
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
provenance="$repo_root/Packages/MemosAPI/OPENAPI_SOURCE"
mkdir -p "$(dirname "$api_dest")" "$(dirname "$fixture_dest")" "$(dirname "$schema_doc_dest")" \
  || die "cannot create the destination directories"

fetch() {
  local path="$1" dest="$2"
  git -C "$src" show "$sha:$path" > "$dest.tmp" || { rm -f "$dest.tmp"; die "cannot read $path at $sha" 1; }
  [ -s "$dest.tmp" ] || { rm -f "$dest.tmp"; die "$path is empty at $sha" 1; }
  mv "$dest.tmp" "$dest"
  printf '  %-28s <- %s\n' "$(basename "$dest")" "$path"
}

echo "syncing from $src at $sha"
fetch openapi.json "$api_dest.upstream"
fetch fixtures/markdown-parity.json "$fixture_dest"
fetch fixtures/markdown-parity.schema.md "$schema_doc_dest"

# See scripts/normalize-openapi.py: without this the generator drops every nullable property,
# `nextCursor` included, and pagination cannot be written at all. The counts are recorded below so
# the day memos-ng emits OAS 3.1 type arrays itself is visible rather than assumed.
normalized="$(python3 "$repo_root/scripts/normalize-openapi.py" "$api_dest.upstream" "$api_dest")" \
  || die "normalising openapi.json failed" 1
rm -f "$api_dest.upstream"
echo "$normalized" | sed 's/^/  /'

{
  echo "# Provenance of the memos-ng artefacts vendored into this package."
  echo "# Written by scripts/sync-openapi.sh — do not edit by hand."
  echo "repo=memos-ng"
  echo "commit=$sha"
  echo "subject=$(git -C "$src" log -1 --pretty=%s "$sha")"
  echo "committed=$(git -C "$src" log -1 --pretty=%cI "$sha")"
  echo "files=Sources/MemosAPI/openapi.json Sources/MemosAPI/Fixtures/markdown-parity.json docs/markdown-parity.schema.md"
  echo "$normalized"
} > "$provenance" || die "cannot write $provenance" 1

echo "recorded $provenance:"
sed 's/^/  /' "$provenance"
