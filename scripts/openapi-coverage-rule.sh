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
import re
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

# --- the config's inclusion list, read as the whole file --------------------------------------
# The reader below accepts ONLY the shapes this config is written in and refuses every other line,
# by number. A reader that SEARCHES for the lines it wants instead accepts files that do not mean
# what it read them to mean, and each of those still adds up here, because what it skipped is
# missing from both sides of the subtraction: a list nested under a key the generator never looks
# at is no filter at all; a second `filter:` or a second `operations:` is the block a real parser
# would keep, not the one a search finds first; an item indented with a tab ends an
# indentation-counted list early and takes every name after it along; a flow-style list read as
# nothing is an empty filter reported as a full one. So the grammar is fixed: indentation of 0, 2
# or 4 spaces, lines that are `key:`, `key: scalar` or `- scalar`, `operations:` a DIRECT child of
# the one top-level `filter:`, and its items plain scalars. Anything else names its line and exits
# 2 — this rule cannot judge a file it cannot read, and the answer to that is never a pass.
KEY_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):(?:[ ]+(.*))?$")
ITEM_LINE = re.compile(r"^-[ ]+(.*)$")
# A plain scalar as this file uses one. It admits no quote, bracket, brace, comma or `#`, so a flow
# list, an anchor, a tag and a trailing comment are each refused rather than half-read.
SCALAR = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_./-]*$")
LEVELS = (0, 2, 4)

# NOTHING IS TIDIED BEFORE IT IS JUDGED. A reader that strips first answers about a file nobody
# wrote: a trailing no-break space belongs to the plain scalar as far as YAML is concerned, so an
# item carrying one names a DIFFERENT operation — and stripping it turns that into a name the
# document defines and the subtraction accepts. The same holds for the split: splitlines() ends a
# line at a form feed, at U+001C–1E, U+0085 and at U+2028/2029 too, so each of those disappears
# before any grammar can refuse it. So: decode strictly, split on "\n" alone, and refuse by code
# point anything the grammar may not read.
try:
    with open(config_path, "rb") as handle:
        text = handle.read().decode("utf-8")
except (UnicodeDecodeError, OSError) as error:
    unusable("%s could not be read as UTF-8 text (%s)" % (config_path, error))

# A CRLF checkout of this file says exactly the same thing, so one "\r" immediately BEFORE a "\n" is
# a line ending and is dropped here. Nowhere else: what follows the last "\n" was ended by the file,
# not by a newline, so a "\r" there stays in its line and is refused below with the rest.
parts = text.split("\n")
lines = [part[:-1] if part.endswith("\r") else part for part in parts[:-1]] + parts[-1:]

# The grammar reads printable ASCII and nothing else. Full-line comments are the one exception,
# because the prose in this config uses an em dash and an ellipsis — but the exception is bounded by
# what YAML itself calls printable: a document holding a C0 or C1 control, a surrogate or one of the
# two noncharacters is one the generator's own parser refuses to load, comment or not, and a rule
# that reads further than the parser it guards is answering about a file that will never be built.
# U+2028 and U+2029 are printable to YAML and refused here anyway: they end a line for some readers
# and vanish for others, which is the whole class this reader exists to refuse.
PRINTABLE = (0x20, 0x7E)
SEPARATORS = (0x2028, 0x2029)


def is_yaml_printable(point):
    return (
        0x20 <= point <= 0x7E
        or 0xA0 <= point <= 0xD7FF
        or 0xE000 <= point <= 0xFFFD
        or 0x10000 <= point <= 0x10FFFF
    ) and point not in SEPARATORS


def is_comment(line):
    return line.lstrip(" ").startswith("#")


def unreadable(number, raw, why):
    unusable("%s:%d %s: %r" % (config_path, number, why, raw))


def check_characters(number, line):
    comment = is_comment(line)
    if not comment and line.lstrip(" ").startswith("\t"):
        unreadable(number, line, "is indented with a tab, which a space-counting reader cannot see")
    for column, char in enumerate(line, 1):
        point = ord(char)
        if not is_yaml_printable(point):
            unreadable(
                number,
                line,
                "holds U+%04X at column %d, which no line of a YAML document may carry"
                % (point, column),
            )
        if not (PRINTABLE[0] <= point <= PRINTABLE[1]) and not comment:
            unreadable(
                number,
                line,
                "holds U+%04X at column %d, where this reader accepts printable ASCII only"
                % (point, column),
            )


included = None
top_keys = {}
top_name = None
top_shape = None  # what has been seen under the current top-level key: list, map or scalar
child_keys = {}
child_name = None
child_shape = None

for number, line in enumerate(lines, 1):
    check_characters(number, line)
    if is_comment(line) or not line.strip(" "):
        continue
    if line != line.rstrip(" "):
        unreadable(number, line, "ends in a space, which no line of this file does")
    stripped = line.lstrip(" ")
    indent = len(line) - len(stripped)
    if indent not in LEVELS:
        unreadable(number, line, "is indented %d spaces, where this file uses 0, 2 and 4" % indent)

    item = ITEM_LINE.match(stripped)
    key = None if item else KEY_LINE.match(stripped)
    if item is None and key is None:
        unreadable(number, line, "is neither a `key:` nor a `- item`")
    value = item.group(1) if item else key.group(2)
    if value is not None and not SCALAR.match(value):
        unreadable(number, line, "carries a value that is not a plain scalar")

    if indent == 0:
        if item:
            unreadable(number, line, "is a list item at the top level, where this file has only keys")
        name = key.group(1)
        if name in top_keys:
            unreadable(
                number, line, "repeats the key %r, first seen at line %d" % (name, top_keys[name])
            )
        top_keys[name] = number
        top_name, top_shape = name, ("scalar" if value is not None else None)
        child_keys, child_name, child_shape = {}, None, None
        continue

    if top_name is None:
        unreadable(number, line, "is indented under no key at all")
    if top_shape == "scalar":
        unreadable(number, line, "is indented under `%s`, which already carries a value" % top_name)

    if indent == 2:
        if item:
            if top_shape == "map":
                unreadable(
                    number, line, "is a list item under `%s`, which already holds keys" % top_name
                )
            top_shape = "list"
            child_name, child_shape = None, None
            continue
        if top_shape == "list":
            unreadable(number, line, "is a key under `%s`, which already holds list items" % top_name)
        top_shape = "map"
        name = key.group(1)
        if name in child_keys:
            unreadable(
                number,
                line,
                "repeats the key %r under `%s`, first seen at line %d"
                % (name, top_name, child_keys[name]),
            )
        child_keys[name] = number
        child_name, child_shape = name, ("scalar" if value is not None else None)
        if top_name == "filter" and name == "operations":
            if value is not None:
                unreadable(number, line, "gives filter.operations a value where a list belongs")
            included = []
        continue

    # Indent 4: the only line this file has this deep is an item of a list opened at indent 2. A key
    # here is the shape that hides a whole inclusion list under a name the generator never reads.
    if key:
        unreadable(
            number,
            line,
            "is a key nested deeper than this file's shape allows, where only `- item` lines appear",
        )
    if child_name is None:
        unreadable(number, line, "is indented under no key of `%s`" % top_name)
    if child_shape == "scalar":
        unreadable(number, line, "is indented under `%s`, which already carries a value" % child_name)
    child_shape = "list"
    if top_name == "filter" and child_name == "operations":
        included.append(value)

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
