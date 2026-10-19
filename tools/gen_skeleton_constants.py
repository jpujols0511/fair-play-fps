#!/usr/bin/env python3
"""Generate the GDScript skeleton constants from the canonical JSON source."""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "specs" / "skeleton_constants.json"
OUTPUT = ROOT / "weapons_proto" / "shared" / "skeleton_constants.gd"


def canonical_bytes(data):
    return json.dumps(
        data,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def to_gdscript(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(to_gdscript(item) for item in value) + "]"
    if isinstance(value, dict):
        entries = [
            "%s: %s" % (json.dumps(key, ensure_ascii=False), to_gdscript(item))
            for key, item in value.items()
        ]
        return "{ " + ", ".join(entries) + " }"
    raise TypeError("unsupported JSON value: %r" % (value,))


def render(data):
    digest = hashlib.sha256(canonical_bytes(data)).hexdigest()
    lines = [
        "# GENERATED from specs/skeleton_constants.json by tools/gen_skeleton_constants.py. Do not edit.",
        "class_name SkeletonConstants",
        "extends RefCounted",
        "",
        'const SKELETON_SHA256 := "%s"' % digest,
        'const VERSION := %s' % to_gdscript(data["version"]),
        "const STAND_HEIGHT := %s" % to_gdscript(data["stand_height"]),
        "const EYE_STAND := %s" % to_gdscript(data["eye_stand"]),
        "const CROUCH_SCALE := %s" % to_gdscript(data["crouch_scale"]),
        "const MAX_REWIND_TICKS_128 := %s" % to_gdscript(data["max_rewind_ticks_128"]),
        "const NEAR_MISS_UNITS := %s" % to_gdscript(data["near_miss_units"]),
        "const BOXES := [",
    ]
    for box in data["boxes"]:
        lines.append("\t%s," % to_gdscript(box))
    lines.extend(["]", ""])
    return "\n".join(lines)


def main(argv):
    check = argv[1:] == ["--check"]
    if argv[1:] not in ([], ["--check"]):
        print("usage: python3 tools/gen_skeleton_constants.py [--check]", file=sys.stderr)
        return 2

    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    expected = render(data)
    if check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != expected:
            print("generated skeleton constants are stale: %s" % OUTPUT.relative_to(ROOT))
            return 1
        print("generated skeleton constants are up to date")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(expected.encode("utf-8"))
    print("wrote %s" % OUTPUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
