#!/usr/bin/env python3
"""Compare retained UI snapshots from the Alicorn direct and convenience APIs.

Usage: python3 tools/compare_ui_dogfood.py before.txt after.txt

Leaf Button and Text nodes have no retained layout children. Their Layout_Style
direction is normalized because it cannot affect their layout or appearance;
all other snapshot records must match byte-for-byte.
"""

import re
import sys
from pathlib import Path


NODE = re.compile(r'^NODE order=(\d+) path="(.*?)" parent="(.*?)" kind=(\w+) children=(\d+) ')
DIRECTION = re.compile(r'(style=Layout_Style\{direction = )"(?:Row|Column)"')


def node_fields(line):
    match = NODE.match(line)
    return match.groups() if match else None


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    before = Path(sys.argv[1]).read_text().splitlines()
    after = Path(sys.argv[2]).read_text().splitlines()
    if not before or before[0] != "scratchpad-ui-api-dogfood-v1":
        raise SystemExit(f"{sys.argv[1]}: unsupported or empty snapshot")
    if not after or after[0] != before[0]:
        raise SystemExit(f"{sys.argv[2]}: unsupported or mismatched snapshot")
    if len(before) != len(after):
        raise SystemExit(f"snapshot line count differs: {len(before)} vs {len(after)}")

    raw_differences = normalized_leaf_nodes = 0
    unmatched = []
    node_count = 0
    for index, (old, new) in enumerate(zip(before, after)):
        old_fields, new_fields = node_fields(old), node_fields(new)
        if old_fields or new_fields:
            if not old_fields or not new_fields:
                unmatched.append((index, old, new))
                continue
            node_count += 1
            if old_fields[:4] != new_fields[:4] or old_fields[4] != new_fields[4]:
                unmatched.append((index, old, new))
                continue
        if old == new:
            continue
        raw_differences += 1
        if old_fields and new_fields and old_fields[3] in ("Button", "Text") and old_fields[4] == new_fields[4] == "0":
            old_normalized, old_count = DIRECTION.subn(r'\1"<leaf-direction>"', old, count=1)
            new_normalized, new_count = DIRECTION.subn(r'\1"<leaf-direction>"', new, count=1)
            if old_count == new_count == 1 and old_normalized == new_normalized:
                normalized_leaf_nodes += 1
                continue
        unmatched.append((index, old, new))

    if unmatched:
        for index, old, new in unmatched[:10]:
            print(f"line {index + 1} differs:\n- {old}\n+ {new}", file=sys.stderr)
        raise SystemExit(f"{len(unmatched)} snapshot records differ beyond leaf text/button direction")
    print(f"matched {node_count} retained nodes and {len(before)} records")
    print(f"raw differing node records: {raw_differences}")
    print(f"normalized leaf Text/Button direction records: {normalized_leaf_nodes}")
    print("bounds, paint, semantics, identities, and ordering match")


if __name__ == "__main__":
    main()
