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

# And the repository this suite ships in, which is the point of the whole exercise.
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
