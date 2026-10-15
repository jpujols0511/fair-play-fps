#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
MAX_TRACKED_BYTES = 1_000_000
SENSITIVE_NAMES = {".env", "id_rsa", "id_ed25519"}
SENSITIVE_PATTERNS = (
    re.compile(rb"BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"gh[pousr]_[A-Za-z0-9_]{20,}"),
)


def tracked_paths() -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    )
    return [ROOT / item.decode() for item in output.split(b"\0") if item]


def main() -> int:
    findings: list[str] = []
    paths = tracked_paths()
    for path in paths:
        relative = path.relative_to(ROOT)
        data = path.read_bytes()
        if path.name in SENSITIVE_NAMES:
            findings.append(f"sensitive filename is tracked: {relative}")
        if b"\0" in data:
            findings.append(f"binary file needs provenance review: {relative}")
        if len(data) > MAX_TRACKED_BYTES:
            findings.append(f"large file needs provenance review: {relative}")
        if relative.as_posix() != "scripts/audit_public_release.py":
            for pattern in SENSITIVE_PATTERNS:
                if pattern.search(data):
                    findings.append(f"possible credential material: {relative}")

    license_text = (ROOT / "LICENSE.txt").read_text(errors="replace")
    if re.search(r"not offered under an open-source\s+license", license_text):
        findings.append("LICENSE.txt is still proprietary; select an open-source license")
    if "Joan Pujols" not in license_text:
        findings.append("LICENSE.txt must preserve Joan Pujols copyright ownership")

    if findings:
        for finding in findings:
            print(f"BLOCK {finding}")
        return 1
    print(f"PASS public-release audit ({len(paths)} tracked files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
