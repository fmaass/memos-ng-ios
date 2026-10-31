#!/usr/bin/env bash
#
# scripts/sync-openapi.sh, checked against throwaway memos-ng and iOS repositories this script
# builds for the purpose.
#
# ADR-0004 lets the app vendor only a TAGGED server release of its own major: the tag is the one
# place the release is written down (the document's info.version reads "dev"), and a contract from
# another major is a contract this app does not speak. A refusal nobody plants is a refusal nobody
# sees stop working, so each one is planted here — an untagged commit, a tag of another major, two
# release tags on one commit — and a same-major tag is accepted as the positive control, with what
# it recorded read back. Every refusal must happen before anything is fetched, so each refused run
# also has to leave the destination empty. A same-major release that predates the guest document
# (openapi-guest.json) is refused the same way, and the accepted run must have vendored that
# document byte for byte and named it in OPENAPI_SOURCE's files= list.
#
# Nothing here writes into the repository: both repositories land in a temporary tree, removed on
# exit. The real script runs by its absolute path with the working directory inside the throwaway
# iOS repository, because it derives every destination from there.
#
# Run it directly (`tests/gate/sync-openapi-tag-test.sh`) or let the gate run it: it is picked up by
# the controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
SCRIPT="$repo_root/scripts/sync-openapi.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing or not executable"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-sync-openapi-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

# The throwaway repositories must not depend on whoever runs this: no identity, no signing, no hooks.
export GIT_AUTHOR_NAME=gate GIT_AUTHOR_EMAIL=gate@example.invalid
export GIT_COMMITTER_NAME=gate GIT_COMMITTER_EMAIL=gate@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c commit.gpgsign=false -c tag.gpgSign=false -c init.defaultBranch=main "$@"; }

fails=0
cases=0
first_fail=0
pass_seen=0

fail() { # $1 message, [$2 exit code to report]
  fails=$((fails + 1))
  if [ "$first_fail" -eq 0 ]; then
    if [ "${2:-1}" -ne 0 ]; then first_fail="${2:-1}"; else first_fail=1; fi
  fi
  echo "FAIL $1"
}

# --- the throwaway memos-ng -----------------------------------------------------------------------
# Every file the script fetches, non-empty, so a refusal can only come from the tag check.
src="$tmp/memos-ng"
mkdir -p "$src/fixtures/auto-memo-date" || { echo "FAIL: cannot build $src"; exit 1; }
g init -q "$src" || { echo "FAIL: cannot init $src"; exit 1; }
commit() { # $1 a marker that makes this commit's documents its own; prints the full SHA
  printf '{"openapi":"3.1.0","marker":"%s"}\n' "$1" > "$src/openapi.json"
  # The guest document is vendored verbatim, so its bytes are deliberately not canonical JSON (no
  # trailing newline, odd spacing): a script that re-serialised it would fail the cmp below.
  printf '{ "openapi" : "3.1.0",  "guest-marker":"%s"}' "$1" > "$src/openapi-guest.json"
  printf '{"cases":[]}\n' > "$src/fixtures/markdown-parity.json"
  printf '# schema\n' > "$src/fixtures/markdown-parity.schema.md"
  printf '{"captures":[]}\n' > "$src/fixtures/auto-memo-date.json"
  printf 'binary-ish\n' > "$src/fixtures/auto-memo-date/one.bin"
  g -C "$src" add -A >/dev/null && g -C "$src" commit -q -m "commit $1" >/dev/null || return 1
  g -C "$src" rev-parse HEAD
}
untagged="$(commit untagged)" || { echo "FAIL: cannot commit"; exit 1; }
g -C "$src" tag release-2 "$untagged" || exit 1
other_major="$(commit other-major)" || exit 1
g -C "$src" tag v1.9.0 "$other_major" || exit 1
look_alike="$(commit look-alike)" || exit 1
g -C "$src" tag v20.0.0 "$look_alike" || exit 1
two_tags="$(commit two-tags)" || exit 1
g -C "$src" tag v2.0.1 "$two_tags" || exit 1
g -C "$src" tag -a -m "second" v2.0.2 "$two_tags" || exit 1
same_major="$(commit same-major)" || exit 1
g -C "$src" tag -a -m "Release 2.1.0" v2.1.0 "$same_major" || exit 1
# A release of the right major from before the guest document existed (memos-ng v2.9.0 and older).
commit pre-guest >/dev/null || exit 1
g -C "$src" rm -q openapi-guest.json >/dev/null && g -C "$src" commit -q -m "pre-guest" >/dev/null || exit 1
pre_guest="$(g -C "$src" rev-parse HEAD)" || exit 1
g -C "$src" tag -a -m "Release 2.0.9" v2.0.9 "$pre_guest" || exit 1

# --- a throwaway iOS tree -------------------------------------------------------------------------
# A git repository (the script finds its root with rev-parse) holding a project.yml that declares
# the marketing version twice, the way the real one does for the app and the share extension.
new_tree() { # $1 name, $2 marketing version; prints the tree
  local work="$tmp/$1"
  mkdir -p "$work" || return 1
  g init -q "$work" || return 1
  # The commented-out line is a literal a loose read would count: a second, different value.
  cat > "$work/project.yml" <<YML
# MARKETING_VERSION: "9.9.9"
targets:
  MemosNG:
    settings:
      base:
        MARKETING_VERSION: "$2"
  MemosShare:
    settings:
      base:
        MARKETING_VERSION: "$2"
YML
  printf '%s' "$work"
}

api_rel="Packages/MemosAPI/Sources/MemosAPI/openapi.json"
guest_rel="Packages/MemosAPI/Sources/MemosAPI/Fixtures/openapi-guest.json"
provenance_rel="Packages/MemosAPI/OPENAPI_SOURCE"
release_rel="Packages/MemosAPI/Sources/MemosAPI/VendoredRelease.swift"

