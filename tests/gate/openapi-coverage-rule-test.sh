#!/usr/bin/env bash
#
# The gate's openapi-coverage rule, checked against documents and configs this script builds for
# the purpose.
#
# `scripts/openapi-coverage-rule.sh` exists because the generator's filter makes omission the
# default: an operation the config does not name is not generated, and nothing goes red. A rule
# that guards a silent failure is itself a silent failure the day it stops biting — so the two
# cases it was written for are planted here rather than argued: an operation the list does not
# name must fail it, and an input it cannot read must fail it too, never skip.
#
# The fixtures are the repository's own document and config, copied and then mutated, because the
# rule compares two real lists against each other: a synthetic document would have to restate the
# sixty-odd operationIds this contract carries and would drift from it on the next re-vendor.
# Nothing here writes into the repository — every fixture lands in a temporary tree, removed on
# exit.
#
# Run it directly (`tests/gate/openapi-coverage-rule-test.sh`) or let the gate run it: it is picked
# up by the controller-side selftest step in bin/mac-gate.sh, which runs every tests/gate/*-test.sh.
#
# Exit: 0 = every case judged as expected; otherwise the first unexpected code (never 0).

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
RULE="$repo_root/scripts/openapi-coverage-rule.sh"
[ -x "$RULE" ] || { echo "FAIL: $RULE is missing or not executable"; exit 1; }

