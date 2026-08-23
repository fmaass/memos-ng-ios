#!/usr/bin/env python3
"""Canonicalise FastAPI's nullable idiom into OAS 3.1 type arrays.

FastAPI writes an optional field as ``anyOf: [{"type": "string"}, {"type": "null"}]``.
swift-openapi-generator does not support a bare ``"null"`` schema and DROPS the whole property,
silently: ``MemoList.nextCursor``, ``MemoOut.archived_at`` and ``UserOut.display_name`` simply do
not exist in the generated types, so cursor pagination cannot be written against them at all.

``type: ["string", "null"]`` says exactly the same thing in JSON Schema 2020-12 and generates a
Swift optional. This rewrite is therefore lossless, and it is applied HERE, at vendoring time,
rather than hidden inside the generator config, so that ``OPENAPI_SOURCE`` can record how many
properties it touched. The day memos-ng emits type arrays itself, that count is 0 and this script
can go.

Only inline schemas are rewritten. ``anyOf: [{"$ref": ...}, {"type": "null"}]`` cannot become a
type array; those are left alone and reported, because a reference plus null is a different fix.
"""

import json
import sys


def is_null_schema(node):
    return isinstance(node, dict) and node.get("type") == "null" and len(node) == 1


def rewrite(node, counts):
    if isinstance(node, dict):
        any_of = node.get("anyOf")
        if isinstance(any_of, list) and len(any_of) == 2 and any(is_null_schema(m) for m in any_of):
            keep = next(m for m in any_of if not is_null_schema(m))
            if "type" in keep and "$ref" not in keep:
                rest = {k: v for k, v in node.items() if k != "anyOf"}
                merged = dict(keep)
                merged.update(rest)
                merged["type"] = [keep["type"], "null"]
                node.clear()
                node.update(merged)
                counts["rewritten"] += 1
            else:
                counts["left"] += 1
        for value in list(node.values()):
            rewrite(value, counts)
    elif isinstance(node, list):
        for value in node:
            rewrite(value, counts)


def main(argv):
    if len(argv) != 3:
        print("usage: normalize-openapi.py <in.json> <out.json>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
    counts = {"rewritten": 0, "left": 0}
    rewrite(document, counts)
    with open(argv[2], "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=1, sort_keys=True)
        handle.write("\n")
    print(f"nullable_rewritten={counts['rewritten']}")
    print(f"nullable_left_as_anyof_ref={counts['left']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
