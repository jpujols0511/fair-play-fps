#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
COMMANDS = (
    ("repository structure", [sys.executable, "scripts/check_repo.py"]),
    (
        "authoritative simulation tests",
        [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
    ),
    ("prototype scenarios", [sys.executable, "scripts/run_prototype.py"]),
)


def main() -> int:
    print(
        f"Fair Play FPS local verification\nroot: {ROOT}\npython: {sys.version.split()[0]}",
        flush=True,
    )
    for label, command in COMMANDS:
        print(f"\n== {label} ==", flush=True)
        completed = subprocess.run(command, cwd=ROOT, check=False)
        if completed.returncode:
            print(f"FAIL {label} (exit {completed.returncode})", file=sys.stderr)
            return completed.returncode
    print("\nPASS local verification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