rel_dir="Packages/MemosAPI/Sources/MemosAPI"
DOCUMENT="$repo_root/$rel_dir/openapi.json"
CONFIG="$repo_root/$rel_dir/openapi-generator-config.yaml"
for input in "$DOCUMENT" "$CONFIG"; do
  [ -f "$input" ] || { echo "FAIL: $input is missing, so no fixture can be built from it"; exit 1; }
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-openapi-coverage-XXXXXX")" || { echo "FAIL: cannot make a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fails=0
cases=0
first_fail=0
pass_seen=0

# A copy of the real pair, which is the only honest fixture: the rule's whole job is to compare the
# vendored document's operationIds against the config's list, and both are this repository's.
new_tree() {
  local name="$1" work="$tmp/$1"
  mkdir -p "$work/$rel_dir" || return 1
  cp "$DOCUMENT" "$work/$rel_dir/openapi.json" || return 1
  cp "$CONFIG" "$work/$rel_dir/openapi-generator-config.yaml" || return 1
  printf '%s' "$work"
}

check() { # $1 label, $2 expected exit, $3 tree root, [$4 a line the output must contain]
  local label="$1" expected="$2" root="$3" needle="${4:-}" out rc
  cases=$((cases + 1))
  out="$("$RULE" "$root" 2>&1)"
  rc=$?
  if [ "$rc" != "$expected" ]; then
    fails=$((fails + 1))
    # A case that was supposed to fail and came back 0 must not hand this suite a 0 to exit with.
    if [ "$first_fail" -eq 0 ]; then
      if [ "$rc" -ne 0 ]; then first_fail=$rc; else first_fail=1; fi
    fi
    echo "FAIL $label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -qF -e "$needle"; then
    fails=$((fails + 1))
    [ "$first_fail" -ne 0 ] || first_fail=1
    echo "FAIL $label: exit $rc was right, but it failed for the wrong reason"
    echo "     | expected the output to name: $needle"
    printf '%s\n' "$out" | sed 's/^/     | /'
    return
  fi
  [ "$expected" != 0 ] || pass_seen=1
  echo "ok   $label -> exit $rc"
}

# The shape of a healthy pair: this repository's own document and config, copied.
w="$(new_tree clean)" || exit 1
check "the document and config as they stand, copied" 0 "$w"

# (i) THE RED PROOF the rule was written for: upstream adds a path, nobody adds it to the list, and
# without this rule it is simply never generated.
w="$(new_tree unlisted-operation)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi.json" <<'PY' || exit 1
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
document["paths"]["/api/gate-synthetic"] = {
    "get": {"operationId": "gate_synthetic_unlisted_get", "responses": {}}
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
PY
check "an operation the inclusion list does not name" 1 "$w" "gate_synthetic_unlisted_get"

# (ii) THE SECOND RED PROOF, in both its halves: an input the rule cannot read is a refusal. A
# missing file must never read as "nothing to complain about".
w="$(new_tree no-config)" || exit 1
rm "$w/$rel_dir/openapi-generator-config.yaml"
check "the generator config removed" 2 "$w" "openapi-generator-config.yaml is missing"

w="$(new_tree no-document)" || exit 1
rm "$w/$rel_dir/openapi.json"
check "the vendored document removed" 2 "$w" "openapi.json is missing"

check "a path that is not a directory at all" 2 "$tmp/does-not-exist"

w="$(new_tree unparseable-document)" || exit 1
printf '{ this is not json' > "$w/$rel_dir/openapi.json"
check "a document that is not JSON" 2 "$w" "could not be read as JSON"

# (iii) the filter removed entirely. Either this rule is obsolete or the list is written in a shape
# it cannot read; both are answers a human gives, never a pass.
w="$(new_tree no-filter)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
kept, dropping = [], False
for line in lines:
    if line.strip() == "filter:" and not line.startswith(" "):
        dropping = True
        continue
    if dropping:
        if line.strip() and not line.startswith(" "):
            dropping = False
        else:
            continue
    kept.append(line)
open(path, "w", encoding="utf-8").write("\n".join(kept) + "\n")
PY
check "the filter block deleted" 2 "$w" "declares no filter.operations list"

# (iv) the subtraction still adds up, but one of the four knowingly-excluded operations has been
# quietly moved into the inclusion list. A name cannot be on both sides.
w="$(new_tree include-an-exclusion)" || exit 1
printf '    - basemap_manifest_api_map_manifest_get\n' >> "$w/$rel_dir/openapi-generator-config.yaml"
check "an excluded operation also included" 1 "$w" "both included and named as deliberately excluded"

# (v) a hand-curated list is exactly what this rule refuses: a name the document does not define
# generates nothing and hides the fact.
w="$(new_tree stale-inclusion)" || exit 1
printf '    - gate_synthetic_invented_get\n' >> "$w/$rel_dir/openapi-generator-config.yaml"
check "an inclusion the document does not define" 1 "$w" "gate_synthetic_invented_get"

# (vi) the exclusion set is pinned to the surface it was written for. Upstream retiring one of the
# four is a decision, not a silent simplification.
w="$(new_tree retired-exclusion)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi.json" <<'PY' || exit 1
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
del document["paths"]["/api/map/manifest"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
PY
check "an excluded operation retired upstream" 1 "$w" "the exclusion set is stale"

# (vii) the positive control biting. A document that parsed but holds no operations makes every
# other comparison vacuously true, which is the shape a truncated or wrong file arrives in.
w="$(new_tree empty-document)" || exit 1
printf '{"openapi": "3.1.0", "paths": {}}' > "$w/$rel_dir/openapi.json"
check "a document with no operations at all" 1 "$w" "checked nothing"

# (viii) WHAT THE CONFIG SAYS, NOT WHAT A SEARCH FINDS IN IT. The rule reads the inclusion list
# without a YAML library, so its reader is the weakest link: anything it does not understand but
# skips is a list it silently read short, and a short list still adds up if the omission happens to
# be a name the document does not define either. Every case below is a config no reader of YAML
# would agree with this one's meaning about, so each must end as an unusable input (exit 2), named
# by line — never as a pass.

# (a) a file that stopped being YAML after the list. The list itself is untouched and correct.
w="$(new_tree invalid-yaml-tail)" || exit 1
printf 'invalid: [\n' >> "$w/$rel_dir/openapi-generator-config.yaml"
check "trailing text that is not YAML" 2 "$w" "not a plain scalar"

# (b) the whole list moved one level deeper, under a key the generator does not read. The names are
# all still there to be found by a search; none of them is filtered by anything.
w="$(new_tree nested-too-deep)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
out, inside = [], False
for line in lines:
    if line == "filter:":
        out.extend(["filter:", "  tags:"])
        inside = True
        continue
    if inside:
        if line.strip() and not line.startswith(" "):
            inside = False
        else:
            out.append(("  " + line) if line.strip() else line)
            continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
check "the list nested one level too deep" 2 "$w" "nested deeper than"

# (c) the list at the top level, outside the filter the generator reads. Same names, no filter.
w="$(new_tree operations-outside-filter)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
out, inside = [], False
for line in lines:
    if line == "filter:":
        inside = True
        continue
    if inside:
        if line.strip() and not line.startswith(" "):
            inside = False
        else:
            out.append(line[2:] if line.startswith("  ") else line)
            continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
check "the list at the top level, outside filter" 2 "$w" "declares no filter.operations list"

# (d) a flow-style list. It is valid YAML and means something, but this reader was written for the
# block form — so it either reads it correctly or refuses it, and never reads it as empty.
w="$(new_tree flow-style-list)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
out, inside = [], False
for line in lines:
    if line == "filter:":
        out.extend(["filter:", "  operations: [create_memo_api_memos_post, list_memos_api_memos_get]"])
        inside = True
        continue
    if inside:
        if line.strip() and not line.startswith(" "):
            inside = False
        else:
            continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
check "a flow-style operations list" 2 "$w" "not a plain scalar"

# (e) an item indented with a tab, which YAML forbids as indentation and an indentation-counting
# reader cannot see at all: it ends the list early and everything after it disappears.
w="$(new_tree tab-indented-item)" || exit 1
printf '\t- gate_synthetic_tab_item\n' >> "$w/$rel_dir/openapi-generator-config.yaml"
check "a list item indented with a tab" 2 "$w" "indented with a tab"

# (f) a duplicate key, in both places it can hide: a second filter block whose list is the one a
# reader would see last, and a second operations list inside the one filter.
w="$(new_tree duplicate-filter)" || exit 1
printf 'filter:\n  operations:\n    - health_health_get\n' >> "$w/$rel_dir/openapi-generator-config.yaml"
check "a second filter block" 2 "$w" "repeats the key"

w="$(new_tree duplicate-operations)" || exit 1
printf '  operations:\n    - health_health_get\n' >> "$w/$rel_dir/openapi-generator-config.yaml"
check "a second operations list inside filter" 2 "$w" "repeats the key"

# (h) the two shapes that are a BROKEN rule rather than an unreadable file, pinned here so the
# reader above cannot turn either of them into a refusal: an empty list generates nothing, and a
# commented-out inclusion is an operation nobody generates.
w="$(new_tree empty-operations)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
kept = [line for line in lines if not line.startswith("    - ")]
open(path, "w", encoding="utf-8").write("\n".join(kept) + "\n")
PY
check "an empty inclusion list" 1 "$w" "empty filter.operations list"

w="$(new_tree commented-out-inclusion)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
target = "    - health_health_get\n"
if target not in text:
    raise SystemExit("fixture: %s does not contain %r" % (path, target))
open(path, "w", encoding="utf-8").write(text.replace(target, "    # - health_health_get\n"))
PY
check "an inclusion commented out" 1 "$w" "health_health_get"

# (ix) WHAT THE BYTES SAY, BEFORE ANYTHING TIDIES THEM. A reader that normalises before it judges
# judges a file nobody wrote: a name ending in a no-break space is a DIFFERENT operation to YAML,
# and a character a line splitter treats as a newline is gone before any grammar can object. Each
# mutation below names its character by code point and builds it with chr(), because a fixture
# whose character cannot be seen in the source of the test is not evidence.
mutate_config() { # $1 tree, $2 code point in hex, $3 placement: after-item|own-line|instead-of-newline
  /usr/bin/python3 - "$1/$rel_dir/openapi-generator-config.yaml" "$2" "$3" <<'PY'
import sys

path, code, placement = sys.argv[1], int(sys.argv[2], 16), sys.argv[3]
char = chr(code)
item = "    - health_health_get\n"
text = open(path, encoding="utf-8").read()
if item not in text:
    raise SystemExit("fixture: %s does not contain %r" % (path, item))
replacement = {
    "after-item": "    - health_health_get" + char + "\n",
    "own-line": item + char + "\n",
    "instead-of-newline": "    - health_health_get" + char,
}[placement]
open(path, "w", encoding="utf-8").write(text.replace(item, replacement))
PY
}

# U+00A0 and U+2003 are whitespace to a strip() and part of the plain scalar to YAML, so an item
# ending in either names an operation that exists nowhere and is generated by nothing.
w="$(new_tree trailing-nbsp)" || exit 1
mutate_config "$w" 00A0 after-item || exit 1
check "an item ending in a no-break space" 2 "$w" "U+00A0"

w="$(new_tree trailing-em-space)" || exit 1
mutate_config "$w" 2003 after-item || exit 1
check "an item ending in an em space" 2 "$w" "U+2003"

# A form feed, a line separator and a lone carriage return: three characters this file may not
# hold, each of which a line splitter reads as the end of a line -- which is to say, deletes before
# the grammar sees it.
w="$(new_tree form-feed)" || exit 1
mutate_config "$w" 000C own-line || exit 1
check "a form feed between two items" 2 "$w" "U+000C"

w="$(new_tree line-separator)" || exit 1
mutate_config "$w" 2028 after-item || exit 1
check "a Unicode line separator after an item" 2 "$w" "U+2028"

w="$(new_tree lone-carriage-return)" || exit 1
mutate_config "$w" 000D instead-of-newline || exit 1
check "a lone carriage return as a line break" 2 "$w" "U+000D"

# The comment exemption is for prose — an em dash, an ellipsis — and not a door. YAML's c-printable
# excludes U+FFFE and U+FFFF wherever they appear, comments included, and a document holding one is
# a document a real parser refuses to load at all; this reader cannot accept what the generator's
# own parser would throw out.
for point in FFFE FFFF; do
  w="$(new_tree "noncharacter-$point")" || exit 1
  /usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" "$point" <<'PY' || exit 1
import sys

path, code = sys.argv[1], int(sys.argv[2], 16)
with open(path, "a", encoding="utf-8") as handle:
    handle.write("# " + chr(code) + "\n")
PY
  check "a comment holding U+$point" 2 "$w" "U+$point"
done

# The other half of the line-ending decision: a "\r" is a line ending only where a "\n" follows it,
# and the end of the file is not a "\n". A terminal one is a character in the last line like any
# other, and this file may not hold it.
w="$(new_tree terminal-carriage-return)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", newline="").read()
if not text.endswith("\n"):
    raise SystemExit("fixture: %s does not end in a newline" % path)
open(path, "w", encoding="utf-8", newline="").write(text[:-1] + chr(0x0D))
PY
check "a carriage return ending the last line" 2 "$w" "U+000D"

# CRLF is the one line ending that is DECIDED rather than refused: a checkout with the other
# convention is a file that still says exactly the same thing, so it is read, and the proof is that
# the list it yields is the same length as the real one.
w="$(new_tree crlf-line-endings)" || exit 1
/usr/bin/python3 - "$w/$rel_dir/openapi-generator-config.yaml" <<'PY' || exit 1
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8", newline="").read()
open(path, "w", encoding="utf-8", newline="").write(text.replace("\n", "\r\n"))
PY
check "the config with CRLF line endings" 0 "$w" "95 operationIds named by filter.operations"

# And the repository this suite ships in, which is the point of the whole exercise. With the copied
# pair at the top of this file it is also the positive control on every refusal above: the real
# config, unmodified, is read by the same reader and accepted.
check "the real repository tree" 0 "$repo_root"

# --- verdict --------------------------------------------------------------------------------------
# The positive control on the suite itself: if no pair was accepted, a rule script that refused
# everything would pass every expectation above that expects a refusal.
if [ "$pass_seen" -ne 1 ]; then
  echo "FAIL: no document was accepted — a rule that refuses everything would pass this suite"
  fails=$((fails + 1))
  [ "$first_fail" -ne 0 ] || first_fail=1
fi

echo "gate openapi-coverage rule: $((cases - fails)) of $cases fixtures as expected"
[ "$fails" -eq 0 ] || { echo "OPENAPI-COVERAGE-TEST FAIL: $fails fixture(s) misjudged"; exit "$first_fail"; }
echo "OPENAPI-COVERAGE-TEST ok"