run() { # $1 tree, $2 sha; sets out and rc
  out="$(cd "$1" && MEMOS_NG_REPO="$src" "$SCRIPT" "$2" 2>&1)"
  rc=$?
}

refused() { # $1 label, $2 tree, $3 sha, $4.. substrings the refusal must name
  local label="$1" tree="$2" sha="$3" needle
  shift 3
  cases=$((cases + 1))
  run "$tree" "$sha"
  if [ "$rc" -ne 2 ]; then
    fail "$label: expected exit 2, got $rc" "$rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  for needle in "$@"; do
    if ! printf '%s\n' "$out" | grep -qF -e "$needle"; then
      fail "$label: exit 2 was right, but the refusal does not name '$needle'"
      printf '%s\n' "$out" | sed 's/^/     | /'
      return
    fi
  done
  # A refusal after a fetch would have left the tree half re-vendored.
  local leftover
  for leftover in "$api_rel" "$guest_rel" "$provenance_rel" "$release_rel"; do
    if [ -e "$tree/$leftover" ]; then
      fail "$label: refused, but $leftover was written first"
      return
    fi
  done
  echo "ok   $label -> exit 2"
}

t="$(new_tree refusals 2.0.0)" || { echo "FAIL: cannot build a tree"; exit 1; }
refused "an untagged commit (its only tag, release-2, is not v*)" "$t" "$untagged" "$untagged" "tag"
refused "a tag of another major (v1.9.0 for app 2.0.0)" "$t" "$other_major" "v1.9.0" "2.0.0" "major 1" "major 2"
refused "a tag whose major only starts like the app's (v20.0.0 for app 2.0.0)" "$t" "$look_alike" "v20.0.0" "major 20" "major 2"
refused "two release tags on one commit" "$t" "$two_tags" "v2.0.1" "v2.0.2"
refused "a release without openapi-guest.json (v2.0.9)" "$t" "$pre_guest" "openapi-guest.json" "v2.0.9"

# The same tag against a project.yml that cannot say which major the app is: two distinct values.
t_split="$(new_tree split 2.0.0)" || exit 1
# (python rather than sed: GNU and BSD sed disagree on replacing only the first match in place.)
python3 - "$t_split/project.yml" <<'PY' || { echo "FAIL: cannot build the split tree"; exit 1; }
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(
    text.replace('MARKETING_VERSION: "2.0.0"', 'MARKETING_VERSION: "3.0.0"', 1))
PY
refused "a project.yml with two distinct marketing versions" "$t_split" "$same_major" "more than one MARKETING_VERSION"

# --- the positive control -------------------------------------------------------------------------
t_ok="$(new_tree accepted 2.0.0)" || exit 1
cases=$((cases + 1))
run "$t_ok" "$same_major"
if [ "$rc" -ne 0 ]; then
  fail "a same-major tag (v2.1.0 for app 2.0.0): expected exit 0, got $rc" "$rc"
  printf '%s\n' "$out" | sed 's/^/     | /'
else
  ok=1
  miss() { echo "     $1"; ok=0; }
  prov="$t_ok/$provenance_rel"
  rel="$t_ok/$release_rel"
  # tag= must sit on the line right after commit=, so a reader of the record sees the pair together.
  after_commit="$(awk 'found { print; exit } /^commit=/ { found = 1 }' "$prov" 2>/dev/null)"
  [ "$(grep -c '^commit=' "$prov" 2>/dev/null)" = 1 ] && grep -qx "commit=$same_major" "$prov" \
    || { miss "accepted: OPENAPI_SOURCE does not record commit=$same_major once"; ok=0; }
  [ "$after_commit" = "tag=v2.1.0" ] \
    || { miss "accepted: the line after commit= is '$after_commit', not tag=v2.1.0"; ok=0; }
  grep -qF 'public static let tag = "v2.1.0"' "$rel" 2>/dev/null \
    || { miss "accepted: VendoredRelease.swift does not hold tag = \"v2.1.0\""; ok=0; }
  grep -qF 'public static let apiMajor = 2' "$rel" 2>/dev/null \
    || { miss "accepted: VendoredRelease.swift does not hold apiMajor = 2"; ok=0; }
  grep -qF '"marker":"same-major"' "$t_ok/$api_rel" 2>/dev/null \
    || { miss "accepted: openapi.json is not the tagged commit's"; ok=0; }
  cmp -s <(g -C "$src" show "$same_major:openapi-guest.json") "$t_ok/$guest_rel" \
    || { miss "accepted: $guest_rel is not byte-identical to the tagged commit's openapi-guest.json"; ok=0; }
  grep '^files=' "$prov" 2>/dev/null | tr ' =' '\n\n' | grep -qx 'Sources/MemosAPI/Fixtures/openapi-guest.json' \
    || { miss "accepted: OPENAPI_SOURCE files= does not name the guest document"; ok=0; }
  if [ "$ok" -ne 1 ]; then
    fail "a same-major tag (v2.1.0 for app 2.0.0): exit 0, but the record is wrong (above)"
  else
    pass_seen=1
    echo "ok   a same-major tag (v2.1.0 for app 2.0.0) -> exit 0, tag=, VendoredRelease.swift and the verbatim guest document recorded"
  fi
fi

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: a script that refused everything would pass every
# expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no commit was accepted — a script that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate sync-openapi tag rule: $((cases - fails)) of $cases cases as expected"
[ "$fails" -eq 0 ] || { echo "SYNC-OPENAPI-TAG-TEST FAIL: $fails case(s) misjudged"; exit "$first_fail"; }
echo "SYNC-OPENAPI-TAG-TEST ok"
