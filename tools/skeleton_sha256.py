#!/usr/bin/env python3
"""Print the SHA-256 of the canonical skeleton JSON."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "specs" / "skeleton_constants.json"


def canonical_bytes(data):
    return json.dumps(
        data,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def main():
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    print(hashlib.sha256(canonical_bytes(data)).hexdigest())


if __name__ == "__main__":
    main()
