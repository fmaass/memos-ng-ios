#!/usr/bin/env bash
#
# The openapi-coverage rule: an operation the vendored contract offers is either generated or
# deliberately not, and nothing is left out by accident.
#
# The generator's `filter:` is inclusion-only: whatever the config does not name is simply not
# generated, and the build of a client that never mentions it stays green. That is exactly the
# failure this repository already met once from the other direction — a property written as a
# nullable union vanished from the generated types and nothing went red — so a filter, which makes
# omission the DEFAULT rather than an accident, cannot be left to a reader's diligence. The next
# re-vendor brings new paths; without this step they would arrive, be filtered out because no one
# added them, and the first sign of it would be a feature that cannot be written.
#
# So the inclusion list is not curated, it is DERIVED: every operationId in the document minus a
# named exclusion set. This script is the arithmetic of that subtraction. It lives beside the
# document rather than inside the test bundle because the two files it reads are the generator
# plugin's declared inputs inside the MemosAPI target's own sources — a test bundle can only reach
# them through a copy, which drifts, or a symlink, which the gate's classifier refuses.
#
# THE EXCLUSION SET LIVES HERE, not in the config, and it is the whole editorial content of this
# rule. The config states WHAT is generated; this states what is knowingly left out and why, so a
# fifth name cannot join it without appearing in a diff next to its reason.
#
#   basemap_manifest_api_map_manifest_get              the basemap archive manifest
#   serve_basemap_archive_api_map_tiles__name__get     the tile archive bytes
#   serve_basemap_archive_api_map_tiles__name__head    its range/size probe
#   serve_basemap_asset_api_map_assets__path__get      the style's fonts, sprites and glyphs
#
# All four serve a self-hosted basemap the app does not read: it draws its map with the platform's
# own map view, and it reaches the household's map data through the markers operation alone. Their
# schemas (the manifest and its archive descriptors) are the ones whose nullable-union properties
# this generator version drops in silence, so excluding the four is also what keeps a dropped
# property from being vendored into the client as an always-nil field.
#
# Usage: openapi-coverage-rule.sh [<repo-root>]     (default: the current directory)
# Exit:  0 = every operationId is accounted for, and every control was found
#        1 = the rule was broken (an unaccounted operation, a stale or contradictory list)
#        2 = the inputs were not usable (a missing tree, a missing or unparseable file), which is
#            never a pass
set -uo pipefail

root="${1:-.}"

if [ ! -d "$root" ]; then
  echo "OPENAPI-COVERAGE FAIL: '$root' is not a directory, so nothing was checked"
  exit 2
fi

document="$root/Packages/MemosAPI/Sources/MemosAPI/openapi.json"
config="$root/Packages/MemosAPI/Sources/MemosAPI/openapi-generator-config.yaml"

for input in "$document" "$config"; do
  if [ ! -f "$input" ]; then
    echo "OPENAPI-COVERAGE FAIL: $input is missing, so the coverage of the generator's filter was"
    echo "                       never checked and this step proves nothing"
    exit 2
  fi
done

# The config is read without a YAML library on purpose: neither machine's /usr/bin/python3 is
# guaranteed to have one, and the fragment this rule needs — one list of plain scalars under
# filter.operations — is narrow enough to read by indentation. Anything the reader cannot make
# sense of is an unusable input (exit 2), never an empty list that would pass.
/usr/bin/python3 - "$document" "$config" <<'PY'
import json
import sys

document_path, config_path = sys.argv[1], sys.argv[2]

# The exclusion set is repeated here from this file's header because the check is arithmetic and
# arithmetic cannot read a comment. Both spellings are compared below, so they cannot drift apart.
EXCLUDED = {
    "basemap_manifest_api_map_manifest_get",
    "serve_basemap_archive_api_map_tiles__name__get",
    "serve_basemap_archive_api_map_tiles__name__head",
    "serve_basemap_asset_api_map_assets__path__get",
}
METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}


def unusable(message):
    print("OPENAPI-COVERAGE FAIL: %s" % message)
    sys.exit(2)


def broken(message):
    print("OPENAPI-COVERAGE FAIL: %s" % message)
    sys.exit(1)


try:
    with open(document_path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
except (ValueError, OSError) as error:
    unusable("%s could not be read as JSON (%s)" % (document_path, error))

paths = document.get("paths")
if not isinstance(paths, dict):
    unusable("%s has no 'paths' object, so it is not the contract this rule checks" % document_path)

documented = {}
for path, item in paths.items():
    if not isinstance(item, dict):
        unusable("%s: the entry for %s is not an object" % (document_path, path))
    for method, operation in item.items():
        if method.lower() not in METHODS:
            continue
        if not isinstance(operation, dict) or not operation.get("operationId"):
            unusable(
                "%s: %s %s carries no operationId, so it cannot be named in a filter"
                % (document_path, method.upper(), path)
            )
        operation_id = operation["operationId"]
        if operation_id in documented:
            unusable("%s: operationId %s appears twice" % (document_path, operation_id))
        documented[operation_id] = path

# A document that parsed but held no operations would make every other check below vacuously true.
# It is the shape a wrong file, a truncated copy or a rewritten vendoring would take, so it is the
# positive control: the count is printed, and a zero is a failure rather than a pass.
print("openapi-coverage: %d operationIds read from the vendored document" % len(documented))
if not documented:
    broken("the document declares no operations at all, so this rule checked nothing")

# --- the config's inclusion list, by indentation ------------------------------------------------
with open(config_path, "r", encoding="utf-8") as handle:
    lines = handle.read().splitlines()


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank(line):
    return not line.strip() or line.lstrip().startswith("#")


included = None
index = 0
while index < len(lines):
    line = lines[index]
    index += 1
    if is_blank(line) or indent_of(line) != 0 or line.strip() != "filter:":
        continue
    # Inside filter:, find operations: and read the items indented under it.
    while index < len(lines):
        inner = lines[index]
        if is_blank(inner):
            index += 1
            continue
        if indent_of(inner) == 0:
            break
        index += 1
        if inner.strip() != "operations:":
            continue
        operations_indent = indent_of(inner)
        included = []
        while index < len(lines):
            item = lines[index]
            if is_blank(item):
                index += 1
                continue
            if indent_of(item) <= operations_indent:
                break
            index += 1
            entry = item.strip()
            if not entry.startswith("- "):
                unusable(
                    "%s:%d is indented under filter.operations but is not a list item: %r"
                    % (config_path, index, item)
                )
            included.append(entry[2:].strip().strip("'\""))
        break
    break

if included is None:
    unusable(
        "%s declares no filter.operations list, so either the filter was removed (in which case "
        "this rule is obsolete and must be removed with it) or it is written in a shape this "
        "reader does not understand" % config_path
    )
if not included:
    broken("%s names an empty filter.operations list, which generates nothing" % config_path)

print("openapi-coverage: %d operationIds named by filter.operations" % len(included))

duplicates = sorted({name for name in included if included.count(name) > 1})
if duplicates:
    broken("filter.operations names these twice: %s" % ", ".join(duplicates))

included_set = set(included)

overlap = sorted(included_set & EXCLUDED)
if overlap:
    broken(
        "these operationIds are both included and named as deliberately excluded: %s"
        % ", ".join(overlap)
    )

stale = sorted(included_set - set(documented))
if stale:
    broken(
        "filter.operations names operationIds the vendored document does not define, so the list "
        "was hand-edited rather than derived: %s" % ", ".join(stale)
    )

# An exclusion is pinned to the surface it was written for. Without this a name kept after upstream
# reused it would silence an unrelated operation, and the subtraction would still add up.
missing_exclusions = sorted(EXCLUDED - set(documented))
if missing_exclusions:
    broken(
        "this rule excludes operationIds the vendored document no longer defines, so the exclusion "
        "set is stale: %s" % ", ".join(missing_exclusions)
    )
misplaced = sorted(name for name in EXCLUDED if not documented[name].startswith("/api/map/"))
if misplaced:
    broken(
        "these excluded operationIds no longer serve the basemap surface this rule excludes: %s"
        % ", ".join("%s (%s)" % (name, documented[name]) for name in misplaced)
    )

unaccounted = sorted(set(documented) - included_set - EXCLUDED)
if unaccounted:
    print(
        "OPENAPI-COVERAGE FAIL: the vendored contract offers operations the generator's filter "
        "neither includes nor knowingly excludes, so they are silently ungenerated:"
    )
    for name in unaccounted:
        print("    %s  (%s)" % (name, documented[name]))
    print(
        "                       add each to filter.operations, or to this rule's exclusion set "
        "with the reason it is not generated"
    )
    sys.exit(1)

print(
    "openapi-coverage OK: %d of %d operations generated, %d knowingly excluded"
    % (len(included_set), len(documented), len(EXCLUDED))
)
PY
exit $?
